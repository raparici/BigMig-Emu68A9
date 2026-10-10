module TexQuadCache #(
    parameter TEXEL_WIDTH = 16,
    parameter DATA_WIDTH = 32,
    parameter ID_WIDTH = 4,
    parameter TEX_ADDR_WIDTH = 17,
    parameter ADDR_WIDTH = TEX_ADDR_WIDTH + 1,  // byte addresses
    parameter CACHE_SIZE = 1024,
    parameter LINE_SIZE = 32,
    parameter CREDITS = 8,                      // line fills issued and not yet written
    parameter CMDQ_LG = 5                       // run-ahead: commands between stage A and stage B
)
(
    input  wire                             aclk,
    input  wire                             resetn,
    input  wire                             invalidate,
    input  wire                             enable,
    input  wire                             nearest,

    input  wire                             s_tr_valid,
    output wire                             s_tr_ready,
    input  wire [TEX_ADDR_WIDTH - 1 : 0]    s_tr_addr_00,
    input  wire [TEX_ADDR_WIDTH - 1 : 0]    s_tr_addr_01,
    input  wire [TEX_ADDR_WIDTH - 1 : 0]    s_tr_addr_10,
    input  wire [TEX_ADDR_WIDTH - 1 : 0]    s_tr_addr_11,

    output wire                             m_tr_valid,
    input  wire                             m_tr_ready,
    output wire [TEXEL_WIDTH - 1 : 0]       m_tr_texel_00,
    output wire [TEXEL_WIDTH - 1 : 0]       m_tr_texel_01,
    output wire [TEXEL_WIDTH - 1 : 0]       m_tr_texel_10,
    output wire [TEXEL_WIDTH - 1 : 0]       m_tr_texel_11,
    output wire [ 3 : 0]                    m_tr_used,      // simulation trace only

    output wire [ID_WIDTH - 1 : 0]          m_axi_arid,
    output reg  [ADDR_WIDTH - 1 : 0]        m_axi_araddr,
    output wire [ 7 : 0]                    m_axi_arlen,
    output wire [ 2 : 0]                    m_axi_arsize,
    output wire [ 1 : 0]                    m_axi_arburst,
    output wire                             m_axi_arlock,
    output wire [ 3 : 0]                    m_axi_arcache,
    output wire [ 2 : 0]                    m_axi_arprot,
    output reg                              m_axi_arvalid,
    input  wire                             m_axi_arready,

    input  wire [ID_WIDTH - 1 : 0]          m_axi_rid,
    input  wire [DATA_WIDTH - 1 : 0]        m_axi_rdata,
    input  wire [ 1 : 0]                    m_axi_rresp,
    input  wire                             m_axi_rlast,
    input  wire                             m_axi_rvalid,
    output wire                             m_axi_rready
);
    localparam TPL      = (LINE_SIZE * 8) / TEXEL_WIDTH;       // texels a line (16)
    localparam OFF_W    = $clog2(TPL);                         // 4
    localparam LINES    = CACHE_SIZE / LINE_SIZE;              // 32
    localparam IDX_W    = $clog2(LINES);                       // 5
    localparam LADDR_W  = TEX_ADDR_WIDTH - OFF_W;              // line address (texel address >> OFF_W)
    localparam TAG_W    = LADDR_W - IDX_W;
    localparam WA_W     = IDX_W + OFF_W - 1;                   // word address inside a bank
    localparam WORDS    = 1 << WA_W;                           // texels a bank (256)
    localparam BEATS    = (LINE_SIZE * 8) / DATA_WIDTH;        // 8 at 32 bits, 4 at 64
    localparam BEAT_W   = (BEATS > 1) ? $clog2(BEATS) : 1;
    localparam integer LAST_BEAT_I = BEATS - 1;
    localparam [BEAT_W - 1 : 0] LAST_BEAT = LAST_BEAT_I[BEAT_W - 1 : 0];
    localparam TPB      = DATA_WIDTH / TEXEL_WIDTH;            // texels a beat
    localparam WPB      = TPB / 2;                             // words a bank a beat (1 or 2)
    localparam RQ_LG    = $clog2(CREDITS * BEATS);
    localparam CMD_FILL = 1'b1;
    localparam CMD_READ = 1'b0;
    // command: { type, used[3:0], 4 x { bank, word } }  (a FILL carries its line index in the low bits)
    localparam CMD_W    = 1 + 4 + 4 * (1 + WA_W);

    localparam credLimit = CREDITS;
    assign m_axi_arid    = 0;
    assign m_axi_arlen   = BEATS[7 : 0] - 8'd1;
    localparam integer AR_SIZE_I = $clog2(DATA_WIDTH / 8);
    localparam [2 : 0] AR_SIZE = AR_SIZE_I[2 : 0];
    assign m_axi_arsize  = AR_SIZE;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 0;
    assign m_axi_arcache = 0;
    assign m_axi_arprot  = 0;

    // ------------------------------------------------------------------------------------------------
    // input FIFO (2 entries): s_tr_ready depends only on a register
    // ------------------------------------------------------------------------------------------------
    localparam IN_W = 4 * TEX_ADDR_WIDTH + 2;
    reg  [IN_W - 1 : 0]     inQ [0 : 1];
    reg  [ 1 : 0]           inCnt;
    reg                     inWr, inRd;
    assign s_tr_ready = inCnt != 2;
    wire                    inPush = s_tr_valid && s_tr_ready;
    wire                    curV = inCnt != 0;
    wire [IN_W - 1 : 0]     cur = inQ[inRd];
    wire [TEX_ADDR_WIDTH - 1 : 0] curA [0 : 3];
    assign curA[0] = cur[0 * TEX_ADDR_WIDTH +: TEX_ADDR_WIDTH];
    assign curA[1] = cur[1 * TEX_ADDR_WIDTH +: TEX_ADDR_WIDTH];
    assign curA[2] = cur[2 * TEX_ADDR_WIDTH +: TEX_ADDR_WIDTH];
    assign curA[3] = cur[3 * TEX_ADDR_WIDTH +: TEX_ADDR_WIDTH];
    wire                    curNearest = cur[4 * TEX_ADDR_WIDTH + 0];
    wire                    curEnable  = cur[4 * TEX_ADDR_WIDTH + 1];
    wire [ 3 : 0]           used = !curEnable ? 4'b0000 : (curNearest ? 4'b0001 : 4'b1111);

    // ------------------------------------------------------------------------------------------------
    // stage A: tags, fills, commands
    // ------------------------------------------------------------------------------------------------
    reg                     tV [0 : LINES - 1];
    reg  [TAG_W - 1 : 0]    tT [0 : LINES - 1];
    wire [LADDR_W - 1 : 0]  la  [0 : 3];
    wire [IDX_W - 1 : 0]    idx [0 : 3];
    wire [TAG_W - 1 : 0]    tag [0 : 3];
    wire [ 3 : 0]           miss;
    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1)
        begin : g_tap
            assign la[g]   = curA[g][OFF_W +: LADDR_W];
            assign idx[g]  = la[g][0 +: IDX_W];
            assign tag[g]  = la[g][IDX_W +: TAG_W];
            assign miss[g] = used[g] && !(tV[idx[g]] && (tT[idx[g]] == tag[g]));
        end
    endgenerate
    wire [ 1 : 0]           first = miss[0] ? 2'd0 : miss[1] ? 2'd1 : miss[2] ? 2'd2 : 2'd3;

    reg  [CMD_W - 1 : 0]    cq [0 : (1 << CMDQ_LG) - 1];
    reg  [CMDQ_LG : 0]      cqWr, cqRd;
    wire [CMDQ_LG : 0]      cqCount = cqWr - cqRd;         // pointer width: a wrapped difference
    wire                    cqFull = cqCount == (1 << CMDQ_LG);
    wire                    cqEmpty = cqWr == cqRd;
    reg  [15 : 0]           cred;
    wire                    fillDone;
    wire                    arFree = !m_axi_arvalid || m_axi_arready;
    wire                    issueFill = curV && (miss != 0) && !cqFull && (cred < credLimit) && arFree && !invalidate;
    wire                    pushRead  = curV && (miss == 0) && !cqFull && !invalidate;

    wire [CMD_W - 1 : 0]    readCmd = { CMD_READ, used,
                                        curA[3][0], idx[3], curA[3][1 +: OFF_W - 1],
                                        curA[2][0], idx[2], curA[2][1 +: OFF_W - 1],
                                        curA[1][0], idx[1], curA[1][1 +: OFF_W - 1],
                                        curA[0][0], idx[0], curA[0][1 +: OFF_W - 1] };
    wire [CMD_W - 1 : 0]    fillCmd = { CMD_FILL, { (CMD_W - 1 - IDX_W) { 1'b0 } }, idx[first] };

    integer i;
    always @(posedge aclk)
    begin
        if (!resetn)
        begin
            inCnt <= 0; inWr <= 0; inRd <= 0;
            cqWr <= 0; cred <= 0;
                                                      // a second driver Quartus refuses (Error 10028); Verilator took it
            m_axi_arvalid <= 1'b0;
            for (i = 0; i < LINES; i = i + 1) tV[i] <= 1'b0;
        end
        else
        begin
            // input FIFO
            if (inPush)
            begin
                inQ[inWr] <= { enable, nearest, s_tr_addr_11, s_tr_addr_10, s_tr_addr_01, s_tr_addr_00 };
                inWr <= !inWr;
            end
            if (pushRead) inRd <= !inRd;
            inCnt <= inCnt + (inPush ? 2'd1 : 2'd0) - (pushRead ? 2'd1 : 2'd0);

            // AR channel
            if (m_axi_arvalid && m_axi_arready) m_axi_arvalid <= 1'b0;
            if (issueFill)
            begin
                m_axi_arvalid <= 1'b1;
                m_axi_araddr  <= { la[first], { (OFF_W + 1) { 1'b0 } } };
                tV[idx[first]] <= 1'b1;
                tT[idx[first]] <= tag[first];
            end
            cred <= cred + (issueFill ? 16'd1 : 16'd0) - (fillDone ? 16'd1 : 16'd0);

            // commands
            if (issueFill)
            begin
                cq[cqWr[CMDQ_LG - 1 : 0]] <= fillCmd;
                cqWr <= cqWr + 1;
            end
            else
            if (pushRead)
            begin
                cq[cqWr[CMDQ_LG - 1 : 0]] <= readCmd;
                cqWr <= cqWr + 1;
            end

            if (invalidate)
                for (i = 0; i < LINES; i = i + 1) tV[i] <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------------------------------
    // R FIFO: CREDITS lines of beats (show-ahead)
    // ------------------------------------------------------------------------------------------------
    reg  [DATA_WIDTH - 1 : 0]   rq [0 : (1 << RQ_LG) - 1];
    reg  [RQ_LG : 0]            rqWr, rqRd;
    wire                        rqEmpty = rqWr == rqRd;
    wire [RQ_LG : 0]            rqCount = rqWr - rqRd;
    wire                        rqFull = rqCount == (1 << RQ_LG);
    assign m_axi_rready = !rqFull;
    wire [DATA_WIDTH - 1 : 0]   rqHead = rq[rqRd[RQ_LG - 1 : 0]];

    // ------------------------------------------------------------------------------------------------
    // stage B: in-order fills and quad reads; two banks, two ports each
    // ------------------------------------------------------------------------------------------------
    wire [CMD_W - 1 : 0]    cmd = cq[cqRd[CMDQ_LG - 1 : 0]];
    wire                    cmdFill = !cqEmpty && (cmd[CMD_W - 1] == CMD_FILL);
    wire                    cmdRead = !cqEmpty && (cmd[CMD_W - 1] == CMD_READ);
    reg  [BEAT_W - 1 : 0]   fBeat;
    reg  [ 2 : 0]           outCnt;
    reg                     rdPend;
    wire                    outSpace = ({ 1'b0, outCnt } + { 3'b0, rdPend }) <= 4'd2;

    wire                    doFill = cmdFill && !rqEmpty;
    wire [IDX_W - 1 : 0]    fillIdx = cmd[0 +: IDX_W];
    wire                    doRead = cmdRead && outSpace;
    assign fillDone = doFill && (fBeat == LAST_BEAT);

    // the quad's taps
    wire [ 3 : 0]           rUsed = cmd[CMD_W - 2 -: 4];
    wire                    tb [0 : 3];
    wire [WA_W - 1 : 0]     tw [0 : 3];
    generate
        for (g = 0; g < 4; g = g + 1)
        begin : g_rtap
            assign tb[g] = cmd[g * (1 + WA_W) + WA_W];
            assign tw[g] = cmd[g * (1 + WA_W) +: WA_W];
        end
    endgenerate

    // per bank: port A = the first used tap in the bank, port B = the first used tap with another word
    reg                     pAv [0 : 1];
    reg  [WA_W - 1 : 0]     pAw [0 : 1];
    reg                     pBv [0 : 1];
    reg  [WA_W - 1 : 0]     pBw [0 : 1];
    reg                     selB [0 : 3];
    reg                     conflict3;
    integer cb, ct;
    always @(*)
    begin
        conflict3 = 1'b0;
        for (cb = 0; cb < 2; cb = cb + 1)
        begin
            pAv[cb] = 1'b0; pAw[cb] = 0; pBv[cb] = 1'b0; pBw[cb] = 0;
            for (ct = 0; ct < 4; ct = ct + 1)
            begin
                if (rUsed[ct] && (tb[ct] == cb[0]))
                begin
                    if (!pAv[cb]) begin pAv[cb] = 1'b1; pAw[cb] = tw[ct]; end
                    else if (tw[ct] != pAw[cb])
                    begin
                        if (!pBv[cb]) begin pBv[cb] = 1'b1; pBw[cb] = tw[ct]; end
                        else if (tw[ct] != pBw[cb]) conflict3 = 1'b1;
                    end
                end
            end
        end
        for (ct = 0; ct < 4; ct = ct + 1)
            selB[ct] = (tw[ct] != pAw[tb[ct]]);
    end

    (* ramstyle = "M10K, no_rw_check" *)
    reg  [TEXEL_WIDTH - 1 : 0]  bank0 [0 : WORDS - 1];
    (* ramstyle = "M10K, no_rw_check" *)
    reg  [TEXEL_WIDTH - 1 : 0]  bank1 [0 : WORDS - 1];
    reg  [TEXEL_WIDTH - 1 : 0]  q0A, q0B, q1A, q1B;
    // fill: beat k of the line holds texels k*TPB .. k*TPB+TPB-1; even texels go to bank 0, odd to bank 1
    wire [WA_W - 1 : 0]         fwA;
    generate
        if (WPB > 1) begin : g_fw2 assign fwA = { fillIdx, fBeat, 1'b0 }; end
        else         begin : g_fw1 assign fwA = { fillIdx, fBeat }; end
    endgenerate
    wire [WA_W - 1 : 0]         fwB = fwA + 1'b1;
    wire [WA_W - 1 : 0]         a0A = doFill ? fwA : pAw[0];
    wire [WA_W - 1 : 0]         a1A = doFill ? fwA : pAw[1];
    wire [WA_W - 1 : 0]         a0B = doFill ? fwB : pBw[0];
    wire [WA_W - 1 : 0]         a1B = doFill ? fwB : pBw[1];
    always @(posedge aclk)
    begin
        // port A
        if (doFill) bank0[a0A] <= rqHead[0 * TEXEL_WIDTH +: TEXEL_WIDTH];
        q0A <= bank0[a0A];
        if (doFill) bank1[a1A] <= rqHead[1 * TEXEL_WIDTH +: TEXEL_WIDTH];
        q1A <= bank1[a1A];
    end
    generate
        if (WPB > 1)
        begin : g_portb_fill
            // a 64-bit beat carries two even and two odd texels: port B writes the second pair
            always @(posedge aclk)
            begin
                if (doFill) bank0[a0B] <= rqHead[2 * TEXEL_WIDTH +: TEXEL_WIDTH];
                q0B <= bank0[a0B];
                if (doFill) bank1[a1B] <= rqHead[3 * TEXEL_WIDTH +: TEXEL_WIDTH];
                q1B <= bank1[a1B];
            end
        end
        else
        begin : g_portb_read
            always @(posedge aclk)
            begin
                q0B <= bank0[pBw[0]];
                q1B <= bank1[pBw[1]];
            end
        end
    endgenerate

    // output FIFO (4 quads), fed one clock after a read
    reg                     sB [0 : 3];
    reg                     sBank [0 : 3];
    reg  [ 3 : 0]           sUsed;
    reg  [4 * TEXEL_WIDTH + 4 - 1 : 0] oq [0 : 3];
    reg  [ 1 : 0]           oqWr, oqRd;
    wire [TEXEL_WIDTH - 1 : 0] rt [0 : 3];
    generate
        for (g = 0; g < 4; g = g + 1)
        begin : g_out
            assign rt[g] = !sUsed[g] ? { TEXEL_WIDTH { 1'b0 } }
                         : (sBank[g] ? (sB[g] ? q1B : q1A) : (sB[g] ? q0B : q0A));
        end
    endgenerate
    wire                    outPop = m_tr_valid && m_tr_ready;
    assign m_tr_valid = outCnt != 0;
    wire [4 * TEXEL_WIDTH + 4 - 1 : 0] oHead = oq[oqRd];
    assign m_tr_texel_00 = oHead[0 * TEXEL_WIDTH +: TEXEL_WIDTH];
    assign m_tr_texel_01 = oHead[1 * TEXEL_WIDTH +: TEXEL_WIDTH];
    assign m_tr_texel_10 = oHead[2 * TEXEL_WIDTH +: TEXEL_WIDTH];
    assign m_tr_texel_11 = oHead[3 * TEXEL_WIDTH +: TEXEL_WIDTH];
    assign m_tr_used     = oHead[4 * TEXEL_WIDTH +: 4];

    // statistics (simulation)
    integer st;
    reg [63 : 0] stQuads, stFills, stDedup, stConflict3, stFillWait, stOutWait;

    always @(posedge aclk)
    begin
        if (!resetn)
        begin
            cqRd <= 0; fBeat <= 0; rqWr <= 0; rqRd <= 0;
            outCnt <= 0; rdPend <= 0; oqWr <= 0; oqRd <= 0;
            stQuads <= 0; stFills <= 0; stDedup <= 0; stConflict3 <= 0; stFillWait <= 0; stOutWait <= 0;
        end
        else
        begin
            // R FIFO
            if (m_axi_rvalid && m_axi_rready)
            begin
                rq[rqWr[RQ_LG - 1 : 0]] <= m_axi_rdata;
                rqWr <= rqWr + 1;
            end
            if (doFill)
            begin
                rqRd <= rqRd + 1;
                fBeat <= (fBeat == LAST_BEAT) ? { BEAT_W { 1'b0 } } : fBeat + 1'b1;
            end
            // commands
            if (fillDone || doRead) cqRd <= cqRd + 1;
            // the read's data lands next clock
            rdPend <= doRead;
            if (doRead)
            begin
                for (st = 0; st < 4; st = st + 1) begin sB[st] <= selB[st]; sBank[st] <= tb[st]; end
                sUsed <= rUsed;
                stQuads <= stQuads + 1;
                if ((rUsed == 4'b1111) && !(pBv[0] && pBv[1])) stDedup <= stDedup + 1;
                if (conflict3) stConflict3 <= stConflict3 + 1;
            end
            if (fillDone) stFills <= stFills + 1;
            if (cmdFill && rqEmpty) stFillWait <= stFillWait + 1;
            if (cmdRead && !outSpace) stOutWait <= stOutWait + 1;
            if (rdPend)
            begin
                oq[oqWr] <= { sUsed, rt[3], rt[2], rt[1], rt[0] };
                oqWr <= oqWr + 1;
            end
            if (outPop) oqRd <= oqRd + 1;
            outCnt <= outCnt + (rdPend ? 3'd1 : 3'd0) - (outPop ? 3'd1 : 3'd0);
        end
    end

endmodule
