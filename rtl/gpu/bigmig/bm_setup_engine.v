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

// triangle setup engine (microcoded)

module bm_setup_engine #(
    parameter UCW = 142,
    parameter NU = 1,                   // units served: 1, or 2 (one engine shared by two units)
    parameter LEAN = 0
) (
    input  wire              clk,
    input  wire              resetn,
    // microcode: address out, word back one clock later (the shared ROM, bm_setup_rom)
    output wire [7:0]        uc_addr,
    input  wire [UCW-1:0]    uc_word,
    // colour ROM (byte -> byte * (1.0f / 255.0f)): address out, data back one clock later
    output wire [7:0]        lut_addr,
    input  wire [31:0]       lut_data,
    input  wire [NU-1:0]     rec_req,
    output wire [NU-1:0]     rec_gnt,
    input  wire [NU-1:0]     rec_we,
    input  wire [NU*7-1:0]   rec_waddr,
    input  wire [NU*32-1:0]  rec_wdata,
    // snooped state (Sn.4 scissor, rows already added)
    input  wire [NU*32-1:0]  st_yoff, st_yend, st_resx, st_resx16, st_scx0, st_scy0, st_scx1, st_scy1,
    input  wire [NU-1:0]     st_scissor, st_tmu0,
    // hand-off: a complete record waits in in_slot; in_soon = one is being received
    input  wire [NU-1:0]     in_avail,
    input  wire [NU*2-1:0]   in_slot,
    input  wire [NU-1:0]     in_soon,
    output reg  [NU-1:0]     in_take,
    // output slots
    input  wire [NU-1:0]     ob_free_avail,
    input  wire [NU*2-1:0]   ob_free_slot,
    output reg  [NU-1:0]     ob_alloc,
    output reg               ob_we,
    output reg  [7:0]        ob_waddr,                  // {slot[1:0], word[5:0]}
    output reg  [31:0]       ob_wdata,
    output reg               ob_wu,
    output reg               ev_drop,
    output reg               ev_done,
    output reg  [1:0]        ev_slot,
    output reg               ev_u,
    output reg               ev_rec_free,
    output reg  [1:0]        ev_rec,
    output reg               ev_rec_u,
    output wire [NU-1:0]     busy,                      // the engine holds a triangle of unit u
    output reg  [31:0]       cnt_iter,
    output reg  [31:0]       cnt_tri,
    output reg  [31:0]       cnt_wait
);
`include "bm_setup_ucode.vh"
    reg         act;                    // a word issues this clock
    reg  [7:0]  pc;                     // its kernel address
    reg  [1:0]  sv;
    reg  [1:0]  srec0, srec1, sob0, sob1;
    reg         su0, su1;               // the unit of the stage-0 / stage-1 triangle (always 0 when NU = 1)
    reg         par;                    // the iteration's parity
    reg         pv;                     // a triangle waits to enter stage 1 (the last iteration's stage 0)
    reg  [1:0]  prec, pob;
    reg         pu;                     // its unit
    reg  [5:0]  wcnt;
    reg         lastu;                  // the unit served last (round-robin)
    wire        at_end  = act && (pc == UC_II - 1);
    wire        decide  = at_end || !act;
    wire        nxt_pv  = at_end ? sv[0] : pv;
    wire [1:0]  nxt_prec = at_end ? srec0 : prec;
    wire [1:0]  nxt_pob  = at_end ? sob0 : pob;
    wire        nxt_pu  = at_end ? su0 : pu;
    wire [NU-1:0] cand  = in_avail & ob_free_avail;
    wire        selu    = (NU > 1) ? (cand[NU-1] && (!cand[0] || !lastu)) : 1'b0;
    wire [1:0]  sel_slot = (NU > 1 && selu) ? in_slot[NU*2-1 -: 2] : in_slot[1:0];
    wire [1:0]  sel_ob   = (NU > 1 && selu) ? ob_free_slot[NU*2-1 -: 2] : ob_free_slot[1:0];
    wire        take    = decide && (|cand);
    wire        hold    = decide && !take && (|in_soon) && (wcnt != 6'd63) && 1'b1;
    wire        start   = decide && (take || (!hold && nxt_pv));
    assign uc_addr = start ? 8'd0 : (pc + 8'd1);
    genvar gu;
    generate for (gu = 0; gu < NU; gu = gu + 1) begin : bz
        // NU = 1: act always holds a triangle in some stage, so this is act || pv, as it was
        assign busy[gu] = (act && ((sv[0] && su0 == gu) || (sv[1] && su1 == gu))) || (pv && pu == gu);
    end endgenerate
    always @(posedge clk) begin
        in_take <= {NU{1'b0}}; ob_alloc <= {NU{1'b0}}; ev_rec_free <= 1'b0;
        if (!resetn) begin
            act <= 1'b0; pc <= 8'd0; sv <= 2'b00; par <= 1'b0; pv <= 1'b0; wcnt <= 6'd0;
            su0 <= 1'b0; su1 <= 1'b0; pu <= 1'b0; lastu <= 1'b0;
            cnt_iter <= 32'd0; cnt_tri <= 32'd0; cnt_wait <= 32'd0;
        end else begin
            if (at_end && sv[1]) begin ev_rec_free <= 1'b1; ev_rec <= srec1; ev_rec_u <= su1; end
            if (start) begin
                act <= 1'b1; pc <= 8'd0; par <= ~par; wcnt <= 6'd0;
                sv <= {nxt_pv, take};
                srec1 <= nxt_prec; sob1 <= nxt_pob; su1 <= nxt_pu;
                if (take) begin
                    srec0 <= sel_slot; sob0 <= sel_ob; su0 <= selu; lastu <= selu;
                    in_take[selu] <= 1'b1; ob_alloc[selu] <= 1'b1;
                    if (!LEAN) cnt_tri <= cnt_tri + 32'd1;
                end
                pv <= 1'b0;
                if (!LEAN) cnt_iter <= cnt_iter + 32'd1;
            end else begin
                if (at_end) begin
                    act <= 1'b0; pv <= sv[0]; prec <= srec0; pob <= sob0; pu <= su0; sv <= 2'b00;
                end else if (act) begin
                    pc <= pc + 8'd1;
                end
                if (hold) begin wcnt <= wcnt + 6'd1; if (!LEAN) cnt_wait <= cnt_wait + 32'd1; end
            end
        end
    end
    wire [UCW-1:0] uw = uc_word;
    `define F(name) uw[name``_LO +: name``_W]
    wire [2:0] m_op = `F(M_OP);   wire [4:0] m_fn = `F(M_FN);   wire [8:0] m_a = `F(M_A);   wire [1:0] m_amode = `F(M_AMODE);
    wire [8:0] m_b = `F(M_B);     wire [7:0] m_dst = `F(M_DST); wire [6:0] m_ob = `F(M_OB); wire [5:0] m_fin = `F(M_FIN);
    wire [4:0] m_fout = `F(M_FOUT); wire [7:0] m_imm = `F(M_IMM); wire m_stage = `F(M_STAGE); wire [1:0] m_acc = `F(M_ACC);
    wire [1:0] m_macc = `F(M_MACC); wire m_last = `F(M_LAST);
    wire [3:0] s_op = `F(S_OP);   wire [4:0] s_fn = `F(S_FN);   wire [8:0] s_a = `F(S_A);   wire [1:0] s_amode = `F(S_AMODE);
    wire [8:0] s_b = `F(S_B);     wire [1:0] s_bmode = `F(S_BMODE); wire [7:0] s_dst = `F(S_DST); wire [6:0] s_ob = `F(S_OB);
    wire [5:0] s_fin = `F(S_FIN); wire [4:0] s_fout = `F(S_FOUT); wire [15:0] s_imm = `F(S_IMM); wire s_stage = `F(S_STAGE);
    `undef F
    localparam MO_NOP = 0, MO_ALU = 1, MO_FMUL = 2, MO_FSQR = 3, MO_IMUL = 4, MO_MACC = 5;
    localparam SO_NOP = 0, SO_ALU = 1, SO_FADD = 2, SO_FSUB = 3, SO_I2F = 4, SO_U30 = 5, SO_LUT = 6, SO_FDIV = 7,
               SO_FSQRT = 8, SO_MARKDROP = 9, SO_DONE = 10;
    wire       mv = act && (m_op != MO_NOP);
    wire       svld = act && (s_op != SO_NOP);
    // physical register of a logical one (0..63 plain; 64..95 rotating: two copies)
    function [6:0] phys(input [6:0] r, input copy);
        phys = r[6] ? {1'b1, r[4:0], copy} : {1'b0, r[5:0]};
    endfunction
    function [4:0] fphys(input [3:0] f, input copy);   // flags: 0..7 plain, 8..13 rotating -> 8..19, 14/15 state
        fphys = (f < 4'd8) ? {1'b0, f} : (f < 4'd14) ? (5'd8 + {f - 4'd8, 1'b0} + {4'd0, copy}) : {1'b1, f};
    endfunction
    wire       mcp = par ^ m_stage, scp = par ^ s_stage;
    wire [1:0] m_rec = m_stage ? srec1 : srec0, s_rec = s_stage ? srec1 : srec0;
    wire       m_u = m_stage ? su1 : su0, s_u = s_stage ? su1 : su0;     // the op's unit (NU = 2)
    // RF read addresses (registered by the RAMs at the end of the issue clock)
    wire [6:0] ra_ma = phys(m_a[6:0], mcp), ra_mb = phys(m_b[6:0], mcp);
    wire [6:0] ra_sa = phys(s_a[6:0], scp), ra_sb = phys(s_b[6:0], scp);
    wire [6:0] rr_ma = {m_rec, m_a[4:0]}, rr_sa = {s_rec, s_a[4:0]}, rr_sb = {s_rec, s_b[4:0]};
    reg        wm_e; reg [6:0] wm_a; reg [31:0] wm_d;       // bank M
    reg        ws_e; reg [6:0] ws_a; reg [31:0] ws_d;       // bank S
    // bank M: 4 read copies; bank S: 4 read copies; REC: 3 read copies (M.A, S.A, S.B) a unit
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rm0 [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rm1 [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rm2 [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rm3 [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rs0 [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rs1 [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rs2 [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rs3 [0:127];
    always @(posedge clk) if (wm_e) begin rm0[wm_a] <= wm_d; rm1[wm_a] <= wm_d; rm2[wm_a] <= wm_d; rm3[wm_a] <= wm_d; end
    always @(posedge clk) if (ws_e) begin rs0[ws_a] <= ws_d; rs1[ws_a] <= ws_d; rs2[ws_a] <= ws_d; rs3[ws_a] <= ws_d; end
    reg [31:0] q_mm_a, q_ms_a, q_mm_b, q_ms_b, q_sm_a, q_ss_a, q_sm_b, q_ss_b;
    always @(posedge clk) begin
        q_mm_a <= rm0[ra_ma]; q_ms_a <= rs0[ra_ma];       // port M.A from both banks
        q_mm_b <= rm1[ra_mb]; q_ms_b <= rs1[ra_mb];       // port M.B
        q_sm_a <= rm2[ra_sa]; q_ss_a <= rs2[ra_sa];       // port S.A
        q_sm_b <= rm3[ra_sb]; q_ss_b <= rs3[ra_sb];       // port S.B
    end
    wire neg_state = 1'b0;
    wire neg_rec = 1'b0;
    localparam RCA = (NU > 1) ? 8 : 7;
    reg        wgl;                                         // the unit granted last
    wire       wsel = (NU > 1) ? (rec_req[NU-1] && (!rec_req[0] || !wgl)) : 1'b0;
    generate if (NU > 1) begin : rg2
        assign rec_gnt = {wsel, !wsel};
        always @(posedge clk) if (!resetn) wgl <= 1'b0; else if (|rec_we) wgl <= wsel;
    end else begin : rg1
        assign rec_gnt = 1'b1;
        always @(posedge clk) wgl <= 1'b0;
    end endgenerate
    wire           rc_we = |rec_we;
    wire [RCA-1:0] rc_wa, rc_ra_ma, rc_ra_sa, rc_ra_sb;
    wire [31:0]    rc_wd = (NU > 1 && wsel) ? rec_wdata[NU*32-1 -: 32] : rec_wdata[31:0];
    generate if (NU > 1) begin : ra2
        assign rc_wa = {wsel, (wsel ? rec_waddr[NU*7-1 -: 7] : rec_waddr[6:0])};
        assign rc_ra_ma = {m_u && !neg_rec, rr_ma}; assign rc_ra_sa = {s_u && !neg_rec, rr_sa}; assign rc_ra_sb = {s_u && !neg_rec, rr_sb};
    end else begin : ra1
        assign rc_wa = rec_waddr[6:0];
        assign rc_ra_ma = rr_ma; assign rc_ra_sa = rr_sa; assign rc_ra_sb = rr_sb;
    end endgenerate
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rc0 [0:(1 << RCA) - 1];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rc1 [0:(1 << RCA) - 1];
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] rc2 [0:(1 << RCA) - 1];
    always @(posedge clk) if (rc_we) begin rc0[rc_wa] <= rc_wd; rc1[rc_wa] <= rc_wd; rc2[rc_wa] <= rc_wd; end
    reg [31:0] q_rc_ma, q_rc_sa, q_rc_sb;
    always @(posedge clk) begin q_rc_ma <= rc0[rc_ra_ma]; q_rc_sa <= rc1[rc_ra_sa]; q_rc_sb <= rc2[rc_ra_sb]; end
    reg        e_mv, e_sv;
    reg [2:0]  e_mop; reg [3:0] e_sop; reg [4:0] e_mfn, e_sfn;
    reg [1:0]  e_mac, e_sac, e_sbc;    // source classes of M.A (M.B class: e_mbc)
    reg [1:0]  e_mbc;
    reg [1:0]  e_mamode, e_samode, e_sbmode;
    reg [6:0]  e_maix, e_mbix, e_saix, e_sbix;
    reg [7:0]  e_mimm; reg [15:0] e_simm;
    reg        e_mdst_v, e_sdst_v; reg [6:0] e_mdst, e_sdst;
    reg        e_mob_v, e_sob_v; reg [5:0] e_mobw, e_sobw; reg [1:0] e_mobs, e_sobs;
    reg        e_mu, e_su;             // the op's unit (NU = 2)
    reg        e_mgate, e_sgate;       // the op's stage holds a triangle
    reg        e_mfin_u, e_mfin_i, e_sfin_u, e_sfin_i; reg [4:0] e_mfin, e_sfin;
    reg        e_mfout_v, e_sfout_v; reg [4:0] e_mfout, e_sfout;
    reg [1:0]  e_macc_k, e_macc_mode; reg e_macc_last;
    reg [21:0] fl;                     // the flag file: 0..19 physical, 20 = SCISSOR, 21 = TMU0 (state)
    always @(posedge clk) begin
        e_mv <= mv; e_sv <= svld;
        e_mop <= m_op; e_sop <= s_op; e_mfn <= m_fn; e_sfn <= s_fn;
        e_mac <= m_a[8:7]; e_mbc <= m_b[8:7]; e_sac <= s_a[8:7]; e_sbc <= s_b[8:7];
        e_mamode <= m_amode; e_samode <= s_amode; e_sbmode <= s_bmode;
        e_maix <= m_a[6:0]; e_mbix <= m_b[6:0]; e_saix <= s_a[6:0]; e_sbix <= s_b[6:0];
        e_mimm <= m_imm; e_simm <= s_imm;
        e_mdst_v <= m_dst[7]; e_mdst <= phys(m_dst[6:0], mcp);
        e_sdst_v <= s_dst[7]; e_sdst <= phys(s_dst[6:0], scp);
        e_mob_v <= m_ob[6]; e_mobw <= m_ob[5:0]; e_mobs <= m_stage ? sob1 : sob0; e_mu <= m_u; e_su <= s_u;
        e_sob_v <= s_ob[6]; e_sobw <= s_ob[5:0]; e_sobs <= s_stage ? sob1 : sob0;
        e_mgate <= m_stage ? sv[1] : sv[0]; e_sgate <= s_stage ? sv[1] : sv[0];
        e_mfin_u <= m_fin[5]; e_mfin_i <= m_fin[4]; e_mfin <= fphys(m_fin[3:0], mcp);
        e_sfin_u <= s_fin[5]; e_sfin_i <= s_fin[4]; e_sfin <= fphys(s_fin[3:0], scp);
        e_mfout_v <= m_fout[4]; e_mfout <= fphys(m_fout[3:0], mcp);
        e_sfout_v <= s_fout[4]; e_sfout <= fphys(s_fout[3:0], scp);
        e_macc_k <= m_acc; e_macc_mode <= m_macc; e_macc_last <= m_last;
        e_drop_mask <= {s_imm[15:14], s_imm[13:8], s_imm[7:0]};
        e_drop_cp <= scp;
    end
    reg [15:0] e_drop_mask; reg e_drop_cp;
    function [31:0] recmode(input [31:0] w, input [1:0] m);
        recmode = (m == 2'd1) ? {{16{w[15]}}, w[15:0]} : (m == 2'd2) ? {{16{w[31]}}, w[31:16]} : w;
    endfunction
    function [31:0] stsel(input [NU*32-1:0] v, input u);    // unit u's word of a per-unit state vector
        stsel = (NU > 1 && u) ? v[NU*32-1 -: 32] : v[31:0];
    endfunction
    function [31:0] special(input [6:0] ix, input u);
        case (ix)
            7'd0: special = stsel(st_yoff, u);  7'd1: special = stsel(st_yend, u);
            7'd2: special = stsel(st_resx, u);  7'd3: special = stsel(st_resx16, u);
            7'd4: special = stsel(st_scx0, u);  7'd5: special = stsel(st_scy0, u);
            7'd6: special = stsel(st_scx1, u);  7'd7: special = stsel(st_scy1, u);
            7'd64: special = UC_CONST0; 7'd65: special = UC_CONST1; 7'd66: special = UC_CONST2; 7'd67: special = UC_CONST3;
            7'd68: special = UC_CONST4;
            default: special = 32'd0;
        endcase
    endfunction
    reg  [31:0] q_sp_ma, q_sp_mb, q_sp_sa, q_sp_sb;
    always @(posedge clk) begin
        q_sp_ma <= special(m_a[6:0], m_u && !neg_state); q_sp_mb <= special(m_b[6:0], m_u && !neg_state);
        q_sp_sa <= special(s_a[6:0], s_u && !neg_state); q_sp_sb <= special(s_b[6:0], s_u && !neg_state);
    end
    function [31:0] opnd(input [1:0] cls, input [31:0] bm, input [31:0] bs, input [31:0] rc, input [1:0] mode, input [31:0] sp);
        case (cls)
            2'd0: opnd = bm;
            2'd1: opnd = bs;
            2'd2: opnd = recmode(rc, mode);
            default: opnd = sp;
        endcase
    endfunction
    wire [31:0] ma = opnd(e_mac, q_mm_a, q_ms_a, q_rc_ma, e_mamode, q_sp_ma);
    wire [31:0] mb = opnd(e_mbc, q_mm_b, q_ms_b, 32'd0, 2'd0, q_sp_mb);
    wire [31:0] sa = opnd(e_sac, q_sm_a, q_ss_a, q_rc_sa, e_samode, q_sp_sa);
    wire [31:0] sb = opnd(e_sbc, q_sm_b, q_ss_b, q_rc_sb, e_sbmode, q_sp_sb);
    // state flags 14/15 (SCISSOR, TMU0): fl[20] / fl[21] for unit 0, fl_u1 for unit 1
    reg  [1:0]  fl_u1;
    wire        m_stf = (NU > 1 && e_mu) ? fl_u1[e_mfin[0]] : (e_mfin[0] ? fl[21] : fl[20]);
    wire        s_stf = (NU > 1 && e_su) ? fl_u1[e_sfin[0]] : (e_sfin[0] ? fl[21] : fl[20]);
    wire        mfl = (e_mfin[4] ? m_stf : fl[e_mfin]) ^ e_mfin_i;   // 14/15 map to 20/21
    wire        sfl = (e_sfin[4] ? s_stf : fl[e_sfin]) ^ e_sfin_i;
    localparam A_MOV = 0, A_SUB = 1, A_ADDK = 2, A_MIN = 3, A_MAX = 4, A_BBX = 5, A_SUBS4 = 6, A_NEGIF = 7,
               A_SHL4NEGIF = 8, A_MINIF = 9, A_ADDIF = 10, A_PACK = 11, A_FMIN = 12, A_FMAX = 13, A_FTRLT = 14,
               A_FTRGT = 15, A_FLE0 = 16, A_FLT = 17, A_FGE = 18, A_FGT = 19;
    function flt(input [31:0] a, input [31:0] b);        // float a < b (no NaNs; -0 == +0)
        if (a[30:0] == 31'd0 && b[30:0] == 31'd0) flt = 1'b0;
        else if (a[31] != b[31]) flt = a[31];
        else if (!a[31]) flt = (a[30:0] < b[30:0]);
        else flt = (a[30:0] > b[30:0]);
    endfunction
    function [31:0] ftrunc(input [31:0] x);              // (float)(int)x for |x| < 2^31 (the setup's |x| > 4 uses)
        reg [7:0] e; reg [22:0] mask;
        begin
            e = x[30:23];
            if (e < 8'd127) ftrunc = 32'd0;
            else if (e >= 8'd150) ftrunc = x;
            else begin
                mask = ~((23'd1 << (8'd150 - e)) - 23'd1);
                ftrunc = {x[31:23], x[22:0] & mask};
            end
        end
    endfunction
    function [32:0] alu(input [4:0] fn, input [31:0] a, input [31:0] b, input [15:0] imm, input f, input fu);
        // {flag, value}
        reg [31:0] y; reg fo; reg signed [31:0] sa_, sb_; reg [31:0] t;
        begin
            sa_ = a; sb_ = b; y = 32'd0; fo = 1'b0;
            case (fn)
                A_MOV:   y = a;
                A_SUB:   y = a - b;
                A_ADDK:  y = a + {{24{imm[7]}}, imm[7:0]};
                A_MIN:   y = (sb_ < sa_) ? b : a;
                A_MAX:   y = (sa_ < sb_) ? b : a;
                A_BBX:   begin t = {{4{a[31]}}, a[31:4]}; y = t[31] ? 32'd0 : ((t > 32'd2047) ? 32'd2047 : t); end
                A_SUBS4: y = {a[27:0], 4'd0} - b;
                A_NEGIF: y = f ? (32'd0 - a) : a;
                A_SHL4NEGIF: begin t = {a[27:0], 4'd0}; y = f ? (32'd0 - t) : t; end
                A_MINIF: y = (f && (sb_ < sa_)) ? b : a;
                A_ADDIF: y = f ? (a + b) : a;
                A_PACK:  y = {b[15:0], a[15:0]};
                A_FMIN:  y = flt(b, a) ? b : a;
                A_FMAX:  y = flt(a, b) ? b : a;
                A_FTRLT: y = flt(a, b) ? ftrunc(a) : 32'd0;
                A_FTRGT: y = flt(b, a) ? ftrunc(a) : 32'd0;
                A_FLE0:  fo = (sa_ <= 0);
                A_FLT:   fo = (sa_ < sb_);
                A_FGE:   fo = (sa_ >= sb_);
                A_FGT:   fo = (sa_ > sb_);
                default: y = a;
            endcase
            if (fn >= A_FLE0 && fu) fo = fo & f;          // a gated compare (the gate is the flag input)
            alu = {fo, y};
        end
    endfunction
    wire [32:0] am = alu(e_mfn, ma, mb, {8'd0, e_mimm}, mfl, e_mfin_u);
    wire [32:0] as = alu(e_sfn, sa, sb, e_simm, sfl, e_sfin_u);
    wire        m_is_alu = e_mv && (e_mop == MO_ALU);
    wire        s_is_alu = e_sv && (e_sop == SO_ALU);
    // ALU results, registered (written into the RF and the output buffer during the next clock)
    reg        rm_v, rm_dv, rm_obv, rm_obu; reg [6:0] rm_d; reg [31:0] rm_y; reg [7:0] rm_oba;
    reg        rs_v, rs_dv, rs_obv, rs_obu; reg [6:0] rs_d; reg [31:0] rs_y; reg [7:0] rs_oba;
    always @(posedge clk) begin
        rm_v <= m_is_alu; rm_dv <= m_is_alu && e_mdst_v; rm_d <= e_mdst; rm_y <= am[31:0];
        rm_obv <= m_is_alu && e_mob_v && e_mgate; rm_oba <= {e_mobs, e_mobw}; rm_obu <= e_mu;
        rs_v <= s_is_alu; rs_dv <= s_is_alu && e_sdst_v; rs_d <= e_sdst; rs_y <= as[31:0];
        rs_obv <= s_is_alu && e_sob_v && e_sgate; rs_oba <= {e_sobs, e_sobw}; rs_obu <= e_su;
        if (!resetn) begin fl <= 22'd0; fl_u1 <= 2'd0; end
        else begin
            if (m_is_alu && e_mfout_v && !e_mfout[4]) fl[e_mfout] <= am[32];
            if (s_is_alu && e_sfout_v && !e_sfout[4]) fl[e_sfout] <= as[32];
            fl[20] <= st_scissor[0]; fl[21] <= st_tmu0[0];
            if (NU > 1) fl_u1 <= {st_tmu0[NU-1], st_scissor[NU-1]};
        end
    end
    wire [19:0] drop_bits;
    genvar g;
    generate for (g = 0; g < 16; g = g + 1) begin : dm
        // the MARKDROP mask names logical flags 0..15; map each to its physical copy
        if (g < 8) begin : gp assign drop_bits[g] = e_drop_mask[g] & fl[g]; end
        else if (g < 14) begin : gr assign drop_bits[g] = e_drop_mask[g] & fl[8 + 2 * (g - 8) + e_drop_cp]; end
        else begin : gs assign drop_bits[g] = e_drop_mask[g] & ((NU > 1 && e_su) ? fl_u1[g - 14] : fl[20 + (g - 14)]); end
    end endgenerate
    assign drop_bits[19:16] = 4'd0;
    always @(posedge clk) begin
        ev_drop <= e_sv && (e_sop == SO_MARKDROP) && e_sgate && (|drop_bits);
        ev_done <= e_sv && (e_sop == SO_DONE) && e_sgate;
        ev_slot <= e_sobs;
        ev_u <= e_su;
    end
    wire        mul_in = e_mv && (e_mop == MO_FMUL || e_mop == MO_FSQR || e_mop == MO_IMUL || e_mop == MO_MACC);
    wire        mul_ov; wire [31:0] mul_y;
    // FSQR multiplies port M.A by itself (M.B cannot read a record word)
    bm_fmul u_mul (.clk(clk), .in_valid(mul_in), .imul(e_mop == MO_IMUL), .a(ma), .b((e_mop == MO_FSQR) ? ma : mb),
                   .out_valid(mul_ov), .y(mul_y));
    // the multiplier's tag pipeline (3 clocks: in at E1, out with y)
    reg  [2:0] t_macc, t_dv, t_last, t_obv, t_fv; reg [6:0] t_d [0:2]; reg [1:0] t_k [0:2], t_mode [0:2];
    reg  [7:0] t_oba [0:2];
    reg  [2:0] t_obu;
    integer z;
    always @(posedge clk) begin
        t_macc[0] <= mul_in && (e_mop == MO_MACC);
        t_dv[0] <= mul_in && e_mdst_v; t_d[0] <= e_mdst; t_k[0] <= e_macc_k; t_mode[0] <= e_macc_mode;
        t_last[0] <= e_macc_last; t_obv[0] <= e_mob_v && e_mgate; t_oba[0] <= {e_mobs, e_mobw}; t_obu[0] <= e_mu;
        t_fv[0] <= mfl;                                             // MACCIF: the re-base flag, taken at E1
        for (z = 1; z < 3; z = z + 1) begin
            t_macc[z] <= t_macc[z-1]; t_dv[z] <= t_dv[z-1]; t_d[z] <= t_d[z-1]; t_k[z] <= t_k[z-1];
            t_mode[z] <= t_mode[z-1]; t_last[z] <= t_last[z-1]; t_obv[z] <= t_obv[z-1]; t_oba[z] <= t_oba[z-1];
            t_fv[z] <= t_fv[z-1]; t_obu[z] <= t_obu[z-1];
        end
    end
    reg  [31:0] acc [0:3];
    wire        add_s   = e_sv && (e_sop == SO_FADD || e_sop == SO_FSUB || e_sop == SO_I2F || e_sop == SO_U30);
    wire        add_m   = mul_ov && t_macc[2];
    wire        add_ov; wire [31:0] add_y;
    // the accumulator into the adder (bypass from the adder's own output when it is landing now)
    reg         ao_macc; reg [1:0] ao_k;
    wire [31:0] acc_now = (add_ov && ao_macc && ao_k == t_k[2]) ? add_y : acc[t_k[2]];
    wire [31:0] add_a   = add_m ? mul_y : sa;
    wire [31:0] add_b   = add_m ? ((t_mode[2] == 2'd0) ? 32'h80000000 : acc_now) : sb;
    wire [1:0]  add_op  = add_m ? 2'd0 : (e_sop == SO_FADD) ? 2'd0 : (e_sop == SO_FSUB) ? 2'd1 : (e_sop == SO_I2F) ? 2'd2 : 2'd3;
    bm_fadd u_add (.clk(clk), .in_valid(add_s || add_m), .op(add_op), .a(add_a), .b(add_b), .out_valid(add_ov), .y(add_y));
    // the adder's tag pipeline (4 clocks: in, then out with y)
    reg  [3:0] a_macc, a_dv, a_last, a_obv, a_fv, a_obu; reg [6:0] a_d [0:3]; reg [1:0] a_k [0:3], a_mode [0:3]; reg [7:0] a_oba [0:3];
    always @(posedge clk) begin
        a_macc[0] <= add_m; a_dv[0] <= add_m ? t_dv[2] : (add_s && e_sdst_v); a_d[0] <= add_m ? t_d[2] : e_sdst;
        a_k[0] <= t_k[2]; a_mode[0] <= t_mode[2]; a_last[0] <= t_last[2]; a_obv[0] <= add_m && t_obv[2];
        a_oba[0] <= t_oba[2]; a_fv[0] <= t_fv[2]; a_obu[0] <= t_obu[2];
        for (z = 1; z < 4; z = z + 1) begin
            a_macc[z] <= a_macc[z-1]; a_dv[z] <= a_dv[z-1]; a_d[z] <= a_d[z-1]; a_k[z] <= a_k[z-1];
            a_mode[z] <= a_mode[z-1]; a_last[z] <= a_last[z-1]; a_obv[z] <= a_obv[z-1]; a_oba[z] <= a_oba[z-1];
            a_fv[z] <= a_fv[z-1]; a_obu[z] <= a_obu[z-1];
        end
    end
    always @(*) begin ao_macc = a_macc[3]; ao_k = a_k[3]; end
    wire [31:0] macc_out = (a_mode[3] == 2'd2 && !a_fv[3]) ? acc[a_k[3]] : add_y;
    always @(posedge clk) if (add_ov && a_macc[3]) acc[a_k[3]] <= add_y;
    assign lut_addr = (e_simm[1:0] == 2'd3) ? sa[31:24] : (e_simm[1:0] == 2'd2) ? sa[23:16] :
                      (e_simm[1:0] == 2'd1) ? sa[15:8] : sa[7:0];
    reg  [1:0] l_v, l_dv; reg [6:0] l_d [0:1];
    reg  [31:0] l_q;
    always @(posedge clk) begin
        l_v[0] <= e_sv && (e_sop == SO_LUT); l_dv[0] <= e_sv && (e_sop == SO_LUT) && e_sdst_v; l_d[0] <= e_sdst;
        l_v[1] <= l_v[0]; l_dv[1] <= l_dv[0]; l_d[1] <= l_d[0];
        l_q <= lut_data;
    end
    wire        div_start = e_sv && (e_sop == SO_FDIV || e_sop == SO_FSQRT);
    wire        div_busy, div_done; wire [31:0] div_y;
    bm_fdivsqrt u_div (.clk(clk), .resetn(resetn), .start(div_start), .sqrt(e_sop == SO_FSQRT), .a(sa), .b(sb),
                       .busy(div_busy), .done(div_done), .y(div_y));
    reg         d_dv; reg [6:0] d_d;
    always @(posedge clk) if (div_start) begin d_dv <= e_sdst_v; d_d <= e_sdst; end
    wire        dw_v = div_done && d_dv;
    always @(*) begin
        wm_e = 1'b0; wm_a = 7'd0; wm_d = 32'd0;
        if (rm_dv) begin wm_e = 1'b1; wm_a = rm_d; wm_d = rm_y; end
        if (mul_ov && !t_macc[2] && t_dv[2]) begin wm_e = 1'b1; wm_a = t_d[2]; wm_d = mul_y; end
        if (add_ov && a_macc[3] && a_last[3] && a_dv[3]) begin wm_e = 1'b1; wm_a = a_d[3]; wm_d = macc_out; end
        ws_e = 1'b0; ws_a = 7'd0; ws_d = 32'd0;
        if (rs_dv) begin ws_e = 1'b1; ws_a = rs_d; ws_d = rs_y; end
        if (l_dv[0]) begin ws_e = 1'b1; ws_a = l_d[0]; ws_d = lut_data; end
        if (add_ov && !a_macc[3] && a_dv[3]) begin ws_e = 1'b1; ws_a = a_d[3]; ws_d = add_y; end
        if (dw_v) begin ws_e = 1'b1; ws_a = d_d; ws_d = div_y; end
    end
    always @(*) begin
        ob_we = 1'b0; ob_waddr = 8'd0; ob_wdata = 32'd0; ob_wu = 1'b0;
        if (rm_obv) begin ob_we = 1'b1; ob_waddr = rm_oba; ob_wdata = rm_y; ob_wu = rm_obu; end
        if (rs_obv) begin ob_we = 1'b1; ob_waddr = rs_oba; ob_wdata = rs_y; ob_wu = rs_obu; end
        if (add_ov && a_macc[3] && a_last[3] && a_obv[3]) begin ob_we = 1'b1; ob_waddr = a_oba[3]; ob_wdata = macc_out; ob_wu = a_obu[3]; end
    end
endmodule
