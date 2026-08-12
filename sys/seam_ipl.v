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

// REG_IPL readback: tear-proof crossing of Paula's active-low IPL and the m68k reset line

module seam_ipl
(
    input             clk,             // AXI / h2f clock
    input             reset_n,

    output     [7:0]  readdata,        // REG_IPL low byte
    output     [7:0]  epoch_gray,      // FL-RST reset-assertion epoch

    input             sync_clk,        // 28 MHz Amiga chip-bus clock
    input      [2:0]  ipl_n,           // Paula IPL, active low
    input             chip_reset_n     // composite m68k reset-line view
);

    // ---- source (28 MHz) domain: coherent snapshot -------------------------
    reg  [2:0] ipl_src   = 3'b111;
    reg        rst_src   = 1'b1;
    reg        rst_src_d = 1'b1;

    always @(posedge sync_clk or negedge reset_n) begin
        if (!reset_n) begin
            ipl_src <= 3'b111;
            rst_src <= 1'b1;
        end else begin
            ipl_src <= ipl_n;
            rst_src <= chip_reset_n;
        end
    end

    // ---- FL-RST: count reset ASSERTIONS, publish as gray -------------------
    reg  [7:0] epoch_bin  = 8'd0;
    reg  [7:0] epoch_gs   = 8'd0;

    always @(posedge sync_clk or negedge reset_n) begin
        if (!reset_n) begin
            rst_src_d <= 1'b1;
            epoch_bin <= 8'd0;
            epoch_gs  <= 8'd0;
        end else begin
            rst_src_d <= rst_src;
            if (rst_src_d && !rst_src) begin           // falling edge = asserted
                epoch_bin <= epoch_bin + 8'd1;
                epoch_gs  <= (epoch_bin + 8'd1) ^ ((epoch_bin + 8'd1) >> 1);
            end
        end
    end

    // ---- AXI domain: 2-FF sync, then the D11 stability filter --------------
    // FL-11: keep every synchroniser chain atomic against physical-synthesis
    // duplication/retiming -- a per-compile CDC lottery bit us before.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg  [2:0] ipl_m1 = 3'b111;
    (* altera_attribute = "-name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg  [2:0] ipl_m2 = 3'b111;
    (* altera_attribute = "-name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg  [2:0] ipl_m3 = 3'b111;
    reg  [2:0] ipl_pub = 3'b111;

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg        rst_m1 = 1'b1;
    (* altera_attribute = "-name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg        rst_m2 = 1'b1;

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg  [7:0] eg_m1 = 8'd0;
    (* altera_attribute = "-name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg  [7:0] eg_m2 = 8'd0;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ipl_m1 <= 3'b111; ipl_m2 <= 3'b111; ipl_m3 <= 3'b111; ipl_pub <= 3'b111;
            rst_m1 <= 1'b1;   rst_m2 <= 1'b1;
            eg_m1  <= 8'd0;   eg_m2  <= 8'd0;
        end else begin
            ipl_m1 <= ipl_src;
            ipl_m2 <= ipl_m1;
            ipl_m3 <= ipl_m2;
            if (ipl_m2 == ipl_m3) ipl_pub <= ipl_m2;   // D11: two equal samples
            rst_m1 <= rst_src;
            rst_m2 <= rst_m1;
            eg_m1  <= epoch_gs;
            eg_m2  <= eg_m1;
        end
    end

    assign readdata   = {4'b0000, rst_m2, ipl_pub};
    assign epoch_gray = eg_m2;

endmodule
