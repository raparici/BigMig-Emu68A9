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

// Module to calculate the reciprocal of a normalized number (1.0 ... 1.9999..). Other numbers are not supported.
// Hint: As soon as a number is normalized (number is shifted to the right until the MSb is 1), it can be interpretet as 1.x,
// Doesn't matter if it is an integer or only the fraction of a number.
// This is based on the paper: An Efficient Hardware Implementation for a Reciprocal Unit
// See: https://www.researchgate.net/publication/220804890_An_Efficient_Hardware_Implementation_for_a_Reciprocal_Unit
// The calculation of the initial value is basically the same, but the multiplexers are 
// all removed. They are not needed in a pipelined version, because all hardware is by
// the nature of a pipeline always utilized and must exist several times.
// It requires 4 + (ITR * 3) clock cycles
// Every iteration doubles the precision, starting with 6 bit initial estimation.
// Means two iterations resulting in 24bit precision.
module ComputeRecip #(
    parameter MS = 25,
    parameter ITR = 2
)
(
    input  wire                                 clk,
    input  wire                                 ce,
    input  wire signed [MS - 1 : 0]             d, // S1.23
    output wire signed [(MS - 1) + MS - 1 : 0]  v // S1.46
);

    ////////////////////////////////////////////////////////////////////////////
    // STEP 0 
    // Calculate the initial estimation with a precission of around 6 bits
    // Note: This equation has only the precission on a range from 0.5 - 1.0.
    // Therefore always add to the mantissa the hidden one. The lowest value of
    // mantissa will then be 1.0 and the highest 1.9999. The calculation 
    // 1 / mantissa will now have a range between 0.5 - 1.0.
    // Clocks: 4
    ////////////////////////////////////////////////////////////////////////////
    wire signed [MS - 1 : 0]  step0_mantissa;
    wire signed [MS - 1 : 0]  step0_mantissaDenumerator;

    NewtonRaphsonIterationInit #(
        .MS(MS)
    ) newtonIterationInit (
        .clk(clk),
        .ce(ce),
        .a(18'b0_010_10100111110011), // 2.65548
        .b(18'b1_010_00010010011111), // -5.92781
        .c(18'b0_100_01001000101011), // 4.28387
        .D(d),
        .x0(step0_mantissa)
    );

    ValueDelay #(.VALUE_SIZE(MS), .DELAY(4)) 
        step0mantissaNegative (.clk(clk), .ce(ce), .in(~d + { { ( MS - 1) { 1'b0 } }, 1'b1 }), .out(step0_mantissaDenumerator));

    ////////////////////////////////////////////////////////////////////////////
    // STEP 1 
    // Calculate the iterations
    // It double the precision by each iteration.
    // Clocks: 3 * ITR
    ////////////////////////////////////////////////////////////////////////////
    wire signed [((MS - 1) + MS) - 1 : 0]   step1_mantissa[ITR : 0];
    wire signed [MS - 1 : 0]                step1_mantissaDenumerator[ITR : 0];

    assign step1_mantissa[0] = { step0_mantissa, { (MS - 1) { 1'b0 } } };
    assign step1_mantissaDenumerator[0] = step0_mantissaDenumerator;

    generate
        genvar i;
        for (i = 0; i < ITR; i = i + 1)
        begin : g_q17_1
            NewtonRaphsonIteration #(
                .MS(MS)
            ) newtonIteration (
                .clk(clk),
                .ce(ce),
                .x0(step1_mantissa[i][MS - 1 +: MS]),
                .Dn(step1_mantissaDenumerator[i]),
                .x1(step1_mantissa[i + 1])
            );

            ValueDelay #(.VALUE_SIZE(MS), .DELAY(3)) 
                step1mantissaNegative (.clk(clk), .ce(ce), .in(step1_mantissaDenumerator[i]), .out(step1_mantissaDenumerator[i + 1]));

        end
    endgenerate

    assign v = step1_mantissa[ITR];
endmodule 

// This module implements the following equation: x1 = x0 * (2 - x0 * D) = x0 * (x0 * -D + 2)
// Clocks: 3
module NewtonRaphsonIteration #(
    // Includes 1 Sign, 1 Integer and rest are the fraction bits. For a float 32 with 23 bit mantissa, this must be 25.
    parameter MS = 25 // S1.23
)
(
    input  wire                                 clk,
    input  wire                                 ce,
    input  wire signed [MS - 1 : 0]             x0, // S1.23
    input  wire signed [MS - 1 : 0]             Dn, // S1.23
    output reg  signed [(MS - 1) + MS - 1 : 0]  x1 // S1.23
);
    localparam [(MS + 2) - 1 : 0] TWO = { 3'b0_10, { ((MS + 2) - 3) { 1'b0 } } }; // signed 2.0 as S2.24

    ////////////////////////////////////////////////////////////////////////////
    // STEP 0 
    // x1 = x0 * -D
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg signed [MS - 1 : 0]         step0_x0; // S1.23
    reg signed [MS + MS - 1 : 0]    step0_x1; // S2.x
    always @(posedge clk)
    if (ce) begin
        step0_x0 <= x0;
        step0_x1 <= x0 * Dn;
    end

    ////////////////////////////////////////////////////////////////////////////
    // STEP 1 
    // x1 = x1 + 2.0
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg signed [MS - 1 : 0]     step1_x0; // S1.23
    reg        [MS - 1 : 0]     step1_x1; // Q2.x
    always @(posedge clk)
    if (ce) begin : step1
        reg signed [(MS + 3) - 1 : 0] x1;
        x1 = $signed(step0_x1[(MS - 2) +: (MS + 2)]) + $signed(TWO);
        step1_x0 <= step0_x0;
        step1_x1 <= x1[0 +: MS];
    end

    ////////////////////////////////////////////////////////////////////////////
    // STEP 2 
    // x1 = x0 * x1
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg [MS + MS - 1 : 0] step2_x1; // Q3.x
    always @(posedge clk)
    if (ce) begin : step2
        step2_x1 = step1_x0 * step1_x1;
        x1 <= { 1'b0, step2_x1[0 +: (MS - 1) + MS - 1] }; // Convert Q3.x to S1.x
    end
endmodule

// This module implements the following equation: x0 = a*x² + b*D + c
// Clocks: 4
module NewtonRaphsonIterationInit #(
    // Includes 1 Sign, 1 Integer and rest are the fraction bits. For a float 32 with 23 bit mantissa, this must be 25.
    parameter MS = 25, // S1.23
    parameter FS = 18 // S3.14
)
(
    input  wire                         clk,
    input  wire                         ce,
    input  wire signed [FS - 1 : 0]     a, // S3.14
    input  wire signed [FS - 1 : 0]     b, // S3.14
    input  wire signed [FS - 1 : 0]     c, // S3.14
    input  wire signed [MS - 1 : 0]     D, // S1.23
    output reg  signed [MS - 1 : 0]     x0 // S1.23
);
`define ConvertFStoMS(x) { x[(FS > MS) ? (FS - MS) : 0 +: (FS > MS) ? MS : FS], { (MS > FS) ? (MS - FS) : 0 { 1'b0 } } }

    ////////////////////////////////////////////////////////////////////////////
    // STEP 0 
    // x0 = a * D 
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg signed [FS - 1 : 0]         step0_b; // S3.14
    reg signed [FS - 1 : 0]         step0_c; // S3.14
    reg signed [MS - 1 : 0]         step0_x; // S1.23
    reg signed [FS + MS - 1 : 0]    step0_x0; // S4.38
    always @(posedge clk)
    if (ce) begin
        step0_b <= b;
        step0_c <= c;
        step0_x <= D;
        step0_x0 <= a * D;
    end

    ////////////////////////////////////////////////////////////////////////////
    // STEP 1 
    // x0 = x0 + b
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg signed [FS - 1 : 0] step1_c; // S3.14
    reg signed [MS - 1 : 0] step1_x; // S1.23
    reg signed [MS - 1 : 0] step1_x0; // S4.x
    always @(posedge clk)
    if (ce) begin
        step1_c <= step0_c;
        step1_x <= step0_x;
        step1_x0 <= $signed(step0_x0[(FS + MS) - MS +: MS]) + ($signed(`ConvertFStoMS(step0_b)) >>> 1);
    end

    ////////////////////////////////////////////////////////////////////////////
    // STEP 2 
    // x0 = x0 * D
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////
    reg signed [FS - 1 : 0]         step2_c; // S3.14
    reg signed [MS + MS - 1 : 0]    step2_x0; // S5.x
    always @(posedge clk)
    if (ce) begin
        step2_c <= step1_c;
        step2_x0 <= step1_x * step1_x0;
    end

    ////////////////////////////////////////////////////////////////////////////
    // STEP 3 
    // x0 = x0 + c
    // Clocks: 1
    ////////////////////////////////////////////////////////////////////////////.x
    always @(posedge clk)
    if (ce) begin : step3
        reg signed [MS - 1 : 0] tmp; // S5.x
        tmp = $signed(step2_x0[MS +: MS]) + ($signed(`ConvertFStoMS(step2_c)) >>> 2); 
        x0 <= $signed({ tmp[0 +: MS - 4], 4'b0 }); // Convert S5.x to S1.x by shiftig by four
    end
endmodule
