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

// RTG mouse pointer composited at scan-out on the native analog output: 32x48, 2bpp, pen 0 transparent, fed by rtg.v's $B80C00 window

`default_nettype none

module rtg_sprite_overlay
(
    // rtg.v sprite window (clk_sys)
    input  wire        wclk,
    input  wire        wr,
    input  wire  [8:0] waddr,        // word index inside the $B80C00 window
    input  wire [15:0] wdata,

    // pixel side: clk_vid, one pixel per ce
    input  wire        clk,
    input  wire        rst,          // active-high, clk domain
    input  wire        ce,
    input  wire        frame_latch,  // 1-ce pulse at the frame wrap (= scanout `load`)
    input  wire [11:0] px_x,         // rtg_scanout counter_x at P0
    input  wire [11:0] px_y,         // rtg_scanout counter_y at P0

    output reg         spr_on,       // 1 = emit spr_rgb for this pixel
    output reg  [23:0] spr_rgb
);

    localparam integer IMG_WORDS = 192;   // 32x48 pens, 2bpp, 8 pens / 16-bit word

    reg [15:0] img [0:255];   // 0..191 used; 256 deep so an out-of-box read stays in range

    reg [23:0]        w_col1, w_col2, w_col3;
    reg signed [11:0] w_x, w_y;
    reg               w_ena;

    always @(posedge wclk) begin
        if (wr) begin
            if (waddr < IMG_WORDS[8:0]) begin
                img[waddr[7:0]] <= wdata;
            end else begin
                case (waddr - IMG_WORDS[8:0])   // 0..8
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

    // 2-FF sync into the pixel domain, then a snapshot at the frame boundary
    reg signed [11:0] x_m, x_s, y_m, y_s;
    reg               ena_m, ena_s;
    reg [23:0]        c1_m, c1_s, c2_m, c2_s, c3_m, c3_s;
    always @(posedge clk) begin
        x_m<=w_x;   x_s<=x_m;
        y_m<=w_y;   y_s<=y_m;
        ena_m<=w_ena; ena_s<=ena_m;
        c1_m<=w_col1; c1_s<=c1_m;
        c2_m<=w_col2; c2_s<=c2_m;
        c3_m<=w_col3; c3_s<=c3_m;
    end

    reg signed [11:0] f_x, f_y;
    reg               f_ena;
    reg [23:0]        f_c1, f_c2, f_c3;
    always @(posedge clk) begin
        if (rst) begin
            f_ena <= 1'b0;
            f_x   <= 12'sd0; f_y <= 12'sd0;
        end else if (frame_latch) begin
            f_x<=x_s; f_y<=y_s; f_ena<=ena_s; f_c1<=c1_s; f_c2<=c2_s; f_c3<=c3_s;
        end
    end

    // 4-stage pipeline, aligned with rtg_scanout's rgb output
    wire signed [12:0] dx = $signed({1'b0, px_x}) - $signed({f_x[11], f_x});
    wire signed [12:0] dy = $signed({1'b0, px_y}) - $signed({f_y[11], f_y});
    wire in_box = f_ena && (dx >= 13'sd0) && (dx < 13'sd32)
                        && (dy >= 13'sd0) && (dy < 13'sd48);
    wire [7:0] raddr = {dy[5:0], 2'b00} + {6'd0, dx[4:3]};

    reg        b1;
    reg  [2:0] sub1;
    reg [15:0] img_q;
    always @(posedge clk) if (ce) begin
        img_q <= img[raddr];
        b1    <= in_box;
        sub1  <= dx[2:0];
    end

    reg       b2;
    reg [1:0] pen2;
    always @(posedge clk) if (ce) begin
        pen2 <= img_q[{sub1, 1'b0} +: 2];   // bit (sub1*2) +:2
        b2   <= b1;
    end

    reg        on3;
    reg [23:0] col3;
    always @(posedge clk) if (ce) begin
        on3 <= b2 && (pen2 != 2'd0);
        case (pen2)
            2'd1:    col3 <= f_c1;
            2'd2:    col3 <= f_c2;
            default: col3 <= f_c3;          // pen 3
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            spr_on  <= 1'b0;
            spr_rgb <= 24'd0;
        end else if (ce) begin
            spr_on  <= on3;
            spr_rgb <= col3;
        end
    end

endmodule

`default_nettype wire
