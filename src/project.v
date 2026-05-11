`default_nettype none

// OCPU top-level (Tiny Tapeout wrapper) - OSPI slave mode
//
// The external FPGA is the OSPI master. It loads instruction pages into iRAM,
// services CPU data memory requests, and coordinates page switches.
//
// ── Pin map ──────────────────────────────────────────────────────────────────
//   uio_in[0]   = OSPI SCK      external master drives clock
//   uio_in[1]   = OSPI CS_N     external master drives chip-select
//   uio_in[7:0] = OSPI IO[7:0]  8-bit parallel data bus (master→slave on write,
//                                slave→master on read via uio_out/uio_oe)
//   uio_in[3]   = page_done     FPGA pulses high when new instruction page loaded
//   uio_in[4]   = page_loading  FPGA holds high while loading a page
//
// ── Output status flags (FPGA polls these) ───────────────────────────────────
//   uo_out[0]   = page_interrupt  1-cycle pulse after slot-15 instruction executes
//   uo_out[1]   = page_loading    echo of uio_in[4], confirms CPU is waiting
//   uo_out[2]   = is_halted       CPU stalled for any reason (page wait / data wait / HLT)
//   uo_out[3]   = data_req        CPU has a pending data memory transaction
//   uo_out[7:4] = 0
//
// ── OSPI address map (cmd 0x02 = write, 0x03 = read) ─────────────────────────
//   0x000000–0x000009  iRAM slots 0–9
//                        write: load instruction byte into slot addr[3:0]
//                        read:  return lower byte of slot addr[3:0]
//   0xFE0000            data_req read: {7'b0, cpu_mem_rw}
//   0xFE0001            data_req read: cpu_mem_addr[15:8]
//   0xFE0002            data_req read: cpu_mem_addr[7:0]
//   0xFE0003            data_req read: cpu_mem_wdata  (valid only on writes)
//   0xFE0100            data_req ack:  write rdata here to unblock CPU
//                        wdata byte → cpu_mem_rdata, pulses cpu_mem_ready 1 cycle
//   0xFD0000            dirty_bits[7:0]   slots 0–7  modified by CPU (SMOD)
//   0xFD0001            dirty_bits[9:8]   slots 8–9  modified by CPU (SMOD)
//   0xFF0000            page_reg read: current instruction page number

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
    output wire [3:0] dbg_pc,
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

    assign ospi_sck_i  = uio_in[0];
    assign ospi_cs_n_i = uio_in[1];
    assign ospi_io_i   = uio_in[7:0];

    assign uio_out = ospi_io_o;
    assign uio_oe  = ospi_io_oe;

    // -------------------------------------------------------------------------
    // iRAM regfile  (16 x 17-bit: bit[16]=dirty, bits[15:0]=instruction word)
    // Two write ports: OSPI slave (page load) and CPU (SMOD instruction)
    // Two read ports:  CPU (fetch by PC slot) and OSPI slave (readback)
    // -------------------------------------------------------------------------
    wire [3:0]  cpu_iram_rd_slot;
    wire [16:0] cpu_iram_rd_data;
    wire        cpu_iram_wr_en;
    wire [3:0]  cpu_iram_wr_slot;
    wire [15:0] cpu_iram_wr_data;
    wire [9:0] dirty_bits;       // bit N = slot N was written by CPU since last page load
    wire [15:0] pg_iram_rd_data; // OSPI readback port (FPGA can verify loaded instructions)

    iram_regfile iram (
        .clk         (clk),
        .rst_n       (rst_n),
        // OSPI write port: active when master writes to address 0x00000N (N=slot)
        .wr_pg_en    (ospi_mem_write && (ospi_mem_addr[23:4] == 20'h00000)),
        .wr_pg_slot  (ospi_mem_addr[3:0]),
        .wr_pg_data  ({ospi_mem_wdata, ospi_mem_wdata}),  // byte replicated to both halves
        // CPU write port (SMOD instruction modifies lower byte of a slot)
        .wr_cpu_en   (cpu_iram_wr_en),
        .wr_cpu_slot (cpu_iram_wr_slot),
        .wr_cpu_data (cpu_iram_wr_data),
        // CPU read port (fetch: slot = current PC)
        .rd_slot     (cpu_iram_rd_slot),
        .rd_data     (cpu_iram_rd_data),
        // dirty-bit vector output
        .dirty_bits  (dirty_bits),
        // OSPI readback port
        .rd_pg_slot  (ospi_mem_addr[3:0]),
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
    // page_interrupt is a 1-cycle pulse from CPU after slot-15 finishes executing.
    // -------------------------------------------------------------------------
    wire [7:0]  page_reg;        // from CPU: current page register value
    wire        page_interrupt;  // from CPU: slot-15 instruction just finished

    wire page_done    = uio_in[3];  // from FPGA: new page is loaded and ready
    wire page_loading = uio_in[4];  // from FPGA: page load is in progress

    // -------------------------------------------------------------------------
    // CPU data memory bus
    // CPU raises mem_req with addr/rw/wdata and stalls in ST_MEM_READ/WRITE.
    // project.v latches the request and exposes it via OSPI address 0xFE00xx.
    // FPGA reads the request, services external DRAM, then writes result to
    // 0xFE0100 which pulses cpu_mem_ready for one cycle to unblock the CPU.
    // -------------------------------------------------------------------------
    wire        cpu_mem_req;    // from CPU: memory transaction requested
    wire        cpu_mem_rw;     // from CPU: 0=read, 1=write
    wire [15:0] cpu_mem_addr;   // from CPU: target address
    wire [7:0]  cpu_mem_wdata;  // from CPU: write data (valid when rw=1)
    reg         cpu_mem_ready;  // to CPU:   1-cycle pulse to unblock
    reg  [7:0]  cpu_mem_rdata;  // to CPU:   read data (valid on ready pulse)

    // latched copy of the pending request (held until FPGA acks)
    reg         dmem_pending;
    reg         dmem_rw_lat;
    reg  [15:0] dmem_addr_lat;
    reg  [7:0]  dmem_wdata_lat;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_pending   <= 0;
            dmem_rw_lat    <= 0;
            dmem_addr_lat  <= 16'h0;
            dmem_wdata_lat <= 8'h0;
            cpu_mem_ready  <= 0;
            cpu_mem_rdata  <= 8'h0;
        end else begin
            cpu_mem_ready <= 0;  // default: deasserted; only high for one cycle on ack

            // latch request when CPU first raises mem_req (ignore while pending)
            if (cpu_mem_req && !dmem_pending) begin
                dmem_pending   <= 1;
                dmem_rw_lat    <= cpu_mem_rw;
                dmem_addr_lat  <= cpu_mem_addr;
                dmem_wdata_lat <= cpu_mem_wdata;
            end

            // FPGA acks by writing rdata to 0xFE0100 via OSPI
            if (ospi_mem_write && (ospi_mem_addr == 24'hFE0100)) begin
                cpu_mem_rdata <= ospi_mem_wdata;
                cpu_mem_ready <= 1;
                dmem_pending  <= 0;
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
                // iRAM readback: slot = addr[3:0], returns lower byte of instruction word
                24'h00000?: ospi_mem_rdata_out <= pg_iram_rd_data[7:0];

                // data memory request registers (FPGA reads to service the CPU)
                24'hFE0000: ospi_mem_rdata_out <= {7'b0, dmem_rw_lat};   // rw flag
                24'hFE0001: ospi_mem_rdata_out <= dmem_addr_lat[15:8];   // addr hi
                24'hFE0002: ospi_mem_rdata_out <= dmem_addr_lat[7:0];    // addr lo
                24'hFE0003: ospi_mem_rdata_out <= dmem_wdata_lat;        // write data

                // dirty bits: which iRAM slots were modified by CPU since last page load
                24'hFD0000: ospi_mem_rdata_out <= dirty_bits[7:0];       // slots 0-7
                24'hFD0001: ospi_mem_rdata_out <= {6'b0, dirty_bits[9:8]};  // slots 8-9

                // current instruction page number
                24'hFF0000: ospi_mem_rdata_out <= page_reg;

                default:    ospi_mem_rdata_out <= 8'hFF;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Status flags output to FPGA
    // FPGA polls uo_out to know when to act:
    //   [0] page_interrupt  — 1-cycle pulse, page swap needed (start loading next page)
    //   [1] page_loading    — echo of uio_in[4], confirms CPU is in page-wait state
    //   [2] is_halted       — CPU not making forward progress for any reason
    //   [3] data_req        — CPU waiting for a data memory transaction to be serviced
    // -------------------------------------------------------------------------
    assign uo_out[0] = page_interrupt;  // 1-cycle pulse: slot-15 executed, load next page
    assign uo_out[1] = page_loading;    // echo: asserted while CPU waits for page load
    assign uo_out[2] = is_halted;       // CPU stalled (page wait / data wait / HLT)
    assign uo_out[3] = dmem_pending;    // CPU has pending data memory request
    assign uo_out[7:4] = 4'b0;

    wire _unused = &{ena, ui_in};

endmodule
