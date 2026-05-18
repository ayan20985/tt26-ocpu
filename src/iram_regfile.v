`default_nettype none

// 4-slot instruction RAM (shrunk from 8 to relieve routing pressure on
// the 1x2 die). each slot is 16 bits: {opcode[3:0], sub[3:0], imm8[7:0]}.
//
// the per-slot dirty bit (formerly bit 16 of each slot) was removed.
// dropping it saves 4 FFs across the file plus their broadcast muxing
// into the OSPI readback path; the external FPGA now writes back every
// iRAM slot on a page swap unconditionally instead of doing a dirty
// scan first. the extra OSPI writeback bytes per swap are negligible
// compared to the place-and-route headroom this buys.

module iram_regfile (
	clk,
	rst_n,
	wr_pg_en,
	wr_pg_slot,
	wr_pg_data,
	wr_cpu_en,
	wr_cpu_slot,
	wr_cpu_data,
	rd_slot,
	rd_data,
	rd_pg_slot,
	rd_pg_data
);
	// page geometry. change SLOT_BITS to resize the iRAM in one place;
	// SLOTS_PER_PAGE is derived from SLOT_BITS so the two stay consistent.
	localparam integer SLOT_BITS      = 2;
	localparam integer SLOTS_PER_PAGE = 1 << SLOT_BITS;

	input  wire                  clk;
	input  wire                  rst_n;
	input  wire                  wr_pg_en;
	input  wire [SLOT_BITS-1:0]  wr_pg_slot;
	input  wire [15:0]           wr_pg_data;
	input  wire                  wr_cpu_en;
	input  wire [SLOT_BITS-1:0]  wr_cpu_slot;
	input  wire [15:0]           wr_cpu_data;
	input  wire [SLOT_BITS-1:0]  rd_slot;
	output wire [15:0]           rd_data;
	input  wire [SLOT_BITS-1:0]  rd_pg_slot;
	output wire [15:0]           rd_pg_data;

	reg [15:0] mem [0:SLOTS_PER_PAGE-1];
	integer i;

	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			for (i = 0; i < SLOTS_PER_PAGE; i = i + 1)
				mem[i] <= 16'h0000;
		else if (wr_pg_en)
			mem[wr_pg_slot] <= wr_pg_data;
		else if (wr_cpu_en)
			mem[wr_cpu_slot] <= wr_cpu_data;

	assign rd_data    = mem[rd_slot];
	assign rd_pg_data = mem[rd_pg_slot];
endmodule
