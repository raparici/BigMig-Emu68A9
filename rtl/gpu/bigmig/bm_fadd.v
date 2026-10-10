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

// IEEE-754 binary32 add/subtract and int32 -> binary32, round to nearest even

module bm_fadd (
    input  wire        clk,
    input  wire        in_valid,
    input  wire [1:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         out_valid,
    output reg  [31:0] y
);
    // ---- s0: operand registers
    reg        v0; reg [1:0] op0; reg [31:0] a0, b0;
    always @(posedge clk) begin
        v0 <= in_valid; op0 <= op; a0 <= a; b0 <= (op == 2'd1) ? {~b[31], b[30:0]} : b;
    end
    wire        cvt  = op0[1];
    wire        sa = a0[31], sb = b0[31];
    wire [7:0]  ea = a0[30:23], eb = b0[30:23];
    wire        za = (ea == 0), zb = (eb == 0);
    wire        ia = (ea == 8'hFF), ib = (eb == 8'hFF);
    wire        na = ia && (a0[22:0] != 0), nb = ib && (b0[22:0] != 0);
    wire [23:0] ma = za ? 24'd0 : {1'b1, a0[22:0]};
    wire [23:0] mb = zb ? 24'd0 : {1'b1, b0[22:0]};
    wire        swap = ({eb, mb} > {ea, ma});
    wire        sx = swap ? sb : sa,   sy = swap ? sa : sb;
    wire [7:0]  ex = swap ? eb : ea,   ey = swap ? ea : eb;
    wire [23:0] mx = swap ? mb : ma,   my = swap ? ma : mb;
    wire [7:0]  d  = ex - ey;
    wire [26:0] ywide = {my, 3'b000};
    wire [26:0] ysh   = (d >= 8'd27) ? 27'd0 : (ywide >> d);
    wire        ylost = (d >= 8'd27) ? (my != 0) : ((ywide & ~({27{1'b1}} << d)) != 0);
    // int -> float: magnitude and sign
    wire        ineg = op0[0] ? 1'b0 : a0[31];
    wire [31:0] imag = ineg ? (~a0 + 32'd1) : a0;
    reg         v1, c1, s1sub, s1x, s1nan, s1inf, s1infs, s1yz;
    reg  [1:0]  op1;
    reg  [7:0]  e1;
    reg  [26:0] x1, y1;                       // x1 = {mx, 000}; y1 = aligned my with guard/round/sticky
    reg  [31:0] i1;
    always @(posedge clk) begin
        v1 <= v0; op1 <= op0; c1 <= cvt;
        s1x <= cvt ? ineg : sx;
        s1sub <= (sx != sy);
        e1 <= ex;
        x1 <= {mx, 3'b000};
        y1 <= {ysh[26:1], ysh[0] | ylost};
        s1nan <= na || nb || (ia && ib && (sa != sb));
        s1inf <= ia || ib;
        s1infs <= ia ? sa : sb;
        s1yz <= (my == 0);
        i1 <= imag;
    end
    wire [27:0] sum  = s1sub ? ({1'b0, x1} - {1'b0, y1}) : ({1'b0, x1} + {1'b0, y1});
    wire [31:0] fld  = c1 ? i1 : {sum, 4'b0000};
    function [5:0] lzc32(input [31:0] v);
        integer k; reg found;
        begin
            lzc32 = 6'd32; found = 1'b0;
            for (k = 31; k >= 0; k = k - 1)
                if (!found && v[k]) begin lzc32 = 6'd31 - k[5:0]; found = 1'b1; end
        end
    endfunction
    reg         v2, c2, s2s, s2nan, s2inf, s2infs, s2zero;
    reg  [1:0]  op2;
    reg  [9:0]  e2;                           // exponent of the value whose leading 1 would sit at field bit 31
    reg  [31:0] f2;
    reg  [5:0]  lz2;
    always @(posedge clk) begin
        v2 <= v1; c2 <= c1; op2 <= op1;
        s2nan <= s1nan; s2inf <= s1inf; s2infs <= s1infs;
        f2 <= fld; lz2 <= lzc32(fld);
        s2zero <= (fld == 32'd0);
        e2 <= c1 ? (op1[0] ? 10'd128 : 10'd158) : ({2'b00, e1} + 10'd1);
        // the sign of a zero sum: -0 only when both operands were -0 (x + (-x) = +0 in RNE)
        s2s <= c1 ? s1x : ((fld == 32'd0) ? (s1x & ~s1sub & s1yz & (x1 == 0)) : s1x);
    end
    // ---- s3: normalise (leading 1 to bit 31), round to nearest even at bit 8, pack
    wire [31:0] nrm = f2 << lz2;
    wire [23:0] mt  = nrm[31:8];
    wire        g   = nrm[7];
    wire        st  = (nrm[6:0] != 0);
    wire        up  = g && (st || mt[0]);
    wire [24:0] mr  = {1'b0, mt} + {24'd0, up};
    wire [9:0]  ef  = e2 - {4'd0, lz2} + {9'd0, mr[24]};
    wire [22:0] fr  = mr[24] ? mr[23:1] : mr[22:0];
    wire        ovf = !ef[9] && (ef >= 10'd255);
    wire        unf = ef[9] || (ef == 10'd0);
    always @(posedge clk) begin
        out_valid <= v2;
        if (!c2 && s2nan)      y <= 32'h7FC00000;
        else if (!c2 && s2inf) y <= {s2infs, 8'hFF, 23'd0};
        else if (s2zero)       y <= {s2s, 31'd0};
        else if (ovf)          y <= {s2s, 8'hFF, 23'd0};
        else if (unf)          y <= {s2s, 31'd0};
        else                   y <= {s2s, ef[7:0], fr};
    end
endmodule
