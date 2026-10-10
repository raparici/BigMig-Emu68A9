module RegisterBankDB
#(
    parameter BANK_SIZE = 8,
    parameter CMD_STREAM_WIDTH = 32,
    parameter COMPRESSED = 1,
    parameter BANK_REG_WIDTH = 32,
    parameter INDEX_WIDTH = $clog2(BANK_SIZE)
)
(
    input  wire                             aclk,
    input  wire                             resetn,

    input  wire                             s_axis_tvalid,
    input  wire                             s_axis_tlast,
    input  wire [CMD_STREAM_WIDTH - 1 : 0]  s_axis_tdata,
    input  wire [INDEX_WIDTH - 1 : 0]       s_axis_tuser,

    output wire [(BANK_SIZE * BANK_REG_WIDTH) - 1 : 0] registers,

    output reg                              registers_updated,
    input  wire                             update_acknowledged,

    input  wire                             active_free,
    output wire                             transferred,
    output wire                             shadow_full
);
    localparam REGISTERS_PER_STREAM_BEAT = CMD_STREAM_WIDTH / BANK_REG_WIDTH;

    reg [BANK_REG_WIDTH - 1 : 0] shadowMem [0 : BANK_SIZE - 1];
    reg [BANK_REG_WIDTH - 1 : 0] activeMem [0 : BANK_SIZE - 1];
    reg [INDEX_WIDTH - 1 : 0] registerIndex;
    reg shadowFull;

    assign shadow_full = shadowFull;
    assign transferred = shadowFull && active_free && !registers_updated;

    always @(posedge aclk)
    begin : Copy
        integer i;
        if (!resetn)
        begin
            registerIndex <= 0;
            shadowFull <= 0;
            registers_updated <= 0;
        end
        else
        begin
            if (update_acknowledged)
            begin
                registers_updated <= 0;
            end

            if (s_axis_tvalid)
            begin
                if (COMPRESSED)
                begin
                    for (i = 0; i < REGISTERS_PER_STREAM_BEAT; i = i + 1)
                    begin : g_q17_1
                        shadowMem[registerIndex + s_axis_tuser + i[0 +: INDEX_WIDTH]] <= s_axis_tdata[BANK_REG_WIDTH * i +: BANK_REG_WIDTH];
                    end
                    registerIndex <= registerIndex + REGISTERS_PER_STREAM_BEAT[0 +: INDEX_WIDTH];
                end
                else
                begin
                    shadowMem[registerIndex + s_axis_tuser] <= s_axis_tdata[0 +: BANK_REG_WIDTH];
                    registerIndex <= registerIndex + 1;
                end

                if (s_axis_tlast)
                begin
                    shadowFull <= 1;
                    registerIndex <= 0;
                end
            end

            if (transferred)
            begin
                for (i = 0; i < BANK_SIZE; i = i + 1)
                begin : g_q17_2
                    activeMem[i] <= shadowMem[i];
                end
                shadowFull <= 0;
                registers_updated <= 1;
            end
        end
    end

    generate
        genvar i;
        for(i = 0; i < BANK_SIZE; i = i + 1)
        begin : g_q17_3
            assign registers[i * BANK_REG_WIDTH +: BANK_REG_WIDTH] = activeMem[i];
        end
    endgenerate

endmodule
