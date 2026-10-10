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

// frames a command-list chunk out of the list DMA stream

module bm_cmd_framer (
    input  wire          clk,
    input  wire          resetn,
    // chunk descriptors, in the order the DMA commands were issued
    input  wire          d_push,
    input  wire [3:0]    d_head,
    input  wire [25:0]   d_len,               // words, >= 1
    input  wire [3:0]    d_tail,
    output wire          d_full,
    // from the DMA
    input  wire          s_tvalid, output wire s_tready, input wire s_tlast, input wire [31:0] s_tdata,
    // to the setup unit
    output wire          m_tvalid, input wire m_tready, output wire m_tlast, output wire m_tuser, output wire [31:0] m_tdata,
    output wire          busy
);
    reg  [33:0] q [0:1];                      // {head, len, tail}
    reg  [1:0]  n; reg wp, rp;
    assign d_full = (n == 2'd2);
    reg         act; reg [3:0] h; reg [25:0] l; reg [3:0] t;
    wire        in_head = act && (h != 4'd0);
    wire        in_body = act && (h == 4'd0) && (l != 26'd0);
    wire        in_tail = act && (h == 4'd0) && (l == 26'd0) && (t != 4'd0);
    assign m_tvalid = s_tvalid && in_body;
    assign m_tdata  = s_tdata;
    assign m_tlast  = s_tlast;
    assign m_tuser  = (l == 26'd1);
    assign s_tready = in_head || in_tail || (in_body && m_tready);
    assign busy = act || (n != 2'd0);
    wire        take = s_tvalid && s_tready;
    always @(posedge clk) begin
        if (!resetn) begin
            n <= 2'd0; wp <= 1'b0; rp <= 1'b0; act <= 1'b0;
        end else begin
            if (d_push && !d_full) begin q[wp] <= {d_head, d_len, d_tail}; wp <= ~wp; end
            if (!act && n != 2'd0) begin
                {h, l, t} <= q[rp]; rp <= ~rp; act <= 1'b1;
            end else if (take) begin
                if (h != 4'd0) h <= h - 4'd1;
                else if (l != 26'd0) l <= l - 26'd1;
                else if (t != 4'd0) t <= t - 4'd1;
                if ((h == 4'd0) && ((l == 26'd1 && t == 4'd0) || (l == 26'd0 && t == 4'd1))) act <= 1'b0;
            end
            n <= n + ((d_push && !d_full) ? 2'd1 : 2'd0) - ((!act && n != 2'd0) ? 2'd1 : 2'd0);
        end
    end
endmodule
