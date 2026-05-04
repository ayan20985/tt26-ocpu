\default_nettype none

module ocpu_core (
    input  wire        clk,
    input  wire        rst_n,
    
    input  wire        run_enable,
    output wire        is_halted,

    output wire [15:0] out_pc,
    input  wire        force_pc_en,
    input  wire [15:0] force_pc_val,
    
    output reg         mem_req,
    output reg         mem_rw,
    output reg  [15:0] mem_addr,
    output reg  [7:0]  mem_wdata,
    input  wire        mem_ready,
    input  wire [7:0]  mem_rdata
);

    reg [7:0] a;      
    reg [7:0] x;      
    reg [7:0] y;      
    reg [7:0] sp;     
    reg [15:0] pc;    
    reg [7:0] sr;     
    reg [7:0] ir;     

    reg [15:0] ea;
    reg [7:0] t1;

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

    reg [4:0] state;
    
    assign is_halted = (state == STATE_HALTED);
    assign out_pc = pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_RESET;
            a <= 0; x <= 0; y <= 0;
            sp <= 8'hFF; pc <= 16'h0000;
            sr <= 8'h20; ir <= 0;
            mem_req <= 0; mem_rw <= 0;
            ea <= 0; t1 <= 0;
        end else if (force_pc_en) begin
            pc <= force_pc_val;
            state <= STATE_FETCH;
        end else begin
            case (state)
                STATE_RESET: begin
                    if (run_enable) state <= STATE_FETCH;
                end
                
                STATE_FETCH: begin
                    mem_req <= 1;
                    mem_rw <= 0;
                    mem_addr <= pc;
                    if (mem_ready) begin
                        ir <= mem_rdata;
                        mem_req <= 0;
                        pc <= pc + 1;
                        state <= STATE_DECODE;
                    end
                end
                
                STATE_DECODE: begin
                    case (ir)
                        8'hA9, 8'hA2, 8'hA0, 8'hF0, 8'hD0, 8'hB0, 8'h90: state <= STATE_OP1; // immediate / rel
                        8'hAD, 8'hAE, 8'hAC, 8'h8D, 8'h8E, 8'h8C, 8'h6D, 8'hED, 8'h2D, 8'h4D, 8'h0D, 8'h4C, 8'h20: state <= STATE_OP1; // abs
                        8'hBD, 8'h9D: state <= STATE_OP1; // abs, x
                        8'hB1, 8'h91: state <= STATE_OP1; // ind, y
                        8'h0A, 8'h4A, 8'hE8, 8'hCA, 8'hC8, 8'h88, 8'hAA, 8'h8A, 8'hA8, 8'h98, 8'h38, 8'h18, 8'h78, 8'h58, 8'h60, 8'h40: state <= STATE_EXECUTE; // implied
                        8'h48, 8'h68: state <= STATE_EXECUTE; // push / pop
                        default: state <= STATE_FETCH; // nop handling
                    endcase
                end

                STATE_OP1: begin
                    mem_req <= 1; mem_rw <= 0; mem_addr <= pc;
                    if (mem_ready) begin
                        ea[7:0] <= mem_rdata;
                        mem_req <= 0; pc <= pc + 1;
                        if (ir == 8'hA9 || ir == 8'hA2 || ir == 8'hA0 || ir == 8'hF0 || ir == 8'hD0 || ir == 8'hB0 || ir == 8'h90) begin
                            state <= STATE_EXECUTE;
                        end else if (ir == 8'hB1 || ir == 8'h91) begin
                            state <= STATE_IND_Y1;
                        end else begin
                            state <= STATE_OP2;
                        end
                    end
                end

                STATE_OP2: begin
                    mem_req <= 1; mem_rw <= 0; mem_addr <= pc;
                    if (mem_ready) begin
                        ea[15:8] <= mem_rdata;
                        mem_req <= 0; pc <= pc + 1;
                        if (ir == 8'hBD || ir == 8'h9D) begin
                            ea <= {mem_rdata, ea[7:0]} + x;
                        end else begin
                            ea <= {mem_rdata, ea[7:0]};
                        end
                        
                        if (ir == 8'h4C || ir == 8'h20) state <= STATE_EXECUTE;
                        else if (ir == 8'h8D || ir == 8'h8E || ir == 8'h8C || ir == 8'h9D) state <= STATE_MEM_WRITE;
                        else state <= STATE_MEM_READ;
                    end
                end

                STATE_IND_Y1: begin
                    mem_req <= 1; mem_rw <= 0; mem_addr <= {8'h00, ea[7:0]};
                    if (mem_ready) begin
                        t1 <= mem_rdata;
                        mem_req <= 0;
                        ea[7:0] <= ea[7:0] + 1;
                        state <= STATE_IND_Y2;
                    end
                end

                STATE_IND_Y2: begin
                    mem_req <= 1; mem_rw <= 0; mem_addr <= {8'h00, ea[7:0]};
                    if (mem_ready) begin
                        ea <= {mem_rdata, t1} + y;
                        mem_req <= 0;
                        if (ir == 8'h91) state <= STATE_MEM_WRITE;
                        else state <= STATE_MEM_READ;
                    end
                end

                STATE_MEM_READ: begin
                    mem_req <= 1; mem_rw <= 0; mem_addr <= ea;
                    if (mem_ready) begin
                        ea[7:0] <= mem_rdata; // reuse ea for read data
                        mem_req <= 0;
                        state <= STATE_EXECUTE;
                    end
                end
                
                STATE_MEM_WRITE: begin
                    mem_req <= 1; mem_rw <= 1; mem_addr <= ea;
                    if (ir == 8'h8D || ir == 8'h9D || ir == 8'h91) mem_wdata <= a;
                    else if (ir == 8'h8E) mem_wdata <= x;
                    else if (ir == 8'h8C) mem_wdata <= y;
                    
                    if (mem_ready) begin
                        mem_req <= 0;
                        mem_rw <= 0;
                        state <= STATE_FETCH;
                    end
                end

                STATE_EXECUTE: begin
                    case (ir)
                        8'hA9, 8'hAD, 8'hBD, 8'hB1: begin a <= ea[7:0]; sr[1] <= (ea[7:0]==0); sr[7] <= ea[7]; end // lda
                        8'hA2, 8'hAE: begin x <= ea[7:0]; sr[1] <= (ea[7:0]==0); sr[7] <= ea[7]; end // ldx
                        8'hA0, 8'hAC: begin y <= ea[7:0]; sr[1] <= (ea[7:0]==0); sr[7] <= ea[7]; end // ldy
                        8'h6D: begin // adc
                            {sr[0], a} <= a + ea[7:0] + sr[0];
                            sr[1] <= (a + ea[7:0] + sr[0] == 0);
                            sr[7] <= a[7];
                        end
                        8'hED: begin // sbc
                            {sr[0], a} <= a - ea[7:0] - ~sr[0]; // simple inverted carry sub
                            sr[1] <= (a - ea[7:0] - ~sr[0] == 0);
                            sr[7] <= a[7];
                        end
                        8'h2D: begin a <= a & ea[7:0]; sr[1] <= ((a & ea[7:0])==0); sr[7] <= a[7]; end // and
                        8'h4D: begin a <= a ^ ea[7:0]; sr[1] <= ((a ^ ea[7:0])==0); sr[7] <= a[7]; end // eor
                        8'h0D: begin a <= a | ea[7:0]; sr[1] <= ((a | ea[7:0])==0); sr[7] <= a[7]; end // ora
                        8'h0A: begin sr[0] <= a[7]; a <= {a[6:0], 1'b0}; sr[1] <= (a[6:0]==0); sr[7] <= a[6]; end // asl
                        8'h4A: begin sr[0] <= a[0]; a <= {1'b0, a[7:1]}; sr[1] <= (a[7:1]==0); sr[7] <= 0; end // lsr
                        8'hE8: begin x <= x + 1; sr[1] <= (x+1==0); sr[7] <= x[7]; end // inx
                        8'hCA: begin x <= x - 1; sr[1] <= (x-1==0); sr[7] <= x[7]; end // dex
                        8'hC8: begin y <= y + 1; sr[1] <= (y+1==0); sr[7] <= y[7]; end // iny
                        8'h88: begin y <= y - 1; sr[1] <= (y-1==0); sr[7] <= y[7]; end // dey
                        8'hAA: begin x <= a; sr[1] <= (a==0); sr[7] <= a[7]; end // tax
                        8'h8A: begin a <= x; sr[1] <= (x==0); sr[7] <= x[7]; end // txa
                        8'hA8: begin y <= a; sr[1] <= (a==0); sr[7] <= a[7]; end // tay
                        8'h98: begin a <= y; sr[1] <= (y==0); sr[7] <= y[7]; end // tya
                        8'h38: sr[0] <= 1; // sec
                        8'h18: sr[0] <= 0; // clc
                        8'h78: sr[2] <= 1; // sei
                        8'h58: sr[2] <= 0; // cli
                        8'h4C: pc <= ea; // jmp
                        8'hF0: if (sr[1]) pc <= pc + {{8{ea[7]}}, ea[7:0]}; // beq
                        8'hD0: if (!sr[1]) pc <= pc + {{8{ea[7]}}, ea[7:0]}; // bne
                        8'hB0: if (sr[0]) pc <= pc + {{8{ea[7]}}, ea[7:0]}; // bcs
                        8'h90: if (!sr[0]) pc <= pc + {{8{ea[7]}}, ea[7:0]}; // bcc
                        8'h20: begin // jsr
                            state <= STATE_PUSH;
                            t1 <= pc[15:8];
                        end
                        8'h60: begin // rts
                            state <= STATE_POP;
                            t1 <= 0;
                        end
                        8'h48: begin // pha
                            state <= STATE_PUSH;
                            t1 <= a;
                        end
                        8'h68: begin // pla
                            state <= STATE_POP;
                        end
                        default: ;
                    endcase
                    
                    if (ir != 8'h20 && ir != 8'h60 && ir != 8'h48 && ir != 8'h68) begin
                        state <= (!run_enable) ? STATE_HALTED : STATE_FETCH;
                    end
                end

                STATE_PUSH: begin
                    mem_req <= 1; mem_rw <= 1; mem_addr <= {8'h01, sp}; mem_wdata <= t1;
                    if (mem_ready) begin
                        sp <= sp - 1;
                        mem_req <= 0;
                        mem_rw <= 0;
                        if (ir == 8'h20 && t1 == pc[15:8]) begin
                            t1 <= pc[7:0]; // jsr pushes pc_l on next cycle
                        end else if (ir == 8'h20) begin
                            pc <= ea;
                            state <= STATE_FETCH;
                        end else begin
                            state <= STATE_FETCH;
                        end
                    end
                end
                
                STATE_POP: begin
                    mem_req <= 1; mem_rw <= 0; mem_addr <= {8'h01, sp + 1};
                    if (mem_ready) begin
                        sp <= sp + 1;
                        mem_req <= 0;
                        if (ir == 8'h68) begin
                            a <= mem_rdata;
                            state <= STATE_FETCH;
                        end else if (ir == 8'h60 && t1 == 0) begin
                            t1 <= mem_rdata; // popped pc_l
                        end else if (ir == 8'h60) begin
                            pc <= {mem_rdata, t1} + 1; // popped pc_h, return address + 1
                            state <= STATE_FETCH;
                        end
                    end
                end

                STATE_HALTED: begin
                    if (run_enable) state <= STATE_FETCH;
                end
            endcase
        end
    end
endmodule
