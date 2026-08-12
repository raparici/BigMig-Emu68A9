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

// seam transaction engine: AXI register writes -> one chip cycle, and the REQ/ACK crossing

module seam_engine #(
    // Native longword: one transaction runs TWO back-to-back chip cycles
    // (A then A+2), halving round trips and CDC crossings per longword.
    parameter integer LONGWORD_EN  = 0,
    // Request FIFO depth as log2.  0 => depth 1 => one request in flight, i.e.
    // behaviourally the pre-FIFO engine, so the proven path stays the default.
    parameter integer REQFIFO_LOG2 = 0
)(
    // ---- AXI / h2f clock domain ------------------------------------------
    input             clk,
    input             reset_n,

    input             reg_write,       // 1-clk write strobe
    input      [2:0]  reg_sel,         // 0 = ADDR, 1 = WDATA, 2 = CTRL (trigger)
    input      [31:0] reg_wdata,

    input             soft_rst,        // stretched chipset-reset level: force idle + flush

    output     [15:0] rdata,           // low word  (REG_RESULT[15:0])
    output     [15:0] rdata_hi,        // high word (longword builds)
    output            status_busy,     // 1 = anything outstanding (queued or in flight)
    output            status_full,     // 1 = the FIFO cannot accept another trigger
    output            status_ovf,      // 1 = a trigger WAS refused since reset (sticky)
    output     [7:0]  done_count,      // retired transactions, wraps freely
    // Latency decomposition: sync_clk ticks from the chip domain seeing the request to
    // completion -- the bridge segment, separated from the CDC and the AXI traffic.

    // ---- 28 MHz Amiga chip-bus domain ------------------------------------
    input             sync_clk,
    output     [22:0] chip_address,
    output            chip_read,
    output            chip_write,
    output     [15:0] chip_writedata,
    output     [1:0]  chip_byteenable, // [0]=UDS, [1]=LDS
    output            chip_longword,
    output            chip_request,
    input      [15:0] chip_readdata,
    input             chip_complete,
    // LW-FUSE: the bridge can serve a Via-B longword in one transaction and says so with
    // chip_lw_done; the second request is then skipped.
    input      [15:0] chip_readdata_hi,
    input             chip_lw_done
);

    localparam integer FIFO_DEPTH = (1 << REQFIFO_LOG2);

    // ======================================================================
    //  AXI clock domain
    // ======================================================================
    reg [22:0] stage_addr  = 23'd0;    // written by the firmware, never by the launcher
    reg [31:0] stage_wdata = 32'd0;
    reg [22:0] live_addr   = 23'd0;    // driven by the launcher, read by the chip domain
    reg [31:0] live_wdata  = 32'd0;
    reg [4:0]  live_ctrl   = 5'd0;

    // ⚠ ramstyle="logic" is required: Quartus infers M10K from these arrays as soon as
    // the depth exceeds 1, and the inferred RAM has a read latency the FSM does not expect.
    (* ramstyle = "logic" *) reg [22:0] fifo_addr  [0:FIFO_DEPTH-1];
    (* ramstyle = "logic" *) reg [31:0] fifo_wdata [0:FIFO_DEPTH-1];
    (* ramstyle = "logic" *) reg [4:0]  fifo_ctrl  [0:FIFO_DEPTH-1];
    reg [REQFIFO_LOG2:0] fifo_count = 0;              // 0..FIFO_DEPTH, needs the extra bit
    reg [REQFIFO_LOG2:0] fifo_wptr  = 0;
    reg [REQFIFO_LOG2:0] fifo_rptr  = 0;

    reg        inflight  = 1'b0;
    reg [15:0] rdata_axi = 16'd0;
    reg [15:0] rdhi_axi  = 16'd0;
    reg [7:0]  done_cnt  = 8'd0;
    reg        ovf_stick = 1'b0;

    // Declared here because the AXI block below reads them: Verilog does not care
    // about module-scope order, but some linters and readers do.
    reg [15:0] readdata_sync    = 16'd0;
    reg [15:0] readdata_hi_sync = 16'd0;
    reg        done_tgl_sync    = 1'b0;

    reg  req_tgl = 1'b0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg [2:0] done_sync = 3'b000;

    wire full  = (fifo_count == FIFO_DEPTH);
    wire empty = (fifo_count == 0);
    wire done_edge = done_sync[2] ^ done_sync[1];

            // A push and a completion can land in the same clock, so fifo_count is updated
            // once from both terms -- two separate branches would drop one.
    wire push_ok = reg_write && (reg_sel == 3'd2) && !full && !soft_rst;
    wire retire  = done_edge && !empty;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            stage_addr <= 23'd0; stage_wdata <= 32'd0;
            live_addr  <= 23'd0; live_wdata  <= 32'd0; live_ctrl <= 5'd0;
            fifo_count <= 0; fifo_wptr <= 0; fifo_rptr <= 0;
            inflight   <= 1'b0;
            rdata_axi  <= 16'd0; rdhi_axi <= 16'd0;
            done_cnt   <= 8'd0;  ovf_stick <= 1'b0;
            req_tgl    <= 1'b0;  done_sync <= 3'b000;
        end else begin
            done_sync <= {done_sync[1:0], done_tgl_sync};

            // ---- register writes from the AXI decoder -----------------------
            if (reg_write) begin
                case (reg_sel)
                    3'd0: stage_addr  <= reg_wdata[22:0];
                    3'd1: stage_wdata <= reg_wdata;          // 32-bit for longword
                    3'd2: begin
            // REG_CTRL is the TRIGGER.  A refused trigger sets the sticky overflow flag
            // instead of vanishing.
                        if (!full && !soft_rst) begin
                            fifo_addr [(fifo_wptr & (FIFO_DEPTH-1))] <= stage_addr;
                            fifo_wdata[(fifo_wptr & (FIFO_DEPTH-1))] <= stage_wdata;
                            fifo_ctrl [(fifo_wptr & (FIFO_DEPTH-1))] <= reg_wdata[4:0];
                            fifo_wptr  <= fifo_wptr + 1'b1;
                        end else if (!soft_rst) begin
                            // A DROPPED CHIP CYCLE.  Never silent again.
                            ovf_stick <= 1'b1;
                        end
                    end
                    default: ;
                endcase
            end

            // ---- launcher ---------------------------------------------------
            // After the register block, so a push and a launch in the same clock
            // read as push-then-launch.  Does NOT decrement on launch: only the
            // completion retires an entry, which is what makes fifo_count mean
            // "anything outstanding".
            //
            // ★ DIRECT LAUNCH (B-18).  On an IDLE engine the trigger must reach the chip
            // domain in the SAME clock as the REG_CTRL write, exactly as the pre-FIFO engine
            // did -- it flipped req_tgl right there in the register block.  Going through the
            // queue first cost one AXI clock on every access, and that clock is not free:
            // chip RAM is reached through sdram_ctrl's CPU port, which is slot-arbitrated
            // against Agnus, so arriving one clock late can miss the slot and wait for the
            // next one.  MEASURED, and the fingerprint is unmistakable: chip-RAM reads cost
            // +190 CPU cycles against the old engine while CUSTOM-register reads -- same
            // engine, same path, but NOT through sdram_ctrl -- are identical (689 vs 687).
            // The queue keeps its behaviour for every other case; this only removes a stage
            // that exists for no one when there is nothing outstanding.
            if (push_ok && !inflight && empty && !soft_rst) begin
                live_addr  <= stage_addr;            // straight from the staging registers:
                live_wdata <= stage_wdata;           // the queue entry being written this
                live_ctrl  <= reg_wdata[4:0];        // same clock is not readable yet
                req_tgl    <= ~req_tgl;
                inflight   <= 1'b1;
            end
            else if (!inflight && !empty && !soft_rst) begin
                live_addr  <= fifo_addr [(fifo_rptr & (FIFO_DEPTH-1))];
                live_wdata <= fifo_wdata[(fifo_rptr & (FIFO_DEPTH-1))];
                live_ctrl  <= fifo_ctrl [(fifo_rptr & (FIFO_DEPTH-1))];
                req_tgl    <= ~req_tgl;
                inflight   <= 1'b1;
            end

            // ---- completion from the chip domain ---------------------------
            if (done_edge) begin
                rdata_axi <= readdata_sync;
                rdhi_axi  <= readdata_hi_sync;
                inflight  <= 1'b0;
                done_cnt  <= done_cnt + 8'd1;
                if (!empty) begin
                    fifo_rptr  <= fifo_rptr + 1'b1;
                end
            end

            // ---- the ONE place fifo_count moves ------------------------------
            // Both events in a single expression: push+retire in the same clock is a no-op on
            // the count, which is correct, instead of one of them being lost.
            if (push_ok != retire)
                fifo_count <= push_ok ? (fifo_count + 1'b1) : (fifo_count - 1'b1);

            // ---- soft reset: force idle AND flush the queue ------------------
            // Last, so it wins over any trigger or completion in the same clock.
            if (soft_rst) begin
                inflight   <= 1'b0;
                fifo_count <= 0;
                fifo_wptr  <= 0;
                fifo_rptr  <= 0;
            end
        end
    end

    assign rdata          = rdata_axi;
    assign rdata_hi       = rdhi_axi;
    assign status_busy    = !empty;      // queued OR in flight -- see the launcher note
    assign status_full    = full;
    assign status_ovf     = ovf_stick;
    assign done_count     = done_cnt;

    // ======================================================================
    //  28 MHz Amiga chip-bus domain
    // ======================================================================
    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_GAP = 2'd2, S_REQ2 = 2'd3;

    reg [1:0]  sstate = S_IDLE;
    reg        hreq   = 1'b0;
    reg        word_sel = 1'b0;                 // 0 = word at A, 1 = word at A+2
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg [2:0] req_sync  = 3'b000;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg [2:0] srst_sync = 3'b000;

    wire start_pulse = req_sync[2] ^ req_sync[1];

    always @(posedge sync_clk or negedge reset_n) begin
        if (!reset_n) begin
            req_sync <= 3'b000; srst_sync <= 3'b000;
            sstate   <= S_IDLE; hreq <= 1'b0; word_sel <= 1'b0;
            readdata_sync <= 16'd0; readdata_hi_sync <= 16'd0;
            done_tgl_sync <= 1'b0;
        end else begin
            req_sync  <= {req_sync[1:0],  req_tgl};
            // The soft reset is synchronised here but req_sync KEEPS SHIFTING, so a
            // request edge that arrived and was not launched is CONSUMED (flushed)
            // rather than relaunching a stale cycle the instant the reset ends.
            srst_sync <= {srst_sync[1:0], soft_rst};

            if (srst_sync[2]) begin
                sstate   <= S_IDLE;
                hreq     <= 1'b0;
                word_sel <= 1'b0;
            end else begin
                case (sstate)
                    S_IDLE: begin
                        hreq     <= 1'b0;
                        word_sel <= 1'b0;
                        if (start_pulse) begin
                            hreq    <= 1'b1;
                            sstate  <= S_REQ;
                        end
                    end

                    S_REQ: begin                       // word at A
                        hreq    <= 1'b1;
                        if (chip_complete) begin
            // LW-FUSE: if the bridge served the whole longword, skip the second request.
                            if ((LONGWORD_EN == 1) && live_ctrl[4] && !chip_lw_done) begin
                                readdata_hi_sync <= chip_readdata;   // A holds the HIGH word
                                hreq             <= 1'b0;            // drop so the bridge re-arms
                                word_sel         <= 1'b1;
                                sstate           <= S_GAP;
                            end else begin
                                readdata_sync <= chip_readdata;
                                if (chip_lw_done) readdata_hi_sync <= chip_readdata_hi;
                                done_tgl_sync <= ~done_tgl_sync;
                                hreq          <= 1'b0;
                                sstate        <= S_IDLE;
                            end
                        end
                    end

                    S_GAP: begin                       // longword only: one-cycle gap so the
                        hreq   <= 1'b0;                //   bridge clears its done latch
                        sstate <= S_REQ2;
                    end

                    S_REQ2: begin                      // longword only: word at A+2
                        hreq <= 1'b1;
                        if (chip_complete) begin
                            readdata_sync <= chip_readdata;          // LOW word
                            done_tgl_sync <= ~done_tgl_sync;         // ack the longword ONCE
                            hreq          <= 1'b0;
                            word_sel      <= 1'b0;
                            sstate        <= S_IDLE;
                        end
                    end

                    default: sstate <= S_IDLE;
                endcase
            end
        end
    end

    // With LONGWORD_EN = 0 the +1 and the word_sel selects fold away to constants,
    // so this is exactly the single-word engine.
    assign chip_address    = ((LONGWORD_EN == 1) && live_ctrl[4] && word_sel)
                             ? (live_addr + 23'd1) : live_addr;
    assign chip_writedata  = ((LONGWORD_EN == 1) && live_ctrl[4] && !word_sel)
                             ? live_wdata[31:16] : live_wdata[15:0];
    assign chip_byteenable = live_ctrl[3:2];
    assign chip_read       = live_ctrl[0];
    assign chip_write      = live_ctrl[1];
    assign chip_longword   = live_ctrl[4];
    assign chip_request    = hreq;

endmodule
