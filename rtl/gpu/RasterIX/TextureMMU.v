// RasterIX
// https://github.com/ToNi3141/RasterIX
// Copyright (c) 2026 ToNi3141

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

module TextureMMU #(
    parameter TEX_ADDR_WIDTH = 18,

    parameter PAGE_SIZE = 2048,

    parameter ID_WIDTH = 4,
    parameter ADDR_WIDTH = 32,

    parameter REGISTERED_LOOKUP = 1
)
(
    input  wire                             aclk,
    input  wire                             resetn,

    // Pagetable interface
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,
    input  wire [ADDR_WIDTH - 1 : 0]        s_axis_tdata,

    // Input interface
    input  wire [TEX_ADDR_WIDTH - 1 : 0]    s_axi_araddr,
    input  wire [ID_WIDTH - 1 : 0]          s_axi_arid,
    input  wire [ 7 : 0]                    s_axi_arlen,
    input  wire [ 2 : 0]                    s_axi_arsize,
    input  wire [ 1 : 0]                    s_axi_arburst,
    input  wire                             s_axi_arlock,
    input  wire [ 3 : 0]                    s_axi_arcache,
    input  wire [ 2 : 0]                    s_axi_arprot,
    input  wire                             s_axi_arvalid,
    output wire                             s_axi_arready,

    // Output interface
    output wire [ID_WIDTH - 1 : 0]          m_axi_arid,
    output wire [ADDR_WIDTH - 1 : 0]        m_axi_araddr,
    output wire [ 7 : 0]                    m_axi_arlen,
    output wire [ 2 : 0]                    m_axi_arsize,
    output wire [ 1 : 0]                    m_axi_arburst,
    output wire                             m_axi_arlock,
    output wire [ 3 : 0]                    m_axi_arcache,
    output wire [ 2 : 0]                    m_axi_arprot,
    output wire                             m_axi_arvalid,
    input  wire                             m_axi_arready
);
    localparam PAGE_ENTRIES_LG = TEX_ADDR_WIDTH - $clog2(PAGE_SIZE);
    localparam OFFSET_WIDTH = TEX_ADDR_WIDTH - PAGE_ENTRIES_LG;

    assign s_axis_tready = 1'b1;

    wire [PAGE_ENTRIES_LG - 1 : 0] lookupIndex = s_axi_araddr[OFFSET_WIDTH +: PAGE_ENTRIES_LG];
    wire [ADDR_WIDTH - 1 : 0] pageOffset
        = { { (ADDR_WIDTH - OFFSET_WIDTH) { 1'b0 } }, s_axi_araddr[0 +: OFFSET_WIDTH] };

    reg [PAGE_ENTRIES_LG - 1 : 0] pageTableIndex;
    always @(posedge aclk) 
    begin
        if (!resetn) 
        begin
            pageTableIndex <= 0;
        end 
        else 
        begin
            if (s_axis_tvalid)
            begin
                pageTableIndex <= pageTableIndex + 1;
                if (s_axis_tlast)
                begin
                    pageTableIndex <= 0;
                end
            end
        end
    end

    generate
        if (REGISTERED_LOOKUP == 0)
        begin : mlab
            (* ramstyle = "MLAB, no_rw_check" *) reg [ADDR_WIDTH - 1 : 0] pageTable [0 : (1 << PAGE_ENTRIES_LG) - 1];

            assign m_axi_arid = s_axi_arid;
            assign m_axi_araddr = pageTable[lookupIndex] + pageOffset;
            assign m_axi_arlen = s_axi_arlen;
            assign m_axi_arsize = s_axi_arsize;
            assign m_axi_arburst = s_axi_arburst;
            assign m_axi_arlock = s_axi_arlock;
            assign m_axi_arcache = s_axi_arcache;
            assign m_axi_arprot = s_axi_arprot;
            assign m_axi_arvalid = s_axi_arvalid;
            assign s_axi_arready = m_axi_arready;

            always @(posedge aclk) if (resetn && s_axis_tvalid) pageTable[pageTableIndex] <= s_axis_tdata[ADDR_WIDTH - 1 : 0];
        end
        else
        begin : m10k
            (* ramstyle = "M10K, no_rw_check" *) reg [ADDR_WIDTH - 1 : 0] pageTable [0 : (1 << PAGE_ENTRIES_LG) - 1];
            reg  [ADDR_WIDTH - 1 : 0]   pagePhys;           // the RAM's registered read: the accepted request's page
            reg                         arValid;
            reg  [ID_WIDTH - 1 : 0]     arId;
            reg  [OFFSET_WIDTH - 1 : 0] arOffset;
            reg  [ 7 : 0]               arLen;
            reg  [ 2 : 0]               arSize;
            reg  [ 1 : 0]               arBurst;
            reg                         arLock;
            reg  [ 3 : 0]               arCache;
            reg  [ 2 : 0]               arProt;
            // one request in the stage; a new one is taken when the stage is empty or empties this clock
            wire                        take = s_axi_arvalid && (!arValid || m_axi_arready);

            assign s_axi_arready = !arValid || m_axi_arready;
            assign m_axi_arvalid = arValid;
            assign m_axi_arid = arId;
            assign m_axi_araddr = pagePhys + { { (ADDR_WIDTH - OFFSET_WIDTH) { 1'b0 } }, arOffset };
            assign m_axi_arlen = arLen;
            assign m_axi_arsize = arSize;
            assign m_axi_arburst = arBurst;
            assign m_axi_arlock = arLock;
            assign m_axi_arcache = arCache;
            assign m_axi_arprot = arProt;

            always @(posedge aclk)
            begin
                if (resetn && s_axis_tvalid)
                    pageTable[pageTableIndex] <= s_axis_tdata[ADDR_WIDTH - 1 : 0];
                if (take)
                    pagePhys <= pageTable[lookupIndex];
            end

            always @(posedge aclk)
            begin
                if (!resetn)
                begin
                    arValid <= 1'b0;
                end
                else
                begin
                    if (take)
                    begin
                        arValid <= 1'b1;
                        arId <= s_axi_arid;
                        arOffset <= s_axi_araddr[0 +: OFFSET_WIDTH];
                        arLen <= s_axi_arlen;
                        arSize <= s_axi_arsize;
                        arBurst <= s_axi_arburst;
                        arLock <= s_axi_arlock;
                        arCache <= s_axi_arcache;
                        arProt <= s_axi_arprot;
                    end
                    else if (m_axi_arready)
                    begin
                        arValid <= 1'b0;
                    end
                end
            end
        end
    endgenerate
endmodule 
