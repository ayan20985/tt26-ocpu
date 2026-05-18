`default_nettype none

// 8-slot instruction RAM (shrunk from 16 to save area for analog block).
// Each slot is 17 bits: {dirty, opcode[3:0], sub[3:0], imm8[7:0]}.

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
	dirty_bits,
	rd_pg_slot,
	rd_pg_data
);
	input wire clk;
	input wire rst_n;
	input wire wr_pg_en;
	input wire [2:0] wr_pg_slot;
	input wire [15:0] wr_pg_data;
	input wire wr_cpu_en;
	input wire [2:0] wr_cpu_slot;
	input wire [15:0] wr_cpu_data;
	input wire [2:0] rd_slot;
	output wire [16:0] rd_data;
	output wire [7:0] dirty_bits;
	input wire [2:0] rd_pg_slot;
	output wire [15:0] rd_pg_data;

	reg [16:0] mem [0:7];
	integer i;

	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			for (i = 0; i < 8; i = i + 1)
				mem[i] <= 17'h00000;
		else if (wr_pg_en)
			mem[wr_pg_slot] <= {1'b0, wr_pg_data};
		else if (wr_cpu_en)
			mem[wr_cpu_slot] <= {1'b1, wr_cpu_data};

	assign rd_data    = mem[rd_slot];
	assign rd_pg_data = mem[rd_pg_slot][15:0];

	genvar g;
	generate
		for (g = 0; g < 8; g = g + 1) begin : gen_dirty
			assign dirty_bits[g] = mem[g][16];
		end
	endgenerate
endmodule
