`default_nettype none

// page_controller.v
// =================
// reference implementation of the external-FPGA side of the page-handshake
// protocol. sits on top of ext/ospi_master.v and a backing program / data
// store (modelled here as two simple memory ports the integrator fills
// with their actual storage backend).
//
// behaviour
// ---------
//   * watches `page_interrupt` from the chip. on its rising edge the chip
//     has just executed slot 7 of `page_current` and is now sitting in
//     ST_PAGE_REQ waiting for a fresh page.
//   * scans `dirty_bits` (OSPI read of 0xFD0000). for each set bit N it
//     reads slot N back (OSPI read of 0x00000N) and writes the byte into
//     the program-store at offset (page_current * 8 + N).
//   * asserts `page_loading` on the chip's `ui_in[3]` and writes 8 OSPI
//     transactions to 0x000000..0x000007 with the bytes from the
//     program-store entry for `page_next`.
//   * pulses `page_done` on `ui_in[2]` and returns to idle.
//
// in parallel it services data-memory requests from the chip:
//   * when `data_req` is high it reads 0xFE0000..0xFE0002 to capture
//     {rw, addr_hi, addr_lo}.
//   * for rw=1: reads 0xFE0003 (wdata), writes the data store, OSPI-
//     writes any byte to 0xFE0100 to ack.
//   * for rw=0: reads the data store, OSPI-writes that byte to 0xFE0100.
//
// the page swap takes priority because it unblocks all future fetches;
// a stalled data_req merely blocks one cpu instruction.

module page_controller (
    input  wire        clk,
    input  wire        rst_n,

    // chip status signals (drive these from the chip's uo_out)
    input  wire        page_interrupt,
    input  wire        is_halted,
    input  wire        data_req,

    // chip page-handshake outputs (drive these onto chip's ui_in[2]/[3])
    output reg         page_loading,
    output reg         page_done,

    // ospi_master request port
    output reg         spi_req,
    output reg         spi_rw,         // 0 = read, 1 = write
    output reg  [23:0] spi_addr,
    output reg  [7:0]  spi_wdata,
    input  wire [7:0]  spi_rdata,
    input  wire        spi_ack,

    // program backing store (one byte per slot; 256 pages * 8 slots)
    output reg  [10:0] prog_addr,      // {page[7:0], slot[2:0]}
    input  wire [7:0]  prog_rdata,
    output reg  [7:0]  prog_wdata,
    output reg         prog_we,

    // data backing store (linear 64K address space)
    output reg  [15:0] data_addr,
    input  wire [7:0]  data_rdata,
    output reg  [7:0]  data_wdata,
    output reg         data_we,

    // next-page hint. the surrounding glue logic computes this from
    // page_interrupt timing and FARJMP imm decode, then drives it before
    // the chip enters ST_PAGE_REQ.
    input  wire [7:0]  page_current,
    input  wire [7:0]  page_next
);

    // -------------------------------------------------------------------
    // states
    // -------------------------------------------------------------------
    localparam [4:0]
        S_IDLE              = 5'd0,
        // page swap — writeback scan
        S_WB_RD_DIRTY       = 5'd1,
        S_WB_PICK           = 5'd2,
        S_WB_RD_SLOT        = 5'd3,
        // page swap — load
        S_LD_RAISE          = 5'd4,
        S_LD_FETCH          = 5'd5,
        S_LD_WRITE          = 5'd6,
        S_LD_NEXT           = 5'd7,
        S_LD_DONE           = 5'd8,
        // data request
        S_DR_RD_RW          = 5'd9,
        S_DR_RD_HI          = 5'd10,
        S_DR_RD_LO          = 5'd11,
        S_DR_RD_WD          = 5'd12,
        S_DR_SERVE_R        = 5'd13,
        S_DR_SERVE_W        = 5'd14,
        S_DR_ACK            = 5'd15;

    reg [4:0] state;

    // captures used across phases
    reg [7:0]  dirty;
    reg [2:0]  slot;
    reg        rw_q;
    reg [15:0] daddr_q;
    reg [7:0]  wdata_q;
    reg [7:0]  rdata_q;

    // rising-edge detector for page_interrupt
    reg page_int_q;
    wire page_int_edge = page_interrupt & ~page_int_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) page_int_q <= 1'b0;
        else        page_int_q <= page_interrupt;
    end

    // priority encoder: lowest set bit of an 8-bit vector
    function automatic [2:0] lowest_set;
        input [7:0] d;
        begin
            casez (d)
                8'b???????1: lowest_set = 3'd0;
                8'b??????10: lowest_set = 3'd1;
                8'b?????100: lowest_set = 3'd2;
                8'b????1000: lowest_set = 3'd3;
                8'b???10000: lowest_set = 3'd4;
                8'b??100000: lowest_set = 3'd5;
                8'b?1000000: lowest_set = 3'd6;
                8'b10000000: lowest_set = 3'd7;
                default:     lowest_set = 3'd0;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------
    // sequencer
    // -------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            page_loading <= 1'b0;
            page_done    <= 1'b0;
            spi_req      <= 1'b0;
            spi_rw       <= 1'b0;
            spi_addr     <= 24'h0;
            spi_wdata    <= 8'h0;
            prog_addr    <= 11'h0;
            prog_wdata   <= 8'h0;
            prog_we      <= 1'b0;
            data_addr    <= 16'h0;
            data_wdata   <= 8'h0;
            data_we      <= 1'b0;
            dirty        <= 8'h0;
            slot         <= 3'h0;
            rw_q         <= 1'b0;
            daddr_q      <= 16'h0;
            wdata_q      <= 8'h0;
            rdata_q      <= 8'h0;
        end else begin
            // pulses default low; states set them high for one cycle
            page_done <= 1'b0;
            prog_we   <= 1'b0;
            data_we   <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                S_IDLE: begin
                    spi_req      <= 1'b0;
                    page_loading <= 1'b0;
                    if (page_int_edge) begin
                        spi_req  <= 1'b1;
                        spi_rw   <= 1'b0;
                        spi_addr <= 24'hFD0000;
                        state    <= S_WB_RD_DIRTY;
                    end else if (data_req) begin
                        spi_req  <= 1'b1;
                        spi_rw   <= 1'b0;
                        spi_addr <= 24'hFE0000;
                        state    <= S_DR_RD_RW;
                    end
                end

                // -- writeback scan ---------------------------------------
                S_WB_RD_DIRTY: if (spi_ack) begin
                    spi_req <= 1'b0;
                    dirty   <= spi_rdata;
                    state   <= S_WB_PICK;
                end

                S_WB_PICK: begin
                    if (dirty == 8'h00) begin
                        state <= S_LD_RAISE;
                    end else begin
                        slot     <= lowest_set(dirty);
                        spi_req  <= 1'b1;
                        spi_rw   <= 1'b0;
                        spi_addr <= {21'h0, lowest_set(dirty)};
                        state    <= S_WB_RD_SLOT;
                    end
                end

                S_WB_RD_SLOT: if (spi_ack) begin
                    spi_req      <= 1'b0;
                    prog_addr    <= {page_current, slot};
                    prog_wdata   <= spi_rdata;
                    prog_we      <= 1'b1;
                    dirty[slot]  <= 1'b0;
                    state        <= S_WB_PICK;
                end

                // -- load new page ----------------------------------------
                S_LD_RAISE: begin
                    page_loading <= 1'b1;
                    slot         <= 3'd0;
                    prog_addr    <= {page_next, 3'd0};
                    state        <= S_LD_FETCH;
                end

                S_LD_FETCH: begin
                    // prog_rdata valid one clk after prog_addr is presented
                    state <= S_LD_WRITE;
                end

                S_LD_WRITE: begin
                    spi_req   <= 1'b1;
                    spi_rw    <= 1'b1;
                    spi_addr  <= {21'h0, slot};
                    spi_wdata <= prog_rdata;
                    state     <= S_LD_NEXT;
                end

                S_LD_NEXT: if (spi_ack) begin
                    spi_req <= 1'b0;
                    if (slot == 3'd7) begin
                        state <= S_LD_DONE;
                    end else begin
                        slot      <= slot + 3'd1;
                        prog_addr <= {page_next, slot + 3'd1};
                        state     <= S_LD_FETCH;
                    end
                end

                S_LD_DONE: begin
                    page_loading <= 1'b0;
                    page_done    <= 1'b1;     // 1-cycle pulse to the chip
                    state        <= S_IDLE;
                end

                // -- data memory request ----------------------------------
                S_DR_RD_RW: if (spi_ack) begin
                    rw_q     <= spi_rdata[0];
                    spi_req  <= 1'b1;
                    spi_rw   <= 1'b0;
                    spi_addr <= 24'hFE0001;
                    state    <= S_DR_RD_HI;
                end

                S_DR_RD_HI: if (spi_ack) begin
                    daddr_q[15:8] <= spi_rdata;
                    spi_req       <= 1'b1;
                    spi_rw        <= 1'b0;
                    spi_addr      <= 24'hFE0002;
                    state         <= S_DR_RD_LO;
                end

                S_DR_RD_LO: if (spi_ack) begin
                    daddr_q[7:0] <= spi_rdata;
                    if (rw_q) begin
                        spi_req  <= 1'b1;
                        spi_rw   <= 1'b0;
                        spi_addr <= 24'hFE0003;
                        state    <= S_DR_RD_WD;
                    end else begin
                        spi_req   <= 1'b0;
                        data_addr <= {daddr_q[15:8], spi_rdata};
                        state     <= S_DR_SERVE_R;
                    end
                end

                S_DR_RD_WD: if (spi_ack) begin
                    wdata_q   <= spi_rdata;
                    spi_req   <= 1'b0;
                    data_addr <= daddr_q;
                    state     <= S_DR_SERVE_W;
                end

                S_DR_SERVE_W: begin
                    data_wdata <= wdata_q;
                    data_we    <= 1'b1;
                    rdata_q    <= 8'h00;       // chip ignores write rdata
                    spi_req    <= 1'b1;
                    spi_rw     <= 1'b1;
                    spi_addr   <= 24'hFE0100;
                    spi_wdata  <= 8'h00;
                    state      <= S_DR_ACK;
                end

                S_DR_SERVE_R: begin
                    // data_rdata is valid 1 clk after data_addr was set
                    rdata_q   <= data_rdata;
                    spi_req   <= 1'b1;
                    spi_rw    <= 1'b1;
                    spi_addr  <= 24'hFE0100;
                    spi_wdata <= data_rdata;
                    state     <= S_DR_ACK;
                end

                S_DR_ACK: if (spi_ack) begin
                    spi_req <= 1'b0;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
