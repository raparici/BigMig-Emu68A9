`default_nettype none
module PixelScoreboard #(
    parameter INDEX_WIDTH = 14,       // band pixel index width (FRAMEBUFFER_SIZE_IN_PIXEL_LG)
    parameter DATA_WIDTH = 64,        // the other rasterizer fields, carried unchanged
    parameter FIFO_DEPTH_LG = 8,      // in-flight tpixel beats tracked; must exceed the semaphore
                                      // depth (2^READ_FIFO_SIZE) + the per-fragment pipeline tail
    parameter CLEAR_ON_RESET = 1
) (
    input  wire                         aclk,
    input  wire                         resetn,

    input  wire                         needsRead,     // current state reads colour, depth, stencil or logic-op dest

    // from the rasterizer
    input  wire                         s_tvalid,
    output wire                         s_tready,
    input  wire                         s_tpixel,
    input  wire                         s_tkeep,
    input  wire                         s_tlast,
    input  wire [INDEX_WIDTH - 1 : 0]   s_tindex,
    input  wire [DATA_WIDTH - 1 : 0]    s_tdata,

    // to the pixel pipeline (the StreamSemaphore)
    output wire                         m_tvalid,
    input  wire                         m_tready,
    output wire                         m_tpixel,
    output wire                         m_tkeep,
    output wire                         m_tlast,
    output wire [INDEX_WIDTH - 1 : 0]   m_tindex,
    output wire [DATA_WIDTH - 1 : 0]    m_tdata,

    // one strobe per tpixel beat leaving the pipeline, in order (RasterIX's ValueTrack decrement),
    // with its framebuffer index
    input  wire                         retire,
    input  wire [INDEX_WIDTH - 1 : 0]   retireIndex,

    output wire                         clearing,
    output wire                         hazardStall,   // a fragment waits for an older one of its pixel
    output wire                         fullStall,     // the in-flight FIFO is full (not expected)
    output reg                          underflow      // sticky: a retire with nothing in flight (not expected)
);
    localparam W = 3 + INDEX_WIDTH + DATA_WIDTH;
    localparam N = 2 ** INDEX_WIDTH;

    ////////////////////////////////////////////////////////////////////////////
    // Input skid buffer: the ready seen by the rasterizer is a register, so the
    // table lookup below is not on the rasterizer's enable path.
    ////////////////////////////////////////////////////////////////////////////
    wire            kValid;
    wire            kReady;
    wire [W - 1 : 0] kAll;
    skidbuffer #(
        .OPT_OUTREG(0),
        .OPT_PASSTHROUGH(0),
        .DW(W)
    ) inSkid (
        .i_clk(aclk),
        .i_reset(!resetn),
        .i_valid(s_tvalid),
        .o_ready(s_tready),
        .i_data({ s_tpixel, s_tkeep, s_tlast, s_tindex, s_tdata }),
        .o_valid(kValid),
        .i_ready(kReady),
        .o_data(kAll)
    );
    wire [INDEX_WIDTH - 1 : 0] kIndex = kAll[DATA_WIDTH +: INDEX_WIDTH];

    reg                         clr;
    reg  [INDEX_WIDTH - 1 : 0]  clrAddr;
    always @(posedge aclk)
    begin
        if (!resetn)
        begin
            clr <= (CLEAR_ON_RESET != 0);
            clrAddr <= 0;
        end
        else if (clr)
        begin
            clrAddr <= clrAddr + 1;
            if (&clrAddr)
                clr <= 0;
        end
    end
    assign clearing = clr;

    ////////////////////////////////////////////////////////////////////////////
    // Check stage X
    ////////////////////////////////////////////////////////////////////////////
    reg                         xValid;
    reg                         xPixel;
    reg                         xKeep;
    reg                         xLast;
    reg  [INDEX_WIDTH - 1 : 0]  xIndex;
    reg  [DATA_WIDTH - 1 : 0]   xData;

    // table read data, aligned with X (read with X's address one clock earlier)
    reg                         sQ;
    reg                         cQ;
    // last clock's table writes, forwarded
    reg                         lastSWe;
    reg                         lastSWd;
    reg  [INDEX_WIDTH - 1 : 0]  lastSWa;
    reg                         lastCWe;
    reg                         lastCWd;
    reg  [INDEX_WIDTH - 1 : 0]  lastCWa;

    wire sCur = (lastSWe && (lastSWa == xIndex)) ? lastSWd : sQ;
    wire cCur = (lastCWe && (lastCWa == xIndex)) ? lastCWd : cQ;
    wire busy = sCur ^ cCur;

    wire fifoFull;
    wire xProducer = xPixel & xKeep & needsRead;
    assign hazardStall = xValid & xProducer & busy;
    assign fullStall = xValid & xPixel & fifoFull;
    wire xGo = xValid & !hazardStall & !fullStall;
    wire xLeave = xGo & m_tready;
    assign kReady = !clr & (!xValid | xLeave);
    wire xLoad = kValid & kReady;

    assign m_tvalid = xGo;
    assign m_tpixel = xPixel;
    assign m_tkeep = xKeep;
    assign m_tlast = xLast;
    assign m_tindex = xIndex;
    assign m_tdata = xData;

    always @(posedge aclk)
    begin
        if (!resetn)
            xValid <= 0;
        else if (xLoad)
            xValid <= 1;
        else if (xLeave)
            xValid <= 0;

        if (xLoad)
            { xPixel, xKeep, xLast, xIndex, xData } <= kAll;
    end

    ////////////////////////////////////////////////////////////////////////////
    // In-flight FIFO: { producer, new S value } per tpixel beat, popped by retire
    ////////////////////////////////////////////////////////////////////////////
    reg  [1 : 0]                fifo [0 : (2 ** FIFO_DEPTH_LG) - 1];
    reg  [FIFO_DEPTH_LG : 0]    wp;
    reg  [FIFO_DEPTH_LG : 0]    rp;
    wire fifoEmpty = (wp == rp);
    assign fifoFull = (wp[FIFO_DEPTH_LG] != rp[FIFO_DEPTH_LG]) && (wp[0 +: FIFO_DEPTH_LG] == rp[0 +: FIFO_DEPTH_LG]);
    wire [1 : 0] head = fifo[rp[0 +: FIFO_DEPTH_LG]];
    wire push = xLeave & xPixel;
    wire pop = retire & !fifoEmpty;

    always @(posedge aclk)
    begin
        if (push)
            fifo[wp[0 +: FIFO_DEPTH_LG]] <= { xProducer, !sCur };
        if (!resetn)
        begin
            wp <= 0;
            rp <= 0;
            underflow <= 0;
        end
        else
        begin
            if (push)
                wp <= wp + 1;
            if (pop)
                rp <= rp + 1;
            if (retire & fifoEmpty)
                underflow <= 1;
        end
    end

    ////////////////////////////////////////////////////////////////////////////
    // The two tables
    ////////////////////////////////////////////////////////////////////////////
    wire                        sWe = clr | (xLeave & xProducer);
    wire [INDEX_WIDTH - 1 : 0]  sWa = clr ? clrAddr : xIndex;
    wire                        sWd = clr ? 1'b0 : !sCur;
    wire                        cWe = clr | (pop & head[1]);
    wire [INDEX_WIDTH - 1 : 0]  cWa = clr ? clrAddr : retireIndex;
    wire                        cWd = clr ? 1'b0 : head[0];
    wire [INDEX_WIDTH - 1 : 0]  rdAddr = xLoad ? kIndex : xIndex;

    (* ramstyle = "no_rw_check" *) reg sTab [0 : N - 1];
    (* ramstyle = "no_rw_check" *) reg cTab [0 : N - 1];

    always @(posedge aclk)
    begin
        sQ <= sTab[rdAddr];
        cQ <= cTab[rdAddr];
        if (sWe)
            sTab[sWa] <= sWd;
        if (cWe)
            cTab[cWa] <= cWd;
    end

    always @(posedge aclk)
    begin
        if (!resetn)
        begin
            lastSWe <= 0;
            lastCWe <= 0;
        end
        else
        begin
            lastSWe <= sWe;
            lastCWe <= cWe;
        end
        lastSWa <= sWa;
        lastSWd <= sWd;
        lastCWa <= cWa;
        lastCWd <= cWd;
    end
endmodule
`default_nettype wire
