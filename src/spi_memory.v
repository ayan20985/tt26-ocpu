`default_nettype none

module spi_memory (
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
    output wire        mosi,
    input  wire        miso
);

    localparam STATE_IDLE     = 0,
               STATE_TRANSFER = 1,
               STATE_DONE     = 2;

    reg [1:0]  state;
    reg [6:0]  bitCount;
    reg [31:0] shiftOut;
    reg [7:0]  shiftIn;
    reg        prevReq;

    assign mosi = shiftOut[31];

    wire isWriteCmd = rw;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            sck <= 0;
            cs_n <= 1;
            ready <= 0;
            rdata <= 0;
            bitCount <= 0;
            shiftOut <= 0;
            shiftIn <= 0;
            prevReq <= 0;
        end else begin
            prevReq <= req;
            case (state)
                STATE_IDLE: begin
                    sck <= 0;
                    cs_n <= 1;
                    ready <= 0;
                    bitCount <= 0;
                    if (req && !prevReq) begin
                        cs_n <= 0;
                        shiftOut <= { (isWriteCmd ? 8'h02 : 8'h03), addr };
                        state <= STATE_TRANSFER;
                    end
                end

                STATE_TRANSFER: begin
                    if (sck == 0) begin
                        sck <= 1;
                        if (bitCount >= 64 && !isWriteCmd) begin
                            shiftIn <= {shiftIn[6:0], miso};
                        end
                    end else begin
                        sck <= 0;
                        if (bitCount < 62) begin
                            shiftOut <= {shiftOut[30:0], 1'b0};
                        end else if (bitCount == 62) begin
                            if (isWriteCmd)
                                shiftOut <= {2'b00, wdata, 24'b0};
                            else
                                shiftOut <= {shiftOut[30:0], 1'b0};
                        end else if (bitCount >= 64 && isWriteCmd) begin
                            shiftOut <= {shiftOut[30:0], 1'b0};
                        end
                        bitCount <= bitCount + 2;

                        if (bitCount >= 78) begin
                            state <= STATE_DONE;
                        end
                    end
                end

                STATE_DONE: begin
                    cs_n <= 1;
                    ready <= 1;
                    if (!isWriteCmd) begin
                        rdata <= shiftIn[5:0];
                    end
                    state <= STATE_IDLE;
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
