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

// Just delays values. For instance, if the DELAY is configured to 4, the 
// value in 'in' will appear after four clock cycles in 'out'. This is useful 
// to implement equations with interim results to easily delay them to the 
// next pipeline step.
// This module is pipelined
module ValueDelay #(
    parameter VALUE_SIZE = 32,
    parameter DELAY = 4
)
(
    input  wire                         clk,
    input  wire                         ce,
    input  wire [VALUE_SIZE - 1 : 0]    in,
    output wire [VALUE_SIZE - 1 : 0]    out
);
    integer i;
    generate 
        if (DELAY > 0)
        begin
            reg  [VALUE_SIZE - 1 : 0] delay[0 : DELAY - 1];
            always @(posedge clk)
            if (ce) begin
                for (i = 0; i < DELAY - 1; i = i + 1)
                begin : g_q17_1
                    delay[i] <= delay[i + 1];
                end
                delay[DELAY - 1] <= in;
            end
            assign out = delay[0];
        end
        else
        begin
            assign out = in;
        end
    endgenerate
endmodule
