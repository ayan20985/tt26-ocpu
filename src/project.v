/*
 * Copyright (c) 2024 Uri Shaked
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_ocpu (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

    // ==========================================
    // CPU Registers
    // ==========================================
    reg [7:0] a;      // Accumulator
    reg [7:0] x;      // X index register
    reg [7:0] y;      // Y index register
    reg [7:0] sp;     // Stack pointer
    reg [15:0] pc;    // Program counter
    reg [7:0] sr;     // Status register (NV-BDIZC)
    
    reg [7:0] ir;     // Instruction register
    reg [7:0] mdr;    // Memory data register
    reg [15:0] addr;  // Address bus register
    
    // ==========================================
    // FSM States
    // ==========================================
    localparam STATE_RESET = 0,
               STATE_FETCH = 1,
               STATE_DECODE = 2,
               STATE_EXECUTE = 3;
               
    reg [2:0] state;
    
    // Status Register Flags
    wire flag_c = sr[0]; // Carry
    wire flag_z = sr[1]; // Zero
    wire flag_i = sr[2]; // Interrupt Disable
    wire flag_d = sr[3]; // Decimal Mode (ignored)
    wire flag_b = sr[4]; // Break
    // bit 5 unused
    wire flag_v = sr[6]; // Overflow
    wire flag_n = sr[7]; // Negative

    // Placeholder assignments for now (so TinyTapeout builds correctly)
    assign uo_out  = a;  // Map accumulator to output just for visibility right now
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;
    wire _unused_ok = &{ena, ui_in, uio_in, R, G, B, hsync, vsync, video_active, pix_x, pix_y};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_RESET;
            a  <= 0;
            x  <= 0;
            y  <= 0;
            sp <= 8'hFF;
            pc <= 16'h0000;
            sr <= 8'h20; // Default status state natively
            ir <= 0;
            mdr <= 0;
            addr <= 0;
        end else begin
            case (state)
                STATE_RESET: begin
                    // Initialize PC from reset vector eventually
                    state <= STATE_FETCH;
                end
                
                STATE_FETCH: begin
                    // Fetch instruction byte
                    // Next state: wait for serial memory or DECODE
                    state <= STATE_DECODE;
                end
                
                STATE_DECODE: begin
                    // Load IR and transition to specific execute cycles based on opcode
                    state <= STATE_EXECUTE;
                end
                
                STATE_EXECUTE: begin
                    // Execute the instruction, adjust PC
                    state <= STATE_FETCH;
                end
                
                default: state <= STATE_RESET;
            endcase
        end
    end

endmodule
