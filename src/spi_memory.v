`default_nettype none

module spi_memory (
    input  wire        clk,
    input  wire        rst_n,
    
    // cpu memory bus interface
    input  wire        req,
    input  wire        rw,        // 0 = read, 1 = write
    input  wire [23:0] addr,      // 8-bit bank + 16-bit address
    input  wire [5:0]  wdata,
    output reg         ready,
    output reg  [5:0]  rdata,
    
    // external spi pins
    output reg         sck,
    output reg         cs_n,
    output wire        mosi,
    input  wire        miso
);

    localparam STATE_IDLE      = 0,
               STATE_TRANSFER  = 1,
               STATE_DONE      = 2;

    reg [1:0]  state;
    reg [6:0]  bit_count;     // counts up to 40 logic steps (32 bits * 2 cycles for cmd/addr + 8 bits * 2 cycles for data)
    reg [31:0] shift_out;
    reg [7:0]  shift_in;
    
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
        end else begin
            case (state)
                STATE_IDLE: begin
                    sck <= 0;
                    cs_n <= 1;
                    ready <= 0;
                    bit_count <= 0;
                    if (req) begin
                        cs_n <= 0;
                        // spi read cmd = 0x03, write cmd = 0x02.
                        shift_out <= { (is_write_cmd ? 8'h02 : 8'h03), addr };
                        state <= STATE_TRANSFER;
                    end
                end
                
                STATE_TRANSFER: begin
                    // toggle sck and shift data to ensure clean spi mode 0 (sample on rising edge).
                    // we need to transfer 32 bits (cmd + addr) and then 8 bits (data).
                    // tracking phases by bit_count: each bit takes 2 clock cycles.
                    if (sck == 0) begin
                        sck <= 1;
                        // sample incoming miso on rising edge if we are in the data-read phase
                        if (bit_count >= 64 && !is_write_cmd) begin
                            shift_in <= {shift_in[6:0], miso};
                        end
                    end else begin
                        sck <= 0;
                        // set up next mosi bit on falling edge
                        // mosi shifts for all 32 cmd+addr bits before the data phase.
                        if (bit_count < 64) begin
                            shift_out <= {shift_out[30:0], 1'b0};
                        end else if (bit_count == 64 && is_write_cmd) begin
                            // cmd/addr sent, load write data to output appending 2 bits to top
                            shift_out <= {2'b00, wdata, 24'b0};
                        end else if (bit_count > 64 && is_write_cmd) begin
                            shift_out <= {shift_out[30:0], 1'b0};
                        end
                        bit_count <= bit_count + 2;
                        
                        // read completes after 8 data bits; write needs two more clocks for 8 mosi bits
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