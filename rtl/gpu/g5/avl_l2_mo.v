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

// texture cache: direct-mapped, 32-byte lines, non-blocking, in order

`timescale 1ns / 1ps
module avl_l2_mo #(
    parameter SIZE_KB = 32,
    parameter AW = 29,                  // word (8-byte) address width
    parameter BCW = 9,
    parameter [AW - 1 : 0] WIN_LO = 0,
    parameter [AW - 1 : 0] WIN_HI = {AW{1'b1}},
    parameter SNOOP = 1,
    parameter BYPASS_TAG = 1,
    parameter RQ_LG = 4,                // return queue: reads past L and not yet returned, lg
    parameter MF_LG = 8                 // master read data FIFO, beats, lg
) (
    input  wire                     clk,
    input  wire                     resetn,
    input  wire                     inv_all,
    input  wire                     off,            // run-time: nothing is cacheable (pass-through)
    output reg  [31 : 0]            hits,
    output reg  [31 : 0]            misses,

    input  wire [AW - 1 : 0]        s_address,
    input  wire                     s_read,
    input  wire                     s_write,
    input  wire [BCW - 1 : 0]       s_burstcount,
    input  wire [63 : 0]            s_writedata,
    input  wire [7 : 0]             s_byteenable,
    output wire                     s_waitrequest,
    output wire [63 : 0]            s_readdata,
    output reg                      s_readdatavalid,

    output wire [AW - 1 : 0]        m_address,
    output wire                     m_read,
    output wire                     m_write,
    output wire [BCW - 1 : 0]       m_burstcount,
    output wire [63 : 0]            m_writedata,
    output wire [7 : 0]             m_byteenable,
    input  wire                     m_waitrequest,
    input  wire [63 : 0]            m_readdata,
    input  wire                     m_readdatavalid,

    output wire                     idle
);
    localparam LINES  = SIZE_KB * 1024 / 32;
    localparam IW     = $clog2(LINES);
    localparam TW     = AW - 2 - IW;
    localparam RQ_D   = 1 << RQ_LG;
    localparam MF_D   = 1 << MF_LG;
    localparam [1 : 0] T_HIT = 2'd0, T_MISS = 2'd1, T_PASS = 2'd2;

    reg  [63 : 0]               data [0 : LINES * 4 - 1];
    (* ramstyle = "M10K, no_rw_check" *)
    reg  [TW : 0]               tags [0 : LINES - 1];       // {valid, tag}: an M10K (see "the tag RAM" below)
    reg  [TW : 0]               tag_q;

    reg                         flushing, flush_pend;
    reg  [IW : 0]               fl_idx;

    // ---------------------------------------------------------------- L stage
    reg                         lv, l_rd, l_wr, l_cache, l_inv, l_first;
    reg  [AW - 1 : 0]           l_addr;
    reg  [BCW - 1 : 0]          l_bc;
    reg  [63 : 0]               l_wdata;
    reg  [7 : 0]                l_be;
    reg                         byp_v;
    reg  [IW - 1 : 0]           byp_idx;
    reg  [TW : 0]               byp_val;
    // write burst tracking at the slave side (Avalon gives the address with the first beat only)
    reg  [BCW - 1 : 0]          w_left;
    reg  [AW - 1 : 0]           w_addr;

    // ---------------------------------------------------------------- return queue + master read FIFO
    reg  [1 : 0]                rq_t   [0 : RQ_D - 1];
    reg  [IW - 1 : 0]           rq_idx [0 : RQ_D - 1];
    reg  [BCW - 1 : 0]          rq_bc  [0 : RQ_D - 1];
    reg  [RQ_LG : 0]            rq_wp, rq_rp;
    reg  [BCW - 1 : 0]          r_beat;
    reg  [63 : 0]               mf [0 : MF_D - 1];
    reg  [MF_LG : 0]            mf_wp, mf_rp;
    reg  [63 : 0]               mf_q;
    reg                         mfv;
    reg  [MF_LG + 1 : 0]        mf_res;                     // beats of issued master reads not yet consumed
    reg  [63 : 0]               o_ram, o_mf;
    reg                         o_sel_ram;

    // ---------------------------------------------------------------- C: what arrives
    wire                        s_cmd   = s_read || s_write;
    wire                        s_first = (w_left == 0);
    wire [AW - 1 : 0]           c_addr  = s_write ? (s_first ? s_address : w_addr) : s_address;
    wire                        c_inwin = (c_addr >= WIN_LO) && (c_addr < WIN_HI);
    wire                        c_cache = s_read && !off && (s_burstcount == 4) && (c_addr[1 : 0] == 2'd0) && c_inwin;
    wire                        c_inv   = s_write && (SNOOP != 0) && c_inwin && (s_first || (c_addr[1 : 0] == 2'd0));

    wire [IW - 1 : 0]           l_idx = l_addr[2 +: IW];
    wire [TW - 1 : 0]           l_tag = l_addr[AW - 1 -: TW];
    wire [TW : 0]               l_tq  = (BYPASS_TAG != 0 && byp_v && (byp_idx == l_idx)) ? byp_val : tag_q;
    wire                        l_hit = l_tq[TW] && (l_tq[TW - 1 : 0] == l_tag);
    wire [BCW - 1 : 0]          l_need = l_cache ? 4 : l_bc;
    wire                        l_credit = ({1'b0, mf_res} + { {(MF_LG + 2 - BCW){1'b0}}, l_need }) <= MF_D;
    assign m_read       = lv && l_rd && !(l_cache && l_hit) && l_credit;
    assign m_write      = lv && l_wr;
    assign m_address    = l_addr;
    assign m_burstcount = l_rd ? l_need : l_bc;
    assign m_writedata  = l_wdata;
    assign m_byteenable = l_be;
    wire                        l_go = lv && ((l_rd && l_cache && l_hit) || ((m_read || m_write) && !m_waitrequest));
    wire                        l_tagw = l_go && ((l_rd && l_cache && !l_hit) || (l_wr && l_inv));
    wire [TW : 0]               l_tagv = l_rd ? {1'b1, l_tag} : {(TW + 1){1'b0}};

    wire [RQ_LG : 0]            rq_n = rq_wp - rq_rp;
    wire                        rq_room = ({1'b0, rq_n} + ((lv && l_rd) ? 1 : 0)) < RQ_D;
    wire                        l_free = !lv || l_go;
    assign s_waitrequest = !(l_free && !flushing && !flush_pend && (s_write || rq_room));
    wire                        c_take = s_cmd && !s_waitrequest;

    wire                        t_we = resetn && (flushing || l_tagw);
    wire [IW - 1 : 0]           t_wa = flushing ? fl_idx[IW - 1 : 0] : l_idx;
    wire [TW : 0]               t_wd = flushing ? {(TW + 1){1'b0}} : l_tagv;
    always @(posedge clk)
    begin
        if (t_we) tags[t_wa] <= t_wd;
        if (resetn && c_take) tag_q <= tags[c_addr[2 +: IW]];
    end

    // ---------------------------------------------------------------- R: in-order returns
    wire                        rq_ne  = rq_wp != rq_rp;
    wire [RQ_LG - 1 : 0]        rq_h   = rq_rp[RQ_LG - 1 : 0];
    wire                        r_hit  = rq_ne && (rq_t[rq_h] == T_HIT);
    wire                        r_mf   = rq_ne && (rq_t[rq_h] != T_HIT) && mfv;
    wire                        r_step = r_hit || r_mf;
    wire                        r_last = r_step && (r_beat == rq_bc[rq_h] - 1'b1);
    wire                        mf_pop = r_mf;
    wire                        mf_load = (mf_wp != mf_rp) && (!mfv || mf_pop);
    assign s_readdata = o_sel_ram ? o_ram : o_mf;

    assign idle = !lv && !rq_ne && (mf_wp == mf_rp) && !mfv && !flushing && !flush_pend;

    always @(posedge clk)
    begin
        if (!resetn)
        begin
            flushing <= 1'b1; flush_pend <= 1'b0; fl_idx <= 0;
            lv <= 1'b0; byp_v <= 1'b0; w_left <= 0;
            rq_wp <= 0; rq_rp <= 0; r_beat <= 0;
            mf_wp <= 0; mf_rp <= 0; mfv <= 1'b0; mf_res <= 0;
            s_readdatavalid <= 1'b0; o_sel_ram <= 1'b0;
            hits <= 0; misses <= 0;
        end
        else
        begin
            if (inv_all)
                flush_pend <= 1'b1;
            if (flush_pend && !lv && !flushing)
            begin
                flushing <= 1'b1;
                flush_pend <= 1'b0;
                fl_idx <= 0;
            end
            if (flushing)
            begin
                fl_idx <= fl_idx + 1'b1;
                byp_v <= 1'b0;
                if (fl_idx == LINES - 1)
                    flushing <= 1'b0;
            end

            // ------------------------------------------------ L
            if (l_tagw)
            begin
                byp_v <= 1'b1;
                byp_idx <= l_idx;
                byp_val <= l_tagv;
            end
            if (l_go && l_rd)
            begin
                rq_t[rq_wp[RQ_LG - 1 : 0]]   <= (l_cache && l_hit) ? T_HIT : (l_cache ? T_MISS : T_PASS);
                rq_idx[rq_wp[RQ_LG - 1 : 0]] <= l_idx;
                rq_bc[rq_wp[RQ_LG - 1 : 0]]  <= l_need;
                rq_wp <= rq_wp + 1'b1;
                if (l_cache)
                begin
                    if (l_hit) hits <= hits + 1;
                    else misses <= misses + 1;
                end
            end
            if (l_go)
                lv <= 1'b0;

            // ------------------------------------------------ C
            if (c_take)
            begin
                lv      <= 1'b1;
                l_rd    <= s_read;
                l_wr    <= s_write;
                l_addr  <= c_addr;
                l_bc    <= s_burstcount;
                l_cache <= c_cache;
                l_inv   <= c_inv;
                l_first <= s_write && s_first;
                l_wdata <= s_writedata;
                l_be    <= s_byteenable;
                if (s_write)
                begin
                    if (s_first)
                    begin
                        w_left <= s_burstcount - 1'b1;
                        w_addr <= s_address + 1'b1;
                    end
                    else
                    begin
                        w_left <= w_left - 1'b1;
                        w_addr <= w_addr + 1'b1;
                    end
                end
            end

            // ------------------------------------------------ master read data
            if (m_readdatavalid)
            begin
                mf[mf_wp[MF_LG - 1 : 0]] <= m_readdata;
                mf_wp <= mf_wp + 1'b1;
            end
            if (mf_load)
            begin
                mf_q <= mf[mf_rp[MF_LG - 1 : 0]];
                mf_rp <= mf_rp + 1'b1;
                mfv <= 1'b1;
            end
            else if (mf_pop)
                mfv <= 1'b0;
            mf_res <= mf_res + ((m_read && !m_waitrequest) ? { {(MF_LG + 2 - BCW){1'b0}}, l_need } : {(MF_LG + 2){1'b0}})
                             - (mf_pop ? { {(MF_LG + 1){1'b0}}, 1'b1 } : {(MF_LG + 2){1'b0}});

            // ------------------------------------------------ R
            s_readdatavalid <= r_step;
            o_sel_ram <= r_hit;
            if (r_hit)
                o_ram <= data[{rq_idx[rq_h], r_beat[1 : 0]}];
            if (r_mf)
            begin
                o_mf <= mf_q;
                if (rq_t[rq_h] == T_MISS)
                    data[{rq_idx[rq_h], r_beat[1 : 0]}] <= mf_q;
            end
            if (r_step)
            begin
                if (r_last)
                begin
                    r_beat <= 0;
                    rq_rp <= rq_rp + 1'b1;
                end
                else
                    r_beat <= r_beat + 1'b1;
            end
        end
    end
endmodule
