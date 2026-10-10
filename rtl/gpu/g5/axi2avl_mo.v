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

// AXI4 -> Avalon-MM adapter with several read bursts outstanding

`timescale 1ns / 1ps
module axi2avl_mo #(
    parameter ID_WIDTH = 8,
    parameter ADDR_WIDTH = 32,
    parameter AVL_AW = ADDR_WIDTH - 3,
    parameter BCW = 9,              // Avalon burstcount width (bursts up to 256 beats need 9 bits)
    parameter NOUT = 8,             // read bursts outstanding: AR accepted, last R beat not yet taken
    parameter RF_LG = 8,            // R FIFO depth in beats, lg
    parameter BQ_LG = 2,            // B queue depth, lg
    parameter CSWAP = 0
) (
    input  wire                     aclk,
    input  wire                     resetn,
    input  wire [7 : 0]             nout_limit,

    input  wire [ID_WIDTH - 1 : 0]  s_awid,
    input  wire [ADDR_WIDTH - 1 : 0] s_awaddr,
    input  wire                     s_awuser,
    input  wire [7 : 0]             s_awlen,
    input  wire                     s_awvalid,
    output wire                     s_awready,
    input  wire [63 : 0]            s_wdata,
    input  wire [7 : 0]             s_wstrb,
    input  wire                     s_wlast,
    input  wire                     s_wvalid,
    output wire                     s_wready,
    output wire [ID_WIDTH - 1 : 0]  s_bid,
    output wire [1 : 0]             s_bresp,
    output wire                     s_bvalid,
    input  wire                     s_bready,
    input  wire [ID_WIDTH - 1 : 0]  s_arid,
    input  wire [ADDR_WIDTH - 1 : 0] s_araddr,
    input  wire                     s_aruser,
    input  wire [7 : 0]             s_arlen,
    input  wire                     s_arvalid,
    output wire                     s_arready,
    output wire [ID_WIDTH - 1 : 0]  s_rid,
    output wire [63 : 0]            s_rdata,
    output wire [1 : 0]             s_rresp,
    output wire                     s_rlast,
    output wire                     s_rvalid,
    input  wire                     s_rready,

    output reg  [AVL_AW - 1 : 0]    avl_address,
    output reg  [BCW - 1 : 0]       avl_burstcount,
    input  wire                     avl_waitrequest,
    input  wire [63 : 0]            avl_readdata,
    input  wire                     avl_readdatavalid,
    output reg                      avl_read,
    output wire [63 : 0]            avl_writedata,
    output wire [7 : 0]             avl_byteenable,
    output wire                     avl_write,

    output wire [7 : 0]             rd_outstanding,
    output wire                     idle
);
    localparam RF_D  = 1 << RF_LG;
    localparam IQ_LG = (NOUT > 1) ? $clog2(NOUT) : 1;
    localparam IQ_D  = 1 << IQ_LG;
    localparam BQ_D  = 1 << BQ_LG;
    localparam [1 : 0] S_IDLE = 2'd0, S_RD = 2'd1, S_WR = 2'd2;

    reg  [1 : 0]                st;
    reg                         last_was_rd;

    // ---------------------------------------------------------------- issued read bursts, in order
    reg  [ID_WIDTH - 1 : 0]     iq_id  [0 : IQ_D - 1];
    reg  [7 : 0]                iq_len [0 : IQ_D - 1];
    reg  [IQ_LG : 0]            iq_wp, iq_rp;
    wire [IQ_LG : 0]            iq_n = iq_wp - iq_rp;
    wire [IQ_LG - 1 : 0]        iq_h = iq_rp[IQ_LG - 1 : 0];

    reg  [63 : 0]               rf [0 : RF_D - 1];
    reg  [RF_LG : 0]            rf_wp, rf_rp;
    reg  [63 : 0]               rq;
    reg                         rqv;
    reg  [RF_LG + 1 : 0]        reserved;       // beats of accepted bursts not yet taken on R
    reg  [7 : 0]                rbeat;

    // ---------------------------------------------------------------- B queue
    reg  [ID_WIDTH - 1 : 0]     bq [0 : BQ_D - 1];
    reg  [BQ_LG : 0]            bq_wp, bq_rp;
    wire                        bq_full = (bq_wp - bq_rp) == BQ_D[BQ_LG : 0];
    reg  [ID_WIDTH - 1 : 0]     wid;

    function [63 : 0] bswap16(input [63 : 0] v);
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                bswap16[k * 16 +: 16] = { v[k * 16 +: 8], v[k * 16 + 8 +: 8] };
        end
    endfunction
    function [63 : 0] cswapf(input [63 : 0] v);
        cswapf = bswap16(v);
    endfunction
    wire                        aw_sw = (CSWAP != 0) && s_awuser;
    wire                        ar_sw = (CSWAP != 0) && s_aruser;
    reg                         wsw;            // the write burst in progress is swapped
    reg  [IQ_D - 1 : 0]         iq_sw;          // per issued read burst: swapped on R

    wire [8 : 0]                ar_beats = {1'b0, s_arlen} + 9'd1;
    wire [7 : 0]                lim = (nout_limit == 0) ? 8'd1 : ((nout_limit > NOUT[7 : 0]) ? NOUT[7 : 0] : nout_limit);
    wire                        ar_ok = ({ {(7 - IQ_LG){1'b0}}, iq_n } < lim)
                                        && (({1'b0, reserved} + { {(RF_LG - 7){1'b0}}, ar_beats }) <= RF_D);
    wire                        aw_ok = s_awvalid && !bq_full;
    wire                        take_ar = (st == S_IDLE) && s_arvalid && ar_ok && !(aw_ok && last_was_rd);
    wire                        take_aw = (st == S_IDLE) && aw_ok && !take_ar;

    assign s_arready      = take_ar;
    assign s_awready      = take_aw;
    assign avl_write      = (st == S_WR) && s_wvalid;
    assign s_wready       = (st == S_WR) && !avl_waitrequest;
    assign avl_writedata  = ((CSWAP != 0) && wsw) ? cswapf(s_wdata) : s_wdata;
    assign avl_byteenable = s_wstrb;

    wire                        r_pop = rqv && s_rready;
    wire                        r_last = (rbeat == iq_len[iq_h]);
    wire                        rf_load = (rf_wp != rf_rp) && (!rqv || r_pop);
    assign s_rvalid = rqv;
    assign s_rdata  = ((CSWAP != 0) && iq_sw[iq_h]) ? cswapf(rq) : rq;
    assign s_rid    = iq_id[iq_h];
    assign s_rlast  = rqv && r_last;
    assign s_rresp  = 2'b00;

    assign s_bvalid = bq_wp != bq_rp;
    assign s_bid    = bq[bq_rp[BQ_LG - 1 : 0]];
    assign s_bresp  = 2'b00;

    assign rd_outstanding = { {(7 - IQ_LG){1'b0}}, iq_n };
    assign idle = (st == S_IDLE) && (iq_n == 0) && !s_bvalid;

    always @(posedge aclk)
    begin
        if (!resetn)
        begin
            st <= S_IDLE;
            avl_read <= 1'b0;
            last_was_rd <= 1'b0;
            iq_wp <= 0; iq_rp <= 0;
            rf_wp <= 0; rf_rp <= 0; rqv <= 1'b0;
            reserved <= 0; rbeat <= 0;
            bq_wp <= 0; bq_rp <= 0;
        end
        else
        begin
            case (st)
            S_IDLE:
                if (take_ar)
                begin
                    avl_address    <= s_araddr[AVL_AW + 2 : 3];
                    avl_burstcount <= ar_beats[BCW - 1 : 0];
                    avl_read       <= 1'b1;
                    st             <= S_RD;
                    last_was_rd    <= 1'b1;
                    iq_id[iq_wp[IQ_LG - 1 : 0]]  <= s_arid;
                    iq_sw[iq_wp[IQ_LG - 1 : 0]]  <= ar_sw;
                    iq_len[iq_wp[IQ_LG - 1 : 0]] <= s_arlen;
                    iq_wp <= iq_wp + 1'b1;
                end
                else if (take_aw)
                begin
                    avl_address    <= s_awaddr[AVL_AW + 2 : 3];
                    avl_burstcount <= {1'b0, s_awlen} + 1'b1;
                    wid            <= s_awid;
                    wsw            <= aw_sw;
                    st             <= S_WR;
                    last_was_rd    <= 1'b0;
                end
            S_RD:
                if (!avl_waitrequest)
                begin
                    avl_read <= 1'b0;
                    st <= S_IDLE;
                end
            S_WR:
                if (s_wvalid && !avl_waitrequest && s_wlast)
                begin
                    bq[bq_wp[BQ_LG - 1 : 0]] <= wid;
                    bq_wp <= bq_wp + 1'b1;
                    st <= S_IDLE;
                end
            default:
                st <= S_IDLE;
            endcase

            if (s_bvalid && s_bready)
                bq_rp <= bq_rp + 1'b1;

            // read data: into the FIFO, then the head register
            if (avl_readdatavalid)
            begin
                rf[rf_wp[RF_LG - 1 : 0]] <= avl_readdata;
                rf_wp <= rf_wp + 1'b1;
            end
            if (rf_load)
            begin
                rq <= rf[rf_rp[RF_LG - 1 : 0]];
                rf_rp <= rf_rp + 1'b1;
                rqv <= 1'b1;
            end
            else if (r_pop)
                rqv <= 1'b0;

            if (r_pop)
            begin
                if (r_last)
                begin
                    rbeat <= 0;
                    iq_rp <= iq_rp + 1'b1;
                end
                else
                    rbeat <= rbeat + 1'b1;
            end
            reserved <= reserved + (take_ar ? { {(RF_LG - 7){1'b0}}, ar_beats } : {(RF_LG + 2){1'b0}})
                                 - (r_pop ? { {(RF_LG + 1){1'b0}}, 1'b1 } : {(RF_LG + 2){1'b0}});
        end
    end
endmodule
