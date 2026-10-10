// Float
// https://github.com/ToNi3141/Float
// Copyright (c) 2021 ToNi3141

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

module LeadingOneFinder
#(
    parameter OUT_SIZE = 8,
    parameter VALUE_SIZE = 23
)
(
    input  wire                     clk,
    input  wire                     ce,
    input  wire [VALUE_SIZE - 1 : 0]    value,
    output reg  [OUT_SIZE - 1 : 0] out
);
    localparam ITERATOR_SIZE = VALUE_SIZE + 1;
    // Should not be a problem in real hardware?
    /* verilator lint_off UNOPTFLAT */
    wire [OUT_SIZE - 1 : 0] tmp [0 : ITERATOR_SIZE - 1];
    /* verilator lint_on UNOPTFLAT */
    assign tmp[0] = {OUT_SIZE{1'b1}}; // Default when no one was found
    generate 
        genvar i;
        for(i = 0; i < ITERATOR_SIZE - 1; i = i + 1)
        begin : g_q17_1
            // if a one was found, use the current i as value, otherwise return the value from the previous step.
            // The biggest value will be found at the end of the array 
            assign tmp[i + 1] = value[i] ? i : tmp[i]; 
        end
    endgenerate

    always @(posedge clk)
    if (ce) begin
        out <= tmp[ITERATOR_SIZE - 1];
    end
endmodule
