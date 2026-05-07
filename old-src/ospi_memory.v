`default_nettype none

// archived copy (same as src/ospi_memory.v) for rebuilding project_full.v
module ospi_memory (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req,
    input  wire        rw,
    input  wire [23:0] addr,
    input  wire [5:0]  wdata,
    output reg         ready,
    output reg  [5:0]  rdata,

    output reg         sck,
    output reg         cs_n,
    output reg  [7:0]  io_o,
    input  wire [7:0]  io_i,
    output reg  [7:0]  io_oe
);

    localparam STATE_IDLE     = 3'd0,
               STATE_CMD      = 3'd1,
               STATE_ADDR     = 3'd2,
               STATE_DATA     = 3'd3,
               STATE_DONE     = 3'd4;

    reg [2:0] state;
    reg [2:0] phaseIdx;
    reg [7:0] cmdSr;
    reg [23:0] addrSr;
    reg [7:0] dataSr;
    reg [7:0] shiftIn;
    reg       prevReq;

    wire isWriteCmd = rw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            sck <= 0;
            cs_n <= 1;
            ready <= 0;
            rdata <= 0;
            phaseIdx <= 0;
            cmdSr <= 0;
            addrSr <= 0;
            dataSr <= 0;
            shiftIn <= 0;
            prevReq <= 0;
            io_o <= 0;
            io_oe <= 0;
        end else begin
            prevReq <= req;
            case (state)
                STATE_IDLE: begin
                    sck <= 0;
                    cs_n <= 1;
                    ready <= 0;
                    io_o <= 0;
                    io_oe <= 0;
                    phaseIdx <= 0;
                    if (req && !prevReq) begin
                        cs_n <= 0;
                        cmdSr <= isWriteCmd ? 8'h02 : 8'h03;
                        addrSr <= addr;
                        dataSr <= {2'b00, wdata};
                        shiftIn <= 0;
                        state <= STATE_CMD;
                    end
                end

                STATE_CMD: begin
                    io_oe <= 8'h01;
                    if (sck == 0) begin
                        io_o <= {7'b0, cmdSr[7]};
                        sck <= 1;
                    end else begin
                        sck <= 0;
                        cmdSr <= {cmdSr[6:0], 1'b0};
                        if (phaseIdx == 3'd7) begin
                            phaseIdx <= 0;
                            state <= STATE_ADDR;
                        end else
                            phaseIdx <= phaseIdx + 1;
                    end
                end

                STATE_ADDR: begin
                    io_oe <= 8'hFF;
                    if (sck == 0) begin
                        case (phaseIdx)
                            3'd0: io_o <= addrSr[23:16];
                            3'd1: io_o <= addrSr[15:8];
                            default: io_o <= addrSr[7:0];
                        endcase
                        sck <= 1;
                    end else begin
                        sck <= 0;
                        if (phaseIdx == 3'd2) begin
                            phaseIdx <= 0;
                            state <= STATE_DATA;
                        end else
                            phaseIdx <= phaseIdx + 1;
                    end
                end

                STATE_DATA: begin
                    if (isWriteCmd) begin
                        io_oe <= 8'hFF;
                        if (sck == 0) begin
                            io_o <= dataSr;
                            sck <= 1;
                        end else begin
                            sck <= 0;
                            state <= STATE_DONE;
                        end
                    end else begin
                        io_oe <= 8'h00;
                        io_o <= 8'b0;
                        if (sck == 0) begin
                            sck <= 1;
                        end else begin
                            sck <= 0;
                            shiftIn <= io_i;
                            state <= STATE_DONE;
                        end
                    end
                end

                STATE_DONE: begin
                    cs_n <= 1;
                    sck <= 0;
                    io_oe <= 0;
                    io_o <= 0;
                    ready <= 1;
                    if (!isWriteCmd)
                        rdata <= shiftIn[5:0];
                    state <= STATE_IDLE;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
