// Copyright 2026 Ruben Aparicio
//
// This file is part of BigMig
//
// BigMig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// BigMig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// RTG scanout line fetcher: Avalon burst reads from ram1 (f2h_sdram1) into rtg_scanout's double-buffered line buffer, one line ahead

`default_nettype none

module rtg_ddr_reader
#(
    parameter LB_AW      = 9,        // per-bank line-buffer word-addr bits (512 x 64b = 4096 B/line)
    parameter [7:0] MAX_BURST = 8'd16 // Avalon burst beats per command (16 x 8B = 128 B; ascal-safe)
)
(
    input  wire        clk,          // clk_100m
    input  wire        rst,          // active-high (sysmem reset_out, clk_100m domain)
    input  wire        enable,       // rtg_scanout_active

    // framebuffer descriptor (quasi-static, latched per frame)
    input  wire [31:0] fb_base,      // physical byte address of pixel (0,0)
    input  wire [13:0] fb_stride,    // row stride in bytes (0 => rounded to 256)
    input  wire [11:0] fb_width,     // active pixels per line
    input  wire [11:0] fb_height,    // active lines (vactive)
    input  wire  [1:0] fb_bpp_l2,    // log2(bytes/pixel): 0=8bpp,1=16bpp,2=32bpp

    // boundary toggles from the pixel domain
    input  wire        px_frame_tgl, // toggles at start of active line 0
    input  wire        px_line_tgl,  // toggles at each new line (active + blank)

    // Avalon-MM burst-read master
    output reg  [28:0] avl_address,
    output reg   [7:0] avl_burstcount,
    output reg         avl_read,
    input  wire        avl_waitrequest,
    input  wire [63:0] avl_readdata,
    input  wire        avl_readdatavalid,
    output wire [63:0] avl_writedata, // read-only master: tied 0
    output wire  [7:0] avl_byteenable,
    output wire        avl_write,

    // line buffer write port
    output reg          lb_we,
    output reg [LB_AW:0] lb_waddr,    // {bank, word[LB_AW-1:0]}
    output reg  [63:0]  lb_wdata
);

    assign avl_writedata = 64'd0;
    assign avl_byteenable = 8'hFF;
    assign avl_write     = 1'b0;

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg frame_m1, frame_m2, frame_m3;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg line_m1,  line_m2,  line_m3;
    wire frame_pulse = frame_m2 ^ frame_m3;
    wire line_pulse  = line_m2  ^ line_m3;

    // everything derived from the descriptor is resolved into registers at the load; line addresses advance incrementally
    reg [11:0] disp_line;
    reg [31:0] fb_base_l;
    reg [13:0] fb_stride_l;   // EFFECTIVE stride (auto-rounded when the guest wrote 0)
    reg [11:0] fb_width_l;
    reg [11:0] fb_height_l;
    reg  [1:0] fb_bpp_l2_l;
    reg  [9:0] beats_l;       // 64-bit beats per line, resolved
    reg        desc_ok_l;     // descriptor is non-degenerate, resolved

    reg [31:0] base_l0;       // line 0
    reg [31:0] base_l1;       // line 1
    reg [31:0] base_next;     // line (disp_line + 1): the active-line fetch target

    // bank tag {valid, generation, line}: a descriptor change bumps the generation and invalidates both banks
    reg  [1:0] desc_gen;
    reg        fill_vld0, fill_vld1;
    reg  [1:0] fill_gen0, fill_gen1;
    reg [11:0] fill_line0, fill_line1;

    reg        b0_ok, b1_ok;

    wire [15:0] in_pix_bytes = {4'd0, fb_width} << fb_bpp_l2;          // width*bpp
    /* verilator lint_off UNUSED */  // upper bits computed wide, used narrow below
    wire [15:0] in_stride_au = (in_pix_bytes + 16'd255) & 16'hFF00;    // round up to 256
    wire [15:0] in_beats     = (in_pix_bytes + 16'd7) >> 3;            // 64-bit beats/line
    /* verilator lint_on UNUSED */
    wire [13:0] in_stride    = (fb_stride != 14'd0) ? fb_stride : in_stride_au[13:0];

    localparam [10:0] LB_WORDS = (11'd1 << LB_AW);                     // LB_AW=9 -> 512
    wire  [9:0] in_beats_c   = (in_beats > {5'd0, LB_WORDS}) ? LB_WORDS[9:0] : in_beats[9:0];

    wire        in_desc_ok   = (fb_height != 12'd0) && (fb_width != 12'd0) &&
                               (in_beats_c != 10'd0);
    wire [31:0] in_base1     = fb_base + {18'd0, in_stride};           // line 1

    wire desc_changed = (fb_base   != fb_base_l)   || (in_stride != fb_stride_l) ||
                        (fb_width  != fb_width_l)  || (fb_height != fb_height_l) ||
                        (fb_bpp_l2 != fb_bpp_l2_l);
    reg  desc_changed_q;

    reg  dbg_vbl_q;   // in_vbl, one cycle late

    wire in_vbl = (disp_line >= fb_height_l);

    // load at every frame start, and early at the start of vblank so the next frame primes with it
    wire vbl_edge  = in_vbl & ~dbg_vbl_q;
    wire desc_load = frame_pulse | vbl_edge;

    wire        nxt_bank  = ~disp_line[0];
    wire [11:0] sel_line  = nxt_bank ? fill_line1 : fill_line0;
    wire        sel_ok    = nxt_bank ? b1_ok      : b0_ok;

    reg        t_valid;
    reg [11:0] t_line;
    reg        t_bank;
    reg [31:0] t_addr;
    always @(*) begin
        t_valid = 1'b0;
        t_line  = 12'd0;
        t_bank  = 1'b0;
        t_addr  = base_l0;
        if (desc_ok_l) begin
            if (!in_vbl) begin
                t_line  = disp_line + 12'd1;
                t_bank  = nxt_bank;
                t_addr  = base_next;
                t_valid = (t_line < fb_height_l) &&
                          !(sel_ok && (sel_line == t_line));
            end else begin
                if (!(b0_ok && (fill_line0 == 12'd0))) begin
                    t_valid = 1'b1; t_line = 12'd0; t_bank = 1'b0; t_addr = base_l0;
                end else if ((fb_height_l > 12'd1) && !(b1_ok && (fill_line1 == 12'd1))) begin
                    t_valid = 1'b1; t_line = 12'd1; t_bank = 1'b1; t_addr = base_l1;
                end
            end
        end
    end

    // fetch engine; S_ORPH drains a burst the watchdog gave up on (an f2sdram burst must never be broken)
    localparam [2:0] S_IDLE = 3'd0, S_ADDR = 3'd1, S_CMD = 3'd2,
                     S_DATA = 3'd3, S_DONE = 3'd4, S_ORPH = 3'd5;
    reg  [2:0] state;
    reg [11:0] cur_line;
    reg        cur_bank;
    reg  [1:0] cur_gen;        // generation this fetch was STARTED under
    reg [28:0] word_addr;      // next 64-bit-word address to command
    reg  [9:0] beats_left;     // beats remaining in the line
    reg  [7:0] beat_cnt;       // beats remaining in the current burst
    reg  [7:0] burst_now;      // beats in the burst currently being commanded
    reg [LB_AW-1:0] wr_word;   // word index within the bank

    // watchdog: a one-cycle pulse after 164 us without progress
    localparam integer WD_BITS = 14;
    reg [WD_BITS-1:0] wd_cnt;
    wire              wd_expire = (wd_cnt == {WD_BITS{1'b1}});

    wire [7:0] burst_this = (beats_left > {2'd0, MAX_BURST}) ? MAX_BURST : beats_left[7:0];

    wire req_acc = avl_read & ~avl_waitrequest;

    wire wd_hold = (state == S_IDLE) | avl_readdatavalid | req_acc;

    /* verilator lint_off UNUSED */
    wire [31:0] line_byte = t_addr;
    /* verilator lint_on UNUSED */

    always @(posedge clk) begin
        frame_m1 <= px_frame_tgl; frame_m2 <= frame_m1; frame_m3 <= frame_m2;
        line_m1  <= px_line_tgl;  line_m2  <= line_m1;  line_m3  <= line_m2;

        lb_we <= 1'b0;

        desc_changed_q <= desc_changed;
        dbg_vbl_q      <= in_vbl;

        b0_ok <= fill_vld0 & (fill_gen0 == desc_gen);
        b1_ok <= fill_vld1 & (fill_gen1 == desc_gen);

        if (wd_hold) wd_cnt <= {WD_BITS{1'b0}};
        else         wd_cnt <= wd_cnt + {{(WD_BITS-1){1'b0}}, 1'b1};  // wraps: one pulse per expiry

        if (rst) begin
            disp_line    <= 12'd0;
            desc_gen     <= 2'd0;
            fill_vld0    <= 1'b0;
            fill_vld1    <= 1'b0;
            fill_gen0    <= 2'd0;
            fill_gen1    <= 2'd0;
            fill_line0   <= 12'd0;
            fill_line1   <= 12'd0;
            b0_ok        <= 1'b0;
            b1_ok        <= 1'b0;
            wd_cnt       <= {WD_BITS{1'b0}};
            cur_gen      <= 2'd0;
            beat_cnt     <= 8'd0;
            fb_base_l    <= 32'd0;
            fb_stride_l  <= 14'd0;
            fb_width_l   <= 12'd0;
            fb_height_l  <= 12'd0;
            fb_bpp_l2_l  <= 2'd0;
            beats_l      <= 10'd0;
            desc_ok_l    <= 1'b0;
            base_l0      <= 32'd0;
            base_l1      <= 32'd0;
            base_next    <= 32'd0;
            desc_changed_q <= 1'b0;
            dbg_vbl_q    <= 1'b0;
            state        <= S_IDLE;
            avl_read     <= 1'b0;
            avl_burstcount <= 8'd1;
            avl_address  <= 29'd0;
        end else begin
            if (desc_load) begin
                fb_base_l    <= fb_base;
                fb_stride_l  <= in_stride;      // resolved (auto-round when guest = 0)
                fb_width_l   <= fb_width;
                fb_height_l  <= fb_height;
                fb_bpp_l2_l  <= fb_bpp_l2;
                beats_l      <= in_beats_c;
                desc_ok_l    <= in_desc_ok;
                base_l0      <= fb_base;        // line 0
                base_l1      <= in_base1;       // line 1
                if (desc_changed_q) desc_gen <= desc_gen + 2'd1;
            end

            if (frame_pulse) begin
                disp_line    <= 12'd0;
                base_next    <= in_base1;       // line 0 is on screen -> fetch line 1
            end else if (line_pulse) begin
                disp_line <= disp_line + 12'd1;
                base_next <= base_next + {18'd0, fb_stride_l};
            end

            case (state)
                S_IDLE: begin
                    avl_read <= 1'b0;
                    if (enable && t_valid && !frame_pulse && !line_pulse) begin
                        cur_line   <= t_line;
                        cur_bank   <= t_bank;
                        cur_gen    <= desc_gen;   // tag the fetch at its start
                        word_addr  <= line_byte[31:3];
                        beats_left <= beats_l;
                        wr_word    <= {LB_AW{1'b0}};
                        state      <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    avl_address    <= word_addr;
                    avl_burstcount <= burst_this;
                    avl_read       <= 1'b1;
                    burst_now      <= burst_this;
                    state          <= S_CMD;
                end

                S_CMD: begin
                    if (!avl_waitrequest) begin
                        avl_read      <= 1'b0;
                        beat_cnt      <= burst_now;
                        beats_left    <= beats_left - {2'd0, burst_now};
                        word_addr     <= word_addr + {21'd0, burst_now};
                        state         <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (avl_readdatavalid) begin
                        lb_we    <= 1'b1;
                        lb_waddr <= {cur_bank, wr_word};
                        lb_wdata <= avl_readdata;
                        wr_word  <= wr_word + {{(LB_AW-1){1'b0}}, 1'b1};
                        beat_cnt <= beat_cnt - 8'd1;
                        if (beat_cnt == 8'd1)
                            state <= (beats_left != 10'd0) ? S_ADDR : S_DONE;
                    end
                    else if (wd_expire) begin
                        state <= S_ORPH;
                    end
                end

                S_DONE: begin
                    if (cur_bank) begin
                        fill_line1 <= cur_line; fill_gen1 <= cur_gen; fill_vld1 <= 1'b1;
                    end else begin
                        fill_line0 <= cur_line; fill_gen0 <= cur_gen; fill_vld0 <= 1'b1;
                    end
                    state <= S_IDLE;
                end

                default: begin // S_ORPH -- drain an abandoned burst
                    if (avl_readdatavalid) begin
                        beat_cnt <= beat_cnt - 8'd1;
                        if (beat_cnt == 8'd1) state <= S_IDLE;
                    end
                    else if (wd_expire) begin
                        beat_cnt  <= 8'd0;
                        fill_vld0 <= 1'b0;   // nothing in either bank is trustworthy
                        fill_vld1 <= 1'b0;   // after a dropped burst
                        state     <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
