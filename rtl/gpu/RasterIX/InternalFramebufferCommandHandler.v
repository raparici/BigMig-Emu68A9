// RasterIX
// https://github.com/ToNi3141/RasterIX
// Copyright (c) 2025 ToNi3141

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Handles the internal framebuffer commands.
// It will handle the commands to clear the framebuffer, apply a scissor
// and read/write the framebuffer content.
module InternalFramebufferCommandHandler
#(
    // Number of pixels a stream beat contains
    parameter NUMBER_OF_PIXELS_PER_BEAT = 2,
    
    // Number of sub pixels the interface of this module contains
    parameter NUMBER_OF_SUB_PIXELS = 4,
    // Number of bits of each sub pixel contains
    parameter SUB_PIXEL_WIDTH = 8,

    // The maximum size of the screen in power of two
    parameter X_BIT_WIDTH = 11,
    parameter Y_BIT_WIDTH = 11,
    parameter FRAMEBUFFER_SIZE_IN_PIXEL_LG = 18, // Framebuffer size in power of two words (PIXEL_WIDTH)

    // The maximum size stream size
    parameter FB_SIZE_IN_PIXEL_LG = 20,

    // Address width
    parameter ADDR_WIDTH = 32,

    // Size of the pixels
    parameter PIXEL_WIDTH = NUMBER_OF_SUB_PIXELS * SUB_PIXEL_WIDTH,

    // Size of the internal memory
    parameter INT_MEM_SIZE = FRAMEBUFFER_SIZE_IN_PIXEL_LG,

    // Width of the AXIS interface with the frame buffer content
    parameter STREAM_WIDTH = NUMBER_OF_PIXELS_PER_BEAT * PIXEL_WIDTH,

    // Number of pixels a AXIS beat or a memory line can contain
    parameter PIXEL_PER_BEAT_LOG2 = $clog2(NUMBER_OF_PIXELS_PER_BEAT),
    // Size constrains of the internal memory
    parameter MEM_PIXEL_WIDTH = NUMBER_OF_SUB_PIXELS * SUB_PIXEL_WIDTH,
    parameter MEM_MASK_WIDTH = NUMBER_OF_PIXELS_PER_BEAT * NUMBER_OF_SUB_PIXELS,
    parameter MEM_WIDTH = MEM_MASK_WIDTH * SUB_PIXEL_WIDTH,
    parameter MEM_ADDR_WIDTH = INT_MEM_SIZE - PIXEL_PER_BEAT_LOG2
)
(
    input   wire                            aclk,
    input   wire                            resetn,

    /////////////////////////
    // Configs
    /////////////////////////
    input  wire [PIXEL_WIDTH - 1 : 0]       confClearColor,
    input  wire                             confEnableScissor,
    input  wire [X_BIT_WIDTH - 1 : 0]       confScissorStartX,
    input  wire [Y_BIT_WIDTH - 1 : 0]       confScissorStartY,
    input  wire [X_BIT_WIDTH - 1 : 0]       confScissorEndX,
    input  wire [Y_BIT_WIDTH - 1 : 0]       confScissorEndY,
    input  wire [Y_BIT_WIDTH - 1 : 0]       confYOffset,
    input  wire [X_BIT_WIDTH - 1 : 0]       confXResolution,
    input  wire [Y_BIT_WIDTH - 1 : 0]       confYResolution,
    input  wire [NUMBER_OF_SUB_PIXELS - 1 : 0] confMask,
    input  wire                             confClearOnCommit,
    input  wire                             pipeWrite,      // the pixel pipeline wrote this band RAM
    input  wire                             cmdClearFull,

    /////////////////////////
    // RAM interface
    /////////////////////////
    output reg  [MEM_WIDTH - 1 : 0]         writeDataPort,
    output reg                              writeEnablePort,
    output wire [MEM_ADDR_WIDTH - 1 : 0]    writeAddrPort,
    output reg  [MEM_MASK_WIDTH - 1 : 0]    writeMaskPort, 

    // Read interface port 1
    input  wire [MEM_WIDTH - 1 : 0]         readDataPort,
    output wire [MEM_ADDR_WIDTH - 1 : 0]    readAddrPort,
    
    /////////////////////////
    // Control
    /////////////////////////

    // Cmd interface
    input  wire                                 apply, // This start a command 
    output reg                                  applied, // This marks if the commands have been applied.
    input  wire                                 cmdCommit, // Starts to stream the memory content via the AXIS interface
    input  wire                                 cmdRead, // Starts to read the memory content via the AXIS interface
    input  wire                                 cmdMemset, // Applies the confClearColor (with respect to the scissor) to the memory
    input  wire [FB_SIZE_IN_PIXEL_LG - 1 : 0]   cmdSize, // Size of the stream 
    input  wire [ADDR_WIDTH - 1 : 0]            cmdAddr,

    // AXI Stream master interface
    output reg                              m_axis_tvalid,
    input  wire                             m_axis_tready,
    output reg                              m_axis_tlast,
    output reg  [STREAM_WIDTH - 1 : 0]      m_axis_tdata,
    output reg  [MEM_MASK_WIDTH - 1 : 0]    m_axis_tstrb,

    input  wire                             s_axis_tvalid,
    output reg                              s_axis_tready,
    input  wire                             s_axis_tlast,
    input  wire [STREAM_WIDTH - 1 : 0]      s_axis_tdata,

    output reg                              m_avalid,
    output reg  [ADDR_WIDTH - 1 : 0]        m_aaddr,
    output reg  [ADDR_WIDTH - 1 : 0]        m_abeats,
    input  wire                             m_aready,
    output reg                              m_arnw // 0 = read, 1 = write
);
    // Stream states
    localparam COMMAND_WAIT_FOR_COMMAND = 0;
    localparam COMMAND_COMMIT = 1;
    localparam COMMAND_MEMSET = 2;
    localparam COMMAND_READ = 3;
    localparam COMMAND_CLEAR_TAIL = 4;
    localparam COMMAND_SKIP = 5;
    
    // State variables
    reg  [MEM_ADDR_WIDTH - 1 : 0]   cmdMemAddr;
    wire [MEM_ADDR_WIDTH - 1 : 0]   cmdMemAddrNext = cmdMemAddr + 1;
    reg  [5 : 0]                    cmdState;
    reg  [MEM_ADDR_WIDTH - 1 : 0]   cmdFbSizeInBeats;
    
    // Scissor variables
    reg  [X_BIT_WIDTH - 1 : 0]      scissorX;
    reg  [Y_BIT_WIDTH - 1 : 0]      scissorY;
    wire [X_BIT_WIDTH - 1 : 0]      scissorXNext = scissorX + NUMBER_OF_PIXELS_PER_BEAT;
    wire [Y_BIT_WIDTH - 1 : 0]      scissorYNext = scissorY - 1;
    wire [MEM_MASK_WIDTH - 1 : 0]   scissorPixelAndColorMask;
    reg  [X_BIT_WIDTH - 1 : 0]      scissorStartX;
    reg  [Y_BIT_WIDTH - 1 : 0]      scissorStartY;
    reg  [X_BIT_WIDTH - 1 : 0]      scissorEndX;
    reg  [Y_BIT_WIDTH - 1 : 0]      scissorEndY;

    // Skid buffer
    reg  [STREAM_WIDTH - 1 : 0]     skidBufferData;
    reg                             skidBufferValid;
    reg                             skidBufferLast;
    reg  [MEM_MASK_WIDTH - 1 : 0]   skidBufferStrb;

    reg                             cocActive;
    reg                             forceFull;
    reg  [5 : 0]                    cmdStateQ;
    always @(posedge aclk) cmdStateQ <= cmdState;
    reg  [PIXEL_WIDTH - 1 : 0]      cocValue;
    reg  [MEM_ADDR_WIDTH : 0]       clrNext;
    reg  [MEM_ADDR_WIDTH - 1 : 0]   clrAddr;
    reg                             clean;
    reg  [PIXEL_WIDTH - 1 : 0]      cleanValue;
    wire                            fullMask = &confMask;
    wire                            memsetIsFull = !confEnableScissor && fullMask;
    wire                            clrInCommit = (clrNext + 2) <= { 1'b0, cmdMemAddr };
    // a full band's size wraps the MEM_ADDR_WIDTH-bit word count to 0 (the stock loops rely on the wrap)
    wire [MEM_ADDR_WIDTH : 0]       fbWords = (cmdFbSizeInBeats == 0) ? (1 << MEM_ADDR_WIDTH) : { 1'b0, cmdFbSizeInBeats };
    wire                            clrTailDone = clrNext >= fbWords;
    assign writeAddrPort = ((cmdState == COMMAND_COMMIT) || (cmdState == COMMAND_CLEAR_TAIL)) ? clrAddr : cmdMemAddr;

    assign readAddrPort = cmdMemAddr;
    wire                            readPortReady;
    wire                            readPortLast;
    wire [MEM_MASK_WIDTH - 1 : 0]   readPortStrb;
    wire                            commitActive = cmdState == COMMAND_COMMIT;

    ValueDelay #(
        .VALUE_SIZE(2 + MEM_MASK_WIDTH),
        .DELAY(1)
    ) readDataPortDelay (
        .clk(aclk),
        .ce(1),
        .in({ commitActive, cmdMemAddrNext == cmdFbSizeInBeats, scissorPixelAndColorMask }),
        .out({ readPortReady, readPortLast, readPortStrb })
    );

    InternalFramebufferScissor #(
        .NUMBER_OF_PIXELS_PER_BEAT(NUMBER_OF_PIXELS_PER_BEAT),
        .NUMBER_OF_SUB_PIXELS(NUMBER_OF_SUB_PIXELS),
        .X_BIT_WIDTH(X_BIT_WIDTH),
        .Y_BIT_WIDTH(Y_BIT_WIDTH)
    ) scissorInst (
        .confEnableScissor(confEnableScissor || commitActive),
        .confScissorStartX(scissorStartX),
        .confScissorStartY(scissorStartY),
        .confScissorEndX(scissorEndX),
        .confScissorEndY(scissorEndY),
        .x(scissorX),
        .y(scissorY),

        .pixelMask(scissorPixelAndColorMask)
    );

    // Command execution
    always @(posedge aclk)
    begin
        if (!resetn)
        begin
            cmdState <= COMMAND_WAIT_FOR_COMMAND;
            writeEnablePort <= 0;
            applied <= 1;
            m_axis_tlast <= 0;
            m_axis_tvalid <= 0;
            skidBufferValid <= 0;
            m_avalid <= 0;
            s_axis_tready <= 0;
            cocActive <= 0;
            clean <= 0;
            forceFull <= 0;
        end
        else
        begin
            if (pipeWrite)
                clean <= 0;
            case (cmdState)
            COMMAND_WAIT_FOR_COMMAND:
            begin : waitForCommand
                cmdMemAddr <= 0;
                scissorX <= 0;
                writeEnablePort <= 0;

                cmdFbSizeInBeats <= cmdSize[PIXEL_PER_BEAT_LOG2 +: MEM_ADDR_WIDTH];

                if (apply && !m_avalid)
                begin
                    applied <= 0;

                    if (cmdMemset) 
                    begin
                        // Here is a mismatch between the RAM addresses and the OpenGL coordinate system.
                        // OpenGL starts at the lower left corner. But this is a fairly high address in the RAM.
                        // The cmdMemAddr starts at zero. This is basically in OpenGL the position (0, confYResolution - 1)
                        scissorY <= confYOffset + confYResolution - 1;

                        scissorStartX <= confScissorStartX;
                        scissorStartY <= confScissorStartY;
                        scissorEndX <= confScissorEndX;
                        scissorEndY <= confScissorEndY;

                        if (confClearOnCommit && clean && memsetIsFull && (cleanValue == confClearColor) && !cmdCommit && !cmdRead)
                            cmdState <= COMMAND_SKIP;
                        else
                        begin
                            cmdState <= COMMAND_MEMSET;
                            clean <= 0;
                            cleanValue <= confClearColor;
                            cocActive <= memsetIsFull || cmdClearFull;   // reused: this MEMSET leaves the band clean
                            forceFull <= cmdClearFull;
                        end
                    end

                    m_abeats <= { 12'b0, cmdSize } >> PIXEL_PER_BEAT_LOG2;
                    m_aaddr <= cmdAddr;

                    if (cmdCommit)
                    begin
                        cocActive <= confClearOnCommit && fullMask;
                        cocValue <= confClearColor;
                        clrNext <= 0;
                        m_avalid <= 1;
                        m_arnw <= 1;
                        scissorY <= confYResolution - 1;
                        scissorStartX <= 0;
                        scissorStartY <= 0;
                        scissorEndX <= confXResolution;
                        scissorEndY <= confYResolution;

                        cmdState <= COMMAND_COMMIT;
                    end

                    if (cmdRead)
                    begin
                        clean <= 0;
                        s_axis_tready <= 1;
                        m_avalid <= 1;
                        m_arnw <= 0;

                        cmdState <= COMMAND_READ;
                    end
                end
                else 
                begin
                    if (!m_avalid)
                    begin
                        applied <= 1;
                    end
                end
            end
            COMMAND_COMMIT:
            begin
                if (cocActive && clrInCommit && !clrTailDone)
                begin
                    writeEnablePort <= 1;
                    writeDataPort <= { NUMBER_OF_PIXELS_PER_BEAT { cocValue } };
                    writeMaskPort <= { MEM_MASK_WIDTH { 1'b1 } };
                    clrAddr <= clrNext[MEM_ADDR_WIDTH - 1 : 0];
                    clrNext <= clrNext + 1;
                end
                else
                    writeEnablePort <= 0;
                if (m_axis_tready || !m_axis_tvalid)
                begin
                    m_axis_tvalid <= readPortReady;
                    if (!m_axis_tlast)
                    begin
                        if (skidBufferValid)
                        begin
                            m_axis_tdata <= skidBufferData;
                            m_axis_tstrb <= skidBufferStrb;
                            m_axis_tlast <= skidBufferLast;
                            skidBufferValid <= 0;
                        end
                        else
                        begin
                            m_axis_tdata <= readDataPort;
                            m_axis_tstrb <= readPortStrb;
                            m_axis_tlast <= readPortLast;
                        end

                        cmdMemAddr <= cmdMemAddrNext;
                        if (scissorXNext == confXResolution)
                        begin
                            scissorX <= 0;
                            scissorY <= scissorYNext;
                        end
                        else
                        begin
                            scissorX <= scissorXNext;
                        end
                    end

                    // Check if we reached the end of the copy process
                    if (m_axis_tlast)
                    begin
                        m_axis_tvalid <= 0;
                        m_axis_tlast <= 0;
 
                        cmdState <= cocActive ? COMMAND_CLEAR_TAIL : COMMAND_WAIT_FOR_COMMAND;
                    end
                end
                else
                begin
                    if (readPortReady && !skidBufferValid)
                    begin
                        skidBufferData <= readDataPort;
                        skidBufferStrb <= readPortStrb;
                        skidBufferLast <= readPortLast;
                        skidBufferValid <= 1;
                    end
                end
            end
            COMMAND_READ:
            begin
                if (s_axis_tvalid && s_axis_tready)
                begin
                    if (s_axis_tlast)
                    begin
                        s_axis_tready <= 0;
                    end
                    if (writeEnablePort)
                    begin
                        cmdMemAddr <= cmdMemAddrNext;
                    end
                    writeMaskPort <= ~0;
                    writeDataPort <= s_axis_tdata;
                    writeEnablePort <= 1;
                end
                if (!s_axis_tready)
                begin
                    writeEnablePort <= 0;
                    cmdState <= COMMAND_WAIT_FOR_COMMAND;
                end
            end
            COMMAND_MEMSET:
            begin
                if (cmdMemAddrNext == cmdFbSizeInBeats)
                begin
                    writeEnablePort <= 0;
                    cmdState <= COMMAND_WAIT_FOR_COMMAND;
                    clean <= cocActive;
                    cocActive <= 0;
                    forceFull <= 0;
                end
                else
                begin
                    writeEnablePort <= 1;
                end

                if (writeEnablePort)
                begin
                    cmdMemAddr <= cmdMemAddrNext;
                end
                writeDataPort <= { NUMBER_OF_PIXELS_PER_BEAT { confClearColor } };
                writeMaskPort <= forceFull ? { MEM_MASK_WIDTH { 1'b1 } } : ({ NUMBER_OF_PIXELS_PER_BEAT { confMask } } & scissorPixelAndColorMask);

                if (scissorXNext == confXResolution)
                begin
                    scissorX <= 0;
                    scissorY <= scissorYNext;
                end
                else
                begin
                    scissorX <= scissorXNext;
                end
            end
            COMMAND_CLEAR_TAIL:
            begin
                if (!clrTailDone)
                begin
                    writeEnablePort <= 1;
                    writeDataPort <= { NUMBER_OF_PIXELS_PER_BEAT { cocValue } };
                    writeMaskPort <= { MEM_MASK_WIDTH { 1'b1 } };
                    clrAddr <= clrNext[MEM_ADDR_WIDTH - 1 : 0];
                    clrNext <= clrNext + 1;
                end
                else
                begin
                    writeEnablePort <= 0;
                    cocActive <= 0;
                    clean <= 1;
                    cleanValue <= cocValue;
                    cmdState <= COMMAND_WAIT_FOR_COMMAND;
                end
            end
            COMMAND_SKIP:
            begin
                if (!apply)
                    cmdState <= COMMAND_WAIT_FOR_COMMAND;
            end
            endcase
        end
        if (m_avalid && m_aready)
        begin
            m_avalid <= 0;
        end
    end
endmodule

module InternalFramebufferScissor
#(
    // Number of pixels a stream beat contains
    parameter NUMBER_OF_PIXELS_PER_BEAT = 2,
    
    // Number of sub pixels the interface of this module contains
    parameter NUMBER_OF_SUB_PIXELS = 4,

    // The maximum size of the screen in power of two
    parameter X_BIT_WIDTH = 11,
    parameter Y_BIT_WIDTH = 11,

    parameter MASK_WIDTH = NUMBER_OF_PIXELS_PER_BEAT * NUMBER_OF_SUB_PIXELS
)
(
    input  wire                       confEnableScissor,
    input  wire [X_BIT_WIDTH - 1 : 0] confScissorStartX,
    input  wire [Y_BIT_WIDTH - 1 : 0] confScissorStartY,
    input  wire [X_BIT_WIDTH - 1 : 0] confScissorEndX,
    input  wire [Y_BIT_WIDTH - 1 : 0] confScissorEndY,
    input  wire [X_BIT_WIDTH - 1 : 0] x,
    input  wire [Y_BIT_WIDTH - 1 : 0] y,

    output wire [MASK_WIDTH - 1 : 0]  pixelMask
);
    `include "InternalFramebufferScissorFunc.vh"

    wire [NUMBER_OF_PIXELS_PER_BEAT - 1 : 0] scissorPixelMask;

    genvar i, j;
    generate
        if (NUMBER_OF_PIXELS_PER_BEAT == 1)
        begin 
            assign scissorPixelMask = scissorFunc(confEnableScissor, confScissorStartX, confScissorStartY, confScissorEndX, confScissorEndY, x, y);
            assign pixelMask = { NUMBER_OF_SUB_PIXELS { scissorPixelMask } };
        end
        else
        begin
            for (i = 0; i < NUMBER_OF_PIXELS_PER_BEAT; i = i + 1)
            begin : g_q17_1
                assign scissorPixelMask[i] = scissorFunc(confEnableScissor, confScissorStartX, confScissorStartY, confScissorEndX, confScissorEndY, x + i, y);
                for (j = 0; j < NUMBER_OF_SUB_PIXELS; j = j + 1)
                begin : g_q17_2
                    assign pixelMask[(i * NUMBER_OF_SUB_PIXELS) + j] = scissorPixelMask[i];
                end
            end
        end
    endgenerate

endmodule
