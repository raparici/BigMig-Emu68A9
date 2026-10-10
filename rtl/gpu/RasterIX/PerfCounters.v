`default_nettype none
module PerfCounters #(
    parameter NUM = 14,               // at most 14 (words 2..15)
    parameter WIDTH = 32,             // counter width, <= 32
    parameter [31 : 0] ID = 32'h47504331,
    parameter [31 : 0] KEEP = 32'hFFFFFFFF
) (
    input  wire                 aclk,
    input  wire                 resetn,
    input  wire                 freeze,
    input  wire                 clear,
    input  wire [NUM - 1 : 0]   events,
    input  wire [7 : 0]         flags,
    input  wire [3 : 0]         addr,
    output reg  [31 : 0]        rdata
);
    reg [WIDTH - 1 : 0] cnt [0 : NUM - 1];
    reg [7 : 0]         sticky;
    integer i;

    always @(posedge aclk)
    begin
        for (i = 0; i < NUM; i = i + 1)
        begin
            if (!resetn || clear || !KEEP[i])
                cnt[i] <= 0;
            else if (!freeze && events[i])
                cnt[i] <= cnt[i] + 1;
        end
        if (!resetn || clear)
            sticky <= 0;
        else
            sticky <= sticky | flags;
    end

    wire [7 : 0] numW = NUM;
    wire [7 : 0] widthW = WIDTH;
    always @(posedge aclk)
    begin
        if (addr == 0)
            rdata <= ID;
        else if (addr == 1)
            rdata <= { widthW, numW, sticky, 7'd0, freeze };
        else if ((addr - 2) < NUM)
            rdata <= cnt[addr - 2];      // zero-extended to 32 bits
        else
            rdata <= 0;
    end
endmodule
`default_nettype wire
