`default_nettype none
module ocpu_core (
	clk,
	rst_n,
	run_enable,
	is_halted,
	page_done,
	page_loading,
	page_interrupt,
	iram_rd_slot,
	iram_rd_data,
	iram_wr_en,
	iram_wr_slot,
	iram_wr_data,
	mem_req,
	mem_rw,
	mem_addr,
	mem_wdata,
	mem_ready,
	mem_rdata,
	page_reg
);
	input wire clk;
	input wire rst_n;
	input wire run_enable;
	output wire is_halted;
	input wire page_done;
	input wire page_loading;
	output wire page_interrupt;  // pulse: page boundary reached (PC==9)
	output wire [3:0] iram_rd_slot;
	input wire [16:0] iram_rd_data;
	output reg iram_wr_en;
	output reg [3:0] iram_wr_slot;
	output reg [15:0] iram_wr_data;
	output reg mem_req;
	output reg mem_rw;
	output reg [15:0] mem_addr;
	output reg [7:0] mem_wdata;
	input wire mem_ready;
	input wire [7:0] mem_rdata;
	output reg [7:0] page_reg;
	reg [7:0] a;
	reg [7:0] x;
	reg [7:0] y;
	reg [7:0] sp;
	reg [4:0] sr;  // reduced: [4]=I, [3]=unused, [2]=N, [1]=Z, [0]=C
	reg [3:0] pc;
	reg [7:0] data_page;
	reg [3:0] ir_op;
	reg [3:0] ir_sub;
	reg [7:0] ir_imm;
	reg [7:0] mdr;
	reg [15:0] eff_addr;
	reg [7:0] t1;
	localparam [3:0] OP_LDA = 4'h0;
	localparam [3:0] OP_STA = 4'h1;
	localparam [3:0] OP_LDX = 4'h2;
	localparam [3:0] OP_LDY = 4'h3;
	localparam [3:0] OP_STX = 4'h4;
	localparam [3:0] OP_STY = 4'h5;
	localparam [3:0] OP_ALU = 4'h6;
	localparam [3:0] OP_BR = 4'h7;
	localparam [3:0] OP_JMP = 4'h8;
	localparam [3:0] OP_JSR = 4'h9;
	localparam [3:0] OP_RTS = 4'ha;
	localparam [3:0] OP_FARJMP = 4'hb;
	localparam [3:0] OP_REG = 4'hc;
	localparam [3:0] OP_LDSP = 4'hd;
	localparam [3:0] OP_SMOD = 4'he;
	localparam [3:0] OP_SYS = 4'hf;
	localparam [3:0] ALU_ADD = 4'h0;
	localparam [3:0] ALU_ADC = 4'h1;
	localparam [3:0] ALU_SUB = 4'h2;
	localparam [3:0] ALU_SBC = 4'h3;
	localparam [3:0] ALU_AND = 4'h4;
	localparam [3:0] ALU_ORA = 4'h5;
	localparam [3:0] ALU_EOR = 4'h6;
	localparam [3:0] ALU_CMP = 4'h7;
	localparam [3:0] ALU_ASL = 4'h8;
	localparam [3:0] ALU_LSR = 4'h9;
	localparam [3:0] REG_TAX = 4'h0;
	localparam [3:0] REG_TXA = 4'h1;
	localparam [3:0] REG_TAY = 4'h2;
	localparam [3:0] REG_TYA = 4'h3;
	localparam [3:0] REG_INX = 4'h4;
	localparam [3:0] REG_DEX = 4'h5;
	localparam [3:0] REG_INY = 4'h6;
	localparam [3:0] REG_DEY = 4'h7;
	localparam [3:0] REG_PHA = 4'h8;
	localparam [3:0] REG_PLA = 4'h9;
	localparam [3:0] REG_TSX = 4'ha;
	localparam [3:0] REG_TXS = 4'hb;
	localparam [3:0] REG_NOP = 4'hf;
	localparam [3:0] LDSP_LDA_DP = 4'h0;
	localparam [3:0] LDSP_STA_DP = 4'h1;
	localparam [3:0] LDSP_LDA_PG = 4'h2;
	localparam [3:0] LDSP_LDSP = 4'h3;
	localparam [3:0] LDSP_STSP = 4'h4;
	localparam [3:0] SYS_HLT = 4'h0;
	localparam [3:0] SYS_SEI = 4'h1;
	localparam [3:0] SYS_CLI = 4'h2;
	localparam [3:0] SYS_SEC = 4'h3;
	localparam [3:0] SYS_CLC = 4'h4;
	localparam [3:0] SYS_CLV = 4'h5;
	localparam [3:0] SYS_RTI = 4'h6;
	localparam [3:0] BR_BEQ = 4'h0;
	localparam [3:0] BR_BNE = 4'h1;
	localparam [3:0] BR_BCS = 4'h2;
	localparam [3:0] BR_BCC = 4'h3;
	localparam [3:0] BR_BMI = 4'h4;
	localparam [3:0] BR_BPL = 4'h5;
	localparam [4:0] ST_RESET = 5'd0;
	localparam [4:0] ST_FETCH = 5'd1;
	localparam [4:0] ST_DECODE = 5'd2;
	localparam [4:0] ST_EXECUTE = 5'd3;
	localparam [4:0] ST_MEM_READ = 5'd4;
	localparam [4:0] ST_MEM_WRITE = 5'd5;
	localparam [4:0] ST_IND_Y1 = 5'd6;
	localparam [4:0] ST_IND_Y2 = 5'd7;
	localparam [4:0] ST_PUSH = 5'd8;
	localparam [4:0] ST_POP = 5'd9;
	localparam [4:0] ST_PAGE_REQ = 5'd10;
	localparam [4:0] ST_PAGE_WAIT = 5'd11;
	localparam [4:0] ST_HALTED = 5'd12;
	reg [4:0] state;
	assign iram_rd_slot = pc;
	assign is_halted = (state == ST_HALTED) || (state == ST_PAGE_REQ) || (state == ST_PAGE_WAIT)
	                || (state == ST_MEM_READ) || (state == ST_MEM_WRITE)
	                || (state == ST_IND_Y1)   || (state == ST_IND_Y2);
	reg page_interrupt_r;
	assign page_interrupt = page_interrupt_r;
	reg wrap_pending;  // set when slot 9 is fetched; triggers page swap after execute
	reg [8:0] alu_result;
	reg [7:0] alu_op_b;
	always @(*) begin
		alu_op_b = (ir_sub[3] ? ir_imm : mdr);
		alu_result = 9'h000;
		if (!ir_sub[3])
			case (ir_sub)
				ALU_ADD: alu_result = {1'b0, a} + {1'b0, alu_op_b};
				ALU_ADC: alu_result = ({1'b0, a} + {1'b0, alu_op_b}) + {8'h00, sr[0]};
				ALU_SUB: alu_result = {1'b0, a} - {1'b0, alu_op_b};
				ALU_SBC: alu_result = ({1'b0, a} - {1'b0, alu_op_b}) - {8'h00, ~sr[0]};
				ALU_AND: alu_result = {1'b0, a & alu_op_b};
				ALU_ORA: alu_result = {1'b0, a | alu_op_b};
				ALU_EOR: alu_result = {1'b0, a ^ alu_op_b};
				ALU_CMP: alu_result = {1'b0, a} - {1'b0, alu_op_b};
				ALU_ASL: alu_result = {a[7], a[6:0], 1'b0};
				ALU_LSR: alu_result = {a[0], 1'b0, a[7:1]};
				default: alu_result = 9'h000;
			endcase
		else
			case (ir_sub[2:0])
				ALU_ADD[2:0]: alu_result = {1'b0, a} + {1'b0, alu_op_b};
				ALU_ADC[2:0]: alu_result = ({1'b0, a} + {1'b0, alu_op_b}) + {8'h00, sr[0]};
				ALU_SUB[2:0]: alu_result = {1'b0, a} - {1'b0, alu_op_b};
				ALU_SBC[2:0]: alu_result = ({1'b0, a} - {1'b0, alu_op_b}) - {8'h00, ~sr[0]};
				ALU_AND[2:0]: alu_result = {1'b0, a & alu_op_b};
				ALU_ORA[2:0]: alu_result = {1'b0, a | alu_op_b};
				ALU_EOR[2:0]: alu_result = {1'b0, a ^ alu_op_b};
				ALU_CMP[2:0]: alu_result = {1'b0, a} - {1'b0, alu_op_b};
				default: alu_result = 9'h000;
			endcase
	end
	reg branch_taken;
	always @(*)
		case (ir_sub)
			BR_BEQ: branch_taken = sr[1];
			BR_BNE: branch_taken = ~sr[1];
			BR_BCS: branch_taken = sr[0];
			BR_BCC: branch_taken = ~sr[0];
			BR_BMI: branch_taken = sr[2];
			BR_BPL: branch_taken = ~sr[2];
			default: branch_taken = 1'b0;
		endcase
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= ST_RESET;
			pc <= 4'h0;
			page_reg <= 8'h00;
			data_page <= 8'h00;
			a <= 8'h00;
			x <= 8'h00;
			y <= 8'h00;
			sp <= 8'hff;
			sr <= 5'h00;
			mem_req <= 0;
			mem_rw <= 0;
			mem_addr <= 16'h0000;
			mem_wdata <= 8'h00;
			iram_wr_en <= 0;
			iram_wr_slot <= 4'h0;
			iram_wr_data <= 16'h0000;
			ir_op <= 4'h0;
			ir_sub <= 4'h0;
			ir_imm <= 8'h00;
			mdr <= 8'h00;
			eff_addr <= 16'h0000;
			t1 <= 8'h00;
			page_interrupt_r <= 0;
			wrap_pending <= 0;
		end
		else begin
			iram_wr_en <= 0;
			mem_req <= mem_req;
			page_interrupt_r <= 0;
			case (state)
				ST_RESET: begin
					wrap_pending <= 0;
					state <= ST_PAGE_REQ;
				end
				ST_PAGE_REQ:
					if (page_loading) begin
						state <= ST_PAGE_WAIT;
					end
				ST_PAGE_WAIT:
					if (page_done) begin
						pc <= 4'h0;
						wrap_pending <= 0;
						state <= ST_FETCH;
					end
				ST_FETCH:
					if (!run_enable)
						state <= ST_HALTED;
					else if (wrap_pending) begin
						// previous slot-9 instruction returned here without passing through ST_EXECUTE
						wrap_pending <= 0;
						page_interrupt_r <= 1;
						state <= ST_PAGE_REQ;
					end else begin
						ir_op <= iram_rd_data[15:12];
						ir_sub <= iram_rd_data[11:8];
						ir_imm <= iram_rd_data[7:0];
						if (pc == 4'h9) begin
							// slot 9: fetch and execute it, wrap PC, page-swap after execute
							pc <= 4'h0;
							wrap_pending <= 1;
						end else begin
							pc <= pc + 1;
						end
						state <= ST_DECODE;
					end
				ST_DECODE:
					case (ir_op)
						OP_LDA:
							case (ir_sub[1:0])
								2'b00: begin
									a <= ir_imm;
									sr[1] <= ir_imm == 0;
									sr[2] <= ir_imm[7];
									state <= ST_EXECUTE;
								end
								2'b01: begin
									eff_addr <= {data_page, ir_imm};
									state <= ST_MEM_READ;
								end
								2'b10: begin
									eff_addr <= {data_page, ir_imm} + {8'h00, x};
									state <= ST_MEM_READ;
								end
								2'b11: begin
									eff_addr <= {data_page, ir_imm};
									state <= ST_IND_Y1;
								end
							endcase
						OP_STA:
							case (ir_sub[1:0])
								2'b00: begin
									eff_addr <= {data_page, ir_imm};
									state <= ST_MEM_WRITE;
								end
								2'b01: begin
									eff_addr <= {data_page, ir_imm} + {8'h00, x};
									state <= ST_MEM_WRITE;
								end
								2'b10: begin
									eff_addr <= {data_page, ir_imm};
									state <= ST_IND_Y1;
								end
								default: state <= ST_EXECUTE;
							endcase
						OP_LDX:
							if (!ir_sub[0]) begin
								x <= ir_imm;
								sr[1] <= ir_imm == 0;
								sr[2] <= ir_imm[7];
								state <= ST_EXECUTE;
							end
							else begin
								eff_addr <= {data_page, ir_imm};
								state <= ST_MEM_READ;
							end
						OP_LDY:
							if (!ir_sub[0]) begin
								y <= ir_imm;
								sr[1] <= ir_imm == 0;
								sr[2] <= ir_imm[7];
								state <= ST_EXECUTE;
							end
							else begin
								eff_addr <= {data_page, ir_imm};
								state <= ST_MEM_READ;
							end
						OP_STX: begin
							eff_addr <= {data_page, ir_imm};
							state <= ST_MEM_WRITE;
						end
						OP_STY: begin
							eff_addr <= {data_page, ir_imm};
							state <= ST_MEM_WRITE;
						end
						OP_ALU:
							if (ir_sub[3])
								state <= ST_EXECUTE;
							else if (ir_sub >= ALU_ASL)
								state <= ST_EXECUTE;
							else begin
								eff_addr <= {data_page, ir_imm};
								state <= ST_MEM_READ;
							end
						OP_BR: state <= ST_EXECUTE;
						OP_JMP: state <= ST_EXECUTE;
						OP_JSR: state <= ST_PUSH;
						OP_RTS: state <= ST_POP;
						OP_FARJMP: state <= ST_EXECUTE;
						OP_REG: state <= (ir_sub == REG_PHA ? ST_PUSH : (ir_sub == REG_PLA ? ST_POP : ST_EXECUTE));
						OP_LDSP: state <= ST_EXECUTE;
						OP_SMOD: state <= ST_EXECUTE;
						OP_SYS: state <= ST_EXECUTE;
						default: state <= ST_EXECUTE;
					endcase
				ST_MEM_READ:
					if (mem_ready && mem_req) begin
						mdr <= mem_rdata;
						mem_req <= 0;
						state <= ST_EXECUTE;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= eff_addr;
					end
				ST_MEM_WRITE:
					if (mem_ready && mem_req) begin
						mem_req <= 0;
						mem_rw <= 0;
						state <= ST_EXECUTE;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 1;
						mem_addr <= eff_addr;
						case (ir_op)
							OP_STA: mem_wdata <= a;
							OP_STX: mem_wdata <= x;
							OP_STY: mem_wdata <= y;
							default: mem_wdata <= a;
						endcase
					end
				ST_IND_Y1:
					if (mem_ready && mem_req) begin
						t1 <= mem_rdata;
						mem_req <= 0;
						eff_addr <= eff_addr + 1;
						state <= ST_IND_Y2;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= eff_addr;
					end
				ST_IND_Y2:
					if (mem_ready && mem_req) begin
						mem_req <= 0;
						eff_addr <= {mem_rdata, t1} + {8'h00, y};
						state <= (ir_op == OP_STA ? ST_MEM_WRITE : ST_MEM_READ);
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= eff_addr;
					end
				ST_PUSH:
					if (mem_ready && mem_req) begin
						sp <= sp - 1;
						mem_req <= 0;
						mem_rw <= 0;
						state <= (ir_op == OP_JSR ? ST_EXECUTE : ST_FETCH);
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 1;
						mem_addr <= {data_page, sp};
						mem_wdata <= (ir_op == OP_JSR ? pc + 4'h1 : a);
					end
				ST_POP:
					if (mem_ready && mem_req) begin
						sp <= sp + 1;
						mem_req <= 0;
						case (ir_op)
							OP_RTS: begin
								pc <= mem_rdata[3:0];
								state <= ST_FETCH;
							end
							OP_REG: begin
								a <= mem_rdata;
								sr[1] <= mem_rdata == 0;
								sr[2] <= mem_rdata[7];
								state <= ST_FETCH;
							end
							default: state <= ST_FETCH;
						endcase
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
						mem_addr <= {data_page, sp + 8'h01};
					end
				ST_EXECUTE: begin
					if (wrap_pending) begin
						wrap_pending <= 0;
						page_interrupt_r <= 1;

						state <= ST_PAGE_REQ;
					end else
						state <= ST_FETCH;
					case (ir_op)
						OP_LDA:
							;
						OP_LDX: begin
							x <= mdr;
							sr[1] <= mdr == 0;
							sr[2] <= mdr[7];
						end
						OP_LDY: begin
							y <= mdr;
							sr[1] <= mdr == 0;
							sr[2] <= mdr[7];
						end
						OP_STX, OP_STY, OP_STA:
							;
						OP_ALU:
							if (ir_sub[2:0] == ALU_CMP[2:0]) begin
								sr[0] <= ~alu_result[8];
								sr[1] <= alu_result[7:0] == 0;
								sr[2] <= alu_result[7];
							end
							else begin
								a <= alu_result[7:0];
								sr[0] <= alu_result[8];
								sr[1] <= alu_result[7:0] == 0;
								sr[2] <= alu_result[7];
							end
						OP_BR:
							if (branch_taken && !wrap_pending)
								pc <= pc + ir_imm[3:0];
						OP_JMP: if (!wrap_pending) pc <= ir_imm[3:0];
						OP_JSR: if (!wrap_pending) pc <= ir_imm[3:0];
						OP_RTS:
							;
						OP_FARJMP:
							state <= ST_PAGE_REQ;
						OP_REG:
							case (ir_sub)
								REG_TAX: begin
									x <= a;
									sr[1] <= a == 0;
									sr[2] <= a[7];
								end
								REG_TXA: begin
									a <= x;
									sr[1] <= x == 0;
									sr[2] <= x[7];
								end
								REG_TAY: begin
									y <= a;
									sr[1] <= a == 0;
									sr[2] <= a[7];
								end
								REG_TYA: begin
									a <= y;
									sr[1] <= y == 0;
									sr[2] <= y[7];
								end
								REG_INX: begin
									x <= x + 1;
									sr[1] <= (x + 1) == 0;
									sr[2] <= (x + 1)[7];
								end
								REG_DEX: begin
									x <= x - 1;
									sr[1] <= (x - 1) == 0;
									sr[2] <= (x - 1)[7];
								end
								REG_INY: begin
									y <= y + 1;
									sr[1] <= (y + 1) == 0;
									sr[2] <= (y + 1)[7];
								end
								REG_DEY: begin
									y <= y - 1;
									sr[1] <= (y - 1) == 0;
									sr[2] <= (y - 1)[7];
								end
								REG_TSX: x <= sp;
								REG_TXS: sp <= x;
								REG_PHA:
									;
								REG_PLA:
									;
								default:
									;
							endcase
						OP_LDSP:
							case (ir_sub)
								LDSP_LDA_DP: a <= data_page;
								LDSP_STA_DP: data_page <= a;
								LDSP_LDA_PG: a <= page_reg;
								LDSP_LDSP: sp <= ir_imm;
								LDSP_STSP: a <= sp;
								default:
									;
							endcase
						OP_SMOD: begin
							iram_wr_en <= 1;
							iram_wr_slot <= ir_sub;
							iram_wr_data <= {iram_rd_data[15:8], a};
						end
						OP_SYS:
							case (ir_sub)
								SYS_HLT: state <= ST_HALTED;
								SYS_SEI: sr[4] <= 1;
								SYS_CLI: sr[4] <= 0;
								SYS_SEC: sr[0] <= 1;
								SYS_CLC: sr[0] <= 0;
								SYS_CLV: ;  // overflow flag removed for area savings
								default:
									;
							endcase
						default:
							;
					endcase
					// PC increment happens in ST_FETCH, not here
				end
				ST_HALTED:
					if (run_enable)
						state <= ST_FETCH;
				default: state <= ST_FETCH;
			endcase
		end
endmodule
