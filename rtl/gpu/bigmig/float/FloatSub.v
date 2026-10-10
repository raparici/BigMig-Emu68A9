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

// Floating point substraction
// This module is pipelined. It can calculate one substraction per clock
// This module has a latency of 4 clock cycles
module FloatSub 
# (
    parameter MANTISSA_SIZE = 23,
    parameter EXPONENT_SIZE = 8,
    parameter ENABLE_OPTIMIZATION = 0,
    parameter FLOAT_SIZE = 1 + EXPONENT_SIZE + MANTISSA_SIZE
)
(
    input  wire                      clk,
    input  wire                      ce,
    input  wire [FLOAT_SIZE - 1 : 0] aIn,
    input  wire [FLOAT_SIZE - 1 : 0] bIn,
    output wire [FLOAT_SIZE - 1 : 0] sum
);
    localparam SIGN_POS = MANTISSA_SIZE + EXPONENT_SIZE;

    wire [FLOAT_SIZE - 1 : 0] comp;
    assign comp = {~bIn[SIGN_POS], bIn[SIGN_POS - 1 : 0]};
    FloatAdd #(.MANTISSA_SIZE(MANTISSA_SIZE), .EXPONENT_SIZE(EXPONENT_SIZE), .ENABLE_OPTIMIZATION(ENABLE_OPTIMIZATION)) add(clk, ce, aIn, comp, sum);
endmodule
