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

// two read-only Avalon-MM burst masters on one slave port, round-robin

module avl_rd_arb2 #(
    parameter AW = 29,
    parameter DEPTH_LG = 2
) (
    input  wire          clk,
    input  wire          rst,
    // master 0
    input  wire [AW-1:0] m0_address, input wire [7:0] m0_burstcount, input wire m0_read,
    output wire          m0_waitrequest, output wire [63:0] m0_readdata, output wire m0_readdatavalid,
    // master 1
    input  wire [AW-1:0] m1_address, input wire [7:0] m1_burstcount, input wire m1_read,
    output wire          m1_waitrequest, output wire [63:0] m1_readdata, output wire m1_readdatavalid,
    // slave
    output wire [AW-1:0] s_address, output wire [7:0] s_burstcount, output wire s_read,
    input  wire          s_waitrequest, input wire [63:0] s_readdata, input wire s_readdatavalid,
    output wire [63:0]   s_writedata, output wire [7:0] s_byteenable, output wire s_write
);
    localparam DEPTH = 1 << DEPTH_LG;
    reg        busy, sel;
    reg        last;                          // the master of the last ACCEPTED command (the round-robin pointer)
    reg  [DEPTH_LG:0] cnt;                    // outstanding bursts
    reg  [8:0] fifo [0:DEPTH-1];              // {master, burstcount}
    reg  [DEPTH_LG-1:0] wp, rp;
    reg  [7:0] left;                          // beats left of the head burst (0 = load from the FIFO)
    wire full = cnt == DEPTH;
    wire free  = !busy && !full;
    wire pick1 = free && m1_read && (!m0_read || !last);
    wire pick0 = free && m0_read && !pick1;
    wire cur   = busy ? sel : pick1;
    wire req   = busy || pick0 || pick1;
    assign s_read       = req;
    assign s_address    = cur ? m1_address : m0_address;
    assign s_burstcount = cur ? m1_burstcount : m0_burstcount;
    assign s_writedata  = 64'd0;
    assign s_byteenable = 8'hFF;
    assign s_write      = 1'b0;
    wire accept = req && !s_waitrequest;
    assign m0_waitrequest = m0_read && !(accept && cur == 1'b0);
    assign m1_waitrequest = m1_read && !(accept && cur == 1'b1);
    // returning beats go to the head burst's master
    wire [8:0] head = fifo[rp];
    wire       hsel = head[8];
    assign m0_readdata = s_readdata;  assign m0_readdatavalid = s_readdatavalid && !hsel;
    assign m1_readdata = s_readdata;  assign m1_readdatavalid = s_readdatavalid &&  hsel;
    wire [7:0] n_left = (left == 8'd0) ? head[7:0] : left;
    wire pop = s_readdatavalid && n_left == 8'd1;
    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; sel <= 1'b0; last <= 1'b1; cnt <= 0; wp <= 0; rp <= 0; left <= 8'd0;
        end else begin
            if (accept) begin
                busy <= 1'b0;
                last <= cur;
                fifo[wp] <= {cur, s_burstcount};
                wp <= wp + 1'b1;
            end else if (req) begin
                busy <= 1'b1; sel <= cur;
            end
            if (s_readdatavalid) begin
                left <= pop ? 8'd0 : n_left - 8'd1;
                if (pop) rp <= rp + 1'b1;
            end
            cnt <= cnt + {{DEPTH_LG{1'b0}}, accept} - {{DEPTH_LG{1'b0}}, pop};
        end
    end
endmodule
