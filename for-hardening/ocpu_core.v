`default_nettype none
module ocpu_core (
	clk,
	rst_n,
	run_enable,
	is_halted,
	dbg_a,
	dbg_x,
	dbg_y,
	dbg_sp,
	dbg_sr,
	dbg_ir,
	dbg_pc,
	out_pc,
	force_pc_en,
	force_pc_val,
	mem_req,
	mem_rw,
	mem_addr,
	mem_wdata,
	mem_ready,
	mem_rdata
);
	input wire clk;
	input wire rst_n;
	input wire run_enable;
	output wire is_halted;
	output wire [5:0] dbg_a;
	output wire [5:0] dbg_x;
	output wire [5:0] dbg_y;
	output wire [5:0] dbg_sp;
	output wire [5:0] dbg_sr;
	output wire [5:0] dbg_ir;
	output wire [15:0] dbg_pc;
	output wire [15:0] out_pc;
	input wire force_pc_en;
	input wire [15:0] force_pc_val;
	output reg mem_req;
	output reg mem_rw;
	output reg [15:0] mem_addr;
	output reg [5:0] mem_wdata;
	input wire mem_ready;
	input wire [5:0] mem_rdata;
	reg [5:0] a;
	reg [5:0] x;
	reg [5:0] y;
	reg [5:0] sp;
	reg [15:0] pc;
	reg [5:0] sr;
	reg [5:0] ir;
	reg [15:0] ea;
	reg [5:0] mdr;
	reg [15:0] memAddr;
	reg [5:0] t1;
	reg jsr_phase;
	localparam STATE_RESET = 5'd0;
	localparam STATE_FETCH = 5'd1;
	localparam STATE_DECODE = 5'd2;
	localparam STATE_OP1 = 5'd3;
	localparam STATE_OP2 = 5'd4;
	localparam STATE_IND_Y1 = 5'd5;
	localparam STATE_IND_Y2 = 5'd6;
	localparam STATE_MEM_READ = 5'd7;
	localparam STATE_MEM_WRITE = 5'd8;
	localparam STATE_EXECUTE = 5'd9;
	localparam STATE_PUSH = 5'd10;
	localparam STATE_POP = 5'd11;
	localparam STATE_HALTED = 5'd12;
	localparam [5:0] OP_LDA_IMM = 6'h00;
	localparam [5:0] OP_LDA_ABS = 6'h01;
	localparam [5:0] OP_LDA_ABS_X = 6'h02;
	localparam [5:0] OP_LDA_IND_Y = 6'h03;
	localparam [5:0] OP_LDX_IMM = 6'h04;
	localparam [5:0] OP_LDX_ABS = 6'h05;
	localparam [5:0] OP_LDY_IMM = 6'h06;
	localparam [5:0] OP_LDY_ABS = 6'h07;
	localparam [5:0] OP_STA_ABS = 6'h08;
	localparam [5:0] OP_STA_ABS_X = 6'h09;
	localparam [5:0] OP_STA_IND_Y = 6'h0a;
	localparam [5:0] OP_STX_ABS = 6'h0b;
	localparam [5:0] OP_STY_ABS = 6'h0c;
	localparam [5:0] OP_ADC_ABS = 6'h0d;
	localparam [5:0] OP_SBC_ABS = 6'h0e;
	localparam [5:0] OP_AND_ABS = 6'h0f;
	localparam [5:0] OP_EOR_ABS = 6'h10;
	localparam [5:0] OP_ORA_ABS = 6'h11;
	localparam [5:0] OP_ASL = 6'h12;
	localparam [5:0] OP_LSR = 6'h13;
	localparam [5:0] OP_INX = 6'h14;
	localparam [5:0] OP_DEX = 6'h15;
	localparam [5:0] OP_INY = 6'h16;
	localparam [5:0] OP_DEY = 6'h17;
	localparam [5:0] OP_TAX = 6'h18;
	localparam [5:0] OP_TXA = 6'h19;
	localparam [5:0] OP_TAY = 6'h1a;
	localparam [5:0] OP_TYA = 6'h1b;
	localparam [5:0] OP_SEC = 6'h1c;
	localparam [5:0] OP_CLC = 6'h1d;
	localparam [5:0] OP_SEI = 6'h1e;
	localparam [5:0] OP_CLI = 6'h1f;
	localparam [5:0] OP_JMP = 6'h20;
	localparam [5:0] OP_JSR = 6'h21;
	localparam [5:0] OP_RTS = 6'h22;
	localparam [5:0] OP_RTI = 6'h23;
	localparam [5:0] OP_PHA = 6'h24;
	localparam [5:0] OP_PLA = 6'h25;
	localparam [5:0] OP_BEQ = 6'h26;
	localparam [5:0] OP_BNE = 6'h27;
	localparam [5:0] OP_BCS = 6'h28;
	localparam [5:0] OP_BCC = 6'h29;
	reg [4:0] state;
	assign is_halted = state == STATE_HALTED;
	assign out_pc = pc;
	assign dbg_a = a;
	assign dbg_x = x;
	assign dbg_y = y;
	assign dbg_sp = sp;
	assign dbg_sr = sr;
	assign dbg_ir = ir;
	assign dbg_pc = pc;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= STATE_RESET;
			a <= 0;
			x <= 0;
			y <= 0;
			sp <= 6'h3f;
			pc <= 16'h0000;
			sr <= 6'h00;
			ir <= 0;
			mem_req <= 0;
			mem_rw <= 0;
			ea <= 0;
			mdr <= 0;
			memAddr <= 0;
			t1 <= 0;
			jsr_phase <= 0;
		end
		else if (force_pc_en) begin
			pc <= force_pc_val;
			state <= STATE_FETCH;
		end
		else
			case (state)
				STATE_RESET:
					if (run_enable)
						state <= STATE_FETCH;
				STATE_FETCH:
					if (mem_ready && mem_req) begin
						ir <= mem_rdata;
						mem_req <= 0;
						pc <= pc + 1;
						state <= STATE_DECODE;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= pc;
					end
				STATE_DECODE:
					case (ir)
						OP_LDA_IMM, OP_LDX_IMM, OP_LDY_IMM, OP_BEQ, OP_BNE, OP_BCS, OP_BCC: state <= STATE_OP1;
						OP_LDA_ABS, OP_LDX_ABS, OP_LDY_ABS, OP_STA_ABS, OP_STX_ABS, OP_STY_ABS, OP_ADC_ABS, OP_SBC_ABS, OP_AND_ABS, OP_EOR_ABS, OP_ORA_ABS, OP_JMP, OP_JSR: state <= STATE_OP1;
						OP_LDA_ABS_X, OP_STA_ABS_X: state <= STATE_OP1;
						OP_LDA_IND_Y, OP_STA_IND_Y: state <= STATE_OP1;
						OP_ASL, OP_LSR, OP_INX, OP_DEX, OP_INY, OP_DEY, OP_TAX, OP_TXA, OP_TAY, OP_TYA, OP_SEC, OP_CLC, OP_SEI, OP_CLI, OP_RTS, OP_RTI: state <= STATE_EXECUTE;
						OP_PHA, OP_PLA: state <= STATE_EXECUTE;
						default: state <= STATE_FETCH;
					endcase
				STATE_OP1:
					if (mem_ready && mem_req) begin
						ea <= {10'h000, mem_rdata};
						mem_req <= 0;
						pc <= pc + 1;
						if (((((((ir == OP_LDA_IMM) || (ir == OP_LDX_IMM)) || (ir == OP_LDY_IMM)) || (ir == OP_BEQ)) || (ir == OP_BNE)) || (ir == OP_BCS)) || (ir == OP_BCC))
							state <= STATE_EXECUTE;
						else if ((ir == OP_LDA_IND_Y) || (ir == OP_STA_IND_Y))
							state <= STATE_IND_Y1;
						else
							state <= STATE_OP2;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= pc;
					end
				STATE_OP2:
					if (mem_ready && mem_req) begin
						mem_req <= 0;
						pc <= pc + 1;
						if ((ir == OP_LDA_ABS_X) || (ir == OP_STA_ABS_X))
							ea <= {mem_rdata, ea[5:0]} + x;
						else
							ea <= {mem_rdata, ea[5:0]};
						if ((ir == OP_JMP) || (ir == OP_JSR))
							state <= STATE_EXECUTE;
						else if (((((ir == OP_STA_ABS) || (ir == OP_STA_ABS_X)) || (ir == OP_STA_IND_Y)) || (ir == OP_STX_ABS)) || (ir == OP_STY_ABS)) begin
							memAddr <= ((ir == OP_LDA_ABS_X) || (ir == OP_STA_ABS_X) ? {mem_rdata, ea[5:0]} + x : {mem_rdata, ea[5:0]});
							state <= STATE_MEM_WRITE;
						end
						else begin
							memAddr <= ((ir == OP_LDA_ABS_X) || (ir == OP_STA_ABS_X) ? {mem_rdata, ea[5:0]} + x : {mem_rdata, ea[5:0]});
							state <= STATE_MEM_READ;
						end
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= pc;
					end
				STATE_IND_Y1:
					if (mem_ready && mem_req) begin
						mem_req <= 0;
						t1 <= mem_rdata;
						ea[5:0] <= ea[5:0] + 1;
						state <= STATE_IND_Y2;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= {10'h000, ea[5:0]};
					end
				STATE_IND_Y2:
					if (mem_ready && mem_req) begin
						mem_req <= 0;
						ea <= {mem_rdata, t1} + y;
						memAddr <= {mem_rdata, t1} + y;
						if (ir == OP_STA_IND_Y)
							state <= STATE_MEM_WRITE;
						else
							state <= STATE_MEM_READ;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= {10'h000, ea[5:0]};
					end
				STATE_MEM_READ:
					if (mem_ready && mem_req) begin
						mem_req <= 0;
						mdr <= mem_rdata;
						state <= STATE_EXECUTE;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= memAddr;
					end
				STATE_MEM_WRITE:
					if (mem_ready && mem_req) begin
						mem_req <= 0;
						mem_rw <= 0;
						state <= STATE_FETCH;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 1;
						mem_addr <= memAddr;
						if (((ir == OP_STA_ABS) || (ir == OP_STA_ABS_X)) || (ir == OP_STA_IND_Y))
							mem_wdata <= a;
						else if (ir == OP_STX_ABS)
							mem_wdata <= x;
						else if (ir == OP_STY_ABS)
							mem_wdata <= y;
					end
				STATE_EXECUTE: begin
					case (ir)
						OP_LDA_IMM: begin
							a <= ea[5:0];
							sr[1] <= ea[5:0] == 0;
						end
						OP_LDA_ABS, OP_LDA_ABS_X, OP_LDA_IND_Y: begin
							a <= mdr;
							sr[1] <= mdr == 0;
						end
						OP_LDX_IMM: begin
							x <= ea[5:0];
							sr[1] <= ea[5:0] == 0;
						end
						OP_LDX_ABS: begin
							x <= mdr;
							sr[1] <= mdr == 0;
						end
						OP_LDY_IMM: begin
							y <= ea[5:0];
							sr[1] <= ea[5:0] == 0;
						end
						OP_LDY_ABS: begin
							y <= mdr;
							sr[1] <= mdr == 0;
						end
						OP_ADC_ABS: begin : sv2v_autoblock_1
							reg [6:0] adc_result;
							adc_result = (a + mdr) + sr[0];
							{sr[0], a} <= adc_result;
							sr[1] <= adc_result[5:0] == 0;
						end
						OP_SBC_ABS: begin : sv2v_autoblock_2
							reg [6:0] sbc_result;
							sbc_result = (a - mdr) - ~sr[0];
							{sr[0], a} <= sbc_result;
							sr[1] <= sbc_result[5:0] == 0;
						end
						OP_AND_ABS: begin : sv2v_autoblock_3
							reg [5:0] and_result;
							and_result = a & mdr;
							a <= and_result;
							sr[1] <= and_result == 0;
						end
						OP_EOR_ABS: begin : sv2v_autoblock_4
							reg [5:0] eor_result;
							eor_result = a ^ mdr;
							a <= eor_result;
							sr[1] <= eor_result == 0;
						end
						OP_ORA_ABS: begin : sv2v_autoblock_5
							reg [5:0] ora_result;
							ora_result = a | mdr;
							a <= ora_result;
							sr[1] <= ora_result == 0;
						end
						OP_ASL: begin : sv2v_autoblock_6
							reg [5:0] asl_result;
							asl_result = {a[4:0], 1'b0};
							sr[0] <= a[5];
							a <= asl_result;
							sr[1] <= asl_result == 0;
						end
						OP_LSR: begin : sv2v_autoblock_7
							reg [5:0] lsr_result;
							lsr_result = {1'b0, a[5:1]};
							sr[0] <= a[0];
							a <= lsr_result;
							sr[1] <= lsr_result == 0;
						end
						OP_INX: begin : sv2v_autoblock_8
							reg [5:0] inx_result;
							inx_result = x + 1;
							x <= inx_result;
							sr[1] <= inx_result == 0;
						end
						OP_DEX: begin : sv2v_autoblock_9
							reg [5:0] dex_result;
							dex_result = x - 1;
							x <= dex_result;
							sr[1] <= dex_result == 0;
						end
						OP_INY: begin : sv2v_autoblock_10
							reg [5:0] iny_result;
							iny_result = y + 1;
							y <= iny_result;
							sr[1] <= iny_result == 0;
						end
						OP_DEY: begin : sv2v_autoblock_11
							reg [5:0] dey_result;
							dey_result = y - 1;
							y <= dey_result;
							sr[1] <= dey_result == 0;
						end
						OP_TAX: begin
							x <= a;
							sr[1] <= a == 0;
						end
						OP_TXA: begin
							a <= x;
							sr[1] <= x == 0;
						end
						OP_TAY: begin
							y <= a;
							sr[1] <= a == 0;
						end
						OP_TYA: begin
							a <= y;
							sr[1] <= y == 0;
						end
						OP_SEC: sr[0] <= 1;
						OP_CLC: sr[0] <= 0;
						OP_SEI: sr[2] <= 1;
						OP_CLI: sr[2] <= 0;
						OP_JMP: pc <= ea;
						OP_BEQ:
							if (sr[1])
								pc <= pc + {{10 {ea[5]}}, ea[5:0]};
						OP_BNE:
							if (!sr[1])
								pc <= pc + {{10 {ea[5]}}, ea[5:0]};
						OP_BCS:
							if (sr[0])
								pc <= pc + {{10 {ea[5]}}, ea[5:0]};
						OP_BCC:
							if (!sr[0])
								pc <= pc + {{10 {ea[5]}}, ea[5:0]};
						OP_JSR: begin
							state <= STATE_PUSH;
							t1 <= (pc - 16'd1) >> 6;
							jsr_phase <= 0;
						end
						OP_RTS: begin
							state <= STATE_POP;
							t1 <= 0;
						end
						OP_PHA: begin
							state <= STATE_PUSH;
							t1 <= a;
						end
						OP_PLA: state <= STATE_POP;
						default:
							;
					endcase
					if ((((ir != OP_JSR) && (ir != OP_RTS)) && (ir != OP_PHA)) && (ir != OP_PLA))
						state <= (!run_enable ? STATE_HALTED : STATE_FETCH);
				end
				STATE_PUSH:
					if (mem_ready && mem_req) begin
						sp <= sp - 1;
						mem_req <= 0;
						mem_rw <= 0;
						if ((ir == OP_JSR) && !jsr_phase) begin
							t1 <= (pc - 16'd1) & 16'h003f;
							jsr_phase <= 1;
						end
						else if (ir == OP_JSR) begin
							pc <= ea;
							state <= STATE_FETCH;
						end
						else
							state <= STATE_FETCH;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 1;
						mem_addr <= {10'h001, sp};
						mem_wdata <= t1;
					end
				STATE_POP:
					if (mem_ready && mem_req) begin
						sp <= sp + 1;
						mem_req <= 0;
						if (ir == OP_PLA) begin
							a <= mem_rdata;
							sr[1] <= mem_rdata == 0;
							state <= STATE_FETCH;
						end
						else if ((ir == OP_RTS) && (t1 == 0)) begin
							t1 <= mem_rdata;
							state <= STATE_POP;
						end
						else if (ir == OP_RTS) begin
							pc <= {mem_rdata, t1} + 1;
							state <= STATE_FETCH;
						end
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= {10'h001, sp + 6'd1};
					end
				STATE_HALTED:
					if (run_enable)
						state <= STATE_FETCH;
				default: state <= STATE_FETCH;
			endcase
endmodule
