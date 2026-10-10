// Float
// https://github.com/ToNi3141/Float
// Copyright (c) 2024 ToNi3141

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
// This is based on the paper: An Efficient Hardware Implementation for a Reciprocal Unit
// See: https://www.researchgate.net/publication/220804890_An_Efficient_Hardware_Implementation_for_a_Reciprocal_Unit
// The calculation of the initial value is basically the same, but the multiplexers are 
// all removed. They are not needed in a pipelined version, because all hardware is by
// the nature of a pipeline always utilized and must exist several times.
// Note: It currently does not handle special cases like inf, NaN or division through zero.
// This module is pipelined. It can calculate one reciprocal per clock.
// It requires 11 clocks to calculate the inverse of a number.
module FloatRecip
# (
    parameter MANTISSA_SIZE = 23,
    parameter EXPONENT_SIZE = 8, // To avoid problems with the MAGIC_NUMBER, disable the configuration of the exponent
    parameter SIGNED_MANZISSA_SIZE = MANTISSA_SIZE + 2, // S1.23
    parameter FLOAT_SIZE = 1 + EXPONENT_SIZE + MANTISSA_SIZE,
    parameter EXPONENT_BIAS = (2 ** (EXPONENT_SIZE - 1)) - 1,
    parameter EXPONENT_INF = (2 ** EXPONENT_SIZE) - 1
)
(
    input  wire                      clk,
    input  wire                      ce,
    input  wire [FLOAT_SIZE - 1 : 0] in,
    output reg  [FLOAT_SIZE - 1 : 0] out
);
    ////////////////////////////////////////////////////////////////////////////
    // STEP 0 
    // Unpack
    // Clocks: 0
    ////////////////////////////////////////////////////////////////////////////
    wire [EXPONENT_SIZE - 1 : 0]    step0_exp       = in[MANTISSA_SIZE +: EXPONENT_SIZE];
    wire                            step0_sign      = in[MANTISSA_SIZE + EXPONENT_SIZE +: 1];
    wire [MANTISSA_SIZE - 1 : 0]    step0_mantissa  = in[0 +: MANTISSA_SIZE];

    ////////////////////////////////////////////////////////////////////////////
    // STEP 1
    // Calculate
    // Clocks: 10
    ////////////////////////////////////////////////////////////////////////////
    wire [EXPONENT_SIZE - 1 : 0]        step1_exp;
    wire                                step1_sign;
    wire [SIGNED_MANZISSA_SIZE - 1 : 0] step1_mantissa;

    ValueDelay #(.VALUE_SIZE(EXPONENT_SIZE), .DELAY(10)) 
        step1exponent (.clk(clk), .ce(ce), .in(EXPONENT_BIAS - (step0_exp - EXPONENT_BIAS + 1)), .out(step1_exp));

    ValueDelay #(.VALUE_SIZE(1), .DELAY(10)) 
        step1sign (.clk(clk), .ce(ce), .in(step0_sign), .out(step1_sign));

    wire signed [SIGNED_MANZISSA_SIZE - 1 : 0]                              mt = { 1'b0, 1'b1, step0_mantissa[0 +: MANTISSA_SIZE] };
    wire        [(SIGNED_MANZISSA_SIZE - 1) + SIGNED_MANZISSA_SIZE - 1 : 0] step1_mantissa_big;
    ComputeRecip #(
        .MS(SIGNED_MANZISSA_SIZE),
        .ITR(2)
    ) recip (
        .clk(clk),
        .ce(ce),
        .d(mt),
        .v(step1_mantissa_big)
    );
    assign step1_mantissa = step1_mantissa_big[SIGNED_MANZISSA_SIZE - 1 +: SIGNED_MANZISSA_SIZE];

    ////////////////////////////////////////////////////////////////////////////
    // STEP 2 
    // Pack 
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    always @(posedge clk)
    if (ce) begin
        out <= { step1_sign, step1_exp + { EXPONENT_SIZE { !(step1_mantissa[MANTISSA_SIZE]) } }, step1_mantissa[0 +: MANTISSA_SIZE] };
    end

endmodule
