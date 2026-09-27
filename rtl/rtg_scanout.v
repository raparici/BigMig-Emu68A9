// Copyright 2026 Ruben Aparicio
// CRT timing generator, CLUT and pixel format conversion ported from MNT ZZ9000's video_formatter.v,
// Copyright (C) 2019-2026 Lucie L. Hartmann / MNT Research GmbH, GPL-3.0-or-later
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

// RTG framebuffer on the analog output at native resolution and a real CRT rate; runs on clk_vid with a pixel clock-enable

`default_nettype none

module rtg_scanout
#(
    parameter LB_AW = 9,     // per-bank line-buffer word-addr bits (must match reader)
    parameter [11:0] HTOTAL0 = 12'd912,   // raster until the first frame boundary
    parameter [11:0] VTOTAL0 = 12'd525
)
(
    input  wire        clk,
    input  wire        rst,           // active-high, clk domain
    input  wire        ce,            // pixel clock-enable (clk_114 / divider)

    // timing, in pixels; latched at the frame boundary
    input  wire [11:0] htotal,        // total pixels per line
    input  wire [11:0] hact,          // active pixels per line (= display width)
    input  wire [11:0] hs_start,
    input  wire [11:0] hs_end,
    input  wire [11:0] vtotal,        // total lines per frame
    input  wire [11:0] vact,          // active lines per frame
    input  wire [11:0] vs_start,
    input  wire [11:0] vs_end,
    input  wire        hs_pol,        // 0: sync-region drives internal HIGH (pin inverts)
    input  wire        vs_pol,

    input  wire  [1:0] cmode,         // 0=8bpp CLUT, 1=16bpp, 2=32bpp
    input  wire        fmt_1555,      // 16bpp: 0=RGB565, 1=RGB1555
    input  wire        fmt_swap,      // FB_FORMAT[5] byte swap, 16bpp only

    // line buffer write port (rtg_ddr_reader)
    input  wire        lb_wclk,
    input  wire        lb_we,
    input  wire [LB_AW:0] lb_waddr,   // {bank, word}
    input  wire [63:0] lb_wdata,

    // CLUT, snooped from the fb_pal bus
    input  wire        pal_clk,
    input  wire        pal_wr,
    input  wire  [7:0] pal_a,
    input  wire [23:0] pal_d,

    // pointer sprite write bus (rtg.v)
    input  wire        spr_wclk,
    input  wire        spr_wr,
    input  wire  [8:0] spr_waddr,
    input  wire [15:0] spr_wdata,

    output reg  [23:0] rgb,
    output reg         hs,
    output reg         vs,
    output reg         de,

    // boundary toggles to the reader
    output reg         frame_tgl,
    output reg         line_tgl
);

    // two banks, dual clock
    reg [63:0] linebuf [0:(2<<LB_AW)-1];
    always @(posedge lb_wclk) if (lb_we) linebuf[lb_waddr] <= lb_wdata;

    reg [23:0] clut [0:255];
    always @(posedge pal_clk) if (pal_wr) clut[pal_a] <= pal_d;

    localparam [11:0] HV_MIN = 12'd4;   // smallest total a counter can still wrap on

    // the raster and the format are latched at the frame boundary, where the reader latches its descriptor
    reg [11:0] htotal_r   = HTOTAL0;
    reg [11:0] hact_r     = 12'd0;
    reg [11:0] hs_start_r = HTOTAL0;
    reg [11:0] hs_end_r   = HTOTAL0;
    reg [11:0] vtotal_r   = VTOTAL0;
    reg [11:0] vact_r     = 12'd0;
    reg [11:0] vs_start_r = VTOTAL0;
    reg [11:0] vs_end_r   = VTOTAL0;
    reg  [1:0] cmode_r    = 2'd2;
    reg        fmt_1555_r = 1'b0;
    reg        fmt_swap_r = 1'b0;

    reg [11:0] counter_x;
    reg [11:0] counter_y;
    wire       eol   = (counter_x >= (htotal_r - 12'd1)); // end of line
    wire       eof   = (counter_y >= (vtotal_r - 12'd1)); // last line of frame

    wire       load  = ce & eol & eof;

    always @(posedge clk) begin
        if (rst || load) begin
            htotal_r   <= (htotal >= HV_MIN) ? htotal : htotal_r;
            vtotal_r   <= (vtotal >= HV_MIN) ? vtotal : vtotal_r;
            hact_r     <= hact;
            hs_start_r <= hs_start;
            hs_end_r   <= hs_end;
            vact_r     <= vact;
            vs_start_r <= vs_start;
            vs_end_r   <= vs_end;
            cmode_r    <= cmode;
            fmt_1555_r <= fmt_1555;
            fmt_swap_r <= fmt_swap;
        end
        if (rst) begin
            counter_x <= 12'd0;
            counter_y <= 12'd0;
            frame_tgl <= 1'b0;
            line_tgl  <= 1'b0;
        end else if (ce) begin
            if (eol) begin
                counter_x <= 12'd0;
                if (eof) begin
                    counter_y <= 12'd0;
                    frame_tgl <= ~frame_tgl;   // start of active line 0 (next ce)
                end else begin
                    counter_y <= counter_y + 12'd1;
                    line_tgl  <= ~line_tgl;     // every line boundary except the frame wrap
                end
            end else begin
                counter_x <= counter_x + 12'd1;
            end
        end
    end

    wire de0 = (counter_x < hact_r) && (counter_y < vact_r);
    wire hs0 = (((counter_x >= hs_start_r) && (counter_x < hs_end_r)) ? 1'b1 : 1'b0) ^ hs_pol;
    wire vs0 = (((counter_y >= vs_start_r) && (counter_y < vs_end_r)) ? 1'b1 : 1'b0) ^ vs_pol;

    wire disp_bank = counter_y[0];
    reg [LB_AW-1:0] word_idx;
    always @(*) begin
        case (cmode_r)
            2'd0:    word_idx = counter_x[LB_AW+2:3]; // 8bpp : 8 px / 64b word
            2'd1:    word_idx = counter_x[LB_AW+1:2]; // 16bpp: 4 px / word
            default: word_idx = counter_x[LB_AW:1];   // 32bpp: 2 px / word
        endcase
    end
    wire [LB_AW:0] rd_addr = {disp_bank, word_idx};

    reg [63:0] rd_q;
    always @(posedge clk) if (ce) rd_q <= linebuf[rd_addr];

    reg [2:0] subsel1;
    always @(posedge clk) if (ce) subsel1 <= counter_x[2:0];

    reg de1,de2,de3, hs1,hs2,hs3, vs1,vs2,vs3;
    always @(posedge clk) begin
        if (rst) begin
            de1<=1'b0; de2<=1'b0; de3<=1'b0;
            hs1<=1'b0; hs2<=1'b0; hs3<=1'b0;
            vs1<=1'b0; vs2<=1'b0; vs3<=1'b0;
        end else if (ce) begin
            de1<=de0; de2<=de1; de3<=de2;
            hs1<=hs0; hs2<=hs1; hs3<=hs2;
            vs1<=vs0; vs2<=vs1; vs3<=vs2;
        end
    end

    reg  [7:0] pix8;
    reg [15:0] pix16;
    /* verilator lint_off UNUSED */
    reg [31:0] pix32;   // [31:24] = alpha, dropped (XRGB8888)
    /* verilator lint_on UNUSED */
    always @(posedge clk) if (ce) begin
        pix8  <= rd_q[{subsel1,      3'b000} +: 8];  // byte  subsel1[2:0]
        pix16 <= rd_q[{subsel1[1:0], 4'b0000} +: 16]; // half  subsel1[1:0]
        pix32 <= rd_q[{subsel1[0],   5'b00000} +: 32];// dword subsel1[0]
    end

    reg [23:0] pal_q;
    always @(posedge clk) if (ce) pal_q <= clut[pix8];

    wire [15:0] pix16_s = fmt_swap_r ? {pix16[7:0], pix16[15:8]} : pix16;

    reg [23:0] exp16, exp32;
    always @(posedge clk) if (ce) begin
        if (fmt_1555_r)
            exp16 <= {pix16_s[14:10],pix16_s[14:12], pix16_s[9:5],pix16_s[9:7], pix16_s[4:0],pix16_s[4:2]};
        else
            exp16 <= {pix16_s[15:11],pix16_s[15:13], pix16_s[10:5],pix16_s[10:9], pix16_s[4:0],pix16_s[4:2]};
        exp32 <= pix32[23:0];  // XRGB8888, alpha dropped
    end

    reg [1:0] cmode2, cmode3;
    always @(posedge clk) if (ce) begin cmode2<=cmode_r; cmode3<=cmode2; end

    wire        spr_on;
    wire [23:0] spr_rgb;
    rtg_sprite_overlay u_sprite
    (
        .wclk        (spr_wclk),
        .wr          (spr_wr),
        .waddr       (spr_waddr),
        .wdata       (spr_wdata),
        .clk         (clk),
        .rst         (rst),
        .ce          (ce),
        .frame_latch (load),
        .px_x        (counter_x),
        .px_y        (counter_y),
        .spr_on      (spr_on),
        .spr_rgb     (spr_rgb)
    );

    always @(posedge clk) begin
        if (rst) begin
            rgb <= 24'd0; de <= 1'b0; hs <= 1'b0; vs <= 1'b0;
        end else if (ce) begin
            if (!de3) rgb <= 24'd0;
            else if (spr_on) rgb <= spr_rgb;   // scan-out sprite over fb pixel
            else case (cmode3)
                2'd0:    rgb <= pal_q;
                2'd1:    rgb <= exp16;
                default: rgb <= exp32;
            endcase
            de <= de3;
            hs <= hs3;
            vs <= vs3;
        end
    end

endmodule

`default_nettype wire
