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

    localparam STATE_IDLE      = 0,
               STATE_TRANSFER  = 1,
               STATE_DONE      = 2;

    reg [1:0]  state;
    reg [6:0]  bit_count;
    reg [31:0] shift_out;
    reg [7:0]  shift_in;
    reg        prev_req;
    
    assign mosi = shift_out[31];
    
    wire is_write_cmd = rw;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            sck <= 0;
            cs_n <= 1;
            ready <= 0;
            rdata <= 0;
            bit_count <= 0;
            shift_out <= 0;
            shift_in <= 0;
            prev_req <= 0;
        end else begin
            prev_req <= req;
            case (state)
                STATE_IDLE: begin
                    sck <= 0;
                    cs_n <= 1;
                    ready <= 0;
                    bit_count <= 0;
                    if (req && !prev_req) begin
                        cs_n <= 0;
                        shift_out <= { (is_write_cmd ? 8'h02 : 8'h03), addr };
                        state <= STATE_TRANSFER;
                    end
                end
                
                STATE_TRANSFER: begin
                    if (sck == 0) begin
                        sck <= 1;
                        if (bit_count >= 64 && !is_write_cmd) begin
                            shift_in <= {shift_in[6:0], miso};
                        end
                    end else begin
                        sck <= 0;
                        if (bit_count < 62) begin
                            shift_out <= {shift_out[30:0], 1'b0};
                        end else if (bit_count == 62) begin
                            if (is_write_cmd)
                                shift_out <= {2'b00, wdata, 24'b0};
                            else
                                shift_out <= {shift_out[30:0], 1'b0};
                        end else if (bit_count >= 64 && is_write_cmd) begin
                            shift_out <= {shift_out[30:0], 1'b0};
                        end
                        bit_count <= bit_count + 2;
                        
                        if (bit_count >= 78) begin
                            state <= STATE_DONE;
                        end
                    end
                end
                
                STATE_DONE: begin
                    cs_n <= 1;
                    ready <= 1;
                    if (!is_write_cmd) begin
                        rdata <= shift_in[5:0];
                    end
                    state <= STATE_IDLE;
                end
                
                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule
