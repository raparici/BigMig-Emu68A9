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

// 1-deep write-posting buffer on the chip bus: re-presents a CPU write until sdram_ctrl
// samples it, because gary's combinational dbr mux can steal the slot after DTACK.
// Agnus DMA always passes with priority.  bypass=1 makes it a wire.

module chip_write_retry (
    input             clk114,     // == sdram_ctrl sysclk (clk_114)
    input             c_7m,       // == c1; sdram_state resets on its rising edge
    input             reset_n,
    input             bypass,     // 1 => transparent (baseline)
    input             dbr,        // Agnus owns this chip cycle (from gary)

    // from minimig_sram_bridge (chip bus, active-low strobes)
    input      [23:1] in_addr,
    input      [15:0] in_data,
    input             in_we,      // _ram_we  : 0 = write
    input             in_oe,      // _ram_oe  : 0 = read / DMA fetch
    input             in_bhe,     // _ram_bhe : 0 = upper byte
    input             in_ble,     // _ram_ble : 0 = lower byte

    // to sdram_ctrl CHIP port
    output reg [23:1] out_addr,
    output reg [15:0] out_data,
    output reg        out_we,
    output reg        out_oe,
    output reg        out_bhe,
    output reg        out_ble
);
    // replicate sdram_ctrl's state counter so we know when the RAS sample (0) is
    reg [3:0] st;
    reg       old7;
    always @(posedge clk114 or negedge reset_n) begin
        if (~reset_n) begin st<=0; old7<=0; end
        else begin
            old7 <= c_7m;
            st   <= st + 4'd1;
            if (~old7 & c_7m) st <= 4'd0;
        end
    end

    reg [23:1] buf_addr;
    reg [15:0] buf_data;
    reg        buf_bhe, buf_ble;
    reg        buf_pend;
    reg        cyc_done;   // this CPU-write cycle already committed once

    wire agnus_slot = dbr;                          // Agnus owns the chip bus
    wire cpu_write  = ~dbr & (in_we == 1'b0);       // a CPU chip write is present
    wire cpu_access = ~dbr & ((in_we==1'b0)|(in_oe==1'b0)); // CPU read or write live

    // ---- combinational output mux ----
    always @(*) begin
        if (bypass || agnus_slot || cpu_access) begin
            // Agnus (priority) OR a live CPU access -> pass straight through
            out_addr=in_addr; out_data=in_data; out_we=in_we; out_oe=in_oe;
            out_bhe=in_bhe;   out_ble=in_ble;
        end else if (buf_pend) begin                // idle CPU slot + pending -> inject
            out_addr=buf_addr; out_data=buf_data; out_we=1'b0; out_oe=1'b1;
            out_bhe=buf_bhe;   out_ble=buf_ble;
        end else begin                              // idle
            out_addr=in_addr; out_data=in_data; out_we=1'b1; out_oe=1'b1;
            out_bhe=1'b1;      out_ble=1'b1;
        end
    end

    // ---- capture / retire ----
    always @(posedge clk114 or negedge reset_n) begin
        if (~reset_n) begin
            buf_pend<=0; cyc_done<=0; buf_addr<=0; buf_data<=0; buf_bhe<=1; buf_ble<=1;
        end else begin
            // arm for a new write cycle once no CPU write is present
            if (~cpu_write) cyc_done <= 1'b0;

            // capture the live CPU write once per cycle
            if (cpu_write && !cyc_done && !buf_pend) begin
                buf_addr<=in_addr; buf_data<=in_data; buf_bhe<=in_bhe; buf_ble<=in_ble;
                buf_pend<=1'b1;
            end

            // a CPU write is sampled by sdram_ctrl at st==0 when out shows a write
            // and Agnus is not overriding it -> retire the buffer.
            if (st==4'd0 && ~agnus_slot && out_we==1'b0 && out_oe==1'b1) begin
                buf_pend <= 1'b0;
                cyc_done <= 1'b1;
            end
        end
    end
endmodule
