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

// triangle setup unit in front of a RasterIX command parser

module bm_setup_unit #(
    parameter LEAN = 0
) (
    input  wire          clk,
    input  wire          resetn,
    input  wire          swap_en,
    input  wire [11:0]   fe_set, fe_clr,
    // the command stream from the DMA; tuser = the last payload word of a list chunk
    input  wire          s_tvalid, output wire s_tready, input wire s_tlast, input wire s_tuser, input wire [31:0] s_tdata,
    // to the render core
    output wire          m_tvalid, input wire m_tready, output wire m_tlast, output wire [31:0] m_tdata,
    // to the list DMA: a chunk ended (with or without a LINK), and the LINK's target
    output reg           chunk_done, output reg chunk_link, output reg [31:0] link_addr, output reg [27:0] link_bytes,
    // the setup engine (bm_setup_engine): records, state, hand-off, output buffer writes, events
    output wire          e_rec_req, input wire e_rec_gnt,
    output wire          e_rec_we, output wire [6:0] e_rec_waddr, output wire [31:0] e_rec_wdata,
    output wire [31:0]   e_yoff, e_yend, e_resx, e_resx16, e_scx0, e_scy0, e_scx1, e_scy1,
    output wire          e_scissor, e_tmu0,
    output wire          e_in_avail, output wire [1:0] e_in_slot, output wire e_in_soon, input wire e_in_take,
    output wire          e_ob_free_avail, output wire [1:0] e_ob_free_slot, input wire e_ob_alloc,
    input  wire          e_ob_we, input wire [7:0] e_ob_waddr, input wire [31:0] e_ob_wdata,
    input  wire          e_ev_drop, input wire e_ev_done, input wire [1:0] e_ev_slot,
    input  wire          e_ev_rec_free, input wire [1:0] e_ev_rec,
    input  wire          e_busy,
    // status and counters
    output wire          pending,          // a triangle is captured, in the engine or not yet streamed
    input  wire          err_clr,          // the register block's CTRL.ERR_CLR
    output reg           err_flag,         // sticky: an err_* counter moved since the last err_clr
    output reg  [31:0]   cnt_tv_in, cnt_tv_out, cnt_tv_drop, cnt_fwd, err_noraw, err_count, err_op, err_trunc,
    output reg  [31:0]   cnt_out_stall,
    output reg  [31:0]   cnt_nop
);
    wire [31:0] w = swap_en ? {s_tdata[7:0], s_tdata[15:8], s_tdata[23:16], s_tdata[31:24]} : s_tdata;
    reg [15:0] sc_x0, sc_y0, sc_x1, sc_y1, yoff, resx, rows;
    reg        fe_sc, fe_t0;
    wire [31:0] st_yoff = {16'd0, yoff}, st_yend = {16'd0, yoff} + {16'd0, rows}, st_resx = {16'd0, resx};
    wire [31:0] st_resx16 = {12'd0, resx, 4'd0};
    wire [31:0] st_scx0 = {12'd0, sc_x0, 4'd0}, st_scy0 = {12'd0, sc_y0, 4'd0};
    wire [31:0] st_scx1 = {12'd0, sc_x1, 4'd0}, st_scy1 = {12'd0, sc_y1, 4'd0};
    reg  [1:0] rs [0:3];                // 0 free, 1 filling, 2 ready, 3 in the engine
    reg  [1:0] rfill, rnext;            // the slot being filled / the oldest ready one
    reg        rtl  [0:3];              // the record's last word carried tlast
    reg  [1:0] obs [0:3];               // output slots: 0 free, 1 allocated, 2 done
    reg        obd [0:3];               // dropped
    reg        obtl [0:3];
    reg  [1:0] oalloc, ostream;         // the next slot to allocate / to stream
    localparam P_HDR = 0, P_FWD = 1, P_REC = 2, P_SKIP = 3, P_LINK = 4, P_DRAIN = 5;
    reg  [2:0]  ps;
    reg  [27:0] pcnt;                   // payload words left
    reg  [4:0]  rpos;
    reg         fwd_cfg; reg [4:0] fwd_reg;
    reg         linkseen;
    wire [3:0]  op = w[31:28];
    wire        ring_free = (rs[rfill] == 2'd0);
    wire        in_soon = (ps == P_REC);
    wire        eng_busy = e_busy;
    reg         obusy;                  // any output slot not free
    wire        rbusy = (rs[0] != 0) || (rs[1] != 0) || (rs[2] != 0) || (rs[3] != 0);
    assign pending = rbusy || eng_busy || obusy;
    reg         acc_word, pres_word;
    always @(*) begin
        acc_word = 1'b0; pres_word = 1'b0;
        case (ps)
            P_HDR: begin
                if (op == 4'd6)      acc_word = ring_free || (w[7:0] != 8'd18);      // capture (or skip a bad count)
                else if (op == 4'd7) acc_word = 1'b1;                                // LINK
                else if (op >= 4'd8 || op == 4'd0) acc_word = 1'b1;                  // dropped (unknown) / NOP
                else begin pres_word = !pending; acc_word = !pending && m_tready; end
            end
            P_FWD:   begin pres_word = 1'b1; acc_word = m_tready; end
            P_REC:   acc_word = e_rec_gnt;              // the record RAM's write port (shared engine: granted)
            P_SKIP, P_LINK, P_DRAIN: acc_word = 1'b1;
            default: acc_word = 1'b0;
        endcase
    end
    assign s_tready = acc_word;
    wire take = s_tvalid && acc_word;
    // payload length of a forwarded command (header excluded): RasterIX's own rules (CommandParser.v)
    function [27:0] plen(input [31:0] h);
        case (h[31:28])
            4'd1: plen = 28'd1;
            4'd3: plen = {20'd0, h[9:2]};
            4'd4: plen = {21'd0, h[8:2]};
            4'd5: plen = {9'd0, h[18:0]};
            default: plen = 28'd0;
        endcase
    endfunction
    // the forwarded word, with the FEATURE_ENABLE override applied
    wire        is_fe_payload = (ps == P_FWD) && fwd_cfg && (fwd_reg == 5'd0);
    wire [31:0] fwd_data = is_fe_payload ? ((w & ~{20'd0, fe_clr}) | {20'd0, fe_set}) : w;
    wire        e_take = e_in_take, e_alloc = e_ob_alloc, ob_we = e_ob_we, ev_drop = e_ev_drop, ev_done = e_ev_done;
    wire        ev_rec_free = e_ev_rec_free;
    wire [7:0]  ob_waddr = e_ob_waddr; wire [31:0] ob_wdata = e_ob_wdata; wire [1:0] ev_slot = e_ev_slot, ev_rec = e_ev_rec;
    wire        r_we = take && (ps == P_REC);
    assign e_rec_we = r_we; assign e_rec_waddr = {rfill, rpos}; assign e_rec_wdata = w;
    assign e_rec_req = (ps == P_REC) && s_tvalid;
    assign e_yoff = st_yoff; assign e_yend = st_yend; assign e_resx = st_resx; assign e_resx16 = st_resx16;
    assign e_scx0 = st_scx0; assign e_scy0 = st_scy0; assign e_scx1 = st_scx1; assign e_scy1 = st_scy1;
    assign e_scissor = fe_sc; assign e_tmu0 = fe_t0;
    assign e_in_avail = (rs[rnext] == 2'd2); assign e_in_slot = rnext; assign e_in_soon = in_soon;
    assign e_ob_free_avail = (obs[oalloc] == 2'd0); assign e_ob_free_slot = oalloc;
    // lean counters: a counter not built stays 0, an error counter is a sticky flag
    function [31:0] inc(input [31:0] v); inc = LEAN ? 32'd0 : v + 32'd1; endfunction
    function [31:0] incerr(input [31:0] v); incerr = LEAN ? 32'd1 : v + 32'd1; endfunction
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] ob [0:255];
    always @(posedge clk) if (ob_we) ob[ob_waddr] <= ob_wdata;
    // streamer: header, then words 0..38 of the slot (the RAM is read one clock ahead)
    reg        st_on; reg [5:0] st_pos; reg [31:0] st_q; reg st_qv;
    wire       slot_ready = (obs[ostream] == 2'd2);
    // output mux: the streamer owns the output while a slot streams; otherwise forwarded words
    wire [5:0] st_rd = (st_on && st_qv && m_tready) ? st_pos + 6'd1 : st_pos;
    always @(posedge clk) st_q <= ob[{ostream, st_rd}];
    assign m_tvalid = st_on ? st_qv : (pres_word && s_tvalid);
    assign m_tdata  = st_on ? (st_pos == 6'd63 ? 32'h3000009C : st_q) : fwd_data;
    assign m_tlast  = st_on ? (st_pos == 6'd38 && obtl[ostream]) : s_tlast;
    integer i;
    always @(posedge clk) begin
        chunk_done <= 1'b0;
        if (!resetn) begin
            ps <= P_HDR; pcnt <= 0; rpos <= 0; rfill <= 0; rnext <= 0; oalloc <= 0; ostream <= 0; obusy <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin rs[i] <= 0; obs[i] <= 0; obd[i] <= 0; end
            sc_x0 <= 0; sc_y0 <= 0; sc_x1 <= 16'hFFFF; sc_y1 <= 16'hFFFF; yoff <= 0; resx <= 16'd640; rows <= 16'd24;
            fe_sc <= 0; fe_t0 <= 0; linkseen <= 0; fwd_cfg <= 0;
            st_on <= 0; st_qv <= 0; st_pos <= 0;
            cnt_tv_in <= 0; cnt_tv_out <= 0; cnt_tv_drop <= 0; cnt_fwd <= 0; err_noraw <= 0; err_count <= 0; err_op <= 0;
            err_trunc <= 0; cnt_out_stall <= 0; cnt_nop <= 0; err_flag <= 1'b0;
        end else begin
            if (err_clr) err_flag <= 1'b0;                          // (an error in the same clock wins: set below)
            // ---- parser
            if (take) begin
                case (ps)
                    P_HDR: begin
                        if (op == 4'd6) begin
                            if (w[7:0] != 8'd18) begin
                                err_count <= incerr(err_count); err_flag <= 1'b1; pcnt <= {20'd0, w[7:0]}; ps <= (w[7:0] != 0) ? P_SKIP : P_HDR;
                            end else begin
                                if (!w[16]) begin err_noraw <= incerr(err_noraw); err_flag <= 1'b1; end
                                rs[rfill] <= 2'd1; rpos <= 0; pcnt <= 28'd18; ps <= P_REC;
                            end
                        end else if (op == 4'd7) begin
                            link_bytes <= w[27:0]; ps <= P_LINK;
                        end else if (op >= 4'd8) begin
                            err_op <= incerr(err_op); err_flag <= 1'b1;
                        end else if (op == 4'd0) begin
                            cnt_nop <= inc(cnt_nop);         // a NOP has no effect: dropped (it would cost the core a drain)
                        end else begin
                            cnt_fwd <= inc(cnt_fwd);
                            fwd_cfg <= (op == 4'd1); fwd_reg <= w[4:0];
                            pcnt <= plen(w); ps <= (plen(w) != 0) ? P_FWD : P_HDR;
                        end
                    end
                    P_FWD: begin
                        if (fwd_cfg) begin
                            case (fwd_reg)
                                5'd0: begin fe_sc <= fwd_data[5]; fe_t0 <= fwd_data[6]; end
                                5'd6: begin sc_x0 <= w[15:0]; sc_y0 <= w[31:16]; end
                                5'd7: begin sc_x1 <= w[15:0] + sc_x0; sc_y1 <= w[31:16] + sc_y0; end
                                5'd8: yoff <= w[31:16];
                                5'd9: begin resx <= w[15:0]; rows <= w[31:16]; end
                                default: ;
                            endcase
                        end
                        pcnt <= pcnt - 1; if (pcnt == 28'd1) ps <= P_HDR;
                    end
                    P_REC: begin
                        rpos <= rpos + 1; pcnt <= pcnt - 1; rtl[rfill] <= s_tlast;
                        if (pcnt == 28'd1) begin rs[rfill] <= 2'd2; rfill <= rfill + 2'd1; ps <= P_HDR; cnt_tv_in <= cnt_tv_in + 1; end
                    end
                    P_SKIP: begin pcnt <= pcnt - 1; if (pcnt == 28'd1) ps <= P_HDR; end
                    P_LINK: begin link_addr <= w; linkseen <= 1'b1; ps <= s_tuser ? P_HDR : P_DRAIN; end
                    P_DRAIN: ;                                              // the rest of a chunk after a LINK
                    default: ;
                endcase
                if (s_tuser) begin
                    // the chunk's last payload word: report, and resynchronise the parser on the next chunk
                    chunk_done <= 1'b1; chunk_link <= linkseen || (ps == P_LINK);
                    linkseen <= 1'b0;
                    if (ps == P_LINK) link_addr <= w;
                    if ((ps == P_FWD && pcnt != 28'd1) || (ps == P_REC && pcnt != 28'd1) || (ps == P_SKIP && pcnt != 28'd1) ||
                        (ps == P_HDR && op == 4'd6 && w[7:0] != 0) || (ps == P_HDR && op == 4'd7) ||
                        (ps == P_HDR && plen(w) != 0 && op < 4'd8 && op != 4'd6 && op != 4'd7)) begin
                        err_trunc <= incerr(err_trunc); err_flag <= 1'b1;
                        if (ps == P_REC || (ps == P_HDR && op == 4'd6)) rs[rfill] <= 2'd0;   // a record cut short: dropped
                    end
                    ps <= P_HDR;
                end
            end
            // ---- the engine takes / frees records, allocates output slots
            if (e_take) begin rs[rnext] <= 2'd3; rnext <= rnext + 2'd1; end
            if (ev_rec_free) rs[ev_rec] <= 2'd0;
            if (e_alloc) begin obs[oalloc] <= 2'd1; obd[oalloc] <= 1'b0; obtl[oalloc] <= rtl[rnext]; oalloc <= oalloc + 2'd1; end
            if (ev_drop) obd[ev_slot] <= 1'b1;
            if (ev_done) obs[ev_slot] <= 2'd2;
            // ---- streamer
            if (!st_on) begin
                if (slot_ready) begin
                    if (obd[ostream] || (ev_drop && ev_slot == ostream)) begin
                        obs[ostream] <= 2'd0; ostream <= ostream + 2'd1; cnt_tv_drop <= inc(cnt_tv_drop);
                    end else begin
                        st_on <= 1'b1; st_pos <= 6'd63; st_qv <= 1'b1;       // 63 = the header word
                    end
                end
            end else begin
                if (m_tready && st_qv) begin
                    if (st_pos == 6'd38) begin
                        st_on <= 1'b0; obs[ostream] <= 2'd0; ostream <= ostream + 2'd1; cnt_tv_out <= cnt_tv_out + 1;
                    end else st_pos <= st_pos + 6'd1;     // 63 + 1 wraps to 0
                end else if (!m_tready) cnt_out_stall <= cnt_out_stall + 1;
            end
            obusy <= (obs[0] != 0) || (obs[1] != 0) || (obs[2] != 0) || (obs[3] != 0) || e_alloc;
        end
    end
endmodule
