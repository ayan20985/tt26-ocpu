`default_nettype none
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
	input wire [3:0] wr_pg_slot;
	input wire [15:0] wr_pg_data;
	input wire wr_cpu_en;
	input wire [3:0] wr_cpu_slot;
	input wire [15:0] wr_cpu_data;
	input wire [3:0] rd_slot;
	output wire [16:0] rd_data;
	output wire [9:0] dirty_bits;
	input wire [3:0] rd_pg_slot;
	output wire [15:0] rd_pg_data;
	reg [16:0] mem [0:9];
	integer i;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			for (i = 0; i < 10; i = i + 1)
				mem[i] <= 17'h00000;
		else if (wr_pg_en && (wr_pg_slot < 10))
			mem[wr_pg_slot] <= {1'b0, wr_pg_data};
		else if (wr_cpu_en && (wr_cpu_slot < 10))
			mem[wr_cpu_slot] <= {1'b1, wr_cpu_data};
	assign rd_data = (rd_slot < 10) ? mem[rd_slot] : 17'h00000;
	assign rd_pg_data = (rd_pg_slot < 10) ? mem[rd_pg_slot][15:0] : 16'h0000;
	genvar _gv_g_1;
	generate
		for (_gv_g_1 = 0; _gv_g_1 < 10; _gv_g_1 = _gv_g_1 + 1) begin : gen_dirty
			localparam g = _gv_g_1;
			assign dirty_bits[g] = mem[g][16];
		end
	endgenerate
endmodule
