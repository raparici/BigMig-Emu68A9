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

// REG_VBR / REG_CACR write mirror of the m68k CPU registers

module seam_cpuregs
(
    input             clk,             // AXI / h2f clock
    input             reset_n,

    input             wr,              // 1-clk write strobe from the AXI decoder
    input             wr_sel,          // 0 = VBR, 1 = CACR
    input      [31:0] wr_data,

    input             sync_clk,        // 28 MHz Amiga chip-bus clock
    output     [31:0] vbr,
    output     [3:0]  cacr
);

    reg [31:0] vbr_axi  = 32'd0;
    reg [3:0]  cacr_axi = 4'd0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            vbr_axi  <= 32'd0;
            cacr_axi <= 4'd0;
        end else if (wr) begin
            if (wr_sel) cacr_axi <= wr_data[3:0];
            else        vbr_axi  <= wr_data;
        end
    end

    reg [31:0] vbr_sync  = 32'd0;
    reg [3:0]  cacr_sync = 4'd0;

    always @(posedge sync_clk or negedge reset_n) begin
        if (!reset_n) begin
            vbr_sync  <= 32'd0;
            cacr_sync <= 4'd0;
        end else begin
            vbr_sync  <= vbr_axi;
            cacr_sync <= cacr_axi;
        end
    end

    assign vbr  = vbr_sync;
    assign cacr = cacr_sync;

endmodule
