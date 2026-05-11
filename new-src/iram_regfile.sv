`default_nettype none

// 8-slot instruction RAM (shrunk from 16 to save area for analog block).
// Each slot is 17 bits: {dirty, opcode[3:0], sub[3:0], imm8[7:0]}.
//
// Two write clients:
//   - external FPGA master writes slots during page-load via OSPI (wr_pg_en).
//   - cpu core writes individual slots (wr_cpu_en) and sets dirty=1.
//
// One read client: cpu core reads by slot index every cycle (combinational).
// FPGA also reads dirty_bits[7:0] for writeback scan via OSPI.
//
// Priority: page-load write wins over cpu write (cpu is halted during load anyway).

module iram_regfile (
    input  wire        clk,
    input  wire        rst_n,

    // page-load write port (driven by OSPI slave)
    input  wire        wr_pg_en,
    input  wire [2:0]  wr_pg_slot,
    input  wire [15:0] wr_pg_data,   // {opcode[3:0], sub[3:0], imm8[7:0]} dirty cleared

    // cpu write port (self-modifying / patching sets dirty=1)
    input  wire        wr_cpu_en,
    input  wire [2:0]  wr_cpu_slot,
    input  wire [15:0] wr_cpu_data,  // {opcode[3:0], sub[3:0], imm8[7:0]}

    // cpu read port (combinational)
    input  wire [2:0]  rd_slot,
    output wire [16:0] rd_data,      // {dirty, opcode[3:0], sub[3:0], imm8[7:0]}

    // dirty vector for writeback scan
    output wire [7:0]  dirty_bits,

    // page_controller read port for writeback
    input  wire [2:0]  rd_pg_slot,
    output wire [15:0] rd_pg_data    // instruction word (no dirty bit) for SPI writeback
);

    reg [16:0] mem [0:7]; // bit16=dirty, bits15:0=instruction

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 8; i = i + 1)
                mem[i] <= 17'h00000;
        end else begin
            if (wr_pg_en) begin
                // page load: clear dirty, write instruction word
                mem[wr_pg_slot] <= {1'b0, wr_pg_data};
            end else if (wr_cpu_en) begin
                // cpu patch: set dirty
                mem[wr_cpu_slot] <= {1'b1, wr_cpu_data};
            end
        end
    end

    assign rd_data    = mem[rd_slot];
    assign rd_pg_data = mem[rd_pg_slot][15:0];

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : gen_dirty
            assign dirty_bits[g] = mem[g][16];
        end
    endgenerate

endmodule
