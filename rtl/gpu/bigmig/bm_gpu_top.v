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

// BigMig GPU: RasterIX units, triangle setup, register block, memory port

module bm_gpu_top #(
    parameter N = 2,
    parameter CACHE_SIZE = 1024,
    parameter L2_KB = 32,
    parameter NOUT = 8,
    parameter [28:0] TEX_WIN_LO = 29'h0,
    parameter [28:0] TEX_WIN_HI = 29'h1FFFFFFF,
    parameter UC_FILE = "bm_setup_ucode.hex",
    parameter LUT_FILE = "bm_setup_lut.hex",
    parameter RAST_FLOAT_PREC = 24,
    parameter RAST_FIX_PREC = 18,
    parameter TEX_PAGE = 4096,
    parameter LIST_FIFO_LG = 0,
    parameter LEAN_CNT = 0,
    parameter SETUP_SHARED = 0,
    parameter COLOR_SWAP = 0
) (
    input  wire          clk_g,
    input  wire          resetn_g,
    // the register block's AXI4-Lite (h2f side)
    input  wire          clk_h,
    input  wire          resetn_h,
    input  wire [11:0]   s_awaddr, input wire s_awvalid, output wire s_awready,
    input  wire [31:0]   s_wdata, input wire s_wvalid, output wire s_wready,
    output wire          s_bvalid, input wire s_bready, output wire [1:0] s_bresp,
    input  wire [11:0]   s_araddr, input wire s_arvalid, output wire s_arready,
    output wire [31:0]   s_rdata, output wire s_rvalid, input wire s_rready, output wire [1:0] s_rresp,
    // ram1 (64-bit Avalon), clk_g
    output wire [28:0]   avl_address, output wire [7:0] avl_burstcount, input wire avl_waitrequest,
    input  wire [63:0]   avl_readdata, input wire avl_readdatavalid, output wire avl_read,
    output wire [63:0]   avl_writedata, output wire [7:0] avl_byteenable, output wire avl_write
);
    localparam SID = 6, MID = SID + $clog2(N);
    localparam [7:0] NOUT8 = NOUT;
    wire        en, swap, cswap, pfz, pcl, kick, eclr, l2inv, bdone; wire [11:0] fe_set, fe_clr;
    wire [31:0] sdir, sseq, fence, kclk; wire [6:0] sbands; wire [1:0] aclaim, agrant; wire [7:0] bidx;
    wire [3:0]  paddr; wire [N*32-1:0] prd; wire [31:0] l2h, l2m;
    wire [N*12*32-1:0] scnt; wire [6*32-1:0] dcnt;
    wire        active; wire [7:0] derr;
    wire [N-1:0] pbusy, wrp, spend, fbusy, serr;
    wire [1:0]  fbusy2 = fbusy, spend2 = spend, wrp2 = wrp, pbusy2 = pbusy;
    wire [31:0] status = {16'd0, fbusy2, spend2, wrp2, pbusy2, 7'd0, active};
    wire [31:0] err = {{(24 - N){1'b0}}, serr, derr};
    bm_gpu_regs #(.N(N), .COLOR_SWAP(COLOR_SWAP)) regs (
        .clk_h(clk_h), .resetn_h(resetn_h),
        .awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready), .wdata(s_wdata), .wvalid(s_wvalid), .wready(s_wready),
        .bvalid(s_bvalid), .bready(s_bready), .bresp(s_bresp), .araddr(s_araddr), .arvalid(s_arvalid), .arready(s_arready),
        .rdata(s_rdata), .rvalid(s_rvalid), .rready(s_rready), .rresp(s_rresp),
        .clk_g(clk_g), .resetn_g(resetn_g), .ctrl_enable(en), .ctrl_swap(swap), .ctrl_cswap(cswap), .perf_freeze(pfz), .perf_clear(pcl),
        .fe_set(fe_set), .fe_clr(fe_clr), .kick(kick), .sub_dir(sdir), .sub_bands(sbands), .sub_seq(sseq),
        .err_clr(eclr), .l2_inv(l2inv), .arm_claim(aclaim), .arm_grant(agrant), .band_idx(bidx), .band_done(bdone),
        .perf_addr(paddr), .perf_rdata(prd), .status(status), .err(err), .fence_done(fence), .kick_clocks(kclk),
        .l2_hits(l2h), .l2_misses(l2m), .setup_cnt(scnt), .disp_cnt(dcnt));
    wire [N-1:0] c_v, c_r; wire [N*32-1:0] c_d;
    wire         r0_v, r0_r; wire [31:0] r0_d;
    wire [N-1:0] f_push, f_full; wire [N*4-1:0] f_head, f_tail; wire [N*26-1:0] f_len;
    wire [N-1:0] ch_done, ch_link; wire [N*32-1:0] l_addr; wire [N*28-1:0] l_bytes;
    bm_gpu_disp #(.N(N), .LEAN(LEAN_CNT)) disp (
        .clk(clk_g), .resetn(resetn_g), .swap_en(swap), .kick(kick), .dir_addr(sdir), .nbands(sbands), .seq(sseq),
        .active(active), .fence_done(fence), .err(derr), .err_clr(eclr),
        .arm_claim(aclaim), .arm_grant(agrant), .band_idx(bidx), .band_done(bdone),
        .c_tvalid(c_v), .c_tready(c_r), .c_tdata(c_d), .r_tvalid(r0_v), .r_tready(r0_r), .r_tdata(r0_d),
        .f_push(f_push), .f_head(f_head), .f_len(f_len), .f_tail(f_tail), .f_full(f_full), .f_busy(fbusy),
        .chunk_done(ch_done), .chunk_link(ch_link), .link_addr(l_addr), .link_bytes(l_bytes),
        .setup_pending(spend), .perf_busy(pbusy), .wr_pending(wrp),
        .cnt_sub(dcnt[0 +: 32]), .cnt_bands0(dcnt[32 +: 32]), .cnt_bands1(dcnt[64 +: 32]), .cnt_chunks(dcnt[96 +: 32]),
        .cnt_links(dcnt[128 +: 32]), .cnt_bytes(dcnt[160 +: 32]), .cnt_kick_clocks(kclk));
    reg  cswap_run;
    always @(posedge clk_g)
        if (!resetn_g) cswap_run <= 1'b0;
        else if (kick && !active) cswap_run <= cswap;
    wire [15:0] uca; wire [283:0] ucq; wire [15:0] la; wire [63:0] lq;
    bm_setup_rom #(.UC_FILE(UC_FILE), .LUT_FILE(LUT_FILE)) rom (.clk(clk_g),
        .uc_addr0(uca[7:0]), .uc_addr1(uca[15:8]), .uc_q0(ucq[141:0]), .uc_q1(ucq[283:142]),
        .lut_addr0(la[7:0]), .lut_addr1(la[15:8]), .lut_q0(lq[31:0]), .lut_q1(lq[63:32]));
    wire [N-1:0]    e_rwe, e_sc, e_t0, e_av, e_soon, e_take, e_obav, e_alloc, e_obwe, e_drop, e_done, e_rfree, e_busy;
    wire [N-1:0]    e_rreq, e_rgnt;
    wire [N*7-1:0]  e_rwa;
    wire [N*32-1:0] e_rwd, e_yoff, e_yend, e_resx, e_resx16, e_scx0, e_scy0, e_scx1, e_scy1, e_obwd, e_iter, e_wait;
    wire [N*2-1:0]  e_slot, e_obslot, e_evslot, e_rec;
    wire [N*8-1:0]  e_obwa;
    genvar j;
    generate if (SETUP_SHARED != 0 && N == 2) begin : es
        // one engine for both units: the output-buffer write and the events go to the unit they name
        wire we, wu, dr, dn, eu, rf, ru; wire [7:0] wa; wire [31:0] wd, it, ws; wire [1:0] sl, rc;
        bm_setup_engine #(.NU(2), .LEAN(LEAN_CNT)) eng (.clk(clk_g), .resetn(resetn_g),
            .uc_addr(uca[7:0]), .uc_word(ucq[141:0]), .lut_addr(la[7:0]), .lut_data(lq[31:0]),
            .rec_req(e_rreq), .rec_gnt(e_rgnt), .rec_we(e_rwe), .rec_waddr(e_rwa), .rec_wdata(e_rwd),
            .st_yoff(e_yoff), .st_yend(e_yend), .st_resx(e_resx), .st_resx16(e_resx16),
            .st_scx0(e_scx0), .st_scy0(e_scy0), .st_scx1(e_scx1), .st_scy1(e_scy1), .st_scissor(e_sc), .st_tmu0(e_t0),
            .in_avail(e_av), .in_slot(e_slot), .in_soon(e_soon), .in_take(e_take),
            .ob_free_avail(e_obav), .ob_free_slot(e_obslot), .ob_alloc(e_alloc),
            .ob_we(we), .ob_waddr(wa), .ob_wdata(wd), .ob_wu(wu), .ev_drop(dr), .ev_done(dn), .ev_slot(sl), .ev_u(eu),
            .ev_rec_free(rf), .ev_rec(rc), .ev_rec_u(ru), .busy(e_busy), .cnt_iter(it), .cnt_tri(), .cnt_wait(ws));
        for (j = 0; j < 2; j = j + 1) begin : dm
            assign e_obwe[j] = we && (wu == j); assign e_obwa[j*8 +: 8] = wa; assign e_obwd[j*32 +: 32] = wd;
            assign e_drop[j] = dr && (eu == j); assign e_done[j] = dn && (eu == j); assign e_evslot[j*2 +: 2] = sl;
            assign e_rfree[j] = rf && (ru == j); assign e_rec[j*2 +: 2] = rc;
        end
        assign e_iter = {32'd0, it}; assign e_wait = {32'd0, ws};     // the shared engine's counters: unit 0's words
        assign uca[15:8] = 8'd0; assign la[15:8] = 8'd0;
    end else begin : ep
        // one engine a unit (engine u on ROM port u)
        for (j = 0; j < N; j = j + 1) begin : e
            wire eu, ru;
            bm_setup_engine #(.NU(1), .LEAN(LEAN_CNT)) eng (.clk(clk_g), .resetn(resetn_g),
                .uc_addr(uca[j*8 +: 8]), .uc_word(ucq[j*142 +: 142]), .lut_addr(la[j*8 +: 8]), .lut_data(lq[j*32 +: 32]),
                .rec_req(e_rreq[j]), .rec_gnt(e_rgnt[j]), .rec_we(e_rwe[j]), .rec_waddr(e_rwa[j*7 +: 7]), .rec_wdata(e_rwd[j*32 +: 32]),
                .st_yoff(e_yoff[j*32 +: 32]), .st_yend(e_yend[j*32 +: 32]), .st_resx(e_resx[j*32 +: 32]),
                .st_resx16(e_resx16[j*32 +: 32]), .st_scx0(e_scx0[j*32 +: 32]), .st_scy0(e_scy0[j*32 +: 32]),
                .st_scx1(e_scx1[j*32 +: 32]), .st_scy1(e_scy1[j*32 +: 32]), .st_scissor(e_sc[j]), .st_tmu0(e_t0[j]),
                .in_avail(e_av[j]), .in_slot(e_slot[j*2 +: 2]), .in_soon(e_soon[j]), .in_take(e_take[j]),
                .ob_free_avail(e_obav[j]), .ob_free_slot(e_obslot[j*2 +: 2]), .ob_alloc(e_alloc[j]),
                .ob_we(e_obwe[j]), .ob_waddr(e_obwa[j*8 +: 8]), .ob_wdata(e_obwd[j*32 +: 32]), .ob_wu(),
                .ev_drop(e_drop[j]), .ev_done(e_done[j]), .ev_slot(e_evslot[j*2 +: 2]), .ev_u(eu),
                .ev_rec_free(e_rfree[j]), .ev_rec(e_rec[j*2 +: 2]), .ev_rec_u(ru), .busy(e_busy[j]),
                .cnt_iter(e_iter[j*32 +: 32]), .cnt_tri(), .cnt_wait(e_wait[j*32 +: 32]));
        end
        if (N < 2) begin : rom1
            assign uca[15:8] = 8'd0; assign la[15:8] = 8'd0;
        end
    end endgenerate
    wire [N-1:0] awuser, aruser;
    wire [N*SID-1:0] awid, bid, arid, rid; wire [N*32-1:0] awaddr, araddr; wire [N*8-1:0] awlen, arlen;
    wire [N*3-1:0] awsize, arsize, awprot, arprot; wire [N*2-1:0] awburst, arburst, bresp, rresp;
    wire [N-1:0] awlock, arlock, awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
    wire [N*4-1:0] awcache, arcache; wire [N*64-1:0] wdata, rdata; wire [N*8-1:0] wstrb;
    genvar i;
    generate for (i = 0; i < N; i = i + 1) begin : u
        wire dv, dr, dl; wire [31:0] dd;              // DMA -> framer
        wire fv, fr, fl, fu; wire [31:0] fd;          // framer -> setup unit
        wire sv, sr, sl; wire [31:0] sd;              // setup unit -> core
        wire rv, rl; wire [31:0] rd; wire swp; wire [31:0] fba; wire [19:0] fbs; wire swv; wire p1, p2;
        reg  swp_q;
        always @(posedge clk_g) swp_q <= resetn_g && swp;
        wire xv, xr, xl, xu; wire [31:0] xd; wire xbusy, qbusy;   // framer -> (list FIFO) -> setup unit
        bm_cmd_framer framer (.clk(clk_g), .resetn(resetn_g),
            .d_push(f_push[i]), .d_head(f_head[i*4 +: 4]), .d_len(f_len[i*26 +: 26]), .d_tail(f_tail[i*4 +: 4]), .d_full(f_full[i]),
            .s_tvalid(dv), .s_tready(dr), .s_tlast(dl), .s_tdata(dd),
            .m_tvalid(xv), .m_tready(xr), .m_tlast(xl), .m_tuser(xu), .m_tdata(xd), .busy(xbusy));
        if (LIST_FIFO_LG != 0) begin : lf
            bm_stream_fifo #(.W(34), .LG(LIST_FIFO_LG)) fifo (.clk(clk_g), .resetn(resetn_g),
                .s_valid(xv), .s_ready(xr), .s_data({xu, xl, xd}),
                .m_valid(fv), .m_ready(fr), .m_data({fu, fl, fd}), .busy(qbusy));
        end else begin : nolf
            assign fv = xv; assign xr = fr; assign fl = xl; assign fu = xu; assign fd = xd; assign qbusy = 1'b0;
        end
        assign fbusy[i] = xbusy | qbusy;                // the fence: no list word anywhere before the setup unit
        wire [31:0] c0, c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11;
        bm_setup_unit #(.LEAN(LEAN_CNT)) setup (.clk(clk_g), .resetn(resetn_g), .swap_en(swap), .fe_set(fe_set), .fe_clr(fe_clr),
            .s_tvalid(fv), .s_tready(fr), .s_tlast(fl), .s_tuser(fu), .s_tdata(fd),
            .m_tvalid(sv), .m_tready(sr), .m_tlast(sl), .m_tdata(sd),
            .chunk_done(ch_done[i]), .chunk_link(ch_link[i]), .link_addr(l_addr[i*32 +: 32]), .link_bytes(l_bytes[i*28 +: 28]),
            .e_rec_req(e_rreq[i]), .e_rec_gnt(e_rgnt[i]),
            .e_rec_we(e_rwe[i]), .e_rec_waddr(e_rwa[i*7 +: 7]), .e_rec_wdata(e_rwd[i*32 +: 32]),
            .e_yoff(e_yoff[i*32 +: 32]), .e_yend(e_yend[i*32 +: 32]), .e_resx(e_resx[i*32 +: 32]), .e_resx16(e_resx16[i*32 +: 32]),
            .e_scx0(e_scx0[i*32 +: 32]), .e_scy0(e_scy0[i*32 +: 32]), .e_scx1(e_scx1[i*32 +: 32]), .e_scy1(e_scy1[i*32 +: 32]),
            .e_scissor(e_sc[i]), .e_tmu0(e_t0[i]),
            .e_in_avail(e_av[i]), .e_in_slot(e_slot[i*2 +: 2]), .e_in_soon(e_soon[i]), .e_in_take(e_take[i]),
            .e_ob_free_avail(e_obav[i]), .e_ob_free_slot(e_obslot[i*2 +: 2]), .e_ob_alloc(e_alloc[i]),
            .e_ob_we(e_obwe[i]), .e_ob_waddr(e_obwa[i*8 +: 8]), .e_ob_wdata(e_obwd[i*32 +: 32]),
            .e_ev_drop(e_drop[i]), .e_ev_done(e_done[i]), .e_ev_slot(e_evslot[i*2 +: 2]),
            .e_ev_rec_free(e_rfree[i]), .e_ev_rec(e_rec[i*2 +: 2]), .e_busy(e_busy[i]),
            .pending(spend[i]), .err_clr(eclr), .err_flag(serr[i]),
            .cnt_tv_in(c0), .cnt_tv_out(c1), .cnt_tv_drop(c2), .cnt_fwd(c11), .err_noraw(c6), .err_count(c7), .err_op(c8),
            .err_trunc(c9), .cnt_out_stall(c5), .cnt_nop(c10));
        assign c3 = e_iter[i*32 +: 32]; assign c4 = e_wait[i*32 +: 32];
        assign scnt[i*12*32 +: 12*32] = {c11, c10, c9, c8, c7, c6, c5, c4, c3, c2, c1, c0};
        RasterIX_IF #(
            .FRAMEBUFFER_SIZE_IN_PIXEL_LG(14), .FRAMEBUFFER_SUB_PIXEL_WIDTH(6), .FRAMEBUFFER_RGB565(1),
            .SUB_PIXEL_CALC_PRECISION(8), .FRAMEBUFFER_ENABLE_ALPHA_CHANNEL(0), .ENABLE_STENCIL_BUFFER(0),
            .ENABLE_DEPTH_BUFFER(1), .TMU_COUNT(1), .ENABLE_MIPMAPPING(1), .ENABLE_TEXTURE_FILTERING(1),
            .TEXTURE_PAGE_SIZE(TEX_PAGE), .ENABLE_EXTERNAL_TEXTURE_MEMORY(1), .CACHE_SIZE(CACHE_SIZE), .ENABLE_FOG(1),
            .MAX_TEXTURE_SIZE(256), .ADDR_WIDTH(32), .ID_WIDTH(SID), .DATA_WIDTH(64),
            .RASTERIZER_FLOAT_PRECISION(RAST_FLOAT_PREC), .RASTERIZER_FIXPOINT_PRECISION(RAST_FIX_PREC),
            .RASTERIZER_ENABLE_FLOAT_INTERPOLATION(0),
            .ENABLE_PERF_COUNTERS(LEAN_CNT ? 2 : 1),
            .EXT_CMD_FILTER(1),
            .COLOR_SWAP(COLOR_SWAP)
        ) rix (
            .aclk(clk_g), .resetn(resetn_g), .colorSwap(cswap_run), .m_axi_awuser(awuser[i]), .m_axi_aruser(aruser[i]),
            .s_cmd_axis_tvalid(c_v[i]), .s_cmd_axis_tready(c_r[i]), .s_cmd_axis_tlast(1'b0), .s_cmd_axis_tdata(c_d[i*32 +: 32]),
            .m_cmd_resp_axis_tvalid(rv), .m_cmd_resp_axis_tready(i == 0 ? r0_r : 1'b1), .m_cmd_resp_axis_tlast(rl),
            .m_cmd_resp_axis_tdata(rd),
            .m_cmdf_axis_tvalid(dv), .m_cmdf_axis_tready(dr), .m_cmdf_axis_tlast(dl), .m_cmdf_axis_tdata(dd),
            .s_cmdf_axis_tvalid(sv), .s_cmdf_axis_tready(sr), .s_cmdf_axis_tlast(sl), .s_cmdf_axis_tdata(sd),
            .swap_fb(swp), .swap_fb_enable_vsync(swv), .fb_addr(fba), .fb_size(fbs),
            .fb_swapped(!(swp && !swp_q)),
            .m_axi_awid(awid[i*SID +: SID]), .m_axi_awaddr(awaddr[i*32 +: 32]), .m_axi_awlen(awlen[i*8 +: 8]),
            .m_axi_awsize(awsize[i*3 +: 3]), .m_axi_awburst(awburst[i*2 +: 2]), .m_axi_awlock(awlock[i]),
            .m_axi_awcache(awcache[i*4 +: 4]), .m_axi_awprot(awprot[i*3 +: 3]), .m_axi_awvalid(awvalid[i]), .m_axi_awready(awready[i]),
            .m_axi_wdata(wdata[i*64 +: 64]), .m_axi_wstrb(wstrb[i*8 +: 8]), .m_axi_wlast(wlast[i]), .m_axi_wvalid(wvalid[i]),
            .m_axi_wready(wready[i]),
            .m_axi_bid(bid[i*SID +: SID]), .m_axi_bresp(bresp[i*2 +: 2]), .m_axi_bvalid(bvalid[i]), .m_axi_bready(bready[i]),
            .m_axi_arid(arid[i*SID +: SID]), .m_axi_araddr(araddr[i*32 +: 32]), .m_axi_arlen(arlen[i*8 +: 8]),
            .m_axi_arsize(arsize[i*3 +: 3]), .m_axi_arburst(arburst[i*2 +: 2]), .m_axi_arlock(arlock[i]),
            .m_axi_arcache(arcache[i*4 +: 4]), .m_axi_arprot(arprot[i*3 +: 3]), .m_axi_arvalid(arvalid[i]), .m_axi_arready(arready[i]),
            .m_axi_rid(rid[i*SID +: SID]), .m_axi_rdata(rdata[i*64 +: 64]), .m_axi_rresp(rresp[i*2 +: 2]), .m_axi_rlast(rlast[i]),
            .m_axi_rvalid(rvalid[i]), .m_axi_rready(rready[i]),
            .perfBusy(pbusy[i]), .perfTriangleRendering(p1), .perfRasterizerStall(p2),
            .perfFreeze(pfz), .perfClear(pcl), .perfAddr(paddr), .perfRdata(prd[i*32 +: 32]));
        if (i == 0) begin : resp0
            assign r0_v = rv; assign r0_d = rd;
        end
    end endgenerate
    wire [28:0] c_address; wire [7:0] c_burstcount, c_byteenable; wire [63:0] c_readdata, c_writedata;
    wire c_waitrequest, c_readdatavalid, c_read, c_write;
    wire [MID-1:0] m_awid, m_bid, m_arid, m_rid; wire [31:0] m_awaddr, m_araddr; wire [7:0] m_awlen, m_arlen;
    wire [2:0] m_awsize, m_arsize, m_awprot, m_arprot; wire [1:0] m_awburst, m_arburst, m_bresp, m_rresp;
    wire m_awlock, m_arlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
    wire m_arvalid, m_arready, m_rlast, m_rvalid, m_rready; wire [3:0] m_awcache, m_arcache, m_awqos, m_arqos, m_awreg, m_arreg;
    wire [63:0] m_wdata, m_rdata; wire [7:0] m_wstrb; wire m_awuser, m_wuser, m_aruser;
    axi_crossbar #(
        .S_COUNT(N), .M_COUNT(1), .DATA_WIDTH(64), .ADDR_WIDTH(32), .S_ID_WIDTH(SID), .M_ID_WIDTH(MID),
        .M_ADDR_WIDTH(32'd32), .S_THREADS({N{32'd4}}), .M_ISSUE(32'd16),
        .AWUSER_ENABLE(COLOR_SWAP != 0), .AWUSER_WIDTH(1), .ARUSER_ENABLE(COLOR_SWAP != 0), .ARUSER_WIDTH(1)
    ) xbar (
        .clk(clk_g), .rst(~resetn_g),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen), .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_awlock(awlock), .s_axi_awcache(awcache), .s_axi_awprot(awprot), .s_axi_awqos({N*4{1'b0}}),
        .s_axi_awuser(awuser), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast), .s_axi_wuser({N{1'b0}}), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bid(bid), .s_axi_bresp(bresp), .s_axi_buser(), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen), .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_arlock(arlock), .s_axi_arcache(arcache), .s_axi_arprot(arprot), .s_axi_arqos({N*4{1'b0}}),
        .s_axi_aruser(aruser), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rlast(rlast), .s_axi_ruser(), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst),
        .m_axi_awlock(m_awlock), .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot), .m_axi_awqos(m_awqos),
        .m_axi_awregion(m_awreg), .m_axi_awuser(m_awuser), .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast), .m_axi_wuser(m_wuser), .m_axi_wvalid(m_wvalid),
        .m_axi_wready(m_wready), .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_buser(1'b0), .m_axi_bvalid(m_bvalid),
        .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arlock(m_arlock), .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot), .m_axi_arqos(m_arqos),
        .m_axi_arregion(m_arreg), .m_axi_aruser(m_aruser), .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast), .m_axi_ruser(1'b0),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready));
    axi2avl_mo #(.ID_WIDTH(MID), .ADDR_WIDTH(32), .AVL_AW(29), .BCW(8), .NOUT(NOUT), .CSWAP(0)) adapter (
        .aclk(clk_g), .resetn(resetn_g), .nout_limit(NOUT8), .rd_outstanding(), .idle(),
        .s_awuser(m_awuser), .s_aruser(m_aruser),
        .s_awid(m_awid), .s_awaddr(m_awaddr), .s_awlen(m_awlen), .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb), .s_wlast(m_wlast), .s_wvalid(m_wvalid), .s_wready(m_wready),
        .s_bid(m_bid), .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
        .s_arid(m_arid), .s_araddr(m_araddr), .s_arlen(m_arlen), .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rid(m_rid), .s_rdata(m_rdata), .s_rresp(m_rresp), .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
        .avl_address(c_address), .avl_burstcount(c_burstcount), .avl_waitrequest(c_waitrequest),
        .avl_readdata(c_readdata), .avl_readdatavalid(c_readdatavalid), .avl_read(c_read),
        .avl_writedata(c_writedata), .avl_byteenable(c_byteenable), .avl_write(c_write));
    avl_l2_mo #(.SIZE_KB(L2_KB), .AW(29), .BCW(8), .WIN_LO(TEX_WIN_LO), .WIN_HI(TEX_WIN_HI), .SNOOP(1)) l2 (
        .clk(clk_g), .resetn(resetn_g), .inv_all(l2inv), .off(1'b0), .idle(), .hits(l2h), .misses(l2m),
        .s_address(c_address), .s_read(c_read), .s_write(c_write), .s_burstcount(c_burstcount),
        .s_writedata(c_writedata), .s_byteenable(c_byteenable), .s_waitrequest(c_waitrequest),
        .s_readdata(c_readdata), .s_readdatavalid(c_readdatavalid),
        .m_address(avl_address), .m_read(avl_read), .m_write(avl_write), .m_burstcount(avl_burstcount),
        .m_writedata(avl_writedata), .m_byteenable(avl_byteenable), .m_waitrequest(avl_waitrequest),
        .m_readdata(avl_readdata), .m_readdatavalid(avl_readdatavalid));
    generate for (i = 0; i < N; i = i + 1) begin : wp
        reg [7:0] n;
        always @(posedge clk_g)
            if (!resetn_g) n <= 8'd0;
            else n <= n + ((awvalid[i] && awready[i]) ? 8'd1 : 8'd0) - ((bvalid[i] && bready[i]) ? 8'd1 : 8'd0);
        assign wrp[i] = (n != 8'd0) || awvalid[i] || wvalid[i];
    end endgenerate
endmodule
