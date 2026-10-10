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

// RTG mouse pointer on the scaled HDMI output, OSD-style, scaled with the picture:
// each output pixel is mapped back to its framebuffer pixel (nearest neighbour)

`default_nettype none

module rtg_hdmi_osd_sprite
(
    // rtg.v sprite window, same words as rtg_sprite_overlay
    input  wire        wr_clk,
    input  wire        wr,
    input  wire  [8:0] waddr,          // word index inside the $B80C00 window
    input  wire [15:0] wdata,

    input  wire        clk_sys,        // where FB_* live; runs the step FSM

    input  wire        clk_video,
    input  wire        ce,             // one pulse per OUTPUT pixel (ascal o_ce)
    input  wire        rst,            // active-high (block init)

    input  wire [23:0] din,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    output reg  [23:0] dout,
    output reg         de_out,
    output reg         hs_out,
    output reg         vs_out,

    // scaler window (clk_vid) and framebuffer size (clk_sys)
    input  wire [11:0] hmin,
    input  wire [11:0] hmax,
    input  wire [11:0] vmin,
    input  wire [11:0] vmax,
    input  wire [11:0] fb_width,
    input  wire [11:0] fb_height,
    input  wire        rtg_en          // RTG is the displayed source
);

    localparam integer IMG_WORDS = 192;

    reg [15:0] img [0:255];             // 0..191 used; sized 256 so an OOB read is safe
    reg [23:0] w_col1, w_col2, w_col3;
    reg signed [11:0] w_x, w_y;
    reg               w_ena;

    always @(posedge wr_clk) begin
        if (wr) begin
            if (waddr < IMG_WORDS[8:0]) begin
                img[waddr[7:0]] <= wdata;
            end else begin
                case (waddr - IMG_WORDS[8:0])
                    9'd0: w_col1[23:16] <= wdata[7:0];
                    9'd1: w_col1[15:0]  <= wdata;
                    9'd2: w_col2[23:16] <= wdata[7:0];
                    9'd3: w_col2[15:0]  <= wdata;
                    9'd4: w_col3[23:16] <= wdata[7:0];
                    9'd5: w_col3[15:0]  <= wdata;
                    9'd6: w_x <= wdata[11:0];
                    9'd7: w_y <= wdata[11:0];
                    9'd8: w_ena <= wdata[0];
                    default: ;
                endcase
            end
        end
    end

    reg signed [11:0] x_a, x_ss, y_a, y_ss;
    reg               ena_a, ena_ss;
    reg [23:0]        c1_a, c1_ss, c2_a, c2_ss, c3_a, c3_ss;
    always @(posedge clk_sys) begin
        x_a<=w_x;      x_ss<=x_a;
        y_a<=w_y;      y_ss<=y_a;
        ena_a<=w_ena;  ena_ss<=ena_a;
        c1_a<=w_col1;  c1_ss<=c1_a;
        c2_a<=w_col2;  c2_ss<=c2_a;
        c3_a<=w_col3;  c3_ss<=c3_a;
    end

    reg [11:0] hmin_s, hmax_s, vmin_s, vmax_s;
    always @(posedge clk_sys) begin
        hmin_s <= hmin; hmax_s <= hmax; vmin_s <= vmin; vmax_s <= vmax;
    end

    // scaled picture size
    wire [12:0] videow = (hmax_s >= hmin_s) ? ({1'b0,hmax_s} - {1'b0,hmin_s} + 13'd1) : 13'd1;
    wire [12:0] videoh = (vmax_s >= vmin_s) ? ({1'b0,vmax_s} - {1'b0,vmin_s} + 13'd1) : 13'd1;

    reg [12:0] p_vw, p_vh;
    reg [11:0] p_fbw, p_fbh;
    wire snap_change = (p_vw != videow) || (p_vh != videoh) ||
                       (p_fbw != fb_width) || (p_fbh != fb_height);
    reg  snap_change_r;   // registered: breaks geometry->capture-enable comb path (timing)

    localparam [2:0] M_IDLE=3'd0, M_HSET=3'd1, M_HDIV=3'd2, M_HFIN=3'd3,
                     M_VSET=3'd4, M_VDIV=3'd5, M_VFIN=3'd6;
    reg  [2:0]  mst;
    reg  [27:0] num;                 // dividend {fb size, 16'b0}, MSB (num[27]) consumed first
    reg  [11:0] rem;                 // running remainder (< den <= 4096)
    reg  [27:0] quo;                 // quotient
    reg  [12:0] den;                 // divisor (videow / videoh, >= 1)
    reg  [4:0]  dbit;                // iteration 0..27
    reg  [19:0] hstep_sys, vstep_sys;   // 4.16 steps (clk_sys result)

    wire [12:0] rem_ext = {rem, num[27]};
    wire [12:0] rem_sub = rem_ext - den;
    wire        dge     = ~rem_sub[12];          // 1 => rem_ext >= den
    wire [19:0] quo_sat = (|quo[27:20]) ? 20'hFFFFF : quo[19:0];

    always @(posedge clk_sys) begin
        if (rst) begin
            mst <= M_IDLE; hstep_sys <= 20'd0; vstep_sys <= 20'd0;
            p_vw <= 13'h1FFF; p_vh <= 13'h1FFF;        // force one recompute
            p_fbw <= 12'hFFF; p_fbh <= 12'hFFF;
            snap_change_r <= 1'b0;
        end else begin
            snap_change_r <= snap_change;
            case (mst)
                M_IDLE: begin
                    if (snap_change_r) begin
                        p_vw<=videow; p_vh<=videoh; p_fbw<=fb_width; p_fbh<=fb_height;
                        mst  <= M_HSET;
                    end
                end
                M_HSET: begin
                    num  <= {p_fbw, 16'd0};
                    den  <= p_vw;
                    rem  <= 12'd0; quo <= 28'd0; dbit <= 5'd0;
                    mst  <= M_HDIV;
                end
                M_HDIV: begin
                    rem  <= dge ? rem_sub[11:0] : rem_ext[11:0];
                    quo  <= {quo[26:0], dge};
                    num  <= {num[26:0], 1'b0};
                    dbit <= dbit + 5'd1;
                    if (dbit == 5'd27) mst <= M_HFIN;
                end
                M_HFIN: begin
                    hstep_sys <= quo_sat;
                    mst <= M_VSET;
                end
                M_VSET: begin
                    num  <= {p_fbh, 16'd0};
                    den  <= p_vh;
                    rem  <= 12'd0; quo <= 28'd0; dbit <= 5'd0;
                    mst  <= M_VDIV;
                end
                M_VDIV: begin
                    rem  <= dge ? rem_sub[11:0] : rem_ext[11:0];
                    quo  <= {quo[26:0], dge};
                    num  <= {num[26:0], 1'b0};
                    dbit <= dbit + 5'd1;
                    if (dbit == 5'd27) mst <= M_VFIN;
                end
                M_VFIN: begin
                    vstep_sys <= quo_sat;
                    mst <= M_IDLE;
                end
                default: mst <= M_IDLE;
            endcase
        end
    end

    reg [19:0]        hst_m, vst_m;
    reg [11:0]        hmn_m, hmx_m, vmn_m, vmx_m;
    reg signed [11:0] sx_m, sy_m;
    reg               ena_m;
    reg               rtge_m, rtge_s;   // RTG-active gate: 2-FF into clk_video
    reg [23:0]        c1_m, c1_s, c2_m, c2_s, c3_m, c3_s;
    always @(posedge clk_video) begin
        hst_m<=hstep_sys; vst_m<=vstep_sys;
        hmn_m<=hmin_s; hmx_m<=hmax_s; vmn_m<=vmin_s; vmx_m<=vmax_s;
        sx_m<=x_ss;    sy_m<=y_ss;
        ena_m<=ena_ss;
        rtge_m<=rtg_en; rtge_s<=rtge_m;
        c1_m<=c1_ss;   c1_s<=c1_m;
        c2_m<=c2_ss;   c2_s<=c2_m;
        c3_m<=c3_ss;   c3_s<=c3_m;
    end

    reg [23:0] d0, d1, d2, d3, d4, d5;
    reg        e0, e1, e2, e3, e4, e5;
    reg        h0, h1, h2, h3, h4, h5;
    reg        v0, v1, v2, v3, v4, v5;

    reg [11:0] pcnt, lcnt;
    reg [19:0]        f_hst, f_vst;
    reg [11:0]        f_hmn, f_hmx, f_vmn, f_vmx;
    reg signed [11:0] f_sx, f_sy;
    reg               f_ena;
    reg [27:0] fy, fx1;               // 12.16 framebuffer coordinate
    reg        yin;

    reg        xin1, yok1;
    reg  [5:0] row1;
    reg        b2;
    reg  [5:0] row2;
    reg  [4:0] col2;
    reg        b3;
    reg  [2:0] sub3;
    reg [15:0] img_q;
    reg        b4;
    reg  [1:0] pen4;
    reg        on5;
    reg [23:0] col5;

    wire [13:0] sy14 = {2'b00, fy[27:16]}  - {{2{f_sy[11]}}, f_sy};
    wire [13:0] sx14 = {2'b00, fx1[27:16]} - {{2{f_sx[11]}}, f_sx};
    wire        yhit = (sy14[13:6] == 8'd0) && (sy14[5:4] != 2'b11);   // 0 <= sy14 < 48
    wire        xhit = (sx14[13:5] == 9'd0);                           // 0 <= sx14 < 32

    always @(posedge clk_video) begin
        if (rst) begin
            e0<=1'b0; e1<=1'b0; e2<=1'b0; e3<=1'b0; e4<=1'b0; e5<=1'b0;
            v0<=1'b0;
            pcnt<=12'd0; lcnt<=12'd0;
            f_ena<=1'b0; f_hst<=20'd0; f_vst<=20'd0;
            f_hmn<=12'd0; f_hmx<=12'd0; f_vmn<=12'd0; f_vmx<=12'd0;
            f_sx<=12'sd0; f_sy<=12'sd0;
            yin<=1'b0; xin1<=1'b0; yok1<=1'b0;
            b2<=1'b0; b3<=1'b0; b4<=1'b0; on5<=1'b0;
            dout<=24'd0; de_out<=1'b0; hs_out<=1'b0; vs_out<=1'b0;
        end else if (ce) begin
            // S0
            d0 <= din;  e0 <= de_in;  h0 <= hs_in;  v0 <= vs_in;
            if (de_in && !e0)  pcnt <= 12'd0;            // de rising: pixel 0 of the line
            else if (de_in)    pcnt <= pcnt + 12'd1;
            if (vs_in && !v0) begin                      // vs rising: frame top, latch the frame's set
                lcnt  <= 12'd0;
                f_hst <= hst_m;  f_vst <= vst_m;
                f_hmn <= hmn_m;  f_hmx <= hmx_m;  f_vmn <= vmn_m;  f_vmx <= vmx_m;
                f_sx  <= sx_m;   f_sy  <= sy_m;   f_ena <= ena_m;
            end else if (!de_in && e0) begin
                lcnt  <= lcnt + 12'd1;                   // de falling: next line
            end
            if (de_in && !e0) begin                      // once a line, before its pixel 0 reaches S1
                yin <= (lcnt >= f_vmn) && (lcnt <= f_vmx);
                fy  <= (lcnt == f_vmn) ? {9'd0, f_vst[19:1]} : (fy + {8'd0, f_vst});
            end
            // S1
            d1 <= d0;  e1 <= e0;  h1 <= h0;  v1 <= v0;
            xin1 <= e0 && (pcnt >= f_hmn) && (pcnt <= f_hmx);
            fx1  <= (pcnt == f_hmn) ? {9'd0, f_hst[19:1]} : (fx1 + {8'd0, f_hst});
            yok1 <= yin && yhit;
            row1 <= sy14[5:0];
            // S2
            d2 <= d1;  e2 <= e1;  h2 <= h1;  v2 <= v1;
            b2   <= f_ena && rtge_s && xin1 && yok1 && xhit;
            row2 <= row1;
            col2 <= sx14[4:0];
            // S3: image row*4 + col/8 (row < 48 -> address < 192)
            d3 <= d2;  e3 <= e2;  h3 <= h2;  v3 <= v2;
            img_q <= img[{row2, col2[4:3]}];
            b3    <= b2;
            sub3  <= col2[2:0];
            // S4
            d4 <= d3;  e4 <= e3;  h4 <= h3;  v4 <= v3;
            pen4  <= img_q[{sub3, 1'b0} +: 2];   // bit (sub3*2) +:2
            b4    <= b3;
            // S5
            d5 <= d4;  e5 <= e4;  h5 <= h4;  v5 <= v4;
            on5   <= b4 && (pen4 != 2'd0);
            case (pen4)
                2'd1:    col5 <= c1_s;
                2'd2:    col5 <= c2_s;
                default: col5 <= c3_s;           // pen 3
            endcase
            // S6 (output mux): sprite over video, DATA ONLY
            dout   <= on5 ? col5 : d5;
            de_out <= e5;  hs_out <= h5;  vs_out <= v5;
        end
    end

endmodule

`default_nettype wire
