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

// AXI-3 to AXI4-Lite adapter for the HPS h2f master (hand-rolled: Qsys needs Quartus 20.1)

`default_nettype none

module h2f_axi3_to_lite #(
	parameter integer ID_WIDTH        = 12,   // h2f master ID width
	parameter integer H2F_ADDR_WIDTH  = 30,   // h2f fabric address (1 GB window @ base 0)
	parameter integer LITE_ADDR_WIDTH = 25,   // axi_seam_slave window (32 MB, offset only)
	parameter integer DATA_WIDTH      = 32
)(
	input  wire                        aclk,
	input  wire                        aresetn,

	// ---- AXI-3 SLAVE side (connect to the hps2fpga h2f master) --------------------
	input  wire [ID_WIDTH-1:0]         s_awid,
	input  wire [H2F_ADDR_WIDTH-1:0]   s_awaddr,
	input  wire [3:0]                  s_awlen,     // ignored (single beat)
	input  wire [2:0]                  s_awsize,    // ignored
	input  wire [1:0]                  s_awburst,   // ignored
	input  wire [1:0]                  s_awlock,    // ignored
	input  wire [3:0]                  s_awcache,   // ignored
	input  wire [2:0]                  s_awprot,
	input  wire                        s_awvalid,
	output wire                        s_awready,

	input  wire [ID_WIDTH-1:0]         s_wid,       // ignored
	input  wire [DATA_WIDTH-1:0]       s_wdata,
	input  wire [(DATA_WIDTH/8)-1:0]   s_wstrb,
	input  wire                        s_wlast,     // ignored (single beat)
	input  wire                        s_wvalid,
	output wire                        s_wready,

	output wire [ID_WIDTH-1:0]         s_bid,
	output wire [1:0]                  s_bresp,
	output wire                        s_bvalid,
	input  wire                        s_bready,

	input  wire [ID_WIDTH-1:0]         s_arid,
	input  wire [H2F_ADDR_WIDTH-1:0]   s_araddr,
	input  wire [3:0]                  s_arlen,     // ignored
	input  wire [2:0]                  s_arsize,    // ignored
	input  wire [1:0]                  s_arburst,   // ignored
	input  wire [1:0]                  s_arlock,    // ignored
	input  wire [3:0]                  s_arcache,   // ignored
	input  wire [2:0]                  s_arprot,
	input  wire                        s_arvalid,
	output wire                        s_arready,

	output wire [ID_WIDTH-1:0]         s_rid,
	output wire [DATA_WIDTH-1:0]       s_rdata,
	output wire [1:0]                  s_rresp,
	output wire                        s_rlast,     // always 1 (single beat)
	output wire                        s_rvalid,
	input  wire                        s_rready,

	// ---- AXI4-Lite MASTER side (connect to axi_seam_slave.s_axi) ------------------
	output wire [LITE_ADDR_WIDTH-1:0]  m_awaddr,
	output wire [2:0]                  m_awprot,
	output wire                        m_awvalid,
	input  wire                        m_awready,

	output wire [DATA_WIDTH-1:0]       m_wdata,
	output wire [(DATA_WIDTH/8)-1:0]   m_wstrb,
	output wire                        m_wvalid,
	input  wire                        m_wready,

	input  wire [1:0]                  m_bresp,
	input  wire                        m_bvalid,
	output wire                        m_bready,

	output wire [LITE_ADDR_WIDTH-1:0]  m_araddr,
	output wire [2:0]                  m_arprot,
	output wire                        m_arvalid,
	input  wire                        m_arready,

	input  wire [DATA_WIDTH-1:0]       m_rdata,
	input  wire [1:0]                  m_rresp,
	input  wire                        m_rvalid,
	output wire                        m_rready
);
	// ---- write address / data: straight pass-through -----------------------------
	assign m_awaddr  = s_awaddr[LITE_ADDR_WIDTH-1:0];   // low bits: slave @ base 0
	assign m_awprot  = s_awprot;
	assign m_awvalid = s_awvalid;
	assign s_awready = m_awready;

	assign m_wdata   = s_wdata;
	assign m_wstrb   = s_wstrb;
	assign m_wvalid  = s_wvalid;
	assign s_wready  = m_wready;

	// ---- read address: straight pass-through -------------------------------------
	assign m_araddr  = s_araddr[LITE_ADDR_WIDTH-1:0];
	assign m_arprot  = s_arprot;
	assign m_arvalid = s_arvalid;
	assign s_arready = m_arready;

	// ---- ID reflection (single-outstanding: one AWID and one ARID in flight) -----
	reg [ID_WIDTH-1:0] awid_q;
	reg [ID_WIDTH-1:0] arid_q;
	always @(posedge aclk or negedge aresetn) begin
		if (!aresetn) begin
			awid_q <= {ID_WIDTH{1'b0}};
			arid_q <= {ID_WIDTH{1'b0}};
		end else begin
			if (s_awvalid & s_awready) awid_q <= s_awid;   // capture at AW handshake
			if (s_arvalid & s_arready) arid_q <= s_arid;   // capture at AR handshake
		end
	end

	// ---- write response: Lite B + reflected BID ----------------------------------
	assign s_bid     = awid_q;
	assign s_bresp   = m_bresp;
	assign s_bvalid  = m_bvalid;
	assign m_bready  = s_bready;

	// ---- read response: Lite R + reflected RID, RLAST=1 (single beat) -------------
	assign s_rid     = arid_q;
	assign s_rdata   = m_rdata;
	assign s_rresp   = m_rresp;
	assign s_rlast   = 1'b1;
	assign s_rvalid  = m_rvalid;
	assign m_rready  = s_rready;

endmodule

`default_nettype wire
