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

// GPU register block: AXI4-Lite slave on the h2f bridge (0xC2000000)

module bm_gpu_regs #(
    parameter N = 2,
    parameter [7:0] SETUP_II = 8'd132,
    parameter COLOR_SWAP = 0
) (
    // AXI4-Lite, clk_h
    input  wire          clk_h,
    input  wire          resetn_h,
    input  wire [11:0]   awaddr, input wire awvalid, output reg awready,
    input  wire [31:0]   wdata, input wire wvalid, output reg wready,
    output reg           bvalid, input wire bready, output wire [1:0] bresp,
    input  wire [11:0]   araddr, input wire arvalid, output reg arready,
    output reg  [31:0]   rdata, output reg rvalid, input wire rready, output wire [1:0] rresp,
    // GPU side, clk_g
    input  wire          clk_g,
    input  wire          resetn_g,
    output reg           ctrl_enable, output reg ctrl_swap, output reg perf_freeze, output reg perf_clear,
    output reg           ctrl_cswap,
    output reg  [11:0]   fe_set, output reg [11:0] fe_clr,
    output reg           kick, output reg [31:0] sub_dir, output reg [6:0] sub_bands, output reg [31:0] sub_seq,
    output reg           err_clr, output reg l2_inv,
    output reg  [1:0]    arm_claim, input wire [1:0] arm_grant, input wire [7:0] band_idx, input wire band_done,
    output reg  [3:0]    perf_addr, input wire [N*32-1:0] perf_rdata,
    input  wire [31:0]   status, input wire [31:0] err, input wire [31:0] fence_done, input wire [31:0] kick_clocks,
    input  wire [31:0]   l2_hits, input wire [31:0] l2_misses,
    input  wire [N*12*32-1:0] setup_cnt,          // per unit: 12 counters (see the map)
    input  wire [6*32-1:0] disp_cnt                 // submissions, bands u0, bands u1, chunks, links, bytes
);
    assign bresp = 2'b00; assign rresp = 2'b00;
    reg        g_alive; reg [3:0] g_acnt;
    always @(posedge clk_g)
        if (!resetn_g) begin g_alive <= 1'b0; g_acnt <= 4'd0; end
        else if (g_acnt != 4'd15) g_acnt <= g_acnt + 4'd1;
        else g_alive <= 1'b1;
    reg        req_t, busy_h, rd_h, dead_h;
    reg [11:0] a_h; reg [31:0] d_h;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg [2:0]  ack_s;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg [2:0]  alive_s;
    reg        ack_seen;
    reg        ack_t;                                // GPU side
    reg [31:0] rd_g;                                 // GPU side: the read data (stable when ack toggles)
    wire       alive   = alive_s[2];
    wire       ack_now = ack_s[2] ^ ack_seen;
    always @(posedge clk_h) begin
        if (!resetn_h) begin
            awready <= 1'b0; wready <= 1'b0; bvalid <= 1'b0; arready <= 1'b0; rvalid <= 1'b0; rdata <= 32'd0;
            req_t <= 1'b0; busy_h <= 1'b0; ack_s <= 3'b000; alive_s <= 3'b000; ack_seen <= 1'b0; rd_h <= 1'b0; dead_h <= 1'b0;
            a_h <= 12'd0; d_h <= 32'd0;
        end else begin
            ack_s <= {ack_s[1:0], ack_t};
            alive_s <= {alive_s[1:0], g_alive};
            awready <= 1'b0; wready <= 1'b0; arready <= 1'b0;
            if (!busy_h && !bvalid && !rvalid) begin
                if (awvalid && wvalid && !awready) begin
                    awready <= 1'b1; wready <= 1'b1; a_h <= awaddr; d_h <= wdata; rd_h <= 1'b0;
                    busy_h <= 1'b1; dead_h <= !alive; if (alive) req_t <= ~req_t;   // in GPU reset: dropped
                end else if (arvalid && !arready) begin
                    arready <= 1'b1; a_h <= araddr; rd_h <= 1'b1;
                    busy_h <= 1'b1; dead_h <= !alive; if (alive) req_t <= ~req_t;   // in GPU reset: reads 0
                end
            end
            if (busy_h && !dead_h && ack_now) begin
                ack_seen <= ack_s[2]; busy_h <= 1'b0;
                if (rd_h) begin rvalid <= 1'b1; rdata <= rd_g; end
                else bvalid <= 1'b1;
            end else if (busy_h && (dead_h || !alive)) begin
                busy_h <= 1'b0;
                if (rd_h) begin rvalid <= 1'b1; rdata <= 32'd0; end
                else bvalid <= 1'b1;
            end
            if (!alive) begin req_t <= 1'b0; ack_seen <= 1'b0; end         // the GPU side's reset values
            if (bvalid && bready) bvalid <= 1'b0;
            if (rvalid && rready) rvalid <= 1'b0;
        end
    end
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON; -name PRESERVE_REGISTER ON" *)
    reg [2:0]  req_s = 3'b000;
    always @(posedge clk_g) req_s <= {req_s[1:0], req_t};
    reg        req_seen;
    wire       req_now = req_s[2] ^ req_seen;
    localparam G_IDLE = 0, G_WAIT = 1, G_ACK = 2, G_CLAIM = 3, G_EXEC = 4;
    reg [2:0]  gs;
    reg [3:0]  wcnt;
    reg [11:0] ga;                                    // the request's payload, copied when the request is seen
    reg [31:0] dg;
    reg        wg;
    wire [11:0] ix0 = ga - 12'h110, ix1 = ga - 12'h140;
    function [31:0] cnt(input [N*12*32-1:0] v, input integer u, input integer k); cnt = v[(u*12 + k)*32 +: 32]; endfunction
    localparam [0:0]  CSW = (COLOR_SWAP != 0) ? 1'b1 : 1'b0;
    localparam [31:0] CAPS = {8'd64, SETUP_II, 1'b0, CSW, 6'b111111, 4'd1, 4'd0};
    localparam [31:0] VERSION = (COLOR_SWAP != 0) ? 32'h00010001 : 32'h00010000;   // interface 1.1 with CSWAP, else 1.0
    always @(posedge clk_g) begin
        kick <= 1'b0; err_clr <= 1'b0; l2_inv <= 1'b0; perf_clear <= 1'b0; arm_claim <= 2'b00;
        if (!resetn_g) begin
            req_seen <= 1'b0; ack_t <= 1'b0; gs <= G_IDLE; wcnt <= 4'd0; ga <= 12'd0; dg <= 32'd0;
            wg <= 1'b0; rd_g <= 32'd0;
            ctrl_enable <= 1'b0; ctrl_swap <= 1'b1; ctrl_cswap <= 1'b0; perf_freeze <= 1'b0; fe_set <= 12'd0; fe_clr <= 12'd0;
            sub_dir <= 32'd0; sub_bands <= 7'd0; sub_seq <= 32'd0; perf_addr <= 4'd0;
        end else begin
            case (gs)
                G_IDLE: if (!g_alive) req_seen <= req_s[2];
                else if (req_now) begin
                    req_seen <= req_s[2]; ga <= a_h; dg <= d_h; wg <= !rd_h; gs <= G_EXEC;
                end
                G_EXEC: begin
                    if (wg) begin
                        // writes
                        case (ga)
                            12'h00C: begin ctrl_enable <= dg[0]; ctrl_swap <= dg[1]; perf_freeze <= dg[2];
                                           perf_clear <= dg[3]; err_clr <= dg[4]; ctrl_cswap <= CSW & dg[5]; end
                            12'h018: begin fe_set <= dg[11:0]; fe_clr <= dg[27:16]; end
                            12'h020: sub_dir <= dg;
                            12'h024: sub_bands <= dg[6:0];
                            12'h028: sub_seq <= dg;
                            12'h02C: kick <= ctrl_enable;
                            12'h038: l2_inv <= dg[0];
                            default: ;
                        endcase
                        gs <= G_ACK;
                    end else begin
                        // reads that need a few clocks: the performance counters, the ARM band claims
                        if (ga >= 12'h080 && ga < 12'h100) begin perf_addr <= ga[5:2]; wcnt <= 4'd3; gs <= G_WAIT; end
                        else if (ga == 12'h040 || ga == 12'h044) begin arm_claim[ga[2]] <= 1'b1; wcnt <= 4'd15; gs <= G_CLAIM; end
                        else begin
                            case (ga)
                                12'h000: rd_g <= 32'h42475055;                 // "BGPU"
                                12'h004: rd_g <= VERSION;
                                12'h008: rd_g <= CAPS | {28'd0, N[3:0]};
                                12'h00C: rd_g <= {26'd0, ctrl_cswap, 2'b00, perf_freeze, ctrl_swap, ctrl_enable};
                                12'h010: rd_g <= status;
                                12'h014: rd_g <= err;
                                12'h018: rd_g <= {4'd0, fe_clr, 4'd0, fe_set};
                                12'h020: rd_g <= sub_dir;
                                12'h024: rd_g <= {25'd0, sub_bands};
                                12'h028: rd_g <= sub_seq;
                                12'h02C: rd_g <= sub_seq;
                                12'h030: rd_g <= fence_done;
                                12'h034: rd_g <= kick_clocks;
                                12'h100: rd_g <= l2_hits;
                                12'h104: rd_g <= l2_misses;
                                12'h180: rd_g <= disp_cnt[0*32 +: 32];
                                12'h184: rd_g <= disp_cnt[1*32 +: 32];
                                12'h188: rd_g <= disp_cnt[2*32 +: 32];
                                12'h18C: rd_g <= disp_cnt[3*32 +: 32];
                                12'h190: rd_g <= disp_cnt[4*32 +: 32];
                                12'h194: rd_g <= disp_cnt[5*32 +: 32];
                                default: begin
                                    if (ga >= 12'h110 && ga < 12'h140) rd_g <= cnt(setup_cnt, 0, {28'd0, ix0[5:2]});
                                    else if (ga >= 12'h140 && ga < 12'h170 && N > 1) rd_g <= cnt(setup_cnt, 1, {28'd0, ix1[5:2]});
                                    else rd_g <= 32'd0;
                                end
                            endcase
                            gs <= G_ACK;
                        end
                    end
                end
                G_WAIT: begin
                    if (wcnt == 4'd0) begin rd_g <= ga[6] ? ((N > 1) ? perf_rdata[N*32-1 -: 32] : 32'd0) : perf_rdata[31:0]; gs <= G_ACK; end
                    else wcnt <= wcnt - 4'd1;
                end
                G_CLAIM: begin
                    if (arm_grant[ga[2]]) begin rd_g <= {band_done, 1'b1, 22'd0, band_idx}; gs <= G_ACK; end
                    else if (wcnt == 4'd0) begin rd_g <= 32'd0; gs <= G_ACK; end        // not granted: try again
                    else begin
                        wcnt <= wcnt - 4'd1;
                        if (!arm_claim[ga[2]]) arm_claim[ga[2]] <= 1'b1;
                    end
                end
                G_ACK: begin ack_t <= ~ack_t; gs <= G_IDLE; end
                default: gs <= G_IDLE;
            endcase
        end
    end
endmodule
