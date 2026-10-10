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

// first-word-fall-through stream FIFO (block-RAM friendly)

module bm_stream_fifo #(
    parameter W = 34,
    parameter LG = 9
) (
    input  wire             clk,
    input  wire             resetn,
    input  wire             s_valid, output wire s_ready, input wire [W - 1 : 0] s_data,
    output wire             m_valid, input wire m_ready, output wire [W - 1 : 0] m_data,
    output wire             busy
);
    localparam D = 1 << LG;
    (* ramstyle = "no_rw_check" *) reg [W - 1 : 0] mem [0 : D - 1];
    reg  [LG : 0]   wp, rp;
    reg  [W - 1 : 0] q;
    reg             qv;
    wire            empty = (wp == rp);
    wire            full = ((wp - rp) == D[LG : 0]);
    wire            wr = s_valid && !full;
    wire            rd = !empty && (!qv || m_ready);
    assign s_ready = !full;
    assign m_valid = qv;
    assign m_data = q;
    assign busy = qv || !empty;
    always @(posedge clk) begin
        if (wr) mem[wp[LG - 1 : 0]] <= s_data;
        if (rd) q <= mem[rp[LG - 1 : 0]];
    end
    always @(posedge clk)
        if (!resetn) begin
            wp <= {(LG + 1){1'b0}}; rp <= {(LG + 1){1'b0}}; qv <= 1'b0;
        end else begin
            if (wr) wp <= wp + 1'b1;
            if (rd) begin rp <= rp + 1'b1; qv <= 1'b1; end
            else if (m_ready) qv <= 1'b0;
        end
endmodule
