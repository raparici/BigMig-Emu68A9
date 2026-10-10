`default_nettype none
module ColorDither #(
    parameter R_WIDTH = 5,
    parameter G_WIDTH = 6,
    parameter B_WIDTH = 5
) (
    input  wire             enable,
    input  wire [1 : 0]     x,          // screen x & 3
    input  wire [1 : 0]     y,          // screen y & 3
    input  wire [31 : 0]    colorIn,    // R [31:24], G [23:16], B [15:8], A [7:0] (COLOR_*_POS)
    output wire [31 : 0]    colorOut
);
    function [3 : 0] threshold;
        input [1 : 0] ty;
        input [1 : 0] tx;
        begin
            case ({ ty, tx })
                4'h0: threshold = 4'd0;   4'h1: threshold = 4'd8;   4'h2: threshold = 4'd2;   4'h3: threshold = 4'd10;
                4'h4: threshold = 4'd12;  4'h5: threshold = 4'd4;   4'h6: threshold = 4'd14;  4'h7: threshold = 4'd6;
                4'h8: threshold = 4'd3;   4'h9: threshold = 4'd11;  4'ha: threshold = 4'd1;   4'hb: threshold = 4'd9;
                4'hc: threshold = 4'd15;  4'hd: threshold = 4'd7;   4'he: threshold = 4'd13;  default: threshold = 4'd5;
            endcase
        end
    endfunction

    function [7 : 0] ditherChannel;
        input [7 : 0] v;
        input [3 : 0] m;
        input integer width;
        reg   [10 : 0] s;
        begin
            if (width == 5)
            begin
                s = ({ 3'b000, v } << 1) - { 7'd0, v[7 : 4] } + { 10'd0, v[7] } + { 7'd0, m };
                ditherChannel = { s[8 : 4], 3'b000 };
            end
            else if (width == 6)
            begin
                s = ({ 3'b000, v } << 2) - { 7'd0, v[7 : 4] } + { 9'd0, v[7 : 6] } + { 7'd0, m };
                ditherChannel = { s[9 : 4], 2'b00 };
            end
            else
            begin
                ditherChannel = v;
            end
        end
    endfunction

    wire [3 : 0] m = threshold(y, x);
    assign colorOut = enable ? { ditherChannel(colorIn[31 : 24], m, R_WIDTH),
                                 ditherChannel(colorIn[23 : 16], m, G_WIDTH),
                                 ditherChannel(colorIn[15 :  8], m, B_WIDTH),
                                 colorIn[7 : 0] }
                             : colorIn;
endmodule
`default_nettype wire
