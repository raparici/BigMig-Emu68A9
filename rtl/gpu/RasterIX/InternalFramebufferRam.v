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

// Wrapper around the dual port RAM to provide a
// multiplexed interface for two ports.
module InternalFramebufferRam
#(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 16,
    parameter WRITE_STROBE_WIDTH = 8,
    parameter NUMBER_OF_PIXELS = 1,
    parameter NUMBER_OF_SUB_PIXELS = 1,
    parameter [63 : 0] LANE_WIDTHS = 0,
    parameter WRITE_MASK_WIDTH = (LANE_WIDTHS != 0) ? NUMBER_OF_PIXELS * NUMBER_OF_SUB_PIXELS : DATA_WIDTH / WRITE_STROBE_WIDTH
)
(
    input   wire                            clk,
    input   wire                            reset,

    input   wire                            enablePort0,
    input   wire                            enablePort1,

    // Write interface port 1
    input  wire [DATA_WIDTH - 1 : 0]        writeDataPort0,
    input  wire                             writeEnablePort0,
    input  wire [ADDR_WIDTH - 1 : 0]        writeAddrPort0,
    input  wire [WRITE_MASK_WIDTH - 1 : 0]  writeMaskPort0, 

    // Read interface port 1
    output wire [DATA_WIDTH - 1 : 0]        readDataPort0,
    input  wire [ADDR_WIDTH - 1 : 0]        readAddrPort0,

    // Write interface port 2
    input  wire [DATA_WIDTH - 1 : 0]        writeDataPort1,
    input  wire                             writeEnablePort1,
    input  wire [ADDR_WIDTH - 1 : 0]        writeAddrPort1,
    input  wire [WRITE_MASK_WIDTH - 1 : 0]  writeMaskPort1, 

    // Read interface port 2
    output wire [DATA_WIDTH - 1 : 0]        readDataPort1,
    input  wire [ADDR_WIDTH - 1 : 0]        readAddrPort1
);
    // Multiplexed interface to the internal memory
    wire [ADDR_WIDTH - 1 : 0]       memBusAddrWrite     = (enablePort0) ? writeAddrPort0    : writeAddrPort1;
    wire [DATA_WIDTH - 1 : 0]       memBusDataIn        = (enablePort0) ? writeDataPort0    : writeDataPort1;
    wire                            memBusWriteEnable   = (enablePort0) ? writeEnablePort0  : writeEnablePort1;
    wire [WRITE_MASK_WIDTH - 1 : 0] memBusWriteMask     = (enablePort0) ? writeMaskPort0    : writeMaskPort1;
    wire [ADDR_WIDTH - 1 : 0]       memBusAddrRead      = (enablePort0) ? readAddrPort0     : readAddrPort1;
    wire [DATA_WIDTH - 1 : 0]       memBusDataOut;
    assign readDataPort0 = memBusDataOut;
    assign readDataPort1 = memBusDataOut;

    function integer laneW;
        input integer j;
        laneW = (LANE_WIDTHS >> (8 * j)) & 255;
    endfunction
    function integer laneOff;
        input integer j;
        integer i;
        begin
            laneOff = 0;
            for (i = 0; i < j; i = i + 1)
                laneOff = laneOff + laneW(i);
        end
    endfunction
    localparam PIXEL_BITS = laneOff(NUMBER_OF_SUB_PIXELS);

    generate
        if (LANE_WIDTHS == 0)
        begin : g_uniform
            // Instance of the internal memory
            DualPortRam ramTile (
                .clk(clk),
                .reset(reset),

                .writeData(memBusDataIn),
                .write(memBusWriteEnable & (enablePort0 | enablePort1)),
                .writeAddr(memBusAddrWrite),
                .writeMask(memBusWriteMask),

                .readData(memBusDataOut),
                .readAddr(memBusAddrRead)
            );
            defparam ramTile.ADDR_WIDTH = ADDR_WIDTH;
            defparam ramTile.MEM_WIDTH = DATA_WIDTH;
            defparam ramTile.WRITE_STROBE_WIDTH = WRITE_STROBE_WIDTH;
        end
        else
        begin : g_lanes
            genvar p, j;
            for (p = 0; p < NUMBER_OF_PIXELS; p = p + 1)
            begin : g_pixel
                for (j = 0; j < NUMBER_OF_SUB_PIXELS; j = j + 1)
                begin : g_lane
                    localparam LW = laneW(j);
                    localparam LO = (p * PIXEL_BITS) + laneOff(j);
                    DualPortRam ramLane (
                        .clk(clk),
                        .reset(reset),

                        .writeData(memBusDataIn[LO +: LW]),
                        .write(memBusWriteEnable & (enablePort0 | enablePort1)),
                        .writeAddr(memBusAddrWrite),
                        .writeMask(memBusWriteMask[(p * NUMBER_OF_SUB_PIXELS) + j]),

                        .readData(memBusDataOut[LO +: LW]),
                        .readAddr(memBusAddrRead)
                    );
                    defparam ramLane.ADDR_WIDTH = ADDR_WIDTH;
                    defparam ramLane.MEM_WIDTH = LW;
                    defparam ramLane.WRITE_STROBE_WIDTH = LW;
                end
            end
        end
    endgenerate

endmodule
