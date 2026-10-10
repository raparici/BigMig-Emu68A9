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

// Floating point addition
// This module is pipelined. It can calculate one addition per clock
// This module has a latency of 4 clock cycles
module FloatAdd
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
    output reg  [FLOAT_SIZE - 1 : 0] sum
);
    localparam MANTISSA_POS = 0;
    localparam EXPONENT_POS = MANTISSA_SIZE;
    localparam SIGN_POS = EXPONENT_POS + EXPONENT_SIZE;
  
    localparam MANTISSA_CALC_SIZE = MANTISSA_SIZE + 3; // Adding sign, first digit, one bit for overflow
    localparam MANTISSA_CALC_SIGN_POS = MANTISSA_CALC_SIZE - 1;
    localparam MANTISSA_CALC_ONE_POS = MANTISSA_SIZE + 1;
    localparam MANTISSA_WIDTH_LOG2 = $clog2(MANTISSA_SIZE);
    localparam MANTISSA_ONE_POS_SIZE = $clog2(MANTISSA_SIZE) + 1;
    localparam EXPONENT_INVALID_VALUE = (2 ** MANTISSA_ONE_POS_SIZE) - 1;

    wire [MANTISSA_ONE_POS_SIZE - 1 : 0] three_exponentCorrection;
    LeadingOneFinder #(
        .OUT_SIZE(MANTISSA_ONE_POS_SIZE), 
        .VALUE_SIZE(MANTISSA_CALC_SIZE)
    ) leadingOneFinder (
        .clk(clk), 
        .ce(ce), 
        .value(two_mantissaSum),
        .out(three_exponentCorrection)
    );

    reg                               one_bigNumberSign;
    reg                               one_smallNumberSign;
    reg  [EXPONENT_SIZE - 1 : 0]      one_bigNumberExponent;
    reg  [EXPONENT_SIZE - 1 : 0]      one_smallNumberExponent;
    reg  [MANTISSA_CALC_SIZE - 1 : 0] one_bigNumberMantissa;
    reg  [MANTISSA_CALC_SIZE - 1 : 0] one_smallNumberMantissa;
    reg  [EXPONENT_SIZE - 1 : 0]      one_exponentDiff;
    reg  [MANTISSA_CALC_SIZE - 1 : 0] one_smallNumberMantissaDenormalized;
    reg                               one_exponentDiffGreaterZero;
    always @(posedge clk)
    if (ce) begin : UnpackAndAdapt
        reg  [FLOAT_SIZE - 1 : 0] bigNumber;
        reg  [FLOAT_SIZE - 1 : 0] smallNumber;
        reg                       expSmallGreaterThanZero;
        reg                       expBigGreaterThanZero;

        // The addition requires that we have the same exponent for the big and small number.
        // Usually the small number will be adapted to the big number.
        if (aIn[EXPONENT_POS +: EXPONENT_SIZE] < bIn[EXPONENT_POS +: EXPONENT_SIZE])
        begin
            bigNumber = bIn;
            smallNumber = aIn;
        end
        else 
        begin
            bigNumber = aIn;
            smallNumber = bIn;
        end
        one_bigNumberExponent = bigNumber[EXPONENT_POS +: EXPONENT_SIZE];
        one_smallNumberExponent = smallNumber[EXPONENT_POS +: EXPONENT_SIZE];

        expSmallGreaterThanZero = one_smallNumberExponent > 0;
        expBigGreaterThanZero = one_bigNumberExponent > 0;

        one_bigNumberMantissa = {2'b0, expBigGreaterThanZero, bigNumber[MANTISSA_POS +: MANTISSA_SIZE]};

        // Denormalize the small mantissa to enable the summerization with the big exponent
        one_exponentDiff = one_bigNumberExponent - one_smallNumberExponent;
        // The timing here is really stressed. A fifth pipeline step could reduce stress here ...
        if (one_exponentDiff >= MANTISSA_SIZE[0 +: EXPONENT_SIZE])
        begin
            // If the small number is too small, set everything to zero
            one_smallNumberMantissa = 0;
            one_smallNumberMantissaDenormalized = 0;
        end
        else 
        begin
            // If the small number is big enough for summerization, denormalize it!
            one_smallNumberMantissa = {2'b0, expSmallGreaterThanZero, smallNumber[MANTISSA_POS +: MANTISSA_SIZE]};
            one_smallNumberMantissaDenormalized = one_smallNumberMantissa >>> one_exponentDiff[0 +: MANTISSA_WIDTH_LOG2];
        end

        one_exponentDiffGreaterZero = one_exponentDiff > 0;
        one_bigNumberSign <= bigNumber[SIGN_POS];
        one_smallNumberSign <= smallNumber[SIGN_POS];
    end

    reg  [MANTISSA_CALC_SIZE - 1 : 0] two_mantissaSum;
    reg                               two_mantissaSumSign;
    reg  [EXPONENT_SIZE - 1 : 0]      two_bigNumberExponent;
    reg  [EXPONENT_SIZE - 1 : 0]      two_smallNumberExponent;
    always @(posedge clk)
    if (ce) begin : Calc
        reg  [MANTISSA_CALC_SIZE - 1 : 0] smallNumberMantissaDenormalized;
        reg  [MANTISSA_CALC_SIZE - 1 : 0] bigNumberMantissaSigned;
        reg  [MANTISSA_CALC_SIZE - 1 : 0] smallNumberMantissaSigned;
        reg  [MANTISSA_CALC_SIZE - 1 : 0] sumMantissa;

        // We should round when we shift the mantissa (which is done in the previous step)
        // But we can also omit that and save logic and latency (when the rounding error can be accepted)
        if (ENABLE_OPTIMIZATION || !one_exponentDiffGreaterZero)
        begin
            smallNumberMantissaDenormalized = one_smallNumberMantissaDenormalized;
        end
        else 
        begin
            smallNumberMantissaDenormalized = one_smallNumberMantissaDenormalized + {{(MANTISSA_CALC_SIZE - 1){1'b0}}, one_smallNumberMantissa[one_exponentDiff - 1]};
        end

        // Convert unsigned number into a signed
        if (one_bigNumberSign)
        begin
            bigNumberMantissaSigned = $signed(~one_bigNumberMantissa) + 1;
        end
        else 
        begin
            bigNumberMantissaSigned = one_bigNumberMantissa;
        end

        // Convert unsigned number into a signed
        if (one_smallNumberSign)
        begin
            smallNumberMantissaSigned = $signed(~smallNumberMantissaDenormalized) + 1;
        end
        else 
        begin
            smallNumberMantissaSigned = smallNumberMantissaDenormalized;
        end

        // Calculate the sum
        sumMantissa = $signed(bigNumberMantissaSigned) + $signed(smallNumberMantissaSigned);

        // Safe the sign of the sum
        two_mantissaSumSign = sumMantissa[MANTISSA_CALC_SIGN_POS];

        // Convert signed sum back to a unsigned number
        if (two_mantissaSumSign)
        begin
            two_mantissaSum <= ~sumMantissa + 1;
        end
        else
        begin
            two_mantissaSum <= sumMantissa;
        end
        two_bigNumberExponent <= one_bigNumberExponent;
        two_smallNumberExponent <= one_smallNumberExponent;
    end
    
    reg  [EXPONENT_SIZE - 1 : 0]            three_bigNumberExponent;
    reg  [EXPONENT_SIZE - 1 : 0]            three_smallNumberExponent;
    reg  [MANTISSA_CALC_SIZE - 1 : 0]       three_sumMantissa;
    reg                                     three_sumMantissaSign;
    always @(posedge clk)
    if (ce) begin
        three_bigNumberExponent <= two_bigNumberExponent;
        three_smallNumberExponent <= two_smallNumberExponent;
        three_sumMantissa <= two_mantissaSum;
        three_sumMantissaSign <= two_mantissaSumSign;
    end

    always @(posedge clk)
    if (ce) begin : Pack
        reg  [EXPONENT_SIZE - 1 : 0] sumExponent;
        reg  [MANTISSA_SIZE - 1 : 0] normalizedMantissa;
        reg  [MANTISSA_CALC_SIZE - 1 : 0] normalizedMantissaCalc;

        // No one was found in the mantissa 
        // Or the exponent of both numbers was zero and the mantissa is till too small to increment the exponent
        if ((three_exponentCorrection == EXPONENT_INVALID_VALUE) 
            || ((three_bigNumberExponent == 0) && (three_smallNumberExponent == 0) && (three_exponentCorrection < MANTISSA_SIZE[0 +: MANTISSA_ONE_POS_SIZE])))
        begin
            sumExponent = 0;
        end
        // Both exponents are zero but the mantissa is big enough to increment the exponent
        else if ((three_bigNumberExponent == 0) && (three_smallNumberExponent == 0) && (three_exponentCorrection == MANTISSA_SIZE[0 +: MANTISSA_ONE_POS_SIZE]))
        begin
            sumExponent = 1;
        end
        // The mantissa got smaller, so the new expoent has to be decremented
        else if (three_exponentCorrection < MANTISSA_SIZE[0 +: MANTISSA_ONE_POS_SIZE])
        begin
            sumExponent = three_bigNumberExponent - {{(EXPONENT_SIZE - MANTISSA_ONE_POS_SIZE){1'h0}}, (MANTISSA_SIZE[0 +: MANTISSA_ONE_POS_SIZE] - three_exponentCorrection)};
        end
        // In all other cases, the exponent can be incremented
        else 
        begin
            sumExponent = three_bigNumberExponent + {{(EXPONENT_SIZE - 1){1'b0}}, three_sumMantissa[MANTISSA_CALC_ONE_POS]};
        end

        // Check if we have to shift the mantissa
        // If the small number was already a denormalized number and the mantissa is still normalized, then we don't need to do anything with the mantissa.
        if ((three_smallNumberExponent == 0) && (three_exponentCorrection < MANTISSA_SIZE[0 +: MANTISSA_ONE_POS_SIZE]))
        begin
            normalizedMantissaCalc = three_sumMantissa;
        end
        // If no one was found in the mantissa, do nothing
        else if (three_exponentCorrection == EXPONENT_INVALID_VALUE)
        begin
            // we could assign a zero here or assign the calculated mantissa, which is obviously also zero. Otherwise we would have found a one and wouldn't be in this case ... 
            normalizedMantissaCalc = three_sumMantissa;
        end
        // We found a denormalized mantissa (a mantissa, which is too small). We have to shift it to the left now till it is normalized
        else if (three_exponentCorrection < (MANTISSA_SIZE[0 +: MANTISSA_ONE_POS_SIZE] + 1))
        begin
            normalizedMantissaCalc = three_sumMantissa << (MANTISSA_SIZE[0 +: MANTISSA_WIDTH_LOG2] - three_exponentCorrection[0 +: MANTISSA_WIDTH_LOG2]);
        end
        // We found a denormalized mantissa, which is too big, for that reason, we have to shift it to the right
        else
        begin
            normalizedMantissaCalc = three_sumMantissa >> 1; // In an addition, we can only shift by one to the right. More is not possible because the summation result can only overflow by one bit
        end
        normalizedMantissa = normalizedMantissaCalc[0 +: MANTISSA_SIZE];

        sum <= {three_sumMantissaSign, sumExponent, normalizedMantissa};
    end
endmodule
