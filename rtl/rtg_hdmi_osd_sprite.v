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

// RTG mouse pointer on the scaled HDMI output, OSD-style: fixed 32x48 output pixels, position mapped through the scaler window

`default_nettype none

module rtg_hdmi_osd_sprite
(
    // rtg.v sprite window, same words as rtg_sprite_overlay
    input  wire        wr_clk,
    input  wire        wr,
    input  wire  [8:0] waddr,          // word index inside the $B80C00 window
    input  wire [15:0] wdata,

    input  wire        clk_sys,        // where hmin/hmax/vmin/vmax/FB_* live

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

    // scaler window and framebuffer size (clk_sys)
    input  wire [11:0] hmin,
    input  wire [11:0] hmax,
    input  wire [11:0] vmin,
    input  wire [11:0] vmax,
    input  wire [11:0] fb_width,
    input  wire [11:0] fb_height,
    input  wire        rtg_en          // RTG is the displayed source
);

    localparam integer IMG_WORDS = 192;

    reg [15:0] img [0:255];             // 0..191 used; 256 deep so an out-of-box read stays in range
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

    // sprite state into clk_sys
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

    // output origin: ox = hmin + sx*(hmax-hmin+1)/fb_width (and oy likewise), bit-serial divide in clk_sys
    wire [12:0] videow = (hmax >= hmin) ? ({1'b0,hmax} - {1'b0,hmin} + 13'd1) : 13'd1;
    wire [12:0] videoh = (vmax >= vmin) ? ({1'b0,vmax} - {1'b0,vmin} + 13'd1) : 13'd1;

    reg signed [11:0] p_x, p_y;
    reg        [11:0] p_hmin, p_vmin;
    reg        [12:0] p_vw, p_vh;
    reg        [11:0] p_fbw, p_fbh;
    wire snap_change = (p_x != x_ss) || (p_y != y_ss) ||
                       (p_hmin != hmin) || (p_vmin != vmin) ||
                       (p_vw != videow) || (p_vh != videoh) ||
                       (p_fbw != fb_width) || (p_fbh != fb_height);
    reg  snap_change_r;   // registered for timing

    localparam [2:0] M_IDLE=3'd0, M_XMUL=3'd1, M_XDIV=3'd2, M_XFIN=3'd3,
                     M_YMUL=3'd4, M_YDIV=3'd5, M_YFIN=3'd6;
    reg  [2:0]  mst;
    reg  [24:0] num;                 // dividend, MSB (num[24]) consumed first
    reg  [11:0] rem;                 // running remainder (< den <= 4095)
    reg  [13:0] quo;                 // quotient (low 14 bits; on-screen fits)
    reg  [11:0] den;                 // divisor (fb_width / fb_height)
    reg  [4:0]  dbit;                // iteration 0..24
    reg  [11:0] absx, absy;
    reg  [12:0] vw_r, vh_r;          // snapshotted multiply operand (isolates the mult)
    reg  [11:0] map_hmin, map_vmin;
    reg         sgnx, sgny;
    reg signed [15:0] ox_sys, oy_sys;  // OUTPUT-space origin (clk_sys result)

    wire [12:0] rem_ext = {rem, num[24]};
    wire [12:0] rem_sub = rem_ext - {1'b0, den};
    wire        dge     = ~rem_sub[12];          // 1 => rem_ext >= den

    always @(posedge clk_sys) begin
        if (rst) begin
            mst <= M_IDLE; ox_sys <= 16'sd0; oy_sys <= 16'sd0;
            p_x <= 12'sd0; p_y <= 12'sd1;              // force one recompute
            p_hmin <= 12'hFFF; p_vmin <= 12'hFFF;
            p_vw <= 13'h1FFF; p_vh <= 13'h1FFF;
            p_fbw <= 12'hFFF; p_fbh <= 12'hFFF;
            snap_change_r <= 1'b0;
        end else begin
            snap_change_r <= snap_change;
            case (mst)
                M_IDLE: begin
                    if (snap_change_r) begin
                        p_x<=x_ss; p_y<=y_ss; p_hmin<=hmin; p_vmin<=vmin;
                        p_vw<=videow; p_vh<=videoh; p_fbw<=fb_width; p_fbh<=fb_height;
                        sgnx <= x_ss[11];
                        sgny <= y_ss[11];
                        absx <= x_ss[11] ? (~x_ss + 12'd1) : x_ss;
                        absy <= y_ss[11] ? (~y_ss + 12'd1) : y_ss;
                        vw_r <= videow;  vh_r <= videoh;
                        map_hmin <= hmin;
                        map_vmin <= vmin;
                        mst  <= M_XMUL;
                    end
                end
                M_XMUL: begin
                    num  <= absx * vw_r;                   // reg*reg 12b*13b -> <=25b
                    den  <= (p_fbw == 12'd0) ? 12'd1 : p_fbw;
                    rem  <= 12'd0; quo <= 14'd0; dbit <= 5'd0;
                    mst  <= M_XDIV;
                end
                M_XDIV: begin
                    rem  <= dge ? rem_sub[11:0] : rem_ext[11:0];
                    quo  <= {quo[12:0], dge};
                    num  <= {num[23:0], 1'b0};
                    dbit <= dbit + 5'd1;
                    if (dbit == 5'd24) mst <= M_XFIN;
                end
                M_XFIN: begin
                    ox_sys <= sgnx ? ($signed({4'd0, map_hmin}) - $signed({2'd0, quo}))
                                   : ($signed({4'd0, map_hmin}) + $signed({2'd0, quo}));
                    mst <= M_YMUL;
                end
                M_YMUL: begin
                    num  <= absy * vh_r;
                    den  <= (p_fbh == 12'd0) ? 12'd1 : p_fbh;
                    rem  <= 12'd0; quo <= 14'd0; dbit <= 5'd0;
                    mst  <= M_YDIV;
                end
                M_YDIV: begin
                    rem  <= dge ? rem_sub[11:0] : rem_ext[11:0];
                    quo  <= {quo[12:0], dge};
                    num  <= {num[23:0], 1'b0};
                    dbit <= dbit + 5'd1;
                    if (dbit == 5'd24) mst <= M_YFIN;
                end
                M_YFIN: begin
                    oy_sys <= sgny ? ($signed({4'd0, map_vmin}) - $signed({2'd0, quo}))
                                   : ($signed({4'd0, map_vmin}) + $signed({2'd0, quo}));
                    mst <= M_IDLE;
                end
                default: mst <= M_IDLE;
            endcase
        end
    end

    // only the result crosses into the pixel clock
    reg signed [15:0] ox_m, ox, oy_m, oy;
    reg               ena_m, ena_s;
    reg               rtge_m, rtge_s;
    reg [23:0]        c1_m, c1_s, c2_m, c2_s, c3_m, c3_s;
    always @(posedge clk_video) begin
        ox_m<=ox_sys;  ox<=ox_m;
        oy_m<=oy_sys;  oy<=oy_m;
        ena_m<=ena_ss; ena_s<=ena_m;
        rtge_m<=rtg_en; rtge_s<=rtge_m;
        c1_m<=c1_ss;   c1_s<=c1_m;
        c2_m<=c2_ss;   c2_s<=c2_m;
        c3_m<=c3_ss;   c3_s<=c3_m;
    end

    // output pixel counters and a 4-stage datapath; de/hs/vs are delayed alike
    reg [11:0] h_cnt, v_cnt;
    reg        deD, vsD;
    always @(posedge clk_video) begin
        if (rst) begin
            h_cnt <= 12'd0; v_cnt <= 12'd0; deD <= 1'b0; vsD <= 1'b0;
        end else if (ce) begin
            deD <= de_in;
            vsD <= vs_in;
            if (de_in && !deD) h_cnt <= 12'd0;          // de rising: new active line
            else if (de_in)    h_cnt <= h_cnt + 12'd1;
            if (!de_in && deD) v_cnt <= v_cnt + 12'd1;  // de falling: next line
            if (vs_in && !vsD) v_cnt <= 12'd0;          // vs rising: frame top
        end
    end

    wire signed [15:0] dx = $signed({4'b0, h_cnt}) - ox;
    wire signed [15:0] dy = $signed({4'b0, v_cnt}) - oy;
    wire in_box = ena_s && rtge_s && de_in
                  && (dx >= 16'sd0) && (dx < 16'sd32)
                  && (dy >= 16'sd0) && (dy < 16'sd48);
    wire [7:0] raddr = {dy[5:0], 2'b00} + {6'd0, dx[4:3]};

    reg        b1;
    reg  [2:0] sub1;
    reg [15:0] img_q;
    reg [23:0] d1;
    reg        e1, h1, v1;
    reg        b2;
    reg  [1:0] pen2;
    reg [23:0] d2;
    reg        e2, h2, v2;
    reg        on3;
    reg [23:0] col3, d3;
    reg        e3, h3, v3;

    always @(posedge clk_video) begin
        if (rst) begin
            b1<=1'b0; b2<=1'b0; on3<=1'b0;
            e1<=1'b0; e2<=1'b0; e3<=1'b0;
            dout<=24'd0; de_out<=1'b0; hs_out<=1'b0; vs_out<=1'b0;
        end else if (ce) begin
            img_q <= img[raddr];
            b1    <= in_box;
            sub1  <= dx[2:0];
            d1    <= din;  e1 <= de_in; h1 <= hs_in; v1 <= vs_in;
            pen2  <= img_q[{sub1, 1'b0} +: 2];   // bit (sub1*2) +:2
            b2    <= b1;
            d2    <= d1;   e2 <= e1;    h2 <= h1;   v2 <= v1;
            on3   <= b2 && (pen2 != 2'd0);
            case (pen2)
                2'd1:    col3 <= c1_s;
                2'd2:    col3 <= c2_s;
                default: col3 <= c3_s;           // pen 3
            endcase
            d3    <= d2;   e3 <= e2;    h3 <= h2;   v3 <= v2;
            dout   <= on3 ? col3 : d3;
            de_out <= e3;  hs_out <= h3;  vs_out <= v3;
        end
    end

endmodule

`default_nettype wire
