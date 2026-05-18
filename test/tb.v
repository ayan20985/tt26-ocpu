`default_nettype none
`timescale 1ns / 1ps

// tb.v - cpu-validation testbench top
// =====================================
// this testbench wires ocpu_core and iram_regfile together exactly like
// project.v does, but it deliberately replaces ospi_memory with a simple
// "page loader + data memory" interface the cocotb driver can poke from
// python. that lets us focus on validating the cpu core (the actual goal
// of this round) without having to drive bytes through the OSPI slave on
// the chip, which currently has a pin-overlap quirk in project.v where
// uio_in[0]=SCK aliases io_i[0] and uio_in[1]=CS_N aliases io_i[1].
// that quirk affects the chip-level OSPI peripheral but does not affect
// the cpu core itself, so it does not block CPU validation.
//
// every signal the cocotb test wants to drive or observe is exposed as a
// wire/reg at this top level so the python side can do plain dut.<name>
// access without reaching into sub-hierarchies.

module tb;
    initial begin
        $dumpfile("tb.fst");
        $dumpvars(0, tb);
    end

    // -- clock / reset / run --
    reg clk;
    reg rst_n;
    reg run_enable;

    // -- page handshake driven by the cocotb fpga model --
    reg  page_done;
    reg  page_loading;
    wire page_interrupt;

    // -- iram write port from the page loader --
    reg         ext_iram_wr_en;
    reg [1:0]   ext_iram_wr_slot;
    reg [15:0]  ext_iram_wr_data;

    // -- iram wires shared with the cpu --
    wire [1:0]  cpu_iram_rd_slot;
    wire [15:0] cpu_iram_rd_data;
    wire        cpu_iram_wr_en;
    wire [1:0]  cpu_iram_wr_slot;
    wire [15:0] cpu_iram_wr_data;

    iram_regfile iram (
        .clk         (clk),
        .rst_n       (rst_n),
        // external (test fpga) write port
        .wr_pg_en    (ext_iram_wr_en),
        .wr_pg_slot  (ext_iram_wr_slot),
        .wr_pg_data  (ext_iram_wr_data),
        // cpu write port (SMOD)
        .wr_cpu_en   (cpu_iram_wr_en),
        .wr_cpu_slot (cpu_iram_wr_slot),
        .wr_cpu_data (cpu_iram_wr_data),
        // cpu read port
        .rd_slot     (cpu_iram_rd_slot),
        .rd_data     (cpu_iram_rd_data),
        // unused page-readback port (only project.v uses it for OSPI readback)
        .rd_pg_slot  (2'b0),
        .rd_pg_data  (/* unused */)
    );

    // -- cpu data memory bus driven by the cocotb data-mem model --
    wire        cpu_mem_req;
    wire        cpu_mem_rw;
    wire [15:0] cpu_mem_addr;
    wire [7:0]  cpu_mem_wdata;
    reg         cpu_mem_ready;
    reg  [7:0]  cpu_mem_rdata;

    // -- status flags --
    wire        is_halted;
    wire [7:0]  page_reg;

    ocpu_core cpu (
        .clk           (clk),
        .rst_n         (rst_n),
        .run_enable    (run_enable),
        .is_halted     (is_halted),
        // page handshake
        .page_done     (page_done),
        .page_loading  (page_loading),
        .page_interrupt(page_interrupt),
        // iram fetch port
        .iram_rd_slot  (cpu_iram_rd_slot),
        .iram_rd_data  (cpu_iram_rd_data),
        // iram write port (SMOD)
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
        // page register (output from cpu)
        .page_reg      (page_reg)
    );

endmodule
