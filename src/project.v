`default_nettype none

// OCPU top-level (Tiny Tapeout wrapper) - OSPI slave mode
//
// The external FPGA is the OSPI master. It loads instruction pages into iRAM,
// services CPU data memory requests, and coordinates page switches.
//
// ── Pin map ──────────────────────────────────────────────────────────────────
// the four control signals (SCK, CS_N, page_done, page_loading) live on the
// dedicated input bank (ui_in) so they cannot alias the bidirectional OSPI
// data bus (uio_in / uio_out / uio_oe). this matters because the OSPI slave
// samples io_i on every SCK rising edge - if SCK shared a bit with io_i,
// the master could never transmit a byte whose value differed from "SCK
// asserted high", which on the old map made it impossible to send the
// write command (0x02). same story for CS_N and the two FPGA->CPU page
// handshake pulses.
//
//   ui_in[0]    = OSPI SCK         external master drives clock
//   ui_in[1]    = OSPI CS_N        external master drives chip-select (active low)
//   ui_in[2]    = page_done        FPGA pulses high when new instruction page loaded
//   ui_in[3]    = page_loading     FPGA holds high while loading a page
//   ui_in[7:4]  = reserved (tied unused on the chip; pull-down on FPGA side)
//
//   uio_in[7:0]  = OSPI IO_I[7:0]  8-bit parallel data, master -> slave on write
//   uio_out[7:0] = OSPI IO_O[7:0]  8-bit parallel data, slave -> master on read
//   uio_oe[7:0]  = OSPI IO_OE      slave drives outputs only during read-data byte
//
// ── Output status flags (FPGA polls these) ───────────────────────────────────
//   uo_out[0]   = page_interrupt  1-cycle pulse after last-slot instruction executes
//   uo_out[1]   = page_loading    echo of ui_in[3], confirms CPU is waiting
//   uo_out[2]   = is_halted       CPU stalled for any reason (page wait / data wait / HLT)
//   uo_out[3]   = data_req        CPU has a pending data memory transaction
//   uo_out[7:4] = 0
//
// ── OSPI address map (cmd 0x02 = write, 0x03 = read) ─────────────────────────
//   0x000000–0x000007  iRAM slot bytes. each slot stores a 16-bit instruction
//                        word as two OSPI-addressable bytes:
//                          addr[2:1] = slot index (0..3)
//                          addr[0]   = 0 -> LOW byte (bits 7:0  / immediate)
//                                      1 -> HIGH byte (bits 15:8 / opcode+sub)
//                        a full instruction load is two writes: first the LOW
//                        byte (latched internally), then the HIGH byte
//                        (commits the full 16-bit word into the iRAM slot in
//                        the same cycle). reads are byte-granular and
//                        return either half directly.
//   0xFE0000            data_req read: {7'b0, cpu_mem_rw}
//   0xFE0001            data_req read: cpu_mem_addr[15:8]
//   0xFE0002            data_req read: cpu_mem_addr[7:0]
//   0xFE0003            data_req read: cpu_mem_wdata  (valid only on writes)
//   0xFE0100            data_req ack:  write rdata here to unblock CPU
//                        wdata byte → cpu_mem_rdata, pulses cpu_mem_ready 1 cycle
//   0xFF0000            page_reg read: current instruction page number
//
// NOTE: the formerly-supported 0xFD0000 dirty-bits readback has been removed
// to save area. the FPGA-side reference implementation must now write back
// every iRAM slot unconditionally on a page swap; this reclaims FFs and
// removes a multi-bit broadcast that was contributing to routing congestion.

module tt_um_ocpu (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
`ifdef OCPU_SIM
    ,
    output wire [7:0] dbg_a,
    output wire [7:0] dbg_x,
    output wire [7:0] dbg_y,
    output wire [7:0] dbg_sp,
    output wire [7:0] dbg_sr,
    output wire [7:0] dbg_ir,
    output wire [1:0] dbg_pc,
    output wire [7:0] dbg_page
`endif
);

    // -------------------------------------------------------------------------
    // OSPI slave pins
    // uio is bidirectional: master drives in, slave drives out via uio_out/uio_oe
    // -------------------------------------------------------------------------
    wire [7:0] ospi_io_i;
    wire [7:0] ospi_io_o;
    wire [7:0] ospi_io_oe;
    wire       ospi_sck_i;
    wire       ospi_cs_n_i;

    // control signals on the dedicated input bank (do NOT alias the data bus)
    assign ospi_sck_i  = ui_in[0];
    assign ospi_cs_n_i = ui_in[1];
    // data bus on the bidirectional bank. uio_in carries master-driven payload
    // bytes on writes (and reads, where the master still drives 4 transfer
    // bytes before tri-stating for the slave to drive byte 4).
    assign ospi_io_i   = uio_in[7:0];

    assign uio_out = ospi_io_o;
    assign uio_oe  = ospi_io_oe;

    // -------------------------------------------------------------------------
    // iRAM regfile  (4 x 16-bit instruction word)
    // Two write ports: OSPI slave (page load) and CPU (SMOD instruction)
    // Two read ports:  CPU (fetch by PC slot) and OSPI slave (readback)
    // -------------------------------------------------------------------------
    wire [1:0]  cpu_iram_rd_slot;
    wire [15:0] cpu_iram_rd_data;
    wire        cpu_iram_wr_en;
    wire [1:0]  cpu_iram_wr_slot;
    wire [15:0] cpu_iram_wr_data;
    wire [15:0] pg_iram_rd_data; // OSPI readback port (FPGA can verify loaded instructions)

    // OSPI loads a full 16-bit instruction word in two OSPI byte writes.
    // address[0]=0 writes the LO byte (latched here without touching iRAM),
    // address[0]=1 writes the HI byte and commits {hi, lo_latch} into the
    // iRAM slot indexed by address[2:1]. valid iRAM range is now
    // 0x000000..0x000007 (4 slots * 2 bytes).
    reg [7:0] iram_lo_latch;
    wire iram_addr_match = (ospi_mem_addr[23:3] == 21'h000000);  // 0x000000..0x000007
    wire iram_wr_lo = ospi_mem_write && iram_addr_match && (ospi_mem_addr[0] == 1'b0);
    wire iram_wr_hi = ospi_mem_write && iram_addr_match && (ospi_mem_addr[0] == 1'b1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) iram_lo_latch <= 8'h0;
        else if (iram_wr_lo) iram_lo_latch <= ospi_mem_wdata;
    end

    iram_regfile iram (
        .clk         (clk),
        .rst_n       (rst_n),
        // OSPI write port: commits on the HI-byte write of each slot.
        // wr_pg_data = {hi, lo_latch} reconstructs the full 16-bit word.
        .wr_pg_en    (iram_wr_hi),
        .wr_pg_slot  (ospi_mem_addr[2:1]),
        .wr_pg_data  ({ospi_mem_wdata, iram_lo_latch}),
        // CPU write port (SMOD instruction modifies lower byte of a slot)
        .wr_cpu_en   (cpu_iram_wr_en),
        .wr_cpu_slot (cpu_iram_wr_slot),
        .wr_cpu_data (cpu_iram_wr_data),
        // CPU read port (fetch: slot = current PC)
        .rd_slot     (cpu_iram_rd_slot),
        .rd_data     (cpu_iram_rd_data),
        // OSPI readback port. note slot index is addr[2:1]; the LO/HI byte
        // selection happens in the rdata-mux below using addr[0].
        .rd_pg_slot  (ospi_mem_addr[2:1]),
        .rd_pg_data  (pg_iram_rd_data)
    );

    // -------------------------------------------------------------------------
    // OSPI slave interface
    // Decodes 5-byte transactions: [cmd | addr_hi | addr_mid | addr_lo | data]
    // Pulses mem_write or mem_read for one cycle when transaction completes
    // -------------------------------------------------------------------------
    wire [23:0] ospi_mem_addr;
    wire [7:0]  ospi_mem_wdata;
    wire        ospi_mem_write;  // pulse: write transaction completed
    wire        ospi_mem_read;   // pulse: read transaction completed (rdata must be pre-loaded)

    reg [7:0] ospi_mem_rdata_out;  // registered read data returned to master

    ospi_memory ospi_slave (
        .clk       (clk),
        .rst_n     (rst_n),
        .sck       (ospi_sck_i),
        .cs_n      (ospi_cs_n_i),
        .io_i      (ospi_io_i),
        .io_o      (ospi_io_o),
        .io_oe     (ospi_io_oe),
        .mem_addr  (ospi_mem_addr),
        .mem_wdata (ospi_mem_wdata),
        .mem_rdata (ospi_mem_rdata_out),
        .mem_write (ospi_mem_write),
        .mem_read  (ospi_mem_read)
    );

    // -------------------------------------------------------------------------
    // Page handshake
    // CPU drives page_req/page_next when it needs a new instruction page loaded.
    // FPGA responds by asserting page_loading (ack) then page_done (complete).
    // page_interrupt is a 1-cycle pulse from CPU after slot-7 finishes executing.
    // -------------------------------------------------------------------------
    wire [7:0]  page_reg;        // from CPU: current page register value
    wire        page_interrupt;  // from CPU: last-slot instruction just finished

    // page handshake also lives on the dedicated input bank to keep it
    // independent of the OSPI data bus traffic.
    wire page_done    = ui_in[2];  // from FPGA: new page is loaded and ready
    wire page_loading = ui_in[3];  // from FPGA: page load is in progress

    // -------------------------------------------------------------------------
    // CPU data memory bus
    // CPU raises mem_req with addr/rw/wdata and stalls in ST_MEM_READ/WRITE.
    // While stalled the CPU holds those signals steady, so we expose them
    // directly to the FPGA via OSPI reads (no latches needed).
    // FPGA acks the transaction by OSPI-writing the read data to 0xFE0100,
    // which pulses cpu_mem_ready for one cycle and latches cpu_mem_rdata.
    // -------------------------------------------------------------------------
    wire        cpu_mem_req;    // from CPU: memory transaction requested
    wire        cpu_mem_rw;     // from CPU: 0=read, 1=write
    wire [15:0] cpu_mem_addr;   // from CPU: target address
    wire [7:0]  cpu_mem_wdata;  // from CPU: write data (valid when rw=1)
    reg         cpu_mem_ready;  // to CPU:   1-cycle pulse to unblock
    reg  [7:0]  cpu_mem_rdata;  // to CPU:   read data (valid on ready pulse)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_mem_ready <= 0;
            cpu_mem_rdata <= 8'h0;
        end else begin
            cpu_mem_ready <= 0;  // default deasserted; one-cycle pulse on FPGA ack

            // FPGA acks by writing rdata to 0xFE0100 via OSPI
            if (ospi_mem_write && (ospi_mem_addr == 24'hFE0100)) begin
                cpu_mem_rdata <= ospi_mem_wdata;
                cpu_mem_ready <= 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // ocpu_core
    // -------------------------------------------------------------------------
    wire is_halted;  // from CPU: stalled (page wait / data wait / HLT)

    ocpu_core cpu (
        .clk           (clk),
        .rst_n         (rst_n),
        .run_enable    (1'b1),
        .is_halted     (is_halted),
        // page handshake
        .page_done     (page_done),
        .page_loading  (page_loading),
        .page_interrupt(page_interrupt),
        // iRAM fetch port
        .iram_rd_slot  (cpu_iram_rd_slot),
        .iram_rd_data  (cpu_iram_rd_data),
        // iRAM write port (SMOD instruction)
        .iram_wr_en    (cpu_iram_wr_en),
        .iram_wr_slot  (cpu_iram_wr_slot),
        .iram_wr_data  (cpu_iram_wr_data),
        // data memory bus
        .mem_req       (cpu_mem_req),
        .mem_rw        (cpu_mem_rw),
        .mem_addr      (cpu_mem_addr),
        .mem_wdata     (cpu_mem_wdata),
        .mem_ready     (cpu_mem_ready),
        .mem_rdata     (cpu_mem_rdata),
        // page register (read-only output, CPU owns this)
        .page_reg      (page_reg)
    );

    // -------------------------------------------------------------------------
    // OSPI read mux
    // Registered one cycle after mem_read pulse (OSPI master must tolerate 1-cycle
    // read latency, which the ospi_memory module already accounts for).
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ospi_mem_rdata_out <= 8'h00;
        end else if (ospi_mem_read) begin
            casez (ospi_mem_addr)
                // iRAM readback: addr 0x000000-0x000007.
                //   addr[2:1] = slot, addr[0] = lo (0) / hi (1) byte select
                24'b0000_0000_0000_0000_0000_0???:
                    ospi_mem_rdata_out <= ospi_mem_addr[0]
                                          ? pg_iram_rd_data[15:8]
                                          : pg_iram_rd_data[7:0];

                // data memory request signals (CPU drives these live while stalled)
                24'hFE0000: ospi_mem_rdata_out <= {7'b0, cpu_mem_rw};    // rw flag
                24'hFE0001: ospi_mem_rdata_out <= cpu_mem_addr[15:8];    // addr hi
                24'hFE0002: ospi_mem_rdata_out <= cpu_mem_addr[7:0];     // addr lo
                24'hFE0003: ospi_mem_rdata_out <= cpu_mem_wdata;         // write data

                // (0xFD0000 dirty_bits register was here. removed for area;
                // FPGA-side writeback is now unconditional - see header.)

                // current instruction page number
                24'hFF0000: ospi_mem_rdata_out <= page_reg;

                default:    ospi_mem_rdata_out <= 8'hFF;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Status flags output to FPGA
    // FPGA polls uo_out to know when to act:
    //   [0] page_interrupt  - 1-cycle pulse, page swap needed (start loading next page)
    //   [1] page_loading    - echo of uio_in[4], confirms CPU is in page-wait state
    //   [2] is_halted       - CPU not making forward progress for any reason
    //   [3] data_req        - CPU waiting for a data memory transaction to be serviced
    // -------------------------------------------------------------------------
    assign uo_out[0] = page_interrupt;  // 1-cycle pulse: last slot executed, load next page
    assign uo_out[1] = page_loading;    // echo: asserted while CPU waits for page load
    assign uo_out[2] = is_halted;       // CPU stalled (page wait / data wait / HLT)
    assign uo_out[3] = cpu_mem_req;     // CPU has pending data memory request
    assign uo_out[7:4] = 4'b0;

    // ui_in[0..3] are the OSPI control + page handshake signals (consumed
    // above). ui_in[7:4] are reserved for future use; tie-off so synthesis
    // does not warn.
    wire _unused = &{ena, ui_in[7:4]};

endmodule
