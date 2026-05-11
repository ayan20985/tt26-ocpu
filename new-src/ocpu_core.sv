`default_nettype none

// OCPU core tiny8-style 8-bit CPU with paged instruction memory.
//
// ISA word format (16 bits in SPI flash, 17 bits in iRAM with dirty bit):
//   [15:12] opcode  (4 bits)
//   [11:8]  sub     (4 bits) register sel, branch mode, ALU variant
//   [7:0]   imm8    (8 bits) immediate / absolute addr / page delta
//
// 4-bit PC indexes iRAM[0..15]. When PC would advance past slot 15 it wraps
// to 0 and raises page_req so the page_controller loads the next page.
// FARJMP sets page_delta and also raises page_req without incrementing page_reg
// here the page_controller receives the requested page number directly.

module ocpu_core (
    input  wire        clk,
    input  wire        rst_n,

    // run control
    input  wire        run_enable,   // held low keeps cpu in HALTED
    output wire        is_halted,

    // page handshake
    output reg         page_req,     // cpu wants a new page loaded
    output reg  [7:0]  page_next,    // which page to load next
    input  wire        page_done,    // page_controller signals iRAM is ready
    input  wire        page_loading, // page_controller is busy (cpu must stay halted)

    // iRAM read port (to iram_regfile, 8 slots)
    output wire [2:0]  iram_rd_slot,
    input  wire [16:0] iram_rd_data, // {dirty, opcode, sub, imm8}

    // iRAM cpu write port (self-modifying code / constant patching)
    output reg         iram_wr_en,
    output reg  [2:0]  iram_wr_slot,
    output reg  [15:0] iram_wr_data,

    // data memory bus (to SPI via project.v arbitration)
    output reg         mem_req,
    output reg         mem_rw,        // 0=read 1=write
    output reg  [15:0] mem_addr,      // {data_page, addr[7:0]}
    output reg  [7:0]  mem_wdata,
    input  wire        mem_ready,
    input  wire [7:0]  mem_rdata,

    // current page register (visible to page_controller and debugger)
    output reg  [7:0]  page_reg,

`ifdef OCPU_SIM
    output wire [7:0]  dbg_a,
    output wire [7:0]  dbg_x,
    output wire [7:0]  dbg_y,
    output wire [7:0]  dbg_sp,
    output wire [7:0]  dbg_sr,
    output wire [7:0]  dbg_ir,
    output wire [2:0]  dbg_pc,
`endif

    output wire [2:0]  out_pc
);

    // -------------------------------------------------------------------------
    // Registers
    // -------------------------------------------------------------------------
    reg [7:0]  a, x, y, sp;
    reg [7:0]  sr;        // [0]=C [1]=Z [2]=N [3]=V [4]=I
    reg [2:0]  pc;        // 3-bit PC indexes iRAM[0..7] (8-slot page)
    reg [7:0]  data_page; // separate page for data accesses

    // decoded fields latched from iram_rd_data at FETCH
    reg [3:0]  ir_op;     // opcode
    reg [3:0]  ir_sub;    // sub-field
    reg [7:0]  ir_imm;    // imm8

    // scratch
    reg [7:0]  mdr;       // memory data register (for read result)
    reg [15:0] eff_addr;  // effective address for data accesses
    reg [7:0]  t1;        // temp for multi-cycle ops

    // -------------------------------------------------------------------------
    // ISA opcodes (4-bit)
    // -------------------------------------------------------------------------
    localparam [3:0]
        OP_LDA   = 4'h0,  // sub[1:0]: 00=imm 01=abs 10=abs+x 11=ind_y
        OP_STA   = 4'h1,  // sub[1:0]: 00=abs 01=abs+x 10=ind_y
        OP_LDX   = 4'h2,  // sub[0]:   0=imm 1=abs
        OP_LDY   = 4'h3,  // sub[0]:   0=imm 1=abs
        OP_STX   = 4'h4,
        OP_STY   = 4'h5,
        OP_ALU   = 4'h6,  // sub[3:0]: selects ADD/SUB/AND/ORA/EOR/CMP/ASL/LSR
        OP_BR    = 4'h7,  // sub[3:0]: BEQ/BNE/BCS/BCC/BMI/BPL; imm8=signed offset
        OP_JMP   = 4'h8,  // intra-page: pc <= imm8[3:0]
        OP_JSR   = 4'h9,  // push pc+1 onto stack, jump to imm8[3:0]
        OP_RTS   = 4'hA,
        OP_FARJMP= 4'hB,  // page_reg += ir_sub (or absolute if ir_sub[3]), reload
        OP_REG   = 4'hC,  // sub: TAX/TXA/TAY/TYA/INX/DEX/INY/DEY/PHA/PLA/NOP
        OP_LDSP  = 4'hD,  // LDA data_page / STA data_page / LDSP / etc (sub-encoded)
        OP_SMOD  = 4'hE,  // self-modify iram slot: slot=sub[3:0] data=imm8 (write imm into A field of slot)
        OP_SYS   = 4'hF;  // HLT / SEI / CLI / SEC / CLC / RTI

    // ALU sub-opcodes (ir_sub when OP_ALU)
    // sub[3]=0: binary op, operand fetched from {data_page, imm8} (memory)
    // sub[3]=1: binary op, operand is imm8 directly (immediate)
    // Exception: ASL/LSR/ROL/ROR (sub >= 4'h8 in abs-mode encoding) operate on A
    // only no operand. To get immediate binary ops use sub[3]=1 with sub[2:0]:
    //   4'h8=ADD#  4'h9=ADC#  4'hA=SUB#  4'hB=SBC#
    //   4'hC=AND#  4'hD=ORA#  4'hE=EOR#  4'hF=CMP#
    // and sub[3]=0 for the memory versions (with ASL/LSR/ROL/ROR unreachable via
    // normal encode assembler uses dedicated sub values 4'h8-4'hB for shifts).
    //
    // Practical encoding:
    //   sub[3]=0, sub[2:0]=0..3  → ADD/ADC/SUB/SBC  abs
    //   sub[3]=0, sub[2:0]=4..7  → AND/ORA/EOR/CMP  abs
    //   sub[3]=0, sub[2:0]=8..B  → ASL/LSR/ROL/ROR  (A only, imm8 ignored)
    //   sub[3]=1, sub[2:0]=0..3  → ADD/ADC/SUB/SBC  #imm
    //   sub[3]=1, sub[2:0]=4..7  → AND/ORA/EOR/CMP  #imm
    localparam [3:0]
        ALU_ADD = 4'h0,   // A = A + mem[imm8]   or  A = A + imm8  (sub[3] selects)
        ALU_ADC = 4'h1,
        ALU_SUB = 4'h2,
        ALU_SBC = 4'h3,
        ALU_AND = 4'h4,
        ALU_ORA = 4'h5,
        ALU_EOR = 4'h6,
        ALU_CMP = 4'h7,
        ALU_ASL = 4'h8,   // shift/rotate no operand, sub[3] must be 0
        ALU_LSR = 4'h9,
        ALU_ROL = 4'hA,
        ALU_ROR = 4'hB;

    // REG sub-opcodes (ir_sub when OP_REG)
    localparam [3:0]
        REG_TAX = 4'h0,
        REG_TXA = 4'h1,
        REG_TAY = 4'h2,
        REG_TYA = 4'h3,
        REG_INX = 4'h4,
        REG_DEX = 4'h5,
        REG_INY = 4'h6,
        REG_DEY = 4'h7,
        REG_PHA = 4'h8,
        REG_PLA = 4'h9,
        REG_TSX = 4'hA,
        REG_TXS = 4'hB,
        REG_NOP = 4'hF;

    // LDSP sub-opcodes (OP_LDSP)
    localparam [3:0]
        LDSP_LDA_DP  = 4'h0,  // load data_page register into A
        LDSP_STA_DP  = 4'h1,  // store A into data_page register
        LDSP_LDA_PG  = 4'h2,  // load page_reg into A
        LDSP_LDSP    = 4'h3,  // SP = imm8
        LDSP_STSP    = 4'h4;  // A  = SP

    // SYS sub-opcodes (OP_SYS)
    localparam [3:0]
        SYS_HLT = 4'h0,
        SYS_SEI = 4'h1,
        SYS_CLI = 4'h2,
        SYS_SEC = 4'h3,
        SYS_CLC = 4'h4,
        SYS_CLV = 4'h5,
        SYS_RTI = 4'h6;

    // Branch condition sub-opcodes (OP_BR)
    localparam [3:0]
        BR_BEQ = 4'h0,
        BR_BNE = 4'h1,
        BR_BCS = 4'h2,
        BR_BCC = 4'h3,
        BR_BMI = 4'h4,
        BR_BPL = 4'h5;

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [4:0]
        ST_RESET      = 5'd0,
        ST_FETCH      = 5'd1,
        ST_DECODE     = 5'd2,
        ST_EXECUTE    = 5'd3,
        ST_MEM_READ   = 5'd4,
        ST_MEM_WRITE  = 5'd5,
        ST_IND_Y1     = 5'd6,
        ST_IND_Y2     = 5'd7,
        ST_PUSH       = 5'd8,
        ST_POP        = 5'd9,
        ST_PAGE_REQ   = 5'd10, // waiting for page_controller to accept
        ST_PAGE_WAIT  = 5'd11, // waiting for page_controller to finish loading
        ST_HALTED     = 5'd12;

    reg [4:0] state;

    // -------------------------------------------------------------------------
    // Wiring
    // -------------------------------------------------------------------------
    assign iram_rd_slot = pc;
    assign out_pc       = pc;
    assign is_halted    = (state == ST_HALTED || state == ST_PAGE_REQ || state == ST_PAGE_WAIT);

`ifdef OCPU_SIM
    assign dbg_a  = a;
    assign dbg_x  = x;
    assign dbg_y  = y;
    assign dbg_sp = sp;
    assign dbg_sr = sr;
    assign dbg_ir = {ir_op, ir_sub};
    assign dbg_pc = pc;
`endif

    // -------------------------------------------------------------------------
    // ALU (combinational helper)
    // -------------------------------------------------------------------------
    reg  [8:0] alu_result;
    reg  [7:0] alu_op_b;

    always @(*) begin
        // sub[3]=1 → immediate operand (ir_imm)
        // sub[3]=0 → memory operand (mdr), also covers shifts which ignore alu_op_b
        alu_op_b   = ir_sub[3] ? ir_imm : mdr;
        alu_result = 9'h000;
        if (!ir_sub[3]) begin
            // Memory-operand binary ops (sub 0-7) and shifts (sub 8-B)
            case (ir_sub)
                ALU_ADD: alu_result = {1'b0, a} + {1'b0, alu_op_b};
                ALU_ADC: alu_result = {1'b0, a} + {1'b0, alu_op_b} + {8'h00, sr[0]};
                ALU_SUB: alu_result = {1'b0, a} - {1'b0, alu_op_b};
                ALU_SBC: alu_result = {1'b0, a} - {1'b0, alu_op_b} - {8'h00, ~sr[0]};
                ALU_AND: alu_result = {1'b0, a & alu_op_b};
                ALU_ORA: alu_result = {1'b0, a | alu_op_b};
                ALU_EOR: alu_result = {1'b0, a ^ alu_op_b};
                ALU_CMP: alu_result = {1'b0, a} - {1'b0, alu_op_b};
                ALU_ASL: alu_result = {a[7], a[6:0], 1'b0};
                ALU_LSR: alu_result = {a[0], 1'b0, a[7:1]};
                ALU_ROL: alu_result = {a[7], a[6:0], sr[0]};
                ALU_ROR: alu_result = {a[0], sr[0], a[7:1]};
                default: alu_result = 9'h000;
            endcase
        end else begin
            // Immediate-operand binary ops — sub[2:0] mirrors ALU_ADD..ALU_CMP
            case (ir_sub[2:0])
                ALU_ADD[2:0]: alu_result = {1'b0, a} + {1'b0, alu_op_b};
                ALU_ADC[2:0]: alu_result = {1'b0, a} + {1'b0, alu_op_b} + {8'h00, sr[0]};
                ALU_SUB[2:0]: alu_result = {1'b0, a} - {1'b0, alu_op_b};
                ALU_SBC[2:0]: alu_result = {1'b0, a} - {1'b0, alu_op_b} - {8'h00, ~sr[0]};
                ALU_AND[2:0]: alu_result = {1'b0, a & alu_op_b};
                ALU_ORA[2:0]: alu_result = {1'b0, a | alu_op_b};
                ALU_EOR[2:0]: alu_result = {1'b0, a ^ alu_op_b};
                ALU_CMP[2:0]: alu_result = {1'b0, a} - {1'b0, alu_op_b};
                default:      alu_result = 9'h000;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Branch taken?
    // -------------------------------------------------------------------------
    reg branch_taken;
    always @(*) begin
        case (ir_sub)
            BR_BEQ:  branch_taken = sr[1];   // Z
            BR_BNE:  branch_taken = ~sr[1];
            BR_BCS:  branch_taken = sr[0];   // C
            BR_BCC:  branch_taken = ~sr[0];
            BR_BMI:  branch_taken = sr[2];   // N
            BR_BPL:  branch_taken = ~sr[2];
            default: branch_taken = 1'b0;
        endcase
    end

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_RESET;
            pc           <= 3'h0;
            page_reg     <= 8'h00;
            data_page    <= 8'h00;
            a  <= 8'h00; x  <= 8'h00;
            y  <= 8'h00; sp <= 8'hFF;
            sr <= 8'h00;
            page_req     <= 0;
            page_next    <= 8'h00;
            mem_req      <= 0;
            mem_rw       <= 0;
            mem_addr     <= 16'h0000;
            mem_wdata    <= 8'h00;
            iram_wr_en   <= 0;
            iram_wr_slot <= 3'h0;
            iram_wr_data <= 16'h0000;
            ir_op  <= 4'h0; ir_sub <= 4'h0; ir_imm <= 8'h00;
            mdr    <= 8'h00; eff_addr <= 16'h0000; t1 <= 8'h00;
        end else begin
            // default: deassert strobes
            iram_wr_en <= 0;
            mem_req    <= mem_req; // held by FSM

            case (state)

                // ----------------------------------------------------------
                ST_RESET: begin
                    // On reset, immediately request page 0 load
                    page_next <= 8'h00;
                    page_req  <= 1;
                    state     <= ST_PAGE_REQ;
                end

                // ----------------------------------------------------------
                // Wait for page_controller to start (page_loading goes high)
                ST_PAGE_REQ: begin
                    if (page_loading) begin
                        page_req <= 0;
                        state    <= ST_PAGE_WAIT;
                    end
                end

                // ----------------------------------------------------------
                // Wait for page load to complete
                ST_PAGE_WAIT: begin
                    if (page_done) begin
                        pc    <= 3'h0;
                        state <= ST_FETCH;
                    end
                end

                // ----------------------------------------------------------
                // Latch instruction from iRAM (combinational read, 1 cycle)
                ST_FETCH: begin
                    if (!run_enable) begin
                        state <= ST_HALTED;
                    end else begin
                        ir_op  <= iram_rd_data[15:12];
                        ir_sub <= iram_rd_data[11:8];
                        ir_imm <= iram_rd_data[7:0];
                        state  <= ST_DECODE;
                    end
                end

                // ----------------------------------------------------------
                ST_DECODE: begin
                    case (ir_op)
                        OP_LDA: begin
                            case (ir_sub[1:0])
                                2'b00: begin // imm
                                    a      <= ir_imm;
                                    sr[1]  <= (ir_imm == 0);
                                    sr[2]  <= ir_imm[7];
                                    state  <= ST_EXECUTE;
                                end
                                2'b01: begin // abs
                                    eff_addr <= {data_page, ir_imm};
                                    state    <= ST_MEM_READ;
                                end
                                2'b10: begin // abs+x
                                    eff_addr <= {data_page, ir_imm} + {8'h00, x};
                                    state    <= ST_MEM_READ;
                                end
                                2'b11: begin // ind,y first fetch zp pointer
                                    eff_addr <= {data_page, ir_imm};
                                    state    <= ST_IND_Y1;
                                end
                            endcase
                        end

                        OP_STA: begin
                            case (ir_sub[1:0])
                                2'b00: begin eff_addr <= {data_page, ir_imm}; state <= ST_MEM_WRITE; end
                                2'b01: begin eff_addr <= {data_page, ir_imm} + {8'h00, x}; state <= ST_MEM_WRITE; end
                                2'b10: begin eff_addr <= {data_page, ir_imm}; state <= ST_IND_Y1; end
                                default: state <= ST_EXECUTE;
                            endcase
                        end

                        OP_LDX: begin
                            if (!ir_sub[0]) begin
                                x <= ir_imm; sr[1] <= (ir_imm==0); sr[2] <= ir_imm[7];
                                state <= ST_EXECUTE;
                            end else begin
                                eff_addr <= {data_page, ir_imm}; state <= ST_MEM_READ;
                            end
                        end

                        OP_LDY: begin
                            if (!ir_sub[0]) begin
                                y <= ir_imm; sr[1] <= (ir_imm==0); sr[2] <= ir_imm[7];
                                state <= ST_EXECUTE;
                            end else begin
                                eff_addr <= {data_page, ir_imm}; state <= ST_MEM_READ;
                            end
                        end

                        OP_STX: begin eff_addr <= {data_page, ir_imm}; state <= ST_MEM_WRITE; end
                        OP_STY: begin eff_addr <= {data_page, ir_imm}; state <= ST_MEM_WRITE; end

                        OP_ALU: begin
                            if (ir_sub[3]) begin
                                // immediate mode: operand is ir_imm, no fetch needed
                                state <= ST_EXECUTE;
                            end else if (ir_sub >= ALU_ASL) begin
                                // shift/rotate: operate on A only, no operand fetch
                                state <= ST_EXECUTE;
                            end else begin
                                // memory mode: fetch operand from {data_page, imm8}
                                eff_addr <= {data_page, ir_imm};
                                state    <= ST_MEM_READ;
                            end
                        end

                        OP_BR:    state <= ST_EXECUTE;
                        OP_JMP:   state <= ST_EXECUTE;
                        OP_JSR:   state <= ST_PUSH;
                        OP_RTS:   state <= ST_POP;
                        OP_FARJMP:state <= ST_EXECUTE;
                        OP_REG:   state <= (ir_sub == REG_PHA) ? ST_PUSH :
                                           (ir_sub == REG_PLA) ? ST_POP  : ST_EXECUTE;
                        OP_LDSP:  state <= ST_EXECUTE;
                        OP_SMOD:  state <= ST_EXECUTE;
                        OP_SYS:   state <= ST_EXECUTE;
                        default:  state <= ST_EXECUTE;
                    endcase
                end

                // ----------------------------------------------------------
                ST_MEM_READ: begin
                    if (mem_ready && mem_req) begin
                        mdr     <= mem_rdata;
                        mem_req <= 0;
                        state   <= ST_EXECUTE;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req  <= 1;
                        mem_rw   <= 0;
                        mem_addr <= eff_addr;
                    end
                end

                // ----------------------------------------------------------
                ST_MEM_WRITE: begin
                    if (mem_ready && mem_req) begin
                        mem_req <= 0;
                        mem_rw  <= 0;
                        state   <= ST_EXECUTE;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req   <= 1;
                        mem_rw    <= 1;
                        mem_addr  <= eff_addr;
                        case (ir_op)
                            OP_STA:  mem_wdata <= a;
                            OP_STX:  mem_wdata <= x;
                            OP_STY:  mem_wdata <= y;
                            default: mem_wdata <= a;
                        endcase
                    end
                end

                // ----------------------------------------------------------
                // Indirect indexed: fetch low byte of pointer from zp
                ST_IND_Y1: begin
                    if (mem_ready && mem_req) begin
                        t1      <= mem_rdata;
                        mem_req <= 0;
                        eff_addr<= eff_addr + 1;
                        state   <= ST_IND_Y2;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req  <= 1;
                        mem_rw   <= 0;
                        mem_addr <= eff_addr;
                    end
                end

                // Indirect indexed: fetch high byte of pointer then add Y
                ST_IND_Y2: begin
                    if (mem_ready && mem_req) begin
                        mem_req  <= 0;
                        eff_addr <= {mem_rdata, t1} + {8'h00, y};
                        state    <= (ir_op == OP_STA) ? ST_MEM_WRITE : ST_MEM_READ;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req  <= 1;
                        mem_rw   <= 0;
                        mem_addr <= eff_addr;
                    end
                end

                // ----------------------------------------------------------
                // Stack push: mem[sp--] = t1 (for JSR) or a (for PHA)
                ST_PUSH: begin
                    if (mem_ready && mem_req) begin
                        sp      <= sp - 1;
                        mem_req <= 0;
                        mem_rw  <= 0;
                        state   <= (ir_op == OP_JSR) ? ST_EXECUTE : ST_FETCH;
                        // after JSR push we go to EXECUTE to set pc
                    end else if (!mem_req && !mem_ready) begin
                        mem_req   <= 1;
                        mem_rw    <= 1;
                        mem_addr  <= {data_page, sp};
                        // JSR return address = pc+1 (5 bits zero-padded to 8)
                        mem_wdata <= (ir_op == OP_JSR) ? {5'h00, pc + 3'h1} : a;
                    end
                end

                // ----------------------------------------------------------
                // Stack pop: a or pc = mem[++sp]
                ST_POP: begin
                    if (mem_ready && mem_req) begin
                        sp      <= sp + 1;
                        mem_req <= 0;
                        case (ir_op)
                            OP_RTS: begin
                                pc    <= mem_rdata[2:0];
                                state <= ST_FETCH;
                            end
                            OP_REG: begin // PLA
                                a     <= mem_rdata;
                                sr[1] <= (mem_rdata == 0);
                                sr[2] <= mem_rdata[7];
                                state <= ST_FETCH;
                            end
                            default: state <= ST_FETCH;
                        endcase
                    end else if (!mem_req && !mem_ready) begin
                        mem_req  <= 1;
                        mem_rw   <= 0;
                        mem_addr <= {data_page, sp + 8'h01};
                    end
                end

                // ----------------------------------------------------------
                ST_EXECUTE: begin
                    // default: advance PC then go to FETCH (overridden by jumps/page ops)
                    state <= ST_FETCH;

                    case (ir_op)

                        OP_LDA: ; // imm already written in DECODE; abs/ind already in mdr

                        OP_LDX: begin x <= mdr; sr[1] <= (mdr==0); sr[2] <= mdr[7]; end
                        OP_LDY: begin y <= mdr; sr[1] <= (mdr==0); sr[2] <= mdr[7]; end
                        OP_STX, OP_STY, OP_STA: ; // memory write completed in ST_MEM_WRITE

                        OP_ALU: begin
                            if (ir_sub[2:0] == ALU_CMP[2:0]) begin
                                // CMP (mem or imm): flags only, no A write
                                sr[0] <= ~alu_result[8];
                                sr[1] <= (alu_result[7:0] == 0);
                                sr[2] <= alu_result[7];
                            end else begin
                                // all other ALU ops (binary + shifts): write A and flags
                                a    <= alu_result[7:0];
                                sr[0]<= alu_result[8];
                                sr[1]<= (alu_result[7:0] == 0);
                                sr[2]<= alu_result[7];
                            end
                        end

                        OP_BR: begin
                            if (branch_taken) begin
                                // imm8 is signed offset relative to current pc (3-bit, same page only)
                                pc <= pc + ir_imm[2:0];
                            end
                        end

                        OP_JMP: begin
                            pc <= ir_imm[2:0]; // intra-page absolute (slot 0..7)
                        end

                        OP_JSR: begin
                            // push already done in ST_PUSH, now jump
                            pc <= ir_imm[2:0];
                        end

                        OP_RTS: ; // pc restored in ST_POP

                        OP_FARJMP: begin
                            // ir_sub[3]: 0=relative, 1=absolute
                            page_next <= ir_sub[3] ? ir_imm : (page_reg + ir_imm);
                            page_req  <= 1;
                            state     <= ST_PAGE_REQ;
                        end

                        OP_REG: begin
                            case (ir_sub)
                                REG_TAX: begin x <= a; sr[1] <= (a==0); sr[2] <= a[7]; end
                                REG_TXA: begin a <= x; sr[1] <= (x==0); sr[2] <= x[7]; end
                                REG_TAY: begin y <= a; sr[1] <= (a==0); sr[2] <= a[7]; end
                                REG_TYA: begin a <= y; sr[1] <= (y==0); sr[2] <= y[7]; end
                                REG_INX: begin x <= x+1; sr[1] <= (x==8'hFF); sr[2] <= (x+1)[7]; end
                                REG_DEX: begin x <= x-1; sr[1] <= (x==8'h01); sr[2] <= (x-1)[7]; end
                                REG_INY: begin y <= y+1; sr[1] <= (y==8'hFF); sr[2] <= (y+1)[7]; end
                                REG_DEY: begin y <= y-1; sr[1] <= (y==8'h01); sr[2] <= (y-1)[7]; end
                                REG_TSX: begin x <= sp; end
                                REG_TXS: begin sp <= x; end
                                REG_PHA: ; // push done in ST_PUSH
                                REG_PLA: ; // pop done in ST_POP
                                default: ; // NOP
                            endcase
                        end

                        OP_LDSP: begin
                            case (ir_sub)
                                LDSP_LDA_DP: a        <= data_page;
                                LDSP_STA_DP: data_page <= a;
                                LDSP_LDA_PG: a        <= page_reg;
                                LDSP_LDSP:   sp        <= ir_imm;
                                LDSP_STSP:   a         <= sp;
                                default: ;
                            endcase
                        end

                        OP_SMOD: begin
                            // Patch imm8 field of an iRAM slot.
                            // slot = ir_sub[2:0] (only 3 bits used, top bit ignored), new imm8 = a.
                            // upper 8 bits (opcode+sub) come from existing iram slot unchanged.
                            iram_wr_en   <= 1;
                            iram_wr_slot <= ir_sub[2:0];
                            // keep opcode+sub of target slot, replace imm8 with A
                            iram_wr_data <= {iram_rd_data[15:8], a};
                        end

                        OP_SYS: begin
                            case (ir_sub)
                                SYS_HLT: state <= ST_HALTED;
                                SYS_SEI: sr[4] <= 1;
                                SYS_CLI: sr[4] <= 0;
                                SYS_SEC: sr[0] <= 1;
                                SYS_CLC: sr[0] <= 0;
                                SYS_CLV: sr[3] <= 0;
                                default: ;
                            endcase
                        end

                        default: ; // NOP

                    endcase

                    // Advance PC unless a jump/page-op already overrode state
                    if (state == ST_FETCH) begin
                        if (pc == 3'h7) begin
                            // Natural page advance: page_reg++, reload next page
                            page_next <= page_reg + 8'h01;
                            page_req  <= 1;
                            state     <= ST_PAGE_REQ;
                        end else begin
                            pc <= pc + 1;
                        end
                    end else begin
                        // page_req path: update page_reg here
                        if (ir_op == OP_FARJMP)
                            page_reg <= page_next;
                        else if (state == ST_PAGE_REQ && page_req)
                            page_reg <= page_next; // natural advance
                    end
                end

                // ----------------------------------------------------------
                ST_HALTED: begin
                    if (run_enable) state <= ST_FETCH;
                end

                default: state <= ST_FETCH;

            endcase
        end
    end

    // page_reg update for natural end-of-page advance
    // (factored out to avoid multiple-driver issues)
    // Done inline above.

endmodule
