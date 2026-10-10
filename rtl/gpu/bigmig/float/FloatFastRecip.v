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

// Floating point reciprocal
// This module is pipelined. It can calculate one reciprocal per clock
// This module uses an magic algorithm to calculate that. It has an error of around 5%
// Refer to https://en.wikipedia.org/wiki/Fast_inverse_square_root
// This module has a latency of 4 clock cycles
module FloatFastRecip 
# (
    parameter MANTISSA_SIZE = 23,
    parameter EXPONENT_SIZE = 8, // To make the implementation a bit more simple, disallow exponent adaption
    parameter FLOAT_SIZE = 1 + EXPONENT_SIZE + MANTISSA_SIZE
)
(
    input  wire                      clk,
    input  wire                      ce,
    input  wire [FLOAT_SIZE - 1 : 0] in,
    output wire [FLOAT_SIZE - 1 : 0] out
);
    localparam MAGIC_NUMBER = 32'hbe6eb3be >> (32 - FLOAT_SIZE); // Some magic number
    reg [FLOAT_SIZE - 1 : 0] inSub;

    always @(posedge clk)
    if (ce) begin
        inSub <= (MAGIC_NUMBER[0 +: FLOAT_SIZE] - in) >> 1;
    end

    FloatMul 
    #(
        .MANTISSA_SIZE(MANTISSA_SIZE),
        .EXPONENT_SIZE(EXPONENT_SIZE),
        .DELAY(1)
    ) 
    floatMul 
    (
        .clk(clk),
        .ce(ce),
        .facAIn(inSub),
        .facBIn(inSub),
        .prod(out)
    );
endmodule
