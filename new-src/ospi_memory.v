`default_nettype none

// OSPI (8-bit parallel) slave memory interface.
// Acts as a responder to an external OSPI master (FPGA).
// Protocol: master sends [8-bit cmd | 24-bit addr | 8-bit data], slave responds with data on reads.
// Read  cmd = 0x03, Write cmd = 0x02.
// All data is transmitted/received on io[7:0] with io_oe controlling tri-state.

module ospi_memory (
    input  wire        clk,        // local clock (independent from OSPI)
    input  wire        rst_n,

    // internal memory interface
    output reg  [23:0] mem_addr,   // address from last OSPI transaction
    output reg  [7:0]  mem_wdata,  // write data from last OSPI transaction
    input  wire [7:0]  mem_rdata,  // data to return on next OSPI read
    output reg         mem_write,  // pulse: OSPI write command completed
    output reg         mem_read,   // pulse: OSPI read command completed

    // physical OSPI slave pins (controlled by external master)
    input  wire        sck,        // serial clock (from master)
    input  wire        cs_n,       // chip select (from master)
    input  wire [7:0]  io_i,       // input data from master (8 bits parallel)
    output wire [7:0]  io_o,       // output data to master (8 bits parallel)
    output wire [7:0]  io_oe       // tri-state control (1=drive, 0=Hi-Z)
);

    // synchronize external OSPI signals to local clock
    reg sck_r1, sck_r2;
    reg cs_r1, cs_r2;
    reg [7:0] io_i_r1, io_i_r2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_r1 <= 0;
            sck_r2 <= 0;
            cs_r1 <= 1;
            cs_r2 <= 1;
            io_i_r1 <= 8'h00;
            io_i_r2 <= 8'h00;
        end else begin
            sck_r1  <= sck;
            sck_r2  <= sck_r1;
            cs_r1   <= cs_n;
            cs_r2   <= cs_r1;
            io_i_r1 <= io_i;
            io_i_r2 <= io_i_r1;
        end
    end

    wire sck_sync = sck_r2;
    wire cs_sync = cs_r2;
    wire [7:0] io_i_sync = io_i_r2;

    // detect SCK rising edge
    reg sck_prev;
    wire sck_rising = sck_sync && !sck_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sck_prev <= 0;
        else
            sck_prev <= sck_sync;
    end

    // shift register for incoming OSPI data: 32 bits for cmd+addr (4 bytes)
    // data byte (5th byte) is consumed directly from io_i_sync, not shifted in.
    reg [31:0] shift_in;
    reg [2:0]  byte_count;  // 0-4 for 5 bytes total
    reg [7:0]  shift_out;
    reg [7:0]  read_data;
    reg [7:0]  cmd_byte;

    assign io_o = shift_out;
    assign io_oe = (cs_sync && byte_count >= 3'd4) ? 8'hFF : 8'h00;  // drive output during data phase

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_in    <= 32'h0;
            byte_count  <= 0;
            shift_out   <= 8'h0;
            read_data   <= 8'h0;
            mem_addr    <= 24'h0;
            mem_wdata   <= 8'h0;
            mem_write   <= 0;
            mem_read    <= 0;
            cmd_byte    <= 8'h0;
        end else begin
            mem_write <= 0;
            mem_read  <= 0;

            if (cs_sync) begin
                // chip select active
                if (sck_rising) begin
                    // shift in 8 bits from master on SCK rising edge
                    shift_in <= {shift_in[23:0], io_i_sync};

                    if (byte_count < 5) begin
                        byte_count <= byte_count + 1;

                        // after byte 0 (cmd), latch command
                        if (byte_count == 0)
                            cmd_byte <= io_i_sync;

                        // after byte 4 (data), transaction complete
                        if (byte_count == 4) begin
                            mem_wdata <= io_i_sync;
                            if (cmd_byte == 8'h02) begin
                                // write command
                                mem_write <= 1;
                            end else if (cmd_byte == 8'h03) begin
                                // read command
                                mem_read <= 1;
                                read_data <= mem_rdata;
                            end
                            byte_count <= 0;
                        end else if (byte_count == 3) begin
                            // after addr (3 bytes), capture it
                            // shift_in after this edge: [cmd,addr_hi,addr_mid,addr_lo]
                            mem_addr <= {shift_in[23:0], io_i_sync};
                        end
                    end

                    // drive shift_out for data phase
                    if (byte_count == 4)
                        shift_out <= read_data;
                end
            end else begin
                // chip select inactive: reset
                byte_count <= 0;
                shift_in   <= 32'h0;
                shift_out  <= 8'h0;
            end
        end
    end

endmodule
