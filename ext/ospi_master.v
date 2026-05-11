// ospi_master.v - OSPI Master for External FPGA
// This module manages communication with the tt26-ocpu ASIC via OSPI slave interface.
// The external FPGA acts as master, driving the paging protocol and page loads.

module ospi_master (
    input clk,
    input rst_n,
    
    // OSPI interface (to ASIC)
    output reg sck,           // serial clock (50 MHz typical)
    output reg cs_n,          // chip select (active low)
    output reg [7:0] io_o,    // data output to ASIC
    input [7:0] io_i,         // data input from ASIC
    
    // status flags from asic
    input page_interrupt,     // pulse: slot-7 instruction finished, page swap needed
    input page_loading,       // asserted: cpu is waiting for page load
    input is_halted,          // asserted: cpu is halted
    
    // Page data interface
    // External system (e.g., external DRAM controller) provides page data
    input [7:0] page_data_in,     // instruction data from external storage
    output reg [2:0] page_data_idx, // which instruction in page (0-7)
    output reg page_data_valid,     // pulse: request next instruction byte
    
    // Page tracking
    output reg [7:0] current_page,  // currently active page
    output reg page_load_done       // pulse: finished loading page into ASIC
);

    // fsm states
    localparam [3:0] 
        ST_IDLE        = 4'h0,
        ST_WAIT_PAGE   = 4'h1,
        ST_LOAD_PAGE   = 4'h2,
        ST_XFER_CMD    = 4'h3,
        ST_XFER_ADDR   = 4'h4,
        ST_XFER_DATA   = 4'h5,
        ST_WAIT_ACK    = 4'h6;

    // OSPI command codes (from ASIC spi_memory module)
    localparam [7:0]
        CMD_WRITE = 8'h02,
        CMD_READ  = 8'h03;

    reg [3:0] state, state_next;
    reg [4:0] byte_count;  // which byte in transaction (0-4: cmd, addr[2:0], data)
    reg [2:0] instr_idx;   // instruction index within page (0-7)
    
    // transaction data
    reg [7:0] cmd_byte;
    reg [23:0] addr;
    reg [7:0] data_byte;

    // clock divider for OSPI SCK (half-period counter)
    reg [4:0] sck_counter;
    wire sck_pulse = (sck_counter == 5'd24);  // ~1 MHz SCK from 50 MHz clk

    // fsm state transitions
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else begin
            state <= state_next;
        end
    end

    // fsm logic
    always @(*) begin
        state_next = state;
        
        case (state)
            ST_IDLE: begin
                // wait for page_interrupt from ASIC
                if (page_interrupt) begin
                    state_next = ST_WAIT_PAGE;
                end
            end
            
            ST_WAIT_PAGE: begin
                // wait for page_loading to indicate cpu is halted and waiting
                if (page_loading) begin
                    state_next = ST_LOAD_PAGE;
                end
            end
            
            ST_LOAD_PAGE: begin
                // load all 8 instructions for this page via OSPI
                if (instr_idx == 3'd7 && byte_count == 5'd0 && sck_pulse) begin
                    // done loading page
                    state_next = ST_IDLE;
                end else begin
                    state_next = ST_XFER_CMD;
                end
            end
            
            ST_XFER_CMD: begin
                // send write command (0x02)
                if (byte_count == 5'd1 && sck_pulse) begin
                    state_next = ST_XFER_ADDR;
                    byte_count = 5'd0;
                end
            end
            
            ST_XFER_ADDR: begin
                // send 3-byte address: 0x00[instr_idx]00
                if (byte_count == 5'd3 && sck_pulse) begin
                    state_next = ST_XFER_DATA;
                    byte_count = 5'd0;
                end
            end
            
            ST_XFER_DATA: begin
                // send data byte (instruction)
                if (byte_count == 5'd1 && sck_pulse) begin
                    if (instr_idx == 3'd7) begin
                        // last instruction, go back to LOAD_PAGE to signal done
                        state_next = ST_LOAD_PAGE;
                    end else begin
                        // next instruction
                        state_next = ST_LOAD_PAGE;
                    end
                    byte_count = 5'd0;
                end
            end
        endcase
    end

    // SCK generation and byte/bit counters
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_counter <= 5'd0;
            sck <= 1'b0;
        end else begin
            if (sck_counter == 5'd24) begin
                sck_counter <= 5'd0;
                sck <= ~sck;  // toggle SCK
            end else begin
                sck_counter <= sck_counter + 1'b1;
            end
        end
    end

    // transaction sequencing
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_count <= 5'd0;
            instr_idx <= 3'd0;
            current_page <= 8'd0;
            page_load_done <= 1'b0;
            cs_n <= 1'b1;
            cmd_byte <= 8'h00;
            addr <= 24'h000000;
            data_byte <= 8'h00;
            io_o <= 8'h00;
            page_data_valid <= 1'b0;
        end else begin
            page_load_done <= 1'b0;  // pulse output
            page_data_valid <= 1'b0; // pulse output
            
            case (state)
                ST_IDLE: begin
                    cs_n <= 1'b1;
                    byte_count <= 5'd0;
                    instr_idx <= 3'd0;
                end
                
                ST_WAIT_PAGE: begin
                    // wait for CPU to halt
                end
                
                ST_LOAD_PAGE: begin
                    if (byte_count == 5'd0 && sck_pulse) begin
                        // start new transaction for this instruction
                        // address = 0x00000N where N = instr_idx (0..7)
                        cs_n <= 1'b0;
                        cmd_byte <= CMD_WRITE;
                        addr <= {21'h000000, instr_idx};
                        page_data_valid <= 1'b1;  // request instruction from external storage
                        byte_count <= byte_count + 1'b1;
                    end else if (byte_count > 5'd0 && byte_count <= 5'd4 && sck_pulse) begin
                        byte_count <= byte_count + 1'b1;
                    end

                    if (instr_idx == 3'd7 && byte_count == 5'd5 && sck_pulse) begin
                        // end transaction after last instruction
                        cs_n <= 1'b1;
                        page_load_done <= 1'b1;  // signal page load complete
                        current_page <= current_page + 1'b1;  // next page
                        instr_idx <= 3'd0;
                        byte_count <= 5'd0;
                    end else if (byte_count == 5'd5 && sck_pulse) begin
                        // end transaction for this instruction
                        cs_n <= 1'b1;
                        instr_idx <= instr_idx + 1'b1;
                        byte_count <= 5'd0;
                    end
                end
            endcase
        end
    end

    // OSPI data output (shift out on SCK falling edge, sample on rising edge)
    always @(posedge clk) begin
        if (sck_pulse && state == ST_LOAD_PAGE) begin
            case (byte_count)
                5'd1: io_o <= cmd_byte;  // command byte
                5'd2: io_o <= addr[23:16];  // address byte 0
                5'd3: io_o <= addr[15:8];   // address byte 1
                5'd4: io_o <= addr[7:0];    // address byte 2
                5'd5: io_o <= page_data_in; // data byte (from external storage)
            endcase
        end
    end

    // page_data_idx output: which instruction slot we're currently loading
    always @(*) begin
        page_data_idx = instr_idx;
    end

endmodule
