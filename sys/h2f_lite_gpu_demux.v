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

// h2f AXI4-Lite bus split between the chip seam and the GPU register block

`default_nettype none
module h2f_lite_gpu_demux #(
	parameter integer A = 30                 // the adapter's lite address width
)(
	input  wire          aclk,
	input  wire          aresetn,
	// from h2f_axi3_to_lite (lite master)
	input  wire [A-1:0]  s_awaddr,  input wire [2:0] s_awprot, input wire s_awvalid, output wire s_awready,
	input  wire [31:0]   s_wdata,   input wire [3:0] s_wstrb,  input wire s_wvalid,  output wire s_wready,
	output wire [1:0]    s_bresp,   output wire s_bvalid,      input wire s_bready,
	input  wire [A-1:0]  s_araddr,  input wire [2:0] s_arsize, input wire [2:0] s_arprot, input wire s_arvalid,
	output wire          s_arready,
	output wire [31:0]   s_rdata,   output wire [1:0] s_rresp, output wire s_rvalid, input wire s_rready,
	// to the seam (axi_seam_slave): unchanged 25-bit offsets
	output wire [24:0]   m0_awaddr, output wire [2:0] m0_awprot, output wire m0_awvalid, input wire m0_awready,
	output wire [31:0]   m0_wdata,  output wire [3:0] m0_wstrb,  output wire m0_wvalid,  input wire m0_wready,
	input  wire [1:0]    m0_bresp,  input wire m0_bvalid,        output wire m0_bready,
	output wire [24:0]   m0_araddr, output wire [2:0] m0_arsize, output wire [2:0] m0_arprot, output wire m0_arvalid,
	input  wire          m0_arready,
	input  wire [31:0]   m0_rdata,  input wire [1:0] m0_rresp,   input wire m0_rvalid,   output wire m0_rready,
	// to the GPU's register block (bm_gpu_regs): 4 KB
	output wire [11:0]   m1_awaddr, output wire m1_awvalid, input wire m1_awready,
	output wire [31:0]   m1_wdata,  output wire m1_wvalid,  input wire m1_wready,
	input  wire [1:0]    m1_bresp,  input wire m1_bvalid,   output wire m1_bready,
	output wire [11:0]   m1_araddr, output wire m1_arvalid, input wire m1_arready,
	input  wire [31:0]   m1_rdata,  input wire [1:0] m1_rresp, input wire m1_rvalid, output wire m1_rready
);
	wire aw_gpu = (s_awaddr[A-1:25] == {{(A-26){1'b0}}, 1'b1});
	wire ar_gpu = (s_araddr[A-1:25] == {{(A-26){1'b0}}, 1'b1});

	// a response owed per channel and slave (address handshake -> response handshake)
	reg w_seam = 1'b0, w_gpu = 1'b0, r_seam = 1'b0, r_gpu = 1'b0;
	always @(posedge aclk) begin
		if (!aresetn) begin
			w_seam <= 1'b0; w_gpu <= 1'b0; r_seam <= 1'b0; r_gpu <= 1'b0;
		end else begin
			w_seam <= (w_seam & ~(m0_bvalid & s_bready)) | (m0_awvalid & m0_awready);
			w_gpu  <= (w_gpu  & ~(m1_bvalid & s_bready)) | (m1_awvalid & m1_awready);
			r_seam <= (r_seam & ~(m0_rvalid & s_rready)) | (m0_arvalid & m0_arready);
			r_gpu  <= (r_gpu  & ~(m1_rvalid & s_rready)) | (m1_arvalid & m1_arready);
		end
	end

	assign m0_awaddr  = s_awaddr[24:0];
	assign m0_awprot  = s_awprot;
	assign m0_awvalid = s_awvalid & ~aw_gpu & ~w_gpu;
	assign m0_wdata   = s_wdata;
	assign m0_wstrb   = s_wstrb;
	assign m0_wvalid  = s_wvalid & ~aw_gpu & ~w_gpu;
	assign m0_bready  = s_bready;
	assign m0_araddr  = s_araddr[24:0];
	assign m0_arsize  = s_arsize;
	assign m0_arprot  = s_arprot;
	assign m0_arvalid = s_arvalid & ~ar_gpu & ~r_gpu;
	assign m0_rready  = s_rready;

	// GPU: its window only, and only while the seam owes the channel nothing
	assign m1_awaddr  = s_awaddr[11:0];
	assign m1_awvalid = s_awvalid & aw_gpu & ~w_seam & ~w_gpu;
	assign m1_wdata   = s_wdata;
	assign m1_wvalid  = s_wvalid & aw_gpu & ~w_seam & ~w_gpu;
	assign m1_bready  = s_bready;
	assign m1_araddr  = s_araddr[11:0];
	assign m1_arvalid = s_arvalid & ar_gpu & ~r_seam & ~r_gpu;
	assign m1_rready  = s_rready;

	// back to the bridge: each slave raises ready / valid only for its own transactions
	assign s_awready = m0_awready | m1_awready;
	assign s_wready  = m0_wready  | m1_wready;
	assign s_bvalid  = m0_bvalid  | m1_bvalid;
	assign s_bresp   = m1_bvalid ? m1_bresp : m0_bresp;
	assign s_arready = m0_arready | m1_arready;
	assign s_rvalid  = m0_rvalid  | m1_rvalid;
	assign s_rdata   = m1_rvalid ? m1_rdata : m0_rdata;
	assign s_rresp   = m1_rvalid ? m1_rresp : m0_rresp;
endmodule
`default_nettype wire
