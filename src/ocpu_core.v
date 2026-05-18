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
	// page geometry. SLOT_BITS must match iram_regfile.v. shrinking from
	// 3 -> 2 cuts the iRAM in half and collapses the slot-fanout that was
	// dominating routing on the 1x2 tile.
	localparam integer SLOT_BITS      = 2;
	localparam integer SLOTS_PER_PAGE = 1 << SLOT_BITS;
	localparam [SLOT_BITS-1:0] LAST_SLOT  = {SLOT_BITS{1'b1}};
	localparam [SLOT_BITS-1:0] FIRST_SLOT = {SLOT_BITS{1'b0}};

	input wire clk;
	input wire rst_n;
	input wire run_enable;
	output wire is_halted;
	input wire page_done;
	input wire page_loading;
	output wire page_interrupt;  // pulse: page boundary reached (PC==LAST_SLOT)
	output wire [SLOT_BITS-1:0] iram_rd_slot;
	input wire [15:0] iram_rd_data;
	output reg iram_wr_en;
	output reg [SLOT_BITS-1:0] iram_wr_slot;
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
	/* verilator lint_off UNUSEDSIGNAL */
	reg [4:0] sr;  // reduced: [4]=I (write-only, no IRQ logic), [3]=unused, [2]=N, [1]=Z, [0]=C
	/* verilator lint_on UNUSEDSIGNAL */
	reg [SLOT_BITS-1:0] pc;  // 2-bit PC indexes iRAM[0..3] (4-slot page)
	reg [7:0] data_page;
	reg [3:0] ir_op;
	reg [3:0] ir_sub;
	reg [7:0] ir_imm;
	reg [7:0] mdr;
	// note: eff_addr eliminated. mem_addr is written directly in ST_DECODE,
	// and re-used during ST_IND_Y1/2 (incremented and replaced in place).
	// note: t1 eliminated. mdr doubles as the low-byte temp during (zp),Y resolution
	// because mdr is not consumed until the final ST_MEM_READ phase.
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
	/* verilator lint_off UNUSEDPARAM */
	localparam [3:0] ALU_ADD = 4'h0;
	localparam [3:0] ALU_ADC = 4'h1;
	localparam [3:0] ALU_SUB = 4'h2;
	localparam [3:0] ALU_SBC = 4'h3;
	localparam [3:0] ALU_AND = 4'h4;
	localparam [3:0] ALU_ORA = 4'h5;
	localparam [3:0] ALU_EOR = 4'h6;
	/* verilator lint_on UNUSEDPARAM */
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
	/* verilator lint_off UNUSEDPARAM */
	localparam [3:0] REG_NOP = 4'hf;
	/* verilator lint_on UNUSEDPARAM */
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
	/* verilator lint_off UNUSEDPARAM */
	localparam [3:0] SYS_RTI = 4'h6;
	/* verilator lint_on UNUSEDPARAM */
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
	reg wrap_pending;  // set when LAST_SLOT is fetched; triggers page swap after execute
	reg [8:0] alu_result;
	reg [7:0] alu_op_b;
	// unified ALU: a single case on the low 3 bits drives one adder/logic block.
	// the high bit (sub[3]) only changes the operand source (mdr vs ir_imm).
	// shift overrides (sub[3]=0, sub == 0x8/0x9) are preserved for the ISA
	// even though the current ST_DECODE never routes them here (kept for spec).
	always @(*) begin
		alu_op_b = (ir_sub[3] ? ir_imm : mdr);
		case (ir_sub[2:0])
			3'h0:    alu_result = {1'b0, a} + {1'b0, alu_op_b};                    // ADD / ADD#
			3'h1:    alu_result = ({1'b0, a} + {1'b0, alu_op_b}) + {8'h00, sr[0]}; // ADC / ADC#
			3'h2:    alu_result = {1'b0, a} - {1'b0, alu_op_b};                    // SUB / SUB#
			3'h3:    alu_result = ({1'b0, a} - {1'b0, alu_op_b}) - {8'h00, ~sr[0]};// SBC / SBC#
			3'h4:    alu_result = {1'b0, a & alu_op_b};                            // AND
			3'h5:    alu_result = {1'b0, a | alu_op_b};                            // ORA
			3'h6:    alu_result = {1'b0, a ^ alu_op_b};                            // EOR
			3'h7:    alu_result = {1'b0, a} - {1'b0, alu_op_b};                    // CMP
			default: alu_result = 9'h000;
		endcase
		// shift override (only active when sub[3]=0 and sub==0x8/0x9)
		if (!ir_sub[3] && (ir_sub == ALU_ASL))
			alu_result = {a[7], a[6:0], 1'b0};
		if (!ir_sub[3] && (ir_sub == ALU_LSR))
			alu_result = {a[0], 1'b0, a[7:1]};
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

	// shared inc/dec datapath for INX/DEX/INY/DEY. one 8-bit adder is muxed
	// between x and y; ir_sub[1] selects which register, ir_sub[0] selects dec.
	wire        idOpIsY  = ir_sub[1];
	wire        idOpIsDec = ir_sub[0];
	wire [7:0]  idOpSrc  = idOpIsY ? y : x;
	wire [7:0]  idOpDst  = idOpIsDec ? (idOpSrc - 8'h01) : (idOpSrc + 8'h01);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= ST_RESET;
			pc <= FIRST_SLOT;
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
			iram_wr_slot <= FIRST_SLOT;
			iram_wr_data <= 16'h0000;
			ir_op <= 4'h0;
			ir_sub <= 4'h0;
			ir_imm <= 8'h00;
			mdr <= 8'h00;
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
						pc <= FIRST_SLOT;
						wrap_pending <= 0;
						state <= ST_FETCH;
					end
				ST_FETCH:
					if (!run_enable)
						state <= ST_HALTED;
					else if (wrap_pending) begin
						// previous LAST_SLOT instruction returned here without passing through ST_EXECUTE
						wrap_pending <= 0;
						page_interrupt_r <= 1;
						state <= ST_PAGE_REQ;
					end else begin
						ir_op <= iram_rd_data[15:12];
						ir_sub <= iram_rd_data[11:8];
						ir_imm <= iram_rd_data[7:0];
						if (pc == LAST_SLOT) begin
							// last slot: fetch and execute it, wrap PC, page-swap after execute
							pc <= FIRST_SLOT;
							wrap_pending <= 1;
						end else begin
							pc <= pc + 1'b1;
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
									mem_addr <= {data_page, ir_imm};
									state <= ST_MEM_READ;
								end
								2'b10: begin
									mem_addr <= {data_page, ir_imm} + {8'h00, x};
									state <= ST_MEM_READ;
								end
								2'b11: begin
									mem_addr <= {data_page, ir_imm};
									state <= ST_IND_Y1;
								end
							endcase
						OP_STA:
							case (ir_sub[1:0])
								2'b00: begin
									mem_addr <= {data_page, ir_imm};
									state <= ST_MEM_WRITE;
								end
								2'b01: begin
									mem_addr <= {data_page, ir_imm} + {8'h00, x};
									state <= ST_MEM_WRITE;
								end
								2'b10: begin
									mem_addr <= {data_page, ir_imm};
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
								mem_addr <= {data_page, ir_imm};
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
								mem_addr <= {data_page, ir_imm};
								state <= ST_MEM_READ;
							end
						OP_STX: begin
							mem_addr <= {data_page, ir_imm};
							state <= ST_MEM_WRITE;
						end
						OP_STY: begin
							mem_addr <= {data_page, ir_imm};
							state <= ST_MEM_WRITE;
						end
						OP_ALU:
							if (ir_sub[3])
								state <= ST_EXECUTE;
							else if (ir_sub >= ALU_ASL)
								state <= ST_EXECUTE;
							else begin
								mem_addr <= {data_page, ir_imm};
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
					// mem_addr was pre-loaded in ST_DECODE / ST_IND_Y2; just drive the request
					if (mem_ready && mem_req) begin
						mdr <= mem_rdata;
						mem_req <= 0;
						state <= ST_EXECUTE;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
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
						case (ir_op)
							OP_STA: mem_wdata <= a;
							OP_STX: mem_wdata <= x;
							OP_STY: mem_wdata <= y;
							default: mem_wdata <= a;
						endcase
					end
				ST_IND_Y1:
					// mdr is reused as the low-byte temp because the final read
					// in ST_MEM_READ will overwrite it before any consumer sees it.
					if (mem_ready && mem_req) begin
						mdr <= mem_rdata;
						mem_addr <= mem_addr + 16'h1;
						mem_req <= 0;
						state <= ST_IND_Y2;
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
					end
				ST_IND_Y2:
					if (mem_ready && mem_req) begin
						mem_addr <= {mem_rdata, mdr} + {8'h00, y};
						mem_req <= 0;
						state <= (ir_op == OP_STA ? ST_MEM_WRITE : ST_MEM_READ);
					end
					else if (!mem_req && !mem_ready) begin
						mem_req <= 1;
						mem_rw <= 0;
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
						// JSR pushes pc+1 (where to resume), zero-padded into the
						// 8-bit memory byte. SLOT_BITS<=8 by construction.
						mem_wdata <= (ir_op == OP_JSR
						              ? {{(8-SLOT_BITS){1'b0}}, pc + 1'b1}
						              : a);
					end
				ST_POP:
					if (mem_ready && mem_req) begin
						sp <= sp + 1;
						mem_req <= 0;
						case (ir_op)
							OP_RTS: begin
								pc <= mem_rdata[SLOT_BITS-1:0];
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
							// LDA #imm already updated A and flags in ST_DECODE
							// (no ST_MEM_READ visited); for the memory-mode
							// variants (abs / abs,X / (zp),Y) we land here
							// AFTER ST_MEM_READ has populated mdr, and the
							// register transfer + flag update happens now.
							if (ir_sub[1:0] != 2'b00) begin
								a <= mdr;
								sr[1] <= mdr == 0;
								sr[2] <= mdr[7];
							end
						OP_LDX:
							// LDX #imm already wrote X / flags in ST_DECODE;
							// only the abs variant routes through ST_MEM_READ
							// and arrives here needing the mdr -> X transfer.
							if (ir_sub[0]) begin
								x <= mdr;
								sr[1] <= mdr == 0;
								sr[2] <= mdr[7];
							end
						OP_LDY:
							// LDY #imm already wrote Y / flags in ST_DECODE
							// (see OP_LDX comment).
							if (ir_sub[0]) begin
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
								pc <= pc + ir_imm[SLOT_BITS-1:0];
						OP_JMP: if (!wrap_pending) pc <= ir_imm[SLOT_BITS-1:0];
						OP_JSR: if (!wrap_pending) pc <= ir_imm[SLOT_BITS-1:0];
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
								// INX/DEX/INY/DEY share one inc/dec adder (idOpDst).
								// flags are derived from the post-update value directly,
								// removing the redundant 8-bit comparators in the prior
								// implementation.
								REG_INX, REG_DEX: begin
									x      <= idOpDst;
									sr[1]  <= ~|idOpDst;
									sr[2]  <= idOpDst[7];
								end
								REG_INY, REG_DEY: begin
									y      <= idOpDst;
									sr[1]  <= ~|idOpDst;
									sr[2]  <= idOpDst[7];
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
							iram_wr_slot <= ir_sub[SLOT_BITS-1:0];
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
