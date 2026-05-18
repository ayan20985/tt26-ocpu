`default_nettype none

// ospi_master.v
// =============
// 8-bit-parallel OSPI master that pairs with src/ospi_memory.v on the
// tt26-ocpu chip. presents a simple synchronous request / acknowledge
// interface to the rest of the FPGA, hides all 5-byte burst sequencing
// and SCK toggling.
//
// request interface (req side):
//   * raise req with rw / addr / wdata stable
//   * wait for ack to pulse high for one clk cycle
//   * on a read, rdata is valid on the same cycle as ack
//   * drop req any time after ack; raising req again starts another burst
//
// physical pins (drive the new chip-side map from src/project.v):
//   sck   -> ui_in[0]   (chip side)
//   cs_n  -> ui_in[1]
//   io_o  -> uio_in[7:0]  (master -> slave bytes 0..3, also byte 4 on writes)
//   io_oe -> 1 except when the slave is driving byte 4 of a read
//   io_i  -> uio_out[7:0] (slave -> master byte 4 on reads)
//
// timing model
// ============
// the OSPI slave samples on SCK rising edges and the master must keep
// io_o stable for >=1 clk cycle around each edge. we therefore split
// every SCK period into two equal half-periods (SCK_DIV clk cycles
// each). on the falling half we update io_o for the byte we're about
// to transmit; on the rising half the slave samples it.
//
// SCK_DIV default = 4 (clk/SCK = 8). bump up if your sim clk is fast
// relative to slave's internal pipeline.
//
// transaction shape (matches src/ospi_memory.v exactly):
//   byte 0 : cmd  (0x02=write, 0x03=read)
//   byte 1 : addr[23:16]
//   byte 2 : addr[15:8]
//   byte 3 : addr[7:0]      (after this byte the slave knows whether it's
//                            a read and triggers mem_read internally)
//   byte 4 : data           (master drives on write; slave drives on read)
//
// the master deasserts cs_n between bursts so the slave's byte_count
// resets cleanly. SCK is held low while cs_n is high.

module ospi_master #(
    parameter integer SCK_DIV = 4   // clk cycles per SCK half-period
) (
    input  wire        clk,
    input  wire        rst_n,

    // transactional request port
    input  wire        req,         // pulse / level: kick off a transaction
    input  wire        rw,          // 0 = read, 1 = write
    input  wire [23:0] addr,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,
    output reg         ack,         // 1-cycle pulse when transaction done

    // pins to the chip (map onto ui_in / uio_* per the chip's pin map)
    output reg         sck,
    output reg         cs_n,
    output reg  [7:0]  io_o,
    output reg         io_oe,       // 1 = master drives uio, 0 = slave drives
    input  wire [7:0]  io_i
);

    // -------------------------------------------------------------------
    // state
    // -------------------------------------------------------------------
    localparam [2:0]
        ST_IDLE  = 3'd0,
        ST_CS_LO = 3'd1,   // assert cs_n, wait one SCK half-period
        ST_SEND  = 3'd2,   // shifting bytes out (or sampling on read byte 4)
        ST_CS_HI = 3'd3,   // raise cs_n, settle, return to IDLE
        ST_ACK   = 3'd4;

    reg [2:0] state;
    reg [2:0] byte_idx;          // 0..4
    reg       half;              // 0 = first half (sck low), 1 = second half (sck high)
    reg [$clog2(SCK_DIV+1)-1:0] tick;  // counts clks within a half-period

    // captured request parameters
    reg        rw_q;
    reg [23:0] addr_q;
    reg [7:0]  wdata_q;

    wire sck_phase_end = (tick == SCK_DIV - 1);

    // -------------------------------------------------------------------
    // pick the byte to transmit for byte_idx in 0..4
    // -------------------------------------------------------------------
    function automatic [7:0] tx_byte;
        input [2:0]  bi;
        input        rw_in;
        input [23:0] a_in;
        input [7:0]  d_in;
        begin
            case (bi)
                3'd0:    tx_byte = rw_in ? 8'h02 : 8'h03;
                3'd1:    tx_byte = a_in[23:16];
                3'd2:    tx_byte = a_in[15:8];
                3'd3:    tx_byte = a_in[7:0];
                3'd4:    tx_byte = d_in;           // only meaningful for write
                default: tx_byte = 8'h00;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------
    // master fsm
    // -------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            byte_idx <= 3'd0;
            half     <= 1'b0;
            tick     <= 0;
            rw_q     <= 1'b0;
            addr_q   <= 24'h0;
            wdata_q  <= 8'h0;
            rdata    <= 8'h0;
            ack      <= 1'b0;
            sck      <= 1'b0;
            cs_n     <= 1'b1;
            io_o     <= 8'h00;
            io_oe    <= 1'b1;
        end else begin
            ack <= 1'b0;  // default; pulse below
            case (state)
                // -----------------------------------------------------------
                ST_IDLE: begin
                    sck   <= 1'b0;
                    cs_n  <= 1'b1;
                    io_oe <= 1'b1;
                    if (req) begin
                        rw_q     <= rw;
                        addr_q   <= addr;
                        wdata_q  <= wdata;
                        byte_idx <= 3'd0;
                        half     <= 1'b0;
                        tick     <= 0;
                        cs_n     <= 1'b0;             // assert cs_n
                        io_o     <= tx_byte(3'd0, rw, addr, wdata);
                        io_oe    <= 1'b1;
                        state    <= ST_CS_LO;
                    end
                end

                // wait one half period after cs_n drops so the slave sees
                // the asserted cs_n before the first SCK edge.
                ST_CS_LO: begin
                    if (sck_phase_end) begin
                        tick  <= 0;
                        half  <= 1'b1;     // entering rising half
                        sck   <= 1'b1;     // SCK rising edge - slave samples
                        state <= ST_SEND;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end

                // SEND: every half-period we toggle SCK. on the falling
                // half we update io_o for the NEXT byte; on the rising
                // half the slave samples. for a read, on the falling
                // half of byte 4 we tri-state io_oe so the slave can drive
                // the data, and on the rising half we sample io_i.
                ST_SEND: begin
                    if (sck_phase_end) begin
                        tick <= 0;
                        if (half == 1'b1) begin
                            // ending the rising half of byte byte_idx.
                            // move to falling half of byte (byte_idx+1).
                            half <= 1'b0;
                            sck  <= 1'b0;
                            if (byte_idx == 3'd4) begin
                                // we just finished sampling byte 4 of a
                                // read (or driving byte 4 of a write).
                                // tear the burst down.
                                cs_n  <= 1'b1;
                                io_oe <= 1'b1;
                                state <= ST_CS_HI;
                            end else begin
                                byte_idx <= byte_idx + 1'b1;
                                // prepare next byte's value on the falling
                                // half so it is stable for the next rising
                                // edge.
                                if ((byte_idx + 3'd1) == 3'd4 && !rw_q) begin
                                    // entering byte 4 of a READ: stop
                                    // driving; slave will take the bus.
                                    io_oe <= 1'b0;
                                    io_o  <= 8'h00;
                                end else begin
                                    io_oe <= 1'b1;
                                    io_o  <= tx_byte(byte_idx + 3'd1,
                                                     rw_q, addr_q, wdata_q);
                                end
                            end
                        end else begin
                            // ending the falling half. SCK goes high, slave
                            // samples io_o (or master samples io_i on read
                            // byte 4).
                            half <= 1'b1;
                            sck  <= 1'b1;
                            if (byte_idx == 3'd4 && !rw_q) begin
                                rdata <= io_i;
                            end
                        end
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end

                // hold cs_n high for one half-period to give the slave time
                // to reset its byte counter before the next burst.
                ST_CS_HI: begin
                    if (sck_phase_end) begin
                        tick  <= 0;
                        state <= ST_ACK;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end

                ST_ACK: begin
                    ack   <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
