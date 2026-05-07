`default_nettype none

module ocpu_core (
    input  wire        clk,
    input  wire        rst_n,
    
    input  wire        run_enable,
    output wire        is_halted,
`ifdef OCPU_SIM
    output wire [5:0]  dbg_a,
    output wire [5:0]  dbg_x,
    output wire [5:0]  dbg_y,
    output wire [5:0]  dbg_sp,
    output wire [5:0]  dbg_sr,
    output wire [5:0]  dbg_ir,
    output wire [15:0] dbg_pc,
`endif

    output wire [15:0] out_pc,
    input  wire        force_pc_en,
    input  wire [15:0] force_pc_val,
    
    output reg         mem_req,
    output reg         mem_rw,
    output reg  [15:0] mem_addr,
    output reg  [5:0]  mem_wdata,
    input  wire        mem_ready,
    input  wire [5:0]  mem_rdata
);

    reg [5:0] a;      
    reg [5:0] x;      
    reg [5:0] y;      
    reg [5:0] sp;     
    reg [15:0] pc;    
    reg [5:0] sr;     
    reg [5:0] ir;     

    reg [15:0] ea;
    reg [5:0]  mdr;
    reg [15:0] memAddr;
    reg [5:0] t1;
    reg       jsr_phase;

    localparam STATE_RESET     = 5'd0,
               STATE_FETCH     = 5'd1,
               STATE_DECODE    = 5'd2,
               STATE_OP1       = 5'd3,
               STATE_OP2       = 5'd4,
               STATE_IND_Y1    = 5'd5,
               STATE_IND_Y2    = 5'd6,
               STATE_MEM_READ  = 5'd7,
               STATE_MEM_WRITE = 5'd8,
               STATE_EXECUTE   = 5'd9,
               STATE_PUSH      = 5'd10,
               STATE_POP       = 5'd11,
               STATE_HALTED    = 5'd12;

    localparam [5:0] OP_LDA_IMM   = 6'h00,
                     OP_LDA_ABS   = 6'h01,
                     OP_LDA_ABS_X = 6'h02,
                     OP_LDA_IND_Y = 6'h03,
                     OP_LDX_IMM   = 6'h04,
                     OP_LDX_ABS   = 6'h05,
                     OP_LDY_IMM   = 6'h06,
                     OP_LDY_ABS   = 6'h07,
                     OP_STA_ABS   = 6'h08,
                     OP_STA_ABS_X = 6'h09,
                     OP_STA_IND_Y = 6'h0A,
                     OP_STX_ABS   = 6'h0B,
                     OP_STY_ABS   = 6'h0C,
                     OP_ADC_ABS   = 6'h0D,
                     OP_SBC_ABS   = 6'h0E,
                     OP_AND_ABS   = 6'h0F,
                     OP_EOR_ABS   = 6'h10,
                     OP_ORA_ABS   = 6'h11,
                     OP_ASL       = 6'h12,
                     OP_LSR       = 6'h13,
                     OP_INX       = 6'h14,
                     OP_DEX       = 6'h15,
                     OP_INY       = 6'h16,
                     OP_DEY       = 6'h17,
                     OP_TAX       = 6'h18,
                     OP_TXA       = 6'h19,
                     OP_TAY       = 6'h1A,
                     OP_TYA       = 6'h1B,
                     OP_SEC       = 6'h1C,
                     OP_CLC       = 6'h1D,
                     OP_SEI       = 6'h1E,
                     OP_CLI       = 6'h1F,
                     OP_JMP       = 6'h20,
                     OP_JSR       = 6'h21,
                     OP_RTS       = 6'h22,
                     OP_RTI       = 6'h23,
                     OP_PHA       = 6'h24,
                     OP_PLA       = 6'h25,
                     OP_BEQ       = 6'h26,
                     OP_BNE       = 6'h27,
                     OP_BCS       = 6'h28,
                     OP_BCC       = 6'h29;

    reg [4:0] state;
    
    assign is_halted = (state == STATE_HALTED);
    assign out_pc = pc;
`ifdef OCPU_SIM
    assign dbg_a = a;
    assign dbg_x = x;
    assign dbg_y = y;
    assign dbg_sp = sp;
    assign dbg_sr = sr;
    assign dbg_ir = ir;
    assign dbg_pc = pc;
`endif

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_RESET;
            a <= 0; x <= 0; y <= 0;
            sp <= 6'h3F; pc <= 16'h0000;
            sr <= 6'h00; ir <= 0;
            mem_req <= 0; mem_rw <= 0;
            ea <= 0; mdr <= 0; memAddr <= 0; t1 <= 0; jsr_phase <= 0;
        end else if (force_pc_en) begin
            pc <= force_pc_val;
            state <= STATE_FETCH;
        end else begin
            case (state)
                STATE_RESET: begin
                    if (run_enable) state <= STATE_FETCH;
                end
                
                // never assert mem_req while mem_ready is still high from the prior
                // transfer (arb wait hold); otherwise we complete instantly on stale rdata.
                STATE_FETCH: begin
                    if (mem_ready && mem_req) begin
                        ir <= mem_rdata;
                        mem_req <= 0;
                        pc <= pc + 1;
                        state <= STATE_DECODE;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 0;
                        mem_addr <= pc;
                    end
                end
                
                STATE_DECODE: begin
                    case (ir)
                        OP_LDA_IMM, OP_LDX_IMM, OP_LDY_IMM, OP_BEQ, OP_BNE, OP_BCS, OP_BCC: state <= STATE_OP1; // immediate / rel
                        OP_LDA_ABS, OP_LDX_ABS, OP_LDY_ABS, OP_STA_ABS, OP_STX_ABS, OP_STY_ABS,
                        OP_ADC_ABS, OP_SBC_ABS, OP_AND_ABS, OP_EOR_ABS, OP_ORA_ABS, OP_JMP, OP_JSR: state <= STATE_OP1; // abs
                        OP_LDA_ABS_X, OP_STA_ABS_X: state <= STATE_OP1; // abs, x
                        OP_LDA_IND_Y, OP_STA_IND_Y: state <= STATE_OP1; // ind, y
                        OP_ASL, OP_LSR, OP_INX, OP_DEX, OP_INY, OP_DEY, OP_TAX, OP_TXA, OP_TAY, OP_TYA,
                        OP_SEC, OP_CLC, OP_SEI, OP_CLI, OP_RTS, OP_RTI: state <= STATE_EXECUTE; // implied
                        OP_PHA, OP_PLA: state <= STATE_EXECUTE; // push / pop
                        default: state <= STATE_FETCH; // nop handling
                    endcase
                end

                STATE_OP1: begin
                    if (mem_ready && mem_req) begin
                        ea <= {10'h00, mem_rdata};
                        mem_req <= 0;
                        pc <= pc + 1;
                        if (ir == OP_LDA_IMM || ir == OP_LDX_IMM || ir == OP_LDY_IMM ||
                            ir == OP_BEQ || ir == OP_BNE || ir == OP_BCS || ir == OP_BCC) begin
                            state <= STATE_EXECUTE;
                        end else if (ir == OP_LDA_IND_Y || ir == OP_STA_IND_Y) begin
                            state <= STATE_IND_Y1;
                        end else begin
                            state <= STATE_OP2;
                        end
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 0;
                        mem_addr <= pc;
                    end
                end

                STATE_OP2: begin
                    if (mem_ready && mem_req) begin
                        mem_req <= 0;
                        pc <= pc + 1;
                        if (ir == OP_LDA_ABS_X || ir == OP_STA_ABS_X) begin
                            ea <= {mem_rdata, ea[5:0]} + x;
                        end else begin
                            ea <= {mem_rdata, ea[5:0]};
                        end
                        
                        if (ir == OP_JMP || ir == OP_JSR) begin
                            state <= STATE_EXECUTE;
                        end else if (ir == OP_STA_ABS || ir == OP_STA_ABS_X || ir == OP_STA_IND_Y || ir == OP_STX_ABS || ir == OP_STY_ABS) begin
                            memAddr <= (ir == OP_LDA_ABS_X || ir == OP_STA_ABS_X) ? ({mem_rdata, ea[5:0]} + x) : ({mem_rdata, ea[5:0]});
                            state <= STATE_MEM_WRITE;
                        end else begin
                            memAddr <= (ir == OP_LDA_ABS_X || ir == OP_STA_ABS_X) ? ({mem_rdata, ea[5:0]} + x) : ({mem_rdata, ea[5:0]});
                            state <= STATE_MEM_READ;
                        end
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 0;
                        mem_addr <= pc;
                    end
                end

                STATE_IND_Y1: begin
                    if (mem_ready && mem_req) begin
                        mem_req <= 0;
                        t1 <= mem_rdata;
                        ea[5:0] <= ea[5:0] + 1;
                        state <= STATE_IND_Y2;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 0;
                        mem_addr <= {10'h00, ea[5:0]};
                    end
                end

                STATE_IND_Y2: begin
                    if (mem_ready && mem_req) begin
                        mem_req <= 0;
                        ea <= {mem_rdata, t1} + y;
                        memAddr <= {mem_rdata, t1} + y;
                        if (ir == OP_STA_IND_Y) state <= STATE_MEM_WRITE;
                        else state <= STATE_MEM_READ;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 0;
                        mem_addr <= {10'h00, ea[5:0]};
                    end
                end

                STATE_MEM_READ: begin
                    if (mem_ready && mem_req) begin
                        mem_req <= 0;
                        mdr <= mem_rdata;
                        state <= STATE_EXECUTE;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 0;
                        mem_addr <= memAddr;
                    end
                end
                
                STATE_MEM_WRITE: begin
                    if (mem_ready && mem_req) begin
                        mem_req <= 0;
                        mem_rw <= 0;
                        state <= STATE_FETCH;
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 1;
                        mem_addr <= memAddr;
                        if (ir == OP_STA_ABS || ir == OP_STA_ABS_X || ir == OP_STA_IND_Y) mem_wdata <= a;
                        else if (ir == OP_STX_ABS) mem_wdata <= x;
                        else if (ir == OP_STY_ABS) mem_wdata <= y;
                    end
                end

                STATE_EXECUTE: begin
                    case (ir)
                        OP_LDA_IMM: begin a <= ea[5:0]; sr[1] <= (ea[5:0]==0); end                      // lda #
                        OP_LDA_ABS, OP_LDA_ABS_X, OP_LDA_IND_Y: begin a <= mdr; sr[1] <= (mdr==0); end // lda abs / abs,x / ind,y
                        OP_LDX_IMM: begin x <= ea[5:0]; sr[1] <= (ea[5:0]==0); end                      // ldx #
                        OP_LDX_ABS: begin x <= mdr; sr[1] <= (mdr==0); end                              // ldx abs
                        OP_LDY_IMM: begin y <= ea[5:0]; sr[1] <= (ea[5:0]==0); end                      // ldy #
                        OP_LDY_ABS: begin y <= mdr; sr[1] <= (mdr==0); end                              // ldy abs
                        OP_ADC_ABS: begin // adc
                            automatic logic [6:0] adc_result = a + mdr + sr[0];
                            {sr[0], a} <= adc_result;
                            sr[1] <= (adc_result[5:0] == 0);
                        end
                        OP_SBC_ABS: begin // sbc
                            automatic logic [6:0] sbc_result = a - mdr - ~sr[0];
                            {sr[0], a} <= sbc_result;
                            sr[1] <= (sbc_result[5:0] == 0);
                        end
                        OP_AND_ABS: begin automatic logic [5:0] and_result = a & mdr; a <= and_result; sr[1] <= (and_result==0); end // and
                        OP_EOR_ABS: begin automatic logic [5:0] eor_result = a ^ mdr; a <= eor_result; sr[1] <= (eor_result==0); end // eor
                        OP_ORA_ABS: begin automatic logic [5:0] ora_result = a | mdr; a <= ora_result; sr[1] <= (ora_result==0); end // ora
                        OP_ASL: begin automatic logic [5:0] asl_result = {a[4:0], 1'b0}; sr[0] <= a[5]; a <= asl_result; sr[1] <= (asl_result==0); end // asl
                        OP_LSR: begin automatic logic [5:0] lsr_result = {1'b0, a[5:1]}; sr[0] <= a[0]; a <= lsr_result; sr[1] <= (lsr_result==0); end // lsr
                        OP_INX: begin automatic logic [5:0] inx_result = x + 1; x <= inx_result; sr[1] <= (inx_result==0); end // inx
                        OP_DEX: begin automatic logic [5:0] dex_result = x - 1; x <= dex_result; sr[1] <= (dex_result==0); end // dex
                        OP_INY: begin automatic logic [5:0] iny_result = y + 1; y <= iny_result; sr[1] <= (iny_result==0); end // iny
                        OP_DEY: begin automatic logic [5:0] dey_result = y - 1; y <= dey_result; sr[1] <= (dey_result==0); end // dey
                        OP_TAX: begin x <= a; sr[1] <= (a==0); end // tax
                        OP_TXA: begin a <= x; sr[1] <= (x==0); end // txa
                        OP_TAY: begin y <= a; sr[1] <= (a==0); end // tay
                        OP_TYA: begin a <= y; sr[1] <= (y==0); end // tya
                        OP_SEC: sr[0] <= 1; // sec
                        OP_CLC: sr[0] <= 0; // clc
                        OP_SEI: sr[2] <= 1; // sei
                        OP_CLI: sr[2] <= 0; // cli
                        OP_JMP: pc <= ea;   // jmp
                        OP_BEQ: if (sr[1]) pc <= pc + {{10{ea[5]}}, ea[5:0]};   // beq
                        OP_BNE: if (!sr[1]) pc <= pc + {{10{ea[5]}}, ea[5:0]};  // bne
                        OP_BCS: if (sr[0]) pc <= pc + {{10{ea[5]}}, ea[5:0]};   // bcs
                        OP_BCC: if (!sr[0]) pc <= pc + {{10{ea[5]}}, ea[5:0]};  // bcc
                        OP_JSR: begin // jsr
                            state <= STATE_PUSH;
                            t1 <= (pc - 16'd1) >> 6;   // push high half of (return addr - 1)
                            jsr_phase <= 0;
                        end
                        OP_RTS: begin // rts
                            state <= STATE_POP;
                            t1 <= 0;
                        end
                        OP_PHA: begin // pha
                            state <= STATE_PUSH;
                            t1 <= a;
                        end
                        OP_PLA: begin // pla
                            state <= STATE_POP;
                        end
                        default: ;
                    endcase
                    
                    if (ir != OP_JSR && ir != OP_RTS && ir != OP_PHA && ir != OP_PLA) begin
                        state <= (!run_enable) ? STATE_HALTED : STATE_FETCH;
                    end
                end

                STATE_PUSH: begin
                    if (mem_ready && mem_req) begin
                        sp <= sp - 1;
                        mem_req <= 0;
                        mem_rw <= 0;
                        if (ir == OP_JSR && !jsr_phase) begin
                            t1 <= (pc - 16'd1) & 16'h003f; // pushed pc_h, now load pc_l
                            jsr_phase <= 1;
                        end else if (ir == OP_JSR) begin
                            pc <= ea;
                            state <= STATE_FETCH;
                        end else begin
                            state <= STATE_FETCH;
                        end
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 1;
                        mem_addr <= {10'h001, sp};
                        mem_wdata <= t1;
                    end
                end
                
                STATE_POP: begin
                    if (mem_ready && mem_req) begin
                        sp <= sp + 1;
                        mem_req <= 0;
                        if (ir == OP_PLA) begin
                            a <= mem_rdata;
                            sr[1] <= (mem_rdata == 0);
                            state <= STATE_FETCH;
                        end else if (ir == OP_RTS && t1 == 0) begin
                            t1 <= mem_rdata; // popped pc_l
                            state <= STATE_POP;
                        end else if (ir == OP_RTS) begin
                            pc <= {mem_rdata, t1} + 1; // popped pc_h, return address + 1
                            state <= STATE_FETCH;
                        end
                    end else if (!mem_req && !mem_ready) begin
                        mem_req <= 1;
                        mem_rw <= 0;
                        mem_addr <= {10'h001, sp + 6'd1};
                    end
                end

                STATE_HALTED: begin
                    if (run_enable) state <= STATE_FETCH;
                end

                default: begin
                    state <= STATE_FETCH;
                end
            endcase
        end
    end
endmodule
