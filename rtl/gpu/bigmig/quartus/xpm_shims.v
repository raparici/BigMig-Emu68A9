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

// behavioural stand-ins for the Xilinx XPM memories RasterIX instantiates

module xpm_memory_sdpram #(
    parameter ADDR_WIDTH_A = 8, parameter ADDR_WIDTH_B = 8, parameter AUTO_SLEEP_TIME = 0,
    parameter BYTE_WRITE_WIDTH_A = 8, parameter CASCADE_HEIGHT = 0, parameter CLOCKING_MODE = "common_clock",
    parameter ECC_MODE = "no_ecc", parameter MEMORY_INIT_FILE = "none", parameter MEMORY_INIT_PARAM = "0",
    parameter MEMORY_OPTIMIZATION = "true", parameter MEMORY_PRIMITIVE = "block", parameter MEMORY_SIZE = 2048,
    parameter MESSAGE_CONTROL = 0, parameter READ_DATA_WIDTH_B = 8, parameter READ_LATENCY_B = 1,
    parameter READ_RESET_VALUE_B = "0", parameter RST_MODE_A = "SYNC", parameter RST_MODE_B = "SYNC",
    parameter SIM_ASSERT_CHK = 0, parameter USE_EMBEDDED_CONSTRAINT = 0, parameter USE_MEM_INIT = 0,
    parameter WAKEUP_TIME = "disable_sleep", parameter WRITE_DATA_WIDTH_A = 8, parameter WRITE_MODE_B = "read_first"
) (
    output wire dbiterrb, output reg [READ_DATA_WIDTH_B-1:0] doutb, output wire sbiterrb,
    input wire [ADDR_WIDTH_A-1:0] addra, input wire [ADDR_WIDTH_B-1:0] addrb, input wire clka, input wire clkb,
    input wire [WRITE_DATA_WIDTH_A-1:0] dina, input wire ena, input wire enb, input wire injectdbiterra,
    input wire injectsbiterra, input wire regceb, input wire rstb, input wire sleep,
    input wire [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea
);
    assign dbiterrb = 1'b0; assign sbiterrb = 1'b0;
    generate if (MEMORY_PRIMITIVE == "distributed") begin : g_mlab
        (* ramstyle = "MLAB, no_rw_check" *) reg [WRITE_DATA_WIDTH_A-1:0] mem [0:(1<<ADDR_WIDTH_A)-1];
        always @(posedge clka) if (ena && wea[0]) mem[addra] <= dina;
        always @(posedge clka) if (enb) doutb <= mem[addrb];
    end else begin : g_m10k
        (* ramstyle = "M10K, no_rw_check" *) reg [WRITE_DATA_WIDTH_A-1:0] mem [0:(1<<ADDR_WIDTH_A)-1];
        always @(posedge clka) if (ena && wea[0]) mem[addra] <= dina;
        always @(posedge clka) if (enb) doutb <= mem[addrb];
    end endgenerate
endmodule

module xpm_memory_tdpram #(
    parameter ADDR_WIDTH_A = 8, parameter ADDR_WIDTH_B = 8, parameter AUTO_SLEEP_TIME = 0,
    parameter BYTE_WRITE_WIDTH_A = 8, parameter BYTE_WRITE_WIDTH_B = 8, parameter CASCADE_HEIGHT = 0,
    parameter CLOCKING_MODE = "common_clock", parameter ECC_MODE = "no_ecc", parameter MEMORY_INIT_FILE = "none",
    parameter MEMORY_INIT_PARAM = "0", parameter MEMORY_OPTIMIZATION = "true", parameter MEMORY_PRIMITIVE = "block",
    parameter MEMORY_SIZE = 2048, parameter MESSAGE_CONTROL = 0, parameter READ_DATA_WIDTH_A = 8,
    parameter READ_DATA_WIDTH_B = 8, parameter READ_LATENCY_A = 1, parameter READ_LATENCY_B = 1,
    parameter READ_RESET_VALUE_A = "0", parameter READ_RESET_VALUE_B = "0", parameter RST_MODE_A = "SYNC",
    parameter RST_MODE_B = "SYNC", parameter SIM_ASSERT_CHK = 0, parameter USE_EMBEDDED_CONSTRAINT = 0,
    parameter USE_MEM_INIT = 0, parameter WAKEUP_TIME = "disable_sleep", parameter WRITE_DATA_WIDTH_A = 8,
    parameter WRITE_DATA_WIDTH_B = 8, parameter WRITE_MODE_A = "read_first", parameter WRITE_MODE_B = "read_first"
) (
    output wire dbiterra, output wire dbiterrb, output reg [READ_DATA_WIDTH_A-1:0] douta,
    output reg [READ_DATA_WIDTH_B-1:0] doutb, output wire sbiterra, output wire sbiterrb,
    input wire [ADDR_WIDTH_A-1:0] addra, input wire [ADDR_WIDTH_B-1:0] addrb, input wire clka, input wire clkb,
    input wire [WRITE_DATA_WIDTH_A-1:0] dina, input wire [WRITE_DATA_WIDTH_B-1:0] dinb, input wire ena,
    input wire enb, input wire injectdbiterra, input wire injectdbiterrb, input wire injectsbiterra,
    input wire injectsbiterrb, input wire regcea, input wire regceb, input wire rsta, input wire rstb, input wire sleep,
    input wire [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea, input wire [WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B-1:0] web
);
    assign dbiterra = 1'b0; assign dbiterrb = 1'b0; assign sbiterra = 1'b0; assign sbiterrb = 1'b0;
    (* ramstyle = "M10K, no_rw_check" *) reg [WRITE_DATA_WIDTH_A-1:0] mem [0:(1<<ADDR_WIDTH_A)-1];
    always @(posedge clka) begin
        if (ena && wea[0]) mem[addra] <= dina;
        if (ena) douta <= mem[addra];
    end
    always @(posedge clka) begin
        if (enb && web[0]) mem[addrb] <= dinb;
        if (enb) doutb <= mem[addrb];
    end
endmodule
