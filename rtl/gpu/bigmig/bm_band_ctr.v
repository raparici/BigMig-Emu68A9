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

// next-band counter shared by the render units and the ARM cores

module bm_band_ctr #(
    parameter N = 4,            // requesters: fabric units + core #1 + core #0
    parameter W = 8
) (
    input  wire          aclk, input wire resetn,
    input  wire          prog_we, input wire [W-1:0] prog_count,     // new frame: bands 0..count-1
    input  wire [N-1:0]  claim,
    output reg  [N-1:0]  grant,
    output reg  [W-1:0]  band,
    output reg           done
);
    localparam LG = $clog2(N);
    reg [W-1:0] next, count; reg [LG-1:0] rr;
    integer i; reg [LG-1:0] pick; reg found; reg [LG:0] idx;
    always @(*) begin
        found = 1'b0; pick = rr;
        for (i = 0; i < N; i = i + 1) begin
            idx = {1'b0, rr} + i[LG:0];
            if (idx >= N[LG:0]) idx = idx - N[LG:0];          // (rr + i) % N, N <= 2^LG
            if (!found && claim[idx[LG-1:0]]) begin found = 1'b1; pick = idx[LG-1:0]; end
        end
    end
    always @(posedge aclk) begin
        grant <= {N{1'b0}};
        if (!resetn) begin next <= 0; count <= 0; rr <= 0; done <= 1'b0; band <= 0; end
        else if (prog_we) begin next <= 0; count <= prog_count; done <= 1'b0; end
        else if (found) begin
            grant[pick] <= 1'b1; rr <= pick + 1'b1;
            if (next < count) begin band <= next; next <= next + 1'b1; done <= 1'b0; end
            else done <= 1'b1;
        end
    end
endmodule
