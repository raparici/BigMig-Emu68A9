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

// h2f AXI4-Lite front-end of the chip seam @ 0xC0000000; register map in the OFF_* below

module axi_seam_slave
#(
	parameter integer C_S_AXI_ADDR_WIDTH = 25,   // 32 MB window (offset only)
	parameter integer C_S_AXI_DATA_WIDTH = 32,
	// Native-longword switch.  BigMig.sv passes 1.  Defaults to 0 so the parameter
	// alone is an A/B: at 0 the burst FSM is pruned and this is byte-identical to the
	// single-word core.
	parameter integer LONGWORD_EN = 0,
	// request-FIFO depth as log2, forwarded to seam_engine. 0 => depth 1 => byte-identical to the pre-FIFO engine, so the FIFO is opt-in.
	parameter integer REQFIFO_LOG2 = 0
)
(
	// ---- AXI4-Lite slave (h2f clock) -----------------------------------
	input                                  S_AXI_ACLK,
	input                                  S_AXI_ARESETN,

	input      [C_S_AXI_ADDR_WIDTH-1:0]    S_AXI_AWADDR,
	input      [2:0]                       S_AXI_AWPROT,
	input                                  S_AXI_AWVALID,
	output                                 S_AXI_AWREADY,

	input      [C_S_AXI_DATA_WIDTH-1:0]    S_AXI_WDATA,
	input      [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
	input                                  S_AXI_WVALID,
	output                                 S_AXI_WREADY,

	output     [1:0]                       S_AXI_BRESP,
	output                                 S_AXI_BVALID,
	input                                  S_AXI_BREADY,

	input      [C_S_AXI_ADDR_WIDTH-1:0]    S_AXI_ARADDR,
	input      [2:0]                       S_AXI_ARSIZE,   // 0 byte, 1 word, 2 longword (chip-RAM window)
	input      [2:0]                       S_AXI_ARPROT,
	input                                  S_AXI_ARVALID,
	output                                 S_AXI_ARREADY,

	output reg [C_S_AXI_DATA_WIDTH-1:0]    S_AXI_RDATA,
	output reg [1:0]                       S_AXI_RRESP,
	output                                 S_AXI_RVALID,
	input                                  S_AXI_RREADY,

	// ---- Amiga chip-bus clock domain -----------------------------------
	input                                  sync_clk,      // clk_sys (28 MHz)

	// word-transaction port -> minimig_m68k_hybrid_bridge.v
	output [22:0] hyb_address,
	output        hyb_read,
	output        hyb_write,
	output [15:0] hyb_writedata,
	output [1:0]  hyb_byteenable,
	output        hyb_longword,
	output        hyb_request,
	input  [15:0] hyb_readdata,
	input         hyb_complete,
	input  [15:0] hyb_readdata_hi,   // LW-FUSE: word at A when hyb_lw_done (see seam_engine)
	input         hyb_lw_done,       // 1 = that completion carried BOTH halves
	input         hyb_cerr,       // sticky DTACK-timeout flag from the bridge (28 MHz)

	// IPL / reset readback inputs (from Paula / minimig, 28 MHz domain)
	input  [2:0]  ipl_n,          // Paula IPL, active-low
	input         blt_busy,       // blitter busy -> REG_IPL bit4
	input         cpu_reset_n,   //  m68k reset_n (wire to minimig cpu_rst)

	// control-plane outputs
	output [31:0] vbr,            // m68k VBR mirror (28 MHz domain)
	output [3:0]  cacr,           // m68k CACR mirror (28 MHz domain)
	output reg [1:0] ovl,   //  raw OVL register (bit0 unconnected)
	output        soft_rst,   //  STRETCHED OVL[1] reset (AXI domain)
	                              //   -> bridge .soft_reset (has its own 2-FF sync)
	output        chip_rst_req    // same reset, 2-FF synced into sync_clk
	                              //   -> BigMig.sv drives minimig._cpu_reset_in
	                              //      with ~chip_rst_req (warm-reboot chipset
	                              //      reset + overlay re-arm)

);

	// ---- window byte-offsets ------------------------------------------
	localparam [24:0] OFF_ADDR    = 25'h0000000;
	localparam [24:0] OFF_WDATA   = 25'h0000004;
	localparam [24:0] OFF_CTRL    = 25'h0000008;
	localparam [24:0] OFF_RESULT  = 25'h000000C;   // folded + BLOCKING; layout at the read
	localparam [24:0] OFF_STATUS  = 25'h0000010;   // non-blocking alias; bit3 FULL is load-bearing
	localparam [24:0] OFF_OVL     = 25'h0000014;
	localparam [24:0] OFF_RDATA_HI= 25'h0000018;   //  longword high word
	localparam [24:0] OFF_RSTEPOCH= 25'h000001C;   // FL-RST epoch protocol (see below)
	localparam [24:0] OFF_IPL     = 25'h1000000;
	localparam [24:0] OFF_VBR     = 25'h1000008;
	localparam [24:0] OFF_CACR    = 25'h100000C;
	// capture-ring readback

	// ================================================================== //
	// AXI4-Lite write channel (single outstanding)                       //
	// ================================================================== //
	reg  axi_awready, axi_wready, axi_bvalid;
	reg  [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;

	// writes wait while a window read owns the engine, so it never sees two writers
	wire win_ar_present;
	wire win_owner;
	wire write_accept = ~axi_awready & S_AXI_AWVALID & S_AXI_WVALID
	                    & (~axi_bvalid | S_AXI_BREADY)
	                    & ~win_owner & ~win_ar_present;

	always @(posedge S_AXI_ACLK) begin
		if (~S_AXI_ARESETN) begin
			axi_awready <= 1'b0;
			axi_wready  <= 1'b0;
			axi_bvalid  <= 1'b0;
			axi_awaddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
		end else begin
			axi_awready <= write_accept;
			axi_wready  <= write_accept;
			if (write_accept) axi_awaddr <= S_AXI_AWADDR;

	// BVALID must rise AFTER the AW/W handshake, never in the same beat.
			if (axi_awready)                  axi_bvalid <= 1'b1;
			else if (axi_bvalid & S_AXI_BREADY) axi_bvalid <= 1'b0;
		end
	end

	// `do_write` is a one-cycle strobe with axi_awaddr / S_AXI_WDATA valid.
	wire do_write = axi_awready;

	assign S_AXI_AWREADY = axi_awready;
	assign S_AXI_WREADY  = axi_wready;
	assign S_AXI_BVALID  = axi_bvalid;
	assign S_AXI_BRESP   = 2'b00; // OKAY

	// ---- write address decode -> per-block strobes --------------------
	wire [24:0] wa = axi_awaddr[24:0];
	reg        aa_write;   // seam_engine register write
	reg  [2:0] aa_sel;     // 0=ADDR 1=WDATA 2=CTRL
	reg        regs_write; // seam_cpuregs write
	reg  [0:0] regs_addr;  // 0=VBR 1=CACR (1-bit vector: matches VHDL port)

	always @* begin
		aa_write   = 1'b0;
		aa_sel     = 3'b000;
		regs_write = 1'b0;
		regs_addr  = 1'b0;
		if (do_write) begin
			case (wa)
				OFF_ADDR : begin aa_write = 1'b1; aa_sel = 3'b000; end
				OFF_WDATA: begin aa_write = 1'b1; aa_sel = 3'b001; end
				OFF_CTRL : begin aa_write = 1'b1; aa_sel = 3'b010; end
				OFF_VBR  : begin regs_write = 1'b1; regs_addr = 1'b0; end
				OFF_CACR : begin regs_write = 1'b1; regs_addr = 1'b1; end
				default  : ;
			endcase
		end
	end

	// REG_OVL is local: bit1 is the reset strobe, bit0 is accepted and unconnected.
	always @(posedge S_AXI_ACLK) begin
		if (~S_AXI_ARESETN) ovl <= 2'b00;
		else if (do_write && (wa == OFF_OVL)) ovl <= S_AXI_WDATA[1:0];
	end

	// self-clearing reset-strobe stretcher on OVL[1]: any write of OVL[1]=1 holds soft_rst for 1024 AXI clocks, long enough for the engine flush, the bridge park and a chipset reset with overlay re-arm
	reg [2:0] crn_axi = 3'b111;
	always @(posedge S_AXI_ACLK) crn_axi <= {crn_axi[1:0], cpu_reset_n};
	reg [9:0] srst_cnt;
	reg       srst_lvl;
	always @(posedge S_AXI_ACLK) begin
		if (~S_AXI_ARESETN) begin
			srst_cnt <= 10'd0;
			srst_lvl <= 1'b0;
		end else if ((do_write && (wa == OFF_OVL) && S_AXI_WDATA[1]) ||
		             (do_write && (wa == OFF_RSTEPOCH) && (S_AXI_WDATA[1] | S_AXI_WDATA[0])) ||
		             ~crn_axi[2]) begin   // external OSD reset (cpu_reset_n low) -> flush the seam too
	// A chipset reset must also park the seam: a cycle launched before it would otherwise
	// complete into a chipset that no longer exists.
			srst_cnt <= 10'd1023;               // (re)trigger: OVL[1] | RSTEPOCH.chip | RSTEPOCH.seam
			srst_lvl <= 1'b1;
		end else if (srst_cnt != 10'd0) begin
			srst_cnt <= srst_cnt - 10'd1;
			srst_lvl <= (srst_cnt != 10'd1);    // registered: glitch-free CDC source
		end
	end
	assign soft_rst = srst_lvl;

	// Split chipset-reset stretcher: OVL[1] keeps its combined meaning, RSTEPOCH separates
	// the two so the chipset can be reset without flushing the seam.
	reg [9:0] crst_cnt;
	reg       crst_lvl;
	always @(posedge S_AXI_ACLK) begin
		if (~S_AXI_ARESETN) begin
			crst_cnt <= 10'd0;
			crst_lvl <= 1'b0;
		end else if ((do_write && (wa == OFF_OVL) && S_AXI_WDATA[1]) ||
		             (do_write && (wa == OFF_RSTEPOCH) && S_AXI_WDATA[0])) begin
			crst_cnt <= 10'd1023;
			crst_lvl <= 1'b1;
		end else if (crst_cnt != 10'd0) begin
			crst_cnt <= crst_cnt - 10'd1;
			crst_lvl <= (crst_cnt != 10'd1);
		end
	end

	// chip-domain copy of the stretched reset (2-FF). Exported so BigMig.sv can drive minimig._cpu_reset_in low for the pulse.
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
	reg [2:0] crst_sync = 3'b000;
	always @(posedge sync_clk) crst_sync <= {crst_sync[1:0], crst_lvl};
	assign chip_rst_req = crst_sync[2];

	// External-reset (OSD / Ctrl-A-A) stretcher: mirror the chipset reset into the seam so
	// an in-flight cycle cannot outlive it.
	reg [15:0] extrst_cnt = 16'd0;
	reg        extrst_lvl = 1'b0;
	reg [2:0]  crn_sync    = 3'b111;   // cpu_reset_n into sync_clk (async from the chip domain)
	always @(posedge sync_clk) begin
		crn_sync <= {crn_sync[1:0], cpu_reset_n};
		if (~crn_sync[2])                       // external reset asserted (synced, active-low)
			extrst_cnt <= 16'hFFFF;             // (re)trigger the ~2.3 ms stretch
		else if (extrst_cnt != 16'd0)
			extrst_cnt <= extrst_cnt - 16'd1;
		extrst_lvl <= (extrst_cnt != 16'd0);    // registered -> glitch-free reset-line view
	end

	// AXI4-Lite read channel (single outstanding). SEAM_BLOCKING_READ holds RVALID low until the cycle completes; the hold MUST stay bounded, or an unbounded one wedges the issuing A9 core with no abort possible.
	localparam SEAM_BLOCKING_READ = 1'b1;
	localparam [10:0] BLK_TIMEOUT = 11'd2047;   // &blk_to saturation ~ 20.5 us

	reg  axi_arready, axi_rvalid;
	reg  [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
	reg  blk_pending;   // a blocking OFF_RESULT read is waiting for aa_busy to clear
	reg  [10:0] blk_to;   //  bounded-hold countdown while blk_pending

	// chip-RAM window, offsets 0x0800000-0x09FFFFF: a read becomes a seam request, R waits for it, SLVERR on timeout
	localparam [3:0] WIN_HI = 4'b0100;          // araddr[24:21] of the window
	localparam [2:0] W_IDLE = 3'd0, W_ADDR = 3'd1, W_CTRL = 3'd2, W_SETTLE = 3'd3, W_PARK = 3'd4;
	reg  [2:0]  win_st = W_IDLE;
	reg         win_write = 1'b0;
	reg  [2:0]  win_sel   = 3'd0;
	reg  [31:0] win_wdata = 32'd0;
	reg  [2:0]  win_size  = 3'd0;
	reg  [7:0]  win_cnt   = 8'd0;               // window retirements, subtracted from DONE
	wire        win_hit_ar = (S_AXI_ARADDR[24:21] == WIN_HI);
	assign win_ar_present = S_AXI_ARVALID & win_hit_ar & ~axi_arready & ~axi_rvalid & ~blk_pending;
	assign win_owner      = (win_st != W_IDLE);
	wire [7:0]  done_seen;                      // DONE net of the window's retirements

	// read-data sources from the register blocks
	wire [15:0] aa_rdata;      // primary/low word (single-word result, or longword A+2)
	wire [15:0] aa_rdata_hi;   //  longword high word (addr A); 0 when LONGWORD_EN=0
	wire        aa_busy;
	wire        aa_full;   //  request FIFO cannot accept another trigger
	wire        aa_ovf;       // sticky: a trigger was REFUSED (a chip cycle was lost)
	wire [7:0]  aa_done_cnt;  // retired transactions -- lets the firmware drop the prime read
	assign done_seen = aa_done_cnt - win_cnt;
	// Quasi-static by construction: lat_bus only changes when a transaction completes, and the
	// firmware reads it once the engine is idle, so a plain 2-FF sync is enough -- there is no
	// moment where a reader can catch it mid-update.  Diagnostic only; nothing steers on it.
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	wire [7:0]  irq_rdata;
	wire [7:0]  epoch_gray;   // FL-RST: gray-coded chipset-reset epoch (seam_ipl)

	// hyb_cerr (sticky DTACK-timeout, bridge domain) -> AXI clock: 2-FF synchroniser of a slowly-changing sticky bit, surfaced in REG_STATUS bit1
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
	reg [2:0] cerr_sync;
	always @(posedge S_AXI_ACLK) begin
		if (~S_AXI_ARESETN) cerr_sync <= 3'b000;
		else                cerr_sync <= {cerr_sync[1:0], hyb_cerr};
	end
	wire cerr_axi = cerr_sync[2];

	always @(posedge S_AXI_ACLK) begin
		if (~S_AXI_ARESETN) begin
			axi_arready <= 1'b0;
			axi_rvalid  <= 1'b0;
			axi_araddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
			S_AXI_RDATA <= {C_S_AXI_DATA_WIDTH{1'b0}};
			blk_pending <= 1'b0;
			blk_to      <= 11'd0;
			S_AXI_RRESP <= 2'b00;
			win_st      <= W_IDLE;
			win_write   <= 1'b0;
			win_cnt     <= 8'd0;
		end else begin
			// gate a new address accept while a blocking read is parked (single outstanding);
			// a window read also needs the engine idle and no register write landing
			if (~axi_arready & S_AXI_ARVALID & ~axi_rvalid & ~blk_pending & ~win_owner &
			    (~win_hit_ar | (~aa_busy & ~soft_rst & ~axi_awready & ~write_accept))) begin
				axi_arready <= 1'b1;
				axi_araddr  <= S_AXI_ARADDR;
				win_size    <= S_AXI_ARSIZE;
			end else begin
				axi_arready <= 1'b0;
			end

			// window request: REG_ADDR, then REG_CTRL (read, both byteenables, longword iff size 2)
			win_write <= 1'b0;
			case (win_st)
				W_ADDR:   begin win_write <= 1'b1; win_sel <= 3'd2;
				                win_wdata <= {27'd0, (win_size == 3'd2) ? 5'b11101 : 5'b01101};
				                win_st <= W_CTRL; end
				W_CTRL:   win_st <= W_SETTLE;
				W_SETTLE: begin win_st <= W_PARK; blk_to <= 11'd0; end
				default:  ;
			endcase

			if (axi_arready) begin
				if ((axi_araddr[24:21] == WIN_HI) && (LONGWORD_EN == 1 || win_size != 3'd2)) begin
					win_write <= 1'b1; win_sel <= 3'd0;
					win_wdata <= {12'd0, axi_araddr[20:1]};
					win_st    <= W_ADDR;
				end else
				if (SEAM_BLOCKING_READ & (axi_araddr[24:0] == OFF_RESULT) & aa_busy) begin
					// cycle still in flight -> PARK: hold RVALID low until it completes
					blk_pending <= 1'b1;
					blk_to      <= 11'd0;
				end else begin
					axi_rvalid  <= 1'b1;
					S_AXI_RRESP <= 2'b00;
					case (axi_araddr[24:0])
						// folded result: busy(31) + cerr(30) + data[15:0] in one beat
						OFF_RESULT  : S_AXI_RDATA <= {aa_busy, cerr_axi, aa_full, aa_ovf, 4'd0, done_seen, aa_rdata};
	// ⚠ bit3 FULL is load-bearing: the firmware gates its pushes on it, and a refused
	// trigger is a lost chip cycle.
						OFF_STATUS  : S_AXI_RDATA <= {28'd0, aa_full, 1'd0, cerr_axi, aa_busy};
						OFF_RDATA_HI: S_AXI_RDATA <= {16'd0, aa_rdata_hi};   //  longword hi
						// FL-RST epoch protocol: [31:28]=4'hE capability magic,
						// [23:16]=epoch (GRAY, compare-only token), [0]=gate
						// (same wired-OR reset_n view as REG_IPL bit3).
						OFF_RSTEPOCH: S_AXI_RDATA <= {4'hE, 4'd0, epoch_gray, 15'd0, irq_rdata[3]};
						OFF_IPL     : S_AXI_RDATA <= {24'd0, irq_rdata};
						// capture-ring readback: DATA = selected record
						// word; STAT = total events (freeze index = (total-1) & 511).
						default     : S_AXI_RDATA <= 32'd0;
					endcase
				end
			end else if (blk_pending) begin
						// Waiting out the in-flight cycle; aa_busy clears on completion.
				blk_to <= blk_to + 11'd1;
				if (~aa_busy || (blk_to == BLK_TIMEOUT) || srst_lvl) begin
					axi_rvalid  <= 1'b1;
					S_AXI_RRESP <= 2'b00;
					S_AXI_RDATA <= {aa_busy, cerr_axi, aa_full, aa_ovf, 4'd0, done_seen, aa_rdata};
					blk_pending <= 1'b0;
					blk_to      <= 11'd0;
				end
			end else if (win_st == W_PARK) begin
				// window read: the first retirement is ours; same bound and releases as the park above
				blk_to <= blk_to + 11'd1;
				if (~aa_busy || (blk_to == BLK_TIMEOUT) || srst_lvl) begin
					axi_rvalid  <= 1'b1;
					S_AXI_RRESP <= aa_busy ? 2'b10 : 2'b00;         // SLVERR if released unretired
					win_cnt     <= win_cnt + 8'd1;
					case (win_size)
						3'd2:    S_AXI_RDATA <= {aa_rdata[7:0], aa_rdata[15:8], aa_rdata_hi[7:0], aa_rdata_hi[15:8]};
						3'd1:    S_AXI_RDATA <= axi_araddr[1] ? {aa_rdata[7:0], aa_rdata[15:8], 16'h0000}
						                                      : {16'h0000, aa_rdata[7:0], aa_rdata[15:8]};
						default: S_AXI_RDATA <= axi_araddr[0] ? {4{aa_rdata[7:0]}} : {4{aa_rdata[15:8]}};
					endcase
					win_st      <= W_IDLE;
					blk_to      <= 11'd0;
				end
			end else if (axi_rvalid & S_AXI_RREADY) begin
				axi_rvalid <= 1'b0;
			end
		end
	end

	assign S_AXI_ARREADY = axi_arready;
	assign S_AXI_RVALID  = axi_rvalid;

	// ================================================================== //
	// Register blocks (mixed-language: Verilog instantiating VHDL)       //
	// ================================================================== //
	seam_engine #(.LONGWORD_EN(LONGWORD_EN), .REQFIFO_LOG2(REQFIFO_LOG2)) u_seam_engine
	(
		.clk             (S_AXI_ACLK),
		.reset_n         (S_AXI_ARESETN),
		.soft_rst        (soft_rst),   //  OVL[1] resets the WHOLE seam
		.reg_write       (aa_write | win_write),   // the window pushes too
		.reg_sel         (win_write ? win_sel   : aa_sel),
		.reg_wdata       (win_write ? win_wdata : S_AXI_WDATA),
		.rdata           (aa_rdata),
		.rdata_hi        (aa_rdata_hi),
		.status_busy     (aa_busy),
		.status_full     (aa_full),
		.status_ovf      (aa_ovf),            // sticky: a chip cycle WAS refused
		.done_count      (aa_done_cnt),

		.sync_clk        (sync_clk),
		.chip_address    (hyb_address),
		.chip_read       (hyb_read),
		.chip_write      (hyb_write),
		.chip_writedata  (hyb_writedata),
		.chip_byteenable (hyb_byteenable),
		.chip_longword   (hyb_longword),
		.chip_request    (hyb_request),
		.chip_readdata   (hyb_readdata),
		.chip_complete   (hyb_complete),
		.chip_readdata_hi(hyb_readdata_hi),
		.chip_lw_done    (hyb_lw_done)
	);

	// bit3 is the m68k RESET-LINE VIEW, wired-OR like a real open-drain RESET: low while
	// minimig asserts it OR while our own OVL[1] pulse is active.
	seam_ipl u_seam_ipl
	(
		.clk           (S_AXI_ACLK),
		.reset_n       (S_AXI_ARESETN),
		.readdata      (irq_rdata),
		.epoch_gray    (epoch_gray),
		.sync_clk      (sync_clk),
		.ipl_n         (ipl_n),
		.blt_busy      (blt_busy),
		.chip_reset_n  (cpu_reset_n & ~chip_rst_req & ~extrst_lvl)   // extrst: stretch the EXTERNAL (OSD) reset so the firmware always catches bit3=0
	);

	seam_cpuregs u_seam_cpuregs
	(
		.clk       (S_AXI_ACLK),
		.reset_n   (S_AXI_ARESETN),
		.wr        (regs_write),
		.wr_sel    (regs_addr),
		.wr_data   (S_AXI_WDATA),
		.sync_clk  (sync_clk),
		.vbr       (vbr),
		.cacr      (cacr)
	);

endmodule
