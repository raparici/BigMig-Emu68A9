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

// Float to signed integer conversion
// This module is pipelined. It can calculate one conversion per clock
// This module has a latency of 2 clock cycles minimum
module FloatToInt 
# (
    parameter MANTISSA_SIZE = 23,
    parameter EXPONENT_SIZE = 8,

    // Has to be at least the size of the mantissa plus the hidden bit and plus sign. 
    // In other words: MANTISSA_SIZE + 2.
    parameter INT_SIZE = 32, 

    // Use this delay to add clock cycles. It adds by default 2 clock cycles, so that the conversion requires 4 clocks.
    parameter DELAY = 2,

    // Selects what happens when the number does not fit into INT_SIZE.
    // 0: the output is zero.
    // 1: the output is the number modulo 2^INT_SIZE. Use this when the consumer is a wrapping
    //    fix point accumulator, which works with an out of range number where only the lower bits are used
    //    and the high bits are discarded.
    parameter OVERFLOW_WRAP = 0,

    parameter FLOAT_SIZE = 1 + EXPONENT_SIZE + MANTISSA_SIZE
)
(
    input  wire                                 clk,
    input  wire                                 ce,
    // This value can be used to shift the bias of the exponent in the float. 
    // This conversion can be useful when converting to a fix point format without any extra cost.
    // For instance a offset of -1 is equal to a multiplication with 2.0,
    // a offset of -2 is equal to a multiplication with 4.0, ...
    input  wire signed  [EXPONENT_SIZE - 1 : 0] offset,
    input  wire         [FLOAT_SIZE - 1 : 0]    in,
    output wire         [INT_SIZE - 1 : 0]      out
);
    localparam UNSIGNED_INT_SIZE = INT_SIZE - 1;
    localparam INT_SIGN_POS = INT_SIZE - 1;
    localparam USNIGNED_INT_SIZE_LOG2 = $clog2(UNSIGNED_INT_SIZE);
    localparam MANTISSA_POS = 0;
    localparam EXPONENT_POS = MANTISSA_SIZE;
    localparam SIGN_POS = EXPONENT_POS + EXPONENT_SIZE;
    localparam EXPONENT_SIGNED_SIZE = EXPONENT_SIZE + 1;
    localparam EXPONENT_BIAS = (2 ** (EXPONENT_SIZE - 1)) - 1;

    reg  [INT_SIZE - 1 : 0] one_number;
    reg                     one_sign;
    reg                     one_overflow;
    reg                     one_shiftedOut;
    reg                     one_underflow;
    reg                     one_round;
    always @(posedge clk)
    if (ce) begin : Unpack
        reg signed [EXPONENT_SIGNED_SIZE - 1 : 0]   exponent;
        reg signed [EXPONENT_SIGNED_SIZE - 1 : 0]   signedShiftSize;
        reg        [INT_SIZE - 1 : 0]               number;
        reg                                         shiftLeft;    
        reg        [USNIGNED_INT_SIZE_LOG2 - 1 : 0] shiftSize;

        one_sign <= in[SIGN_POS +: 1];
        exponent = in[EXPONENT_POS +: EXPONENT_SIZE] - $unsigned($signed(EXPONENT_BIAS[0 +: EXPONENT_SIZE]) + offset);

        // A float in the range of an integer will always have set the hidden bit to one since we can't display fractions with an integer
        number = {{(INT_SIZE - MANTISSA_SIZE - 1){1'b0}}, 1'b1, in[MANTISSA_POS +: MANTISSA_SIZE]};

        shiftLeft = exponent > $signed(MANTISSA_SIZE[0 +: EXPONENT_SIGNED_SIZE]);
        if (shiftLeft)
        begin
            signedShiftSize = exponent - MANTISSA_SIZE[0 +: EXPONENT_SIGNED_SIZE];
        end
        else
        begin
            signedShiftSize = MANTISSA_SIZE[0 +: EXPONENT_SIGNED_SIZE] - exponent;
        end
        shiftSize = signedShiftSize[0 +: USNIGNED_INT_SIZE_LOG2];

        one_overflow <= exponent >= (INT_SIZE - 1); // Substracting sign bit
        
        // shiftSize is truncated, so a shift beyond INT_SIZE would wrap around instead of
        // shifting every bit out
        one_shiftedOut <= shiftLeft && (signedShiftSize >= $signed(INT_SIZE[0 +: EXPONENT_SIGNED_SIZE]));
        
        one_underflow <= exponent < 0;

        if (shiftLeft)
        begin
            one_round <= 0;
            one_number <= number << shiftSize;
        end
        else 
        begin
            one_round <= number[shiftSize - 1];
            one_number <= number >> shiftSize;
        end
    end

    reg [FLOAT_SIZE - 1 : 0] two_out;
    always @(posedge clk)
    if (ce) begin : Pack
        reg                     underflow;
        reg                     overflow;
        reg                     sign;
        reg  [INT_SIZE - 1 : 0] number;
        // Reevaluate underflow
        if (one_underflow)
        begin
            // If we where able to round, then the last value was bigger than 0.5. Therefor we can round now.
            if (one_round)
            begin
                underflow = 0;
                number = 1; 
            end
            else
            begin
                underflow = 1;
                number = 0; 
            end
        end
        else 
        begin
            underflow = one_underflow;
            number = one_number + {{(INT_SIZE - 1){1'b0}}, one_round};
        end
        overflow = one_overflow;
        sign = one_sign;

        if (one_shiftedOut || (overflow && (OVERFLOW_WRAP == 0)))
        begin
            two_out <= 0;
        end
        else
        begin
            if (sign)
            begin
                two_out <= ~number + 1;
            end
            else
            begin
                two_out <= number;
            end
        end
    end

    ValueDelay #(.VALUE_SIZE(FLOAT_SIZE), .DELAY(DELAY)) 
        currentIterationDelayer (.clk(clk), .ce(ce), .in(two_out), .out(out));
endmodule
