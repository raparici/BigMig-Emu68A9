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

// Floating point multiplication
// This module is pipelined. It can calculate one multiplication per clock
// This module has a latency of 2 clock cycles minimum
module FloatMul
# (
    parameter MANTISSA_SIZE = 23,
    parameter EXPONENT_SIZE = 8,
    parameter DELAY = 2, // Use this delay to add clock cycles. It adds by default 2 clock cycles, so that the multiplier requieres 4 clocks.
    parameter FLOAT_SIZE = 1 + EXPONENT_SIZE + MANTISSA_SIZE
)
(
    input  wire                      clk,
    input  wire                      ce,
    input  wire [FLOAT_SIZE - 1 : 0] facAIn,
    input  wire [FLOAT_SIZE - 1 : 0] facBIn,
    output wire [FLOAT_SIZE - 1 : 0] prod
);
    localparam MANTISSA_POS = 0;
    localparam EXPONENT_POS = MANTISSA_SIZE;
    localparam SIGN_POS = EXPONENT_POS + EXPONENT_SIZE;

    localparam EXPONENT_BIAS = (2 ** (EXPONENT_SIZE - 1)) - 1;
    localparam EXPONENT_INF = (2 ** EXPONENT_SIZE) - 1;

    localparam MANTISSA_CALC_SIZE = MANTISSA_SIZE + 1; // Add hidden bit
    localparam MANTISSA_PROD_SIZE = MANTISSA_CALC_SIZE * 2;
    localparam EXPONENT_SUM_ADDITIONAL_BITS = 1 + 1; // Add one bit for sign and one for overflow
    localparam EXPONENT_SUM_SIZE = EXPONENT_SIZE + EXPONENT_SUM_ADDITIONAL_BITS; 

    reg  [FLOAT_SIZE - 1 : 0]           prodReg;

    reg  [EXPONENT_SUM_SIZE - 1 : 0]    one_facAExponent;
    reg  [EXPONENT_SUM_SIZE - 1 : 0]    one_facBExponent;
    reg  [MANTISSA_PROD_SIZE - 1 : 0]   one_mantissaProd;
    reg                                 one_mantissaProdSign;
    reg  [EXPONENT_SIZE - 1 : 0]        one_exponentSum;
    reg                                 one_exponentUnderflow;
    reg                                 one_exponentOverflow;
    always @(posedge clk)
    if (ce) begin : UnpackAndCompute
        // Unpack
        reg  [FLOAT_SIZE - 1 : 0]   facA;
        reg  [FLOAT_SIZE - 1 : 0]   facB;
        reg                         expFacBGreaterThanZero;
        reg                         expFacAGreaterThanZero;
        reg  [MANTISSA_CALC_SIZE - 1 : 0] facAMantissa;
        reg  [MANTISSA_CALC_SIZE - 1 : 0] facBMantissa;
        reg                         facASign;
        reg                         facBSign;
        // Compute
        reg signed [EXPONENT_SUM_SIZE - 1 : 0]  sumExponent;

        //////////////////////////////////////
        // Unpack
        //////////////////////////////////////

        facA = facBIn;
        facB = facAIn;

        facASign = facA[SIGN_POS];
        facBSign = facB[SIGN_POS];

        one_facAExponent = {{EXPONENT_SUM_ADDITIONAL_BITS{1'b0}}, facA[EXPONENT_POS +: EXPONENT_SIZE]};
        one_facBExponent = {{EXPONENT_SUM_ADDITIONAL_BITS{1'b0}}, facB[EXPONENT_POS +: EXPONENT_SIZE]};

        expFacBGreaterThanZero = |one_facBExponent;
        expFacAGreaterThanZero = |one_facAExponent;

        facAMantissa = {expFacAGreaterThanZero, facA[MANTISSA_POS +: MANTISSA_SIZE]};
        facBMantissa = {expFacBGreaterThanZero, facB[MANTISSA_POS +: MANTISSA_SIZE]};

        //////////////////////////////////////
        // Compute
        //////////////////////////////////////

        // Compute the mantissa product
        one_mantissaProd <= facBMantissa * facAMantissa;

        // Compute the sign of the product
        one_mantissaProdSign <= facASign ^ facBSign;

        // Compute the exponent
        sumExponent = $signed(one_facBExponent) + ($signed(one_facAExponent) - EXPONENT_BIAS);
        
        // Clamp the exponent
        if ((sumExponent < 0) || (facBMantissa == 0) || (facAMantissa == 0))
        begin
            one_exponentUnderflow <= 1;
            one_exponentOverflow <= 0;
            one_exponentSum <= 0;
        end
        else if (sumExponent >= EXPONENT_INF)
        begin
            one_exponentUnderflow <= 0;
            one_exponentOverflow <= 1;
            one_exponentSum <= EXPONENT_INF;
        end
        else 
        begin
            one_exponentUnderflow <= 0;
            one_exponentOverflow <= 0;
            one_exponentSum <= sumExponent[0 +: EXPONENT_SIZE];
        end
    end

    always @(posedge clk)
    if (ce) begin : Pack
        reg  [EXPONENT_SIZE - 1 : 0] exponentSum;
        reg  [EXPONENT_SIZE : 0]     exponentSumTmp;
        reg  [MANTISSA_PROD_SIZE - 1 : 0] mantissaNormalized;
        reg                          normalizationRequired;
        reg                          mantissaOverlow;

        normalizationRequired = (one_facAExponent != 0) || (one_facBExponent != 0);
        mantissaOverlow = one_mantissaProd[(MANTISSA_SIZE * 2) + 1];

        // Check if the exponent underflows (for instance when you multiply two numbers where the result is too small to encode)
        if (one_exponentUnderflow)
        begin
            exponentSum = 0;
            mantissaNormalized = 0;
        end
        // Check if the exponent overflows (for instance when you multiply two numbers where the result is too big to encode)
        else if (one_exponentOverflow)
        begin
            exponentSum = EXPONENT_INF;
            mantissaNormalized = 0;
        end
        else 
        begin
            // Check if the mantissa is too big so the mantissa has to be shifted.
            // If so, we have to add each step, we shift the mantissa, to the exponent
            if (normalizationRequired)
            begin
                // Standard case where we have a normalized mantissa. In this case we can just use the calculated sum.
                exponentSumTmp = one_exponentSum + {{EXPONENT_SIZE{1'b0}}, mantissaOverlow};
            end
            else
            begin
                // Set exponent to zero because the mantissa is not big enough for a shift. This also implies that the exponent where already zero. Otherwise this case wouldn't happen
                exponentSumTmp = 0;
            end

            exponentSum = exponentSumTmp[0 +: EXPONENT_SIZE];

            // Check if we have to normalize the mantissa
            if (exponentSumTmp == EXPONENT_INF)
            begin
                mantissaNormalized = 0;
            end
            else if (normalizationRequired)
            begin
                mantissaNormalized = one_mantissaProd >> ({{(MANTISSA_PROD_SIZE - MANTISSA_SIZE){1'b0}}, MANTISSA_SIZE[0 +: MANTISSA_SIZE]} 
                                                                 + {{(MANTISSA_PROD_SIZE - 1){1'b0}}, mantissaOverlow});
            end
            else 
            begin
                mantissaNormalized = one_mantissaProd;
            end
        end

        prodReg <= {one_mantissaProdSign, exponentSum, mantissaNormalized[0 +: MANTISSA_SIZE]};
    end

    ValueDelay #(.VALUE_SIZE(FLOAT_SIZE), .DELAY(DELAY)) 
        currentIterationDelayer (.clk(clk), .ce(ce), .in(prodReg), .out(prod));
endmodule
