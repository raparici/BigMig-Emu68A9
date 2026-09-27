// Copyright 2026 Ruben Aparicio
// Chip-bus cycle generator cloned from cpu_wrapper.v, (c) Tobias Gubener / Alexey Melnikov
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

// the seam's chip-bus master: one word transaction -> one Amiga chip cycle.
// chip RAM goes down sdram_ctrl's CPU port (Via-B); everything else runs a chip-bus cycle.

module minimig_m68k_hybrid_bridge
(
	// ---- clocking / reset (same domain as cpu_wrapper's chip FSM) --------
	input             clk,            // 28.6 MHz Amiga system clock (clk_sys)
	input             reset_n,        // active-low; parks the bus when 0
	input             ph1,            // CPU phase-1 enable  (BigMig.sv divider)
	input             ph2,            // CPU phase-2 enable  (BigMig.sv divider)
	input             soft_reset,     // REG_OVL[1] reset strobe (h2f domain); fabric-resets the FSM

	// ---- word-transaction port (HYBRIDCPU_* contract, from seam_engine) --
	input      [22:0] ext_address,    // m68k WORD address (addr>>1)
	input             ext_read,       // 1 = read cycle  (informational)
	input             ext_write,      // 1 = write cycle
	input      [15:0] ext_writedata,  // 16-bit write data, A9/m68k order
	input       [1:0] ext_byteenable, // [0]=UDS (d8..15), [1]=LDS (d0..7)
	input             ext_request,    // held high until ext_complete
	input             ext_longword,   // live: claimed by the LW-FUSE on the Via-B path
	output     [15:0] ext_readdata,   // 16-bit read data, A9/m68k order
	output            ext_complete,   // 1-clk pulse: cycle done, ext_readdata valid
	// LW-FUSE: a Via-B longword read is served as ONE transaction. Strictly additive -- chip-bus longwords and every write still take two.
	output reg [15:0] ext_readdata_hi,// word at A (the HIGH half); valid when ext_lw_done
	output reg        ext_lw_done,    // 1 = this completion carries BOTH halves
	output reg        cerr,           // sticky: a cycle force-completed on DTACK timeout

	// ---- Amiga chip bus (drop-in for cpu_wrapper's chip_* master role) --
	output     [23:1] chip_addr,      // -> minimig.cpu_address
	input      [15:0] chip_dout,      // <- minimig.cpu_data  (read data)
	output     [15:0] chip_din,       // -> minimig.cpudata_in (write data)
	output            chip_as,        // -> minimig._cpu_as
	output            chip_uds,       // -> minimig._cpu_uds
	output            chip_lds,       // -> minimig._cpu_lds
	output            chip_rw,        // -> minimig.cpu_r_w   (1=read,0=write)
	input             chip_dtack,     // <- minimig._cpu_dtack

	// ---- VIA-B: sdram_ctrl CPU-port master (chip RAM only) --------------
	input             viab_en,        // 1 = route chip RAM via the CPU port (tie-off)
	input             viab_posted,    // 1 = writes complete on buffer ACCEPT (ramready)
	// Completion is SDRAM commit, not just arbitration.
	input             ovl,            // minimig.chip_ovl: Kickstart overlay active
	input       [1:0] chip_memcfg,    // memory_config[1:0]: chip-RAM size (block mirroring)
	input             blit_busy,      // blitter busy: paces Via-B launches during a blit
	output reg [24:1] cp_addr,        // -> sdram_ctrl.cpuAddr (post-mirroring, chip space)
	output reg        cp_cs,          // -> sdram_ctrl.cpuCS (armed one clk AFTER the payload)
	output reg  [1:0] cp_state,       // -> sdram_ctrl.cpustate (01 idle, 10 read, 11 write)
	output reg        cp_u,           // -> sdram_ctrl.cpuU (active-low upper-byte select)
	output reg        cp_l,           // -> sdram_ctrl.cpuL (active-low lower-byte select)
	output reg [15:0] cp_wdata,       // -> sdram_ctrl.cpuWR (dedicated launch-latched reg:
	                                  //    NOT wd_r/chip_din, so the cp_* -> ram1 false
	                                  //    path in BigMig.sdc cannot catch the chip-bus
	                                  //    datapath that wd_r also feeds)
	input      [15:0] cp_rdata,       // <- sdram_ctrl.cpuRD
	input             cp_ramready,    // <- sdram_ctrl.ramready (LEVEL until cpuCS drops)
	input             cp_write_busy,  // <- sdram_ctrl.write_busy (write buffer undrained)

	// the IDE windows PARK the chip bus: a DTACKed cycle would race fastchip's ready and hand back stale sectors. $B8xxxx does not -- do not unify the branches.
	input             fc_ide_ena,     // <- ide_ena & ide_fast (the SAME net fastchip gets)
	output reg        fc_sel,         // -> fastchip.sel      ($B8xxxx, $DAxxxx, $DE1xxx)
	input             fc_selack,      // <- fastchip.sel_ack  (1 = fastchip owns this cycle)
	input             fc_ready,       // <- fastchip.ready
	input      [15:0] fc_dout         // <- fastchip.dout
);

	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
	reg [2:0] srst_sync;
	always @(posedge clk or negedge reset_n) begin
		if (~reset_n) srst_sync <= 3'b000;
		else          srst_sync <= {srst_sync[1:0], soft_reset};
	end
	wire soft_rst = srst_sync[2];

	reg busy;
	reg done_latch;                       // set when a cycle finished; holds
	                                      // ext_complete deasserted view until
	                                      // request drops
	wire start = ext_request & ~busy & ~done_latch;

	// registered phase enables (mirror cpu_wrapper.v ph1n/ph2n)
	reg ph1n, ph2n;
	always @(posedge clk) begin
		ph1n <= ph1;
		ph2n <= ph2;
	end

	// chip-bus cycle generator on the negedge: 0 idle/drive strobes, 1 settle, 2 latch + DTACK, 3 recovery; Via-B adds 4, 5, 7, 8 for the CPU-port path
	localparam [3:0] VB_REQ = 4'd4, VB_DRAIN = 4'd5, VB_CAP = 4'd7,
	                 VB_LW2 = 4'd8;
	reg  [3:0] stage;
	reg        waitm;      // DTACK sampled on phase-2 (active-low: 0 = acked)
	reg        ready;      // cycle finished this phase
	reg        complete_p; // one-phase completion pulse
	reg        c_as, c_rw, c_uds, c_lds;
	// The live cycle's address, write data and byteenable are LATCHED at launch, so a
	// later control write cannot change a cycle already in flight.
	reg [22:0] addr_r;     // launched word address
	reg [15:0] wd_r;       // launched write data
	reg  [1:0] be_r;       // launched byteenable [0]=UDS,[1]=LDS
	reg [15:0] chipdout_i; // latched read data (chip order)
	reg [15:0] dtack_to;   // DTACK watchdog: counts ph1 phases the cycle waits in
	// Widened to 16 bits so the watchdog cannot expire during a legitimate long wait.
	reg  [5:0] ph_idle;    // review 2026-07 #5: PHASE-FREEZE detector -- clk cycles
	                       // without a ph1n while a cycle is in flight (see below).
	reg        vb_wr;      // VIA-B: launched cycle is a write (drain applies)
	reg        vb_lw;      // LW-FUSE: this Via-B READ serves both halves in one transaction
	reg        vb_second;  // ...and we are on the second half (A+2)
	// while a blit runs, Via-B launches are spaced BLITFAIR_CCK clk_sys apart (about one chip cycle)
	localparam [4:0] BLITFAIR_CCK = 5'd16;
	reg  [4:0] vb_throttle = 5'd0;
	reg [15:0] vb_to;      // VIA-B watchdog: clk cycles waiting on the CPU port.
	// 65536 x ~35 ns ~= 2.3 ms -- far above any legal wait, so the watchdog only fires
	// on a real hang.

	// ---- VIA-B branch decode (mirrors gary.v + bankmapper + sram_bridge) --
	// ext_address is the m68k WORD address (byte>>1): byte[N] = ext_address[N-1].
	wire       vb_is_chip = (ext_address[22:20] == 3'b000);       // byte < $200000
	wire [1:0] vb_blk     = ext_address[19:18];                    // 512K block index
	// OVL: while the Kickstart overlay is up, 512K block 0 is ROM territory on
	// the CPU side (gary.v:153/160 -- reads go to sel_kick, writes are void).
	// Keep it on the chip bus for byte-identical semantics.
	wire       vb_ovl_lock = ovl & (vb_blk == 2'b00);
	wire       vb_sel      = viab_en & vb_is_chip & ~vb_ovl_lock;
	// Block mirroring: map like the chip port so Agnus and the seam always alias, in
	// every memory configuration.
	wire [1:0] vb_blk_map = (chip_memcfg == 2'b11) ?  vb_blk :
	                        (chip_memcfg == 2'b10) ? ((vb_blk == 2'b11) ? 2'b00 : vb_blk) :
	                        (chip_memcfg == 2'b01) ? {1'b0, vb_blk[0]} :
	                                                  2'b00;
	wire [24:1] vb_cp_addr = {4'b0000, vb_blk_map, ext_address[17:0]};

	// fastchip window decode: $B8xxxx (Akiko + RTG) always, the IDE windows only when the
	// CPU-side Gayle is the enabled one, so fc_sel never claims what fastchip will not answer.
	wire fc_hit_b8    = (ext_address[22:15] ==  8'hB8);
	wire fc_hit_ide   = fc_ide_ena & (ext_address[22:15] ==  8'hDA);
	wire fc_hit_gayle = fc_ide_ena & (ext_address[22:11] == 12'hDE1);
	// The windows that must NOT drive the chip bus at all (see the port comment).
	wire fc_park_bus  = fc_hit_ide | fc_hit_gayle;
	wire fc_hit       = fc_hit_b8  | fc_park_bus;

	always @(negedge clk or negedge reset_n) begin
		if (~reset_n) begin
			stage      <= 4'd0;
			c_as       <= 1'b1;
			c_rw       <= 1'b1;
			c_uds      <= 1'b1;
			c_lds      <= 1'b1;
			ready      <= 1'b0;
			waitm      <= 1'b1;
			complete_p <= 1'b0;
			chipdout_i <= 16'd0;
			addr_r     <= 23'd0;
			wd_r       <= 16'd0;
			be_r       <= 2'd0;
			dtack_to   <= 16'd0;
			ph_idle    <= 6'd0;
			cerr       <= 1'b0;
			fc_sel     <= 1'b0;
			cp_addr    <= 24'd0;
			cp_cs      <= 1'b0;
			cp_state   <= 2'b01;
			cp_u       <= 1'b1;
			cp_l       <= 1'b1;
			cp_wdata   <= 16'd0;
			vb_wr      <= 1'b0;
			vb_to      <= 16'd0;
			vb_lw      <= 1'b0;
			vb_second  <= 1'b0;
			vb_throttle<= 5'd0;
			ext_readdata_hi <= 16'd0;
			ext_lw_done     <= 1'b0;
		end
		else if (soft_rst) begin
			// REG_OVL[1] recovery hammer: park the bus idle, clear the error.
			stage      <= 4'd0;
			c_as       <= 1'b1;
			c_rw       <= 1'b1;
			c_uds      <= 1'b1;
			c_lds      <= 1'b1;
			ready      <= 1'b0;
			waitm      <= 1'b1;
			complete_p <= 1'b0;
			dtack_to   <= 16'd0;
			ph_idle    <= 6'd0;
			cerr       <= 1'b0;
			fc_sel     <= 1'b0;
			cp_cs      <= 1'b0;   // VIA-B: park the CPU port too
			cp_state   <= 2'b01;
			vb_to      <= 16'd0;
			vb_lw      <= 1'b0;
			vb_second  <= 1'b0;
			vb_throttle<= 5'd0;
			ext_lw_done<= 1'b0;
		end
		else begin
			// Sample DTACK on phase 2 (chip_dtack is active-low)
			if (ph2n) waitm <= chip_dtack;

			complete_p <= 1'b0;
			// a Via-B request launches on any negedge; the chip-bus branch keeps the ph1 gate
			if (ph1n || (stage == 4'd0 && busy && vb_sel)) begin
				complete_p <= ready;
				ready      <= 1'b0;
				case (stage)
				// Launch off the PERSISTENT busy latch, not the request edge: the edge can
				// arrive between ph1 pulses.
					3'd0: if (busy && !(vb_sel && blit_busy && vb_throttle != 5'd0)) begin
							// launch -- and LATCH the payload: from here to
							// completion the cycle uses ONLY the *_r copies;
							// upstream xa_* changes cannot touch it.
							addr_r   <= ext_address;
							wd_r     <= ext_writedata;
							be_r     <= ext_byteenable;
							// cerr describes THIS cycle, so clear it at launch.  While it was
							// sticky, one transient DTACK timeout made every later access
							// report failure and the guest was handed corrupt data.
							cerr     <= 1'b0;
							// clear with cerr: a stale lw_done makes the next longword
							// return half garbage.
							ext_lw_done <= 1'b0;
							if (vb_sel) begin
					// VIA-B: chip RAM goes down sdram_ctrl's CPU port; the chip bus stays
					// parked for the whole access.
								cp_addr  <= vb_cp_addr;
								cp_state <= ext_write ? 2'b11 : 2'b10;
								// writes: byteenable -> active-low selects;
								// reads: full word (fold happens on ext_readdata)
								cp_u     <= ext_write ? ~ext_byteenable[0] : 1'b0;
								cp_l     <= ext_write ? ~ext_byteenable[1] : 1'b0;
								cp_wdata <= (ext_byteenable[0] ^ ext_byteenable[1])
								            ? {ext_writedata[7:0], ext_writedata[7:0]}
								            :  ext_writedata;
								vb_wr    <= ext_write;
								vb_to    <= 16'd0;           // arm the watchdog
					// LW-FUSE: claim the whole longword only on the Via-B branch.  A
					// chip-bus longword still takes two requests.
								vb_lw    <= ext_longword & ~ext_write;
								vb_second<= 1'b0;
								vb_throttle <= blit_busy ? BLITFAIR_CCK : 5'd0;
								stage    <= VB_REQ;
							end
							else begin
						// Classic chip-bus cycle: registers, CIA, kick, and chip RAM
						// when Via-B is off.
								c_as     <= fc_park_bus;         // 1 = bus parked
								c_rw     <= ~ext_write;          // 1=read, 0=write
								c_uds    <= ~ext_byteenable[0];  // active-low
								c_lds    <= ~ext_byteenable[1];
								dtack_to <= 16'd0;               // arm the watchdog
								vb_lw    <= 1'b0;                // LW-FUSE never claims the chip bus
								vb_second<= 1'b0;
								stage    <= 4'd1;
							// fastchip select: Akiko/RTG and the CPU-side Gayle.
								fc_sel   <= fc_hit;
							end
						end
					4'd1: stage <= 4'd2;
					3'd2: begin
							// when fastchip claims the cycle its data is the answer; for the IDE windows fc_ready is the only completion there is
							chipdout_i <= fc_selack ? fc_dout : chip_dout;
							dtack_to   <= dtack_to + 1'b1;
							// End on DTACK, on fastchip's ready, OR force-complete if
							// the watchdog expired (a cycle that never DTACKs). Either
							// way the bus is raised and the seam re-armed -> no wedge.
							if (~waitm || (fc_selack & fc_ready) || (&dtack_to)) begin
								c_as   <= 1'b1;
								c_rw   <= 1'b1;
								c_uds  <= 1'b1;
								c_lds  <= 1'b1;
								fc_sel <= 1'b0;
								// sticky: timed out with DTACK still not seen.  A
								// fastchip-served cycle is NOT an error, so it must not
								// latch cerr even though gary stayed silent.
								cerr  <= cerr | ((&dtack_to) & waitm & ~fc_selack);
								ready <= 1'b1;
								stage <= 4'd3;
							end
						end
					4'd3: stage <= 4'd0;
					default: ; // VB stages advance in the un-gated block below
				endcase
			end

			// Via-B CPU-port progression runs every negedge, not ph-gated: cp_ramready/cp_write_busy are held levels from the 114 MHz domain
			if (stage == VB_REQ) begin
				vb_to <= vb_to + 1'b1;
				if (~cp_cs) begin
					cp_cs <= 1'b1;               // ARM: payload latched last negedge
				end
				else if (cp_ramready) begin
					if (vb_wr) begin
						cp_cs    <= 1'b0;       // write accepted -> drain wait
						cp_state <= 2'b01;      // (or complete right here when posted)
						if (viab_posted) begin
							complete_p <= 1'b1;
							vb_lw      <= 1'b0;
							vb_second  <= 1'b0;
							stage      <= 4'd0;
						end
						else
							stage    <= VB_DRAIN;
					end
					else begin
						stage    <= VB_CAP;     // read: data captured NEXT clk
					end                          // (cp_cs stays up -- see header)
				end
				else if (&vb_to) begin
					// port dead: force-complete with sticky cerr, exactly like a DTACK timeout
					cp_cs      <= 1'b0;
					cp_state   <= 2'b01;
					cerr       <= 1'b1;
					complete_p <= 1'b1;
					stage      <= 4'd0;
				end
			end
			else if (stage == VB_CAP) begin
				// one negedge after ramready: cp_rdata is now stable across the
				// whole multicycle window -- capture and release the port.
				cp_cs      <= 1'b0;
				if (vb_lw && ~vb_second) begin
							// LW-FUSE first half: the m68k longword is (A << 16) | (A+2),
							// so this pass carries the HIGH word.
					ext_readdata_hi <= cp_rdata;
					cp_addr    <= cp_addr + 24'd1;   // A+2 (cp_addr is a WORD address)
					vb_second  <= 1'b1;
					vb_to      <= 16'd0;             // re-arm the watchdog for half 2
					stage      <= VB_LW2;
				end
				else begin
					cp_state   <= 2'b01;             // release the port for real
					chipdout_i <= cp_rdata;
					// LW-FUSE reported ONLY here, and only if both halves actually ran.
					// Every force-completion path leaves it 0, so a watchdog
					// give-up can never tell seam_engine it already has the high word.
					complete_p  <= 1'b1;
					ext_lw_done <= vb_lw & vb_second;
					vb_lw       <= 1'b0;
					vb_second   <= 1'b0;
					stage       <= 4'd0;
				end
			end
			else if (stage == VB_LW2) begin
							// ⚠ cp_state STAYS at read: the port must stay armed for the
							// second word, or ramready never comes and the access hangs.
				stage <= VB_REQ;
			end
			else if (stage == VB_DRAIN) begin
				// strict ordering: ext_complete only after the write buffer
				// committed to the SDRAM array (write_busy low). Normally 1-2
				// clk114 after accept; bounded by the same watchdog.
				vb_to <= vb_to + 1'b1;
				if (~cp_write_busy) begin
					complete_p <= 1'b1;
					vb_lw      <= 1'b0;
					vb_second  <= 1'b0;
					stage      <= 4'd0;
				end
				else if (&vb_to) begin
					cerr       <= 1'b1;
					complete_p <= 1'b1;
					stage      <= 4'd0;
				end
			end
			// blit pacing countdown, reloaded at each Via-B launch
			if (vb_throttle != 5'd0) vb_throttle <= vb_throttle - 5'd1;

			// Phase-freeze watchdog: a minimig CPU reset freezes ph1/ph2 mid-cycle, and
			// everything above is ph1n-gated, so the cycle would wedge with busy=1 and never
			// latch cerr.  Count free-running clks without a ph1n and force-complete.
			if (ph1n || !((stage == 4'd1) || (stage == 4'd2) || (stage == 4'd0 && busy)))
				ph_idle <= 6'd0;
			else
				ph_idle <= ph_idle + 1'b1;
			if ((&ph_idle) && ((stage == 4'd1) || (stage == 4'd2) || (stage == 4'd0 && busy))) begin
				c_as       <= 1'b1;
				c_rw       <= 1'b1;
				c_uds      <= 1'b1;
				c_lds      <= 1'b1;
				cerr       <= 1'b1;      // sticky, same as a DTACK timeout
				ready      <= 1'b0;
				complete_p <= 1'b1;      // one-clk pulse; consumed on posedge
				stage      <= 4'd3;      // ph1n (post-thaw) returns it to idle
				ph_idle    <= 6'd0;
			end
		end
	end

	// -------------------------------------------------------------------- //
	// busy / done bookkeeping (posedge domain)                            //
	// -------------------------------------------------------------------- //
	always @(posedge clk or negedge reset_n) begin
		if (~reset_n) begin
			busy       <= 1'b0;
			done_latch <= 1'b0;
		end
		else if (soft_rst) begin              // REG_OVL[1] recovery hammer
			busy       <= 1'b0;
			done_latch <= 1'b0;
		end
		else begin
			if (start)            busy <= 1'b1;   // a cycle is now in flight
			else if (complete_p)  busy <= 1'b0;   // it finished

			if (complete_p)       done_latch <= 1'b1; // block re-launch...
			else if (~ext_request) done_latch <= 1'b0; // ...until req drops
		end
	end

	// Outputs: all cycle-payload signals come from the launch-latched copies, so a live
	// cycle cannot follow a later control change.
	assign chip_addr = addr_r;              // word address -> [23:1]
	assign chip_as   = c_as;
	assign chip_rw   = c_rw;
	assign chip_uds  = c_uds;
	assign chip_lds  = c_lds;

	// byte-lane routing by BYTEENABLE, correct by construction for word and byte, both parities.
	wire is_byte = be_r[0] ^ be_r[1];

	// WRITE: word = identity (BE value order already correct after the A9
	// le-wrappers); byte = duplicate onto both lanes -- the asserted UDS/LDS
	// strobe selects which half actually latches, so the duplicate is safe.
	assign chip_din = is_byte ? {wd_r[7:0], wd_r[7:0]}
	                          :  wd_r;
	// (cp_wdata is a DEDICATED launch-latched register with the same
	//  byte-duplication -- see the port declaration for why it must not
	//  share wd_r/chip_din.)

	// READ: word = identity; byte = fold the strobed lane down into [7:0]
	// (even/UDS -> chipdout_i[15:8]; odd/LDS -> chipdout_i[7:0]).
	assign ext_readdata = ~is_byte ? chipdout_i
	                    :  be_r[0] ? {8'h00, chipdout_i[15:8]}   // even / UDS lane
	                               : {8'h00, chipdout_i[7:0]};   // odd  / LDS lane

	assign ext_complete = complete_p;

endmodule
