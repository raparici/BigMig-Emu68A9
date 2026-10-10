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

// AXI read path whose returning data is never refused (read credits)

module bm_axi_rd_credit #(
    parameter ID_WIDTH = 8,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 64,
`ifdef BM_RD_CREDIT_LG
    parameter DEPTH_LG = `BM_RD_CREDIT_LG
`else
    parameter DEPTH_LG = 6                  // 64 beats: 8 of the DMA's 64-byte bursts in flight
`endif
) (
    input  wire                         clk,
    input  wire                         resetn,
    // from the requester
    input  wire [ID_WIDTH - 1 : 0]      s_arid,
    input  wire [ADDR_WIDTH - 1 : 0]    s_araddr,
    input  wire [7 : 0]                 s_arlen,
    input  wire [2 : 0]                 s_arsize,
    input  wire [1 : 0]                 s_arburst,
    input  wire                         s_arlock,
    input  wire [3 : 0]                 s_arcache,
    input  wire [2 : 0]                 s_arprot,
    input  wire                         s_arvalid,
    output wire                         s_arready,
    output wire [ID_WIDTH - 1 : 0]      s_rid,
    output wire [DATA_WIDTH - 1 : 0]    s_rdata,
    output wire [1 : 0]                 s_rresp,
    output wire                         s_rlast,
    output wire                         s_rvalid,
    input  wire                         s_rready,
    // to the shared read path
    output wire [ID_WIDTH - 1 : 0]      m_arid,
    output wire [ADDR_WIDTH - 1 : 0]    m_araddr,
    output wire [7 : 0]                 m_arlen,
    output wire [2 : 0]                 m_arsize,
    output wire [1 : 0]                 m_arburst,
    output wire                         m_arlock,
    output wire [3 : 0]                 m_arcache,
    output wire [2 : 0]                 m_arprot,
    output wire                         m_arvalid,
    input  wire                         m_arready,
    input  wire [ID_WIDTH - 1 : 0]      m_rid,
    input  wire [DATA_WIDTH - 1 : 0]    m_rdata,
    input  wire [1 : 0]                 m_rresp,
    input  wire                         m_rlast,
    input  wire                         m_rvalid,
    output wire                         m_rready
);
    localparam DEPTH = 1 << DEPTH_LG;
    localparam W = ID_WIDTH + DATA_WIDTH + 2 + 1;
    reg  [DEPTH_LG : 0]     resv;
    wire [8 : 0]            need = {1'b0, s_arlen} + 9'd1;
    wire [9 : 0]            after = {{(9 - DEPTH_LG){1'b0}}, resv} + {1'b0, need};
    wire                    room = (after <= DEPTH);
    assign m_arvalid = s_arvalid && room;               // room only grows while an address waits: AXI-stable
    assign s_arready = m_arready && room;
    assign m_arid = s_arid; assign m_araddr = s_araddr; assign m_arlen = s_arlen; assign m_arsize = s_arsize;
    assign m_arburst = s_arburst; assign m_arlock = s_arlock; assign m_arcache = s_arcache; assign m_arprot = s_arprot;
    (* ramstyle = "MLAB, no_rw_check" *) reg [W - 1 : 0] mem [0 : DEPTH - 1];
    reg  [DEPTH_LG : 0]     wp, rp;
    wire                    push = m_rvalid;
    wire                    pop = s_rvalid && s_rready;
    wire [W - 1 : 0]        head = mem[rp[DEPTH_LG - 1 : 0]];
    assign m_rready = 1'b1;
    assign s_rvalid = (wp != rp);
    assign {s_rid, s_rdata, s_rresp, s_rlast} = head;
    always @(posedge clk) if (push) mem[wp[DEPTH_LG - 1 : 0]] <= {m_rid, m_rdata, m_rresp, m_rlast};
    wire [DEPTH_LG : 0]     take = (s_arvalid && s_arready) ? need[DEPTH_LG : 0] : {(DEPTH_LG + 1){1'b0}};
    always @(posedge clk)
        if (!resetn) begin
            wp <= {(DEPTH_LG + 1){1'b0}}; rp <= {(DEPTH_LG + 1){1'b0}}; resv <= {(DEPTH_LG + 1){1'b0}};
        end else begin
            if (push) wp <= wp + 1'b1;
            if (pop) rp <= rp + 1'b1;
            resv <= resv + take - (pop ? {{DEPTH_LG{1'b0}}, 1'b1} : {(DEPTH_LG + 1){1'b0}});
        end
endmodule
