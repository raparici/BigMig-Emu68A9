// Copyright 2026 Ruben Aparicio
//
// This file is part of BigMig
//
// BigMig is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// (at your option) any later version.
//
// BigMig is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// IEEE-754 binary32 multiply, round to nearest even; also the setup unit's integer multiply

module bm_fmul (
    input  wire        clk,
    input  wire        in_valid,
    input  wire        imul,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         out_valid,
    output reg  [31:0] y
);
    // ---- stage 0: unpack into the DSP operands
    wire        sa = a[31], sb = b[31];
    wire [7:0]  ea = a[30:23], eb = b[30:23];
    wire        za = (ea == 8'd0), zb = (eb == 8'd0);          // zero or subnormal (DAZ)
    wire        ia = (ea == 8'hFF), ib = (eb == 8'hFF);
    wire        na = ia && (a[22:0] != 0), nb = ib && (b[22:0] != 0);
    wire [26:0] fa = imul ? a[26:0] : (za ? 27'd0 : {3'd0, 1'b1, a[22:0]});
    wire [26:0] fb = imul ? b[26:0] : (zb ? 27'd0 : {3'd0, 1'b1, b[22:0]});
    reg  signed [26:0] r_a, r_b;
    reg         r_v, r_imul, r_s, r_zero, r_inf, r_nan;
    reg  [9:0]  r_e;                                            // ea + eb - 127, signed 10-bit
    always @(posedge clk) begin
        r_v    <= in_valid;
        r_imul <= imul;
        r_a    <= fa;
        r_b    <= fb;
        r_s    <= sa ^ sb;
        r_nan  <= na || nb || (ia && zb && !ib) || (ib && za && !ia) || (ia && zb) || (ib && za);
        r_inf  <= (ia || ib);
        r_zero <= (za || zb);
        r_e    <= {2'b00, ea} + {2'b00, eb} - 10'd127;
    end
    // ---- stage 1: the product (one 27 x 27 DSP)
    reg  signed [53:0] p;
    reg         p_v, p_imul, p_s, p_zero, p_inf, p_nan;
    reg  [9:0]  p_e;
    always @(posedge clk) begin
        p      <= r_a * r_b;
        p_v    <= r_v;
        p_imul <= r_imul;
        p_s    <= r_s;
        p_zero <= r_zero;
        p_inf  <= r_inf;
        p_nan  <= r_nan;
        p_e    <= r_e;
    end
    wire [47:0] m   = p[47:0];
    wire        hi  = m[47];
    wire [23:0] mt  = hi ? m[47:24] : m[46:23];                 // 1.xxx, 24 bits
    wire        g   = hi ? m[23] : m[22];
    wire        st  = hi ? (m[22:0] != 0) : (m[21:0] != 0);
    wire        up  = g && (st || mt[0]);
    wire [24:0] mr  = {1'b0, mt} + {24'd0, up};                 // 25 bits: carry when 1.111..1 rounds up
    wire [9:0]  e1  = p_e + {9'd0, hi} + {9'd0, mr[24]};
    wire [22:0] fr  = mr[24] ? mr[23:1] : mr[22:0];             // after a carry the mantissa is 1.000..0
    wire        ovf = !e1[9] && (e1 >= 10'd255);
    wire        unf = e1[9] || (e1 == 10'd0);                   // FTZ
    always @(posedge clk) begin
        out_valid <= p_v;
        if (p_imul)        y <= p[31:0];
        else if (p_nan)    y <= 32'h7FC00000;
        else if (p_inf)    y <= {p_s, 8'hFF, 23'd0};
        else if (p_zero)   y <= {p_s, 31'd0};
        else if (ovf)      y <= {p_s, 8'hFF, 23'd0};
        else if (unf)      y <= {p_s, 31'd0};
        else               y <= {p_s, e1[7:0], fr};
    end
endmodule
