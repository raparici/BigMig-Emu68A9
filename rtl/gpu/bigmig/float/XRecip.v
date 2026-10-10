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

// Integer reciprocal
// It automatically normalizes a number to calculate the reciprocal of that.
// If the input number is a integer number in the format Q10.0, then the output
// will be a number in the format Q0.20. A Q0.10 as input is outputted as Q10.10.
// This module is pipelined. It can calculate one reciprocal per clock.
// It requires 7 + (ITERATIONS * 3) clocks to calculate the inverse of a number.
// Every iteration doubles the precision, starting with 6 bit initial estimation.
// Means two iterations resulting in 24bit precision.
module XRecip
# (
    parameter NUMBER_WIDTH = 24,
    parameter ITERATIONS = 2,
    parameter SIGNED_NUMBER_WIDTH = NUMBER_WIDTH + 1,
    parameter EXPONENT_SIZE = $clog2(NUMBER_WIDTH) + 1
)
(
    input  wire                                         clk,
    input  wire                                         ce,
    input  wire [NUMBER_WIDTH - 1 : 0]                  in,
    output reg  [NUMBER_WIDTH + NUMBER_WIDTH - 1 : 0]   out
);
    ////////////////////////////////////////////////////////////////////////////
    // STEP 0
    // Find exponent
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg  [NUMBER_WIDTH - 1 : 0]     step0_number;

    wire [EXPONENT_SIZE - 1 : 0]    step0_exponent;
    LeadingOneFinder #(
        .OUT_SIZE(EXPONENT_SIZE),
        .VALUE_SIZE(NUMBER_WIDTH)
    ) leadingOneFinder (
        .clk(clk),
        .ce(ce),
        .value(in),
        .out(step0_exponent)
    );
    always @(posedge clk)
    if (ce) begin
        step0_number <= in;
    end

    ////////////////////////////////////////////////////////////////////////////
    // STEP 1
    // Normalize number
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg  [SIGNED_NUMBER_WIDTH - 1 : 0]  step1_number;
    reg  [EXPONENT_SIZE - 1 : 0]        step1_exponent;
    always @(posedge clk)
    if (ce) begin
        step1_exponent <= step0_exponent;
        step1_number <= { 1'b0, step0_number << (NUMBER_WIDTH[0 +: EXPONENT_SIZE] - step0_exponent - 1) };
    end

    ////////////////////////////////////////////////////////////////////////////
    // STEP 2
    // Compute 
    // Clocks: 4 + (ITERATIONS * 3)
    ////////////////////////////////////////////////////////////////////////////
    wire [(SIGNED_NUMBER_WIDTH * 2) - 2 : 0]    step2_number;
    wire [EXPONENT_SIZE - 1 : 0]                step2_exponent;

    ComputeRecip #(
        .MS(SIGNED_NUMBER_WIDTH),
        .ITR(ITERATIONS)
    ) step2recip (
        .clk(clk),
        .ce(ce),
        .d(step1_number),
        .v(step2_number)
    );

    ValueDelay #(.VALUE_SIZE(EXPONENT_SIZE), .DELAY(4 + (ITERATIONS * 3))) 
        step2exponent (.clk(clk), .ce(ce), .in(step1_exponent), .out(step2_exponent));

    ////////////////////////////////////////////////////////////////////////////
    // STEP 3 
    // Denormalize 
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    always @(posedge clk)
    if (ce) begin
        out <= step2_number[0 +: NUMBER_WIDTH + NUMBER_WIDTH] >> step2_exponent;
    end

endmodule
