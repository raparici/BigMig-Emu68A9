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

// IEEE-754 binary32 divide and square root, round to nearest even, two bits a clock

module bm_fdivsqrt (
    input  wire        clk,
    input  wire        resetn,
    input  wire        start,
    input  wire        sqrt,          // 0: a / b, 1: sqrt(a)
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         busy,
    output reg         done,          // one clock, with y
    output reg  [31:0] y
);
    localparam N = 26;                // result bits: 1 integer + 25 fraction (24 kept + guard + round)
    localparam N2 = N / 2;            // double steps
    reg         m_sqrt, sgn, special;
    reg  [31:0] sval;                 // the special result
    reg  signed [10:0] e;             // the result's biased exponent before rounding
    reg  [29:0] r;                    // partial remainder
    reg  [29:0] dv;                   // divisor (div) / unused (sqrt)
    reg  [26:0] q;                    // quotient / root bits so far
    reg  [49:0] rad;                  // sqrt: the radicand bits not yet brought down
    reg  [5:0]  k;
    // unpack
    wire        sa = a[31], sb = b[31];
    wire [7:0]  ea = a[30:23], eb = b[30:23];
    wire        za = (ea == 0), zb = (eb == 0);
    wire        ia = (ea == 8'hFF), ib = (eb == 8'hFF);
    wire        na = ia && (a[22:0] != 0), nb = ib && (b[22:0] != 0);
    wire [23:0] ma = {1'b1, a[22:0]}, mb = {1'b1, b[22:0]};
    wire        eodd = ~ea[0];                                   // (ea - 127) odd  <=>  ea even
    always @(posedge clk) begin
        done <= 1'b0;
        if (!resetn) begin
            busy <= 1'b0;
        end else if (start && !busy) begin
            m_sqrt <= sqrt;
            busy <= 1'b1;
            k <= 6'd0;
            q <= 27'd0;
            if (!sqrt) begin
                sgn <= sa ^ sb;
                special <= 1'b1;
                if (na || nb || (ia && ib) || (za && zb)) sval <= 32'h7FC00000;
                else if (ia || zb)                       sval <= {sa ^ sb, 8'hFF, 23'd0};
                else if (za || ib)                       sval <= {sa ^ sb, 31'd0};
                else                                     special <= 1'b0;
                // quotient in [1, 2): pre-shift the dividend when ma < mb
                if (ma < mb) begin r <= {5'd0, ma, 1'b0}; e <= {3'd0, ea} - {3'd0, eb} + 11'sd126; end
                else         begin r <= {6'd0, ma};       e <= {3'd0, ea} - {3'd0, eb} + 11'sd127; end
                dv <= {6'd0, mb};
            end else begin
                sgn <= sa;
                special <= 1'b1;
                if (na)                sval <= 32'h7FC00000;
                else if (za)           sval <= {sa, 31'd0};                 // sqrt(+-0) = +-0
                else if (sa)           sval <= 32'h7FC00000;
                else if (ia)           sval <= {1'b0, 8'hFF, 23'd0};
                else                   special <= 1'b0;
                rad <= eodd ? {ma, 26'd0} : {1'b0, ma, 25'd0};
                // (ea - 127) / 2, rounded down, + 127; the root of the radicand lies in [1, 2)
                e <= ({3'd0, ea} - 11'sd127 - (eodd ? 11'sd1 : 11'sd0)) / 2 + 11'sd127;
                r <= 30'd0;
            end
        end else if (busy) begin
            if (k == N2[5:0]) begin
                // q holds N bits (1.xxx with N-1 fraction bits); sticky = remainder != 0
                busy <= 1'b0;
                done <= 1'b1;
            end else begin
                k <= k + 6'd1;
                r <= r2n; q <= q2n; rad <= {rad[45:0], 4'b0000};
            end
        end
    end
    wire [29:0] d1s = r - dv;
    wire        d1b = !d1s[29];
    wire [29:0] r1d = d1b ? {d1s[28:0], 1'b0} : {r[28:0], 1'b0};
    wire [29:0] d2s = r1d - dv;
    wire        d2b = !d2s[29];
    wire [29:0] r2d = d2b ? {d2s[28:0], 1'b0} : {r1d[28:0], 1'b0};
    wire [29:0] s1r = {r[27:0], rad[49:48]};
    wire [29:0] s1t = {1'b0, q[26:0], 2'b01};
    wire [29:0] s1d = s1r - s1t;
    wire        s1b = !s1d[29];
    wire [29:0] r1s = s1b ? s1d : s1r;
    wire [26:0] q1  = {q[25:0], s1b};
    wire [29:0] s2r = {r1s[27:0], rad[47:46]};
    wire [29:0] s2t = {1'b0, q1[26:0], 2'b01};
    wire [29:0] s2d = s2r - s2t;
    wire        s2b = !s2d[29];
    wire [29:0] r2s = s2b ? s2d : s2r;
    wire [29:0] r2n = m_sqrt ? r2s : r2d;
    wire [26:0] q2n = m_sqrt ? {q1[25:0], s2b} : {q[24:0], d1b, d2b};
    // rounding of the finished result (combinational from q, r, e; registered into y when done)
    wire [23:0] mt  = q[25:2];
    wire        g   = q[1];
    wire        st  = q[0] | (r != 0);
    wire        up  = g && (st || mt[0]);
    wire [24:0] mr  = {1'b0, mt} + {24'd0, up};
    wire signed [10:0] ef = e + (mr[24] ? 11'sd1 : 11'sd0);
    wire [22:0] fr  = mr[24] ? mr[23:1] : mr[22:0];
    always @(posedge clk)
        if (busy && k == N2[5:0]) begin
            if (special)            y <= sval;
            else if (ef >= 11'sd255) y <= {sgn, 8'hFF, 23'd0};
            else if (ef <= 11'sd0)   y <= {sgn, 31'd0};
            else                     y <= {sgn, ef[7:0], fr};
        end
endmodule
