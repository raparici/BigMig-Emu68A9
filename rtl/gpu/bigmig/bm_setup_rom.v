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

// triangle setup microcode and colour table, two read ports each

module bm_setup_rom #(
    parameter UCW = 142,
    parameter UC_FILE = "bm_setup_ucode.hex",
    parameter LUT_FILE = "bm_setup_lut.hex"
) (
    input  wire            clk,
    input  wire [7:0]      uc_addr0, uc_addr1,
    output reg  [UCW-1:0]  uc_q0, uc_q1,
    input  wire [7:0]      lut_addr0, lut_addr1,
    output reg  [31:0]     lut_q0, lut_q1
);
    (* ramstyle = "M10K" *) reg [UCW-1:0] uc [0:255];
    (* ramstyle = "M10K" *) reg [31:0] lut [0:255];
    initial begin
        $readmemh(UC_FILE, uc);
        $readmemh(LUT_FILE, lut);
    end
    always @(posedge clk) begin
        uc_q0 <= uc[uc_addr0]; uc_q1 <= uc[uc_addr1];
        lut_q0 <= lut[lut_addr0]; lut_q1 <= lut[lut_addr1];
    end
endmodule
