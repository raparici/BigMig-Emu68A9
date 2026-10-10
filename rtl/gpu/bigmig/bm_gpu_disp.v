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

// GPU list DMA control

module bm_gpu_disp #(
    parameter N = 2,
    parameter LEAN = 0
) (
    input  wire              clk,
    input  wire              resetn,
    input  wire              swap_en,
    // the register block
    input  wire              kick,                    // DOORBELL (one clock), with:
    input  wire [31:0]       dir_addr,
    input  wire [6:0]        nbands,
    input  wire [31:0]       seq,
    output reg               active,                  // a submission is in progress
    output reg  [31:0]       fence_done,
    output reg  [7:0]        err,
    input  wire              err_clr,
    // the band counter's ARM claimers (the register block's CLAIM0/1 reads)
    input  wire [1:0]        arm_claim,
    output wire [1:0]        arm_grant,
    output wire [7:0]        band_idx,
    output wire              band_done,
    // per unit: RasterIX_IF's DMA command input
    output reg  [N-1:0]      c_tvalid, input wire [N-1:0] c_tready, output reg [N*32-1:0] c_tdata,
    // unit 0's DMA response stream (the directory)
    input  wire              r_tvalid, output wire r_tready, input wire [31:0] r_tdata,
    // per unit: framer descriptors
    output reg  [N-1:0]      f_push, output reg [N*4-1:0] f_head, output reg [N*26-1:0] f_len, output reg [N*4-1:0] f_tail,
    input  wire [N-1:0]      f_full, input wire [N-1:0] f_busy,
    // per unit: chunk events from the setup units
    input  wire [N-1:0]      chunk_done, input wire [N-1:0] chunk_link,
    input  wire [N*32-1:0]   link_addr, input wire [N*28-1:0] link_bytes,
    // per unit: drained?
    input  wire [N-1:0]      setup_pending, input wire [N-1:0] perf_busy, input wire [N-1:0] wr_pending,
    // counters
    output reg  [31:0]       cnt_sub, cnt_bands0, cnt_bands1, cnt_chunks, cnt_links, cnt_bytes, cnt_kick_clocks
);
    localparam LGN = (N > 1) ? $clog2(N) : 1;
    localparam integer NM1I = N - 1;
    localparam [LGN-1:0] NM1 = NM1I[LGN-1:0];
    (* ramstyle = "MLAB, no_rw_check" *) reg [63:0] dir [0:63];
    reg         dwe; reg [5:0] dwa; reg [63:0] dwd; reg [31:0] dlo;
    reg  [5:0]  dra; reg [63:0] drq;
    always @(posedge clk) begin
        if (dwe) dir[dwa] <= dwd;
        drq <= dir[dra];
    end
    localparam D_IDLE = 0, D_CMD = 1, D_ADDR = 2, D_RECV = 3, D_GO = 4;
    reg  [2:0]  ds;
    reg  [6:0]  nb;
    reg  [31:0] sq;
    reg  [31:0] da;                                   // the directory's address
    reg  [3:0]  dhead;                                // words before the directory in its aligned span
    reg  [8:0]  dtot;                                 // words in the span
    reg  [8:0]  dcnt;
    reg         dir_ready, bprog;
    reg  [31:0] kick_clk;
    reg  [LGN-1:0] dturn;
    wire [8:0]  drel = dcnt - {5'd0, dhead};
    wire [31:0] rsw = swap_en ? {r_tdata[7:0], r_tdata[15:8], r_tdata[23:16], r_tdata[31:24]} : r_tdata;
    assign r_tready = 1'b1;
    wire [31:0] dspan_lo = {da[31:6], 6'd0};
    wire [31:0] dspan_hi = da + {22'd0, nb, 3'd0} + 32'd63;
    wire [31:0] dbytes   = {dspan_hi[31:6], 6'd0} - dspan_lo;
    wire [N+1:0] grants;
    reg  [N-1:0] u_claim;
    bm_band_ctr #(.N(N + 2), .W(8)) bands (.aclk(clk), .resetn(resetn), .prog_we(bprog), .prog_count({1'b0, nb}),
        .claim({arm_claim, u_claim}), .grant(grants), .band(band_idx), .done(band_done));
    assign arm_grant = grants[N+1:N];
    localparam U_IDLE = 0, U_CLAIM = 1, U_WAITG = 2, U_DIR = 3, U_DIR1 = 4, U_DIR2 = 5, U_HDR = 6, U_ADR = 7, U_ADR2 = 8,
               U_WAIT = 9, U_FIN = 10;
    reg  [3:0]  us [0:N-1];
    reg  [31:0] ca [0:N-1];                           // the chunk's address
    reg  [27:0] cb [0:N-1];                           // its length in bytes
    reg  [7:0]  ub [0:N-1];                           // the band
    wire [31:0] lo   [0:N-1];
    wire [31:0] hi   [0:N-1];
    wire [31:0] span [0:N-1];                         // the aligned span's bytes
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : sp
        assign lo[g] = {ca[g][31:6], 6'd0};
        assign hi[g] = ca[g] + {4'd0, cb[g]} + 32'd63;
        assign span[g] = {hi[g][31:6], 6'd0} - lo[g];
    end endgenerate
    integer u;
    reg [N-1:0] drained;
    always @(*) for (u = 0; u < N; u = u + 1)
        drained[u] = (us[u] == U_FIN) && !setup_pending[u] && !perf_busy[u] && !wr_pending[u] && !f_busy[u];
    always @(posedge clk) begin
        f_push <= {N{1'b0}}; bprog <= 1'b0; dwe <= 1'b0;
        if (!resetn) begin
            ds <= D_IDLE; active <= 1'b0; dir_ready <= 1'b0; fence_done <= 32'd0; err <= 8'd0;
            c_tvalid <= {N{1'b0}}; u_claim <= {N{1'b0}}; dturn <= {LGN{1'b0}}; nb <= 7'd0;
            for (u = 0; u < N; u = u + 1) us[u] <= U_IDLE;
            cnt_sub <= 0; cnt_bands0 <= 0; cnt_bands1 <= 0; cnt_chunks <= 0; cnt_links <= 0; cnt_bytes <= 0;
            cnt_kick_clocks <= 0; kick_clk <= 0;
        end else begin
            if (err_clr) err <= 8'd0;
            if (active) kick_clk <= kick_clk + 32'd1;
            dturn <= (dturn == NM1) ? {LGN{1'b0}} : dturn + 1'b1;
            // ---- the doorbell and the directory
            if (kick && active) err[1] <= 1'b1;                     // ignored: the submission in progress continues
            case (ds)
                D_IDLE: if (kick && !active) begin
                    if (nbands == 7'd0 || nbands > 7'd64 || dir_addr[2:0] != 3'd0) err[0] <= 1'b1;
                    else begin
                        nb <= nbands; sq <= seq; da <= dir_addr; active <= 1'b1; dir_ready <= 1'b0; kick_clk <= 32'd0;
                        bprog <= 1'b1; cnt_sub <= cnt_sub + 32'd1; ds <= D_CMD;
                    end
                end
                D_CMD: begin
                    // unit 0's DMA: memory -> ST0 (the response stream)
                    dhead <= da[5:2]; dtot <= dbytes[10:2]; dcnt <= 9'd0;
                    c_tvalid[0] <= 1'b1; c_tdata[31:0] <= {2'b01, 2'b11, dbytes[27:0]};
                    if (c_tvalid[0] && c_tready[0]) begin c_tdata[31:0] <= dspan_lo; ds <= D_ADDR; end
                end
                D_ADDR: if (c_tready[0]) begin c_tvalid[0] <= 1'b0; ds <= D_RECV; end
                D_RECV: if (r_tvalid) begin
                    if (dcnt >= {5'd0, dhead} && dcnt < {5'd0, dhead} + {1'b0, nb, 1'b0}) begin
                        if (!drel[0]) dlo <= rsw;
                        else begin dwe <= 1'b1; dwa <= drel[6:1]; dwd <= {rsw, dlo}; end
                    end
                    dcnt <= dcnt + 9'd1;
                    if (dcnt + 9'd1 == dtot) ds <= D_GO;
                end
                D_GO: begin dir_ready <= 1'b1; ds <= D_IDLE; end   // the last entry is written in this clock
                default: ds <= D_IDLE;
            endcase
            // ---- per unit
            for (u = 0; u < N; u = u + 1) begin
                case (us[u])
                    U_IDLE: if (active && dir_ready) us[u] <= U_CLAIM;
                    U_CLAIM: begin u_claim[u] <= 1'b1; us[u] <= U_WAITG; end
                    U_WAITG: begin
                        // one claim outstanding at a time: re-claim only after a clock without a grant
                        u_claim[u] <= 1'b0;
                        if (grants[u]) begin
                            if (band_done) us[u] <= U_FIN;
                            else begin ub[u] <= band_idx; us[u] <= U_DIR; end
                        end else if (!u_claim[u]) u_claim[u] <= 1'b1;
                    end
                    U_DIR: if (dturn == u[LGN-1:0]) begin dra <= ub[u][5:0]; us[u] <= U_DIR1; end
                    U_DIR1: us[u] <= U_DIR2;
                    U_DIR2: begin
                        ca[u] <= drq[31:0]; cb[u] <= drq[59:32];
                        if (drq[59:32] == 28'd0) us[u] <= U_CLAIM;                                   // an empty band
                        else if (drq[1:0] != 2'd0 || drq[33:32] != 2'd0) begin err[2] <= 1'b1; us[u] <= U_CLAIM; end
                        else us[u] <= U_HDR;
                    end
                    U_HDR: if (!f_full[u] && !c_tvalid[u]) begin
                        // the framer: words before / of / after the chunk in its 64-byte aligned span
                        f_push[u] <= 1'b1;
                        f_head[u*4 +: 4] <= ca[u][5:2];
                        f_len[u*26 +: 26] <= cb[u][27:2];
                        f_tail[u*4 +: 4] <= 4'd0 - ca[u][5:2] - cb[u][5:2];
                        // the DMA: memory -> ST1 (the command parser), the aligned span
                        c_tvalid[u] <= 1'b1;
                        c_tdata[u*32 +: 32] <= {2'b10, 2'b11, span[u][27:0]};
                        cnt_chunks <= cnt_chunks + 32'd1; if (!LEAN) cnt_bytes <= cnt_bytes + {4'd0, cb[u]};
                        us[u] <= U_ADR;
                    end
                    U_ADR: if (c_tready[u]) begin c_tdata[u*32 +: 32] <= lo[u]; us[u] <= U_ADR2; end  // the header went
                    U_ADR2: if (c_tready[u]) begin c_tvalid[u] <= 1'b0; us[u] <= U_WAIT; end          // the address went
                    U_WAIT: if (chunk_done[u]) begin
                        if (chunk_link[u] && link_bytes[u*28 +: 28] != 28'd0) begin
                            ca[u] <= link_addr[u*32 +: 32]; cb[u] <= link_bytes[u*28 +: 28]; cnt_links <= cnt_links + 32'd1;
                            if (link_addr[u*32 +: 2] != 2'd0 || link_bytes[u*28 +: 2] != 2'd0) begin err[2] <= 1'b1; us[u] <= U_CLAIM; end
                            else us[u] <= U_HDR;
                        end else begin
                            if (u == 0) cnt_bands0 <= cnt_bands0 + 32'd1; else cnt_bands1 <= cnt_bands1 + 32'd1;
                            us[u] <= U_CLAIM;
                        end
                    end
                    U_FIN: ;
                    default: us[u] <= U_IDLE;
                endcase
            end
            // ---- the fence: every unit has run out of bands and is drained
            if (active && dir_ready && (&drained)) begin
                fence_done <= sq; active <= 1'b0; dir_ready <= 1'b0; cnt_kick_clocks <= kick_clk;
                for (u = 0; u < N; u = u + 1) us[u] <= U_IDLE;
            end
        end
    end
endmodule
