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

    // synchronize external OSPI signals to local clock (single stage)
    reg sck_r1;
    reg cs_r1;
    reg [7:0] io_i_r1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_r1 <= 0;
            cs_r1 <= 1;
            io_i_r1 <= 8'h00;
        end else begin
            sck_r1  <= sck;
            cs_r1   <= cs_n;
            io_i_r1 <= io_i;
        end
    end

    wire sck_sync = sck_r1;
    wire cs_sync = cs_r1;
    wire [7:0] io_i_sync = io_i_r1;

    // detect SCK rising edge
    reg sck_prev;
    wire sck_rising = sck_sync && !sck_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sck_prev <= 0;
        else
            sck_prev <= sck_sync;
    end

    // byte-streamed protocol: incoming bytes are written directly into the
    // address/data output registers driven by byte_count, so no separate
    // 32-bit shift register is needed. cmd_byte is also shrunk to two
    // single-bit flags (read vs. write) latched when byte 0 arrives.
    reg [2:0]  byte_count;
    reg [7:0]  shift_out;
    reg        is_read_cmd;
    reg        is_write_cmd;

    // io_o always carries the current shift_out latch. io_oe is asserted
    // only during byte 4 of a READ transaction (slave drives data), and the
    // chip is selected. on a WRITE, the master keeps driving the bus for
    // byte 4 too, so the slave must stay tri-stated to avoid bus contention.
    assign io_o  = shift_out;
    assign io_oe = (!cs_sync && is_read_cmd && byte_count == 3'd4)
                   ? 8'hFF : 8'h00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_count   <= 0;
            shift_out    <= 8'h0;
            mem_addr     <= 24'h0;
            mem_wdata    <= 8'h0;
            mem_write    <= 0;
            mem_read     <= 0;
            is_read_cmd  <= 0;
            is_write_cmd <= 0;
        end else begin
            // these are 1-cycle pulses to the upstream mem-bus consumer
            mem_write <= 0;
            mem_read  <= 0;

            // cs_n is active LOW. process bytes ONLY while the chip is
            // selected, i.e. cs_sync == 0.
            if (!cs_sync) begin
                if (sck_rising) begin
                    case (byte_count)
                        // byte 0: command. latch the two cmd-decode flags
                        // instead of keeping the whole 8-bit cmd_byte.
                        3'd0: begin
                            is_write_cmd <= (io_i_sync == 8'h02);
                            is_read_cmd  <= (io_i_sync == 8'h03);
                        end
                        // bytes 1-3: address arrives MSB first.
                        3'd1: mem_addr[23:16] <= io_i_sync;
                        3'd2: mem_addr[15:8]  <= io_i_sync;
                        3'd3: begin
                            mem_addr[7:0] <= io_i_sync;
                            // address now complete. for a read, ask the
                            // upstream rdata mux to update NOW so the
                            // registered ospi_mem_rdata_out has the right
                            // value by the time the master clocks byte 4.
                            // the mux in project.v takes 1 extra clk cycle,
                            // which is well within one SCK half-period.
                            if (is_read_cmd) mem_read <= 1;
                        end
                        // byte 4: data byte completes the transaction. on a
                        // write, master drove this byte; capture and pulse
                        // mem_write. on a read, the master sampled io_o and
                        // we have nothing to do here.
                        3'd4: begin
                            mem_wdata <= io_i_sync;
                            if (is_write_cmd)
                                mem_write <= 1;
                        end
                        default: ;
                    endcase

                    byte_count <= (byte_count == 3'd4)
                                  ? 3'd0
                                  : (byte_count + 3'd1);
                end

                // while we're in the data phase of a read, keep mirroring
                // the currently-valid mem_rdata onto the output latch so
                // shift_out is stable by the time the master clocks SCK
                // for byte 4. (mem_rdata is registered upstream and was
                // updated one cycle after the byte-3 mem_read pulse.)
                if (is_read_cmd && byte_count == 3'd4)
                    shift_out <= mem_rdata;
            end else begin
                // CS_N high: chip deselected. reset byte counter so the
                // next burst starts cleanly, and stop driving the bus.
                byte_count   <= 0;
                shift_out    <= 8'h0;
                is_read_cmd  <= 0;
                is_write_cmd <= 0;
            end
        end
    end

endmodule
