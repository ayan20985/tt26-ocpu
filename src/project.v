`default_nettype none

module tt_um_ocpu (
    input  wire [7:0] ui_in,    // dedicated inputs.
    output wire [7:0] uo_out,   // dedicated outputs.
    input  wire [7:0] uio_in,   // IO input path.
    output wire [7:0] uio_out,  // IO output path.
    output wire [7:0] uio_oe,   // IO enable path (active high, 0 is input, 1 is output).
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it.
    input  wire       clk,      // clock signal.
    input  wire       rst_n     // active low reset signal.
`ifdef OCPU_SIM
    ,
    output wire [5:0] dbg_a,
    output wire [5:0] dbg_x,
    output wire [5:0] dbg_y,
    output wire [5:0] dbg_sp,
    output wire [5:0] dbg_sr,
    output wire [5:0] dbg_ir,
    output wire [15:0] dbg_pc,
    output wire [5:0] dbg_mmio_bank,
    output wire [5:0] dbg_oc_cache
`endif
);
 reg cache [5:0][31:0];
    // shared system registers
    reg [5:0] mmio_bank;     // mmio bank register for memory paging beyond 64kb.
    reg [5:0] oc_cache;      // overclocking diagnostic cache register.
    
    // master fsm setup
    localparam MASTER_STATE_INIT = 0,
               MASTER_STATE_RUN  = 1;

    reg [1:0] master_state;
    
    wire core0_halted;
    
    reg core0_run_en;

    wire [15:0] core0_pc;
    
    // memory interface lines for core
    wire        c0_mem_req;
    wire        c0_mem_rw;
    wire [15:0] c0_mem_addr;
    wire [5:0]  c0_mem_wdata;
    reg         c0_mem_ready;
    reg  [5:0]  c0_mem_rdata;

    ocpu_core core0 (
        .clk(clk),
        .rst_n(rst_n),
        .run_enable(core0_run_en),
        .is_halted(core0_halted),
`ifdef OCPU_SIM
        .dbg_a(dbg_a),
        .dbg_x(dbg_x),
        .dbg_y(dbg_y),
        .dbg_sp(dbg_sp),
        .dbg_sr(dbg_sr),
        .dbg_ir(dbg_ir),
        .dbg_pc(dbg_pc),
`endif
        .out_pc(core0_pc),
        .force_pc_en(1'b0),
        .force_pc_val(16'b0),
        .mem_req(c0_mem_req),
        .mem_rw(c0_mem_rw),
        .mem_addr(c0_mem_addr),
        .mem_wdata(c0_mem_wdata),
        .mem_ready(c0_mem_ready),
        .mem_rdata(c0_mem_rdata)
    );

    // spi fsm states and memory bus
    wire spi_miso = ui_in[0];
    wire spi_sck;
    wire spi_cs_n;
    wire spi_mosi;
    wire pll_ctrl = (mmio_bank[5]);
    
    assign uo_out[0] = spi_sck;
    assign uo_out[1] = spi_cs_n;
    assign uo_out[2] = spi_mosi;
    assign uo_out[3] = pll_ctrl;
    assign uo_out[7:4] = 4'b0000;
    
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;
    wire _unused_ok = &{ena, ui_in[7:1], uio_in};
`ifdef OCPU_SIM
    assign dbg_mmio_bank = mmio_bank;
    assign dbg_oc_cache = oc_cache;
`endif

    reg        spi_req;
    reg        spi_rw;
    reg [23:0] spi_addr;
    reg [5:0]  spi_wdata;
    wire       spi_ready;
    wire [5:0] spi_rdata;

    spi_memory spi_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .req(spi_req),
        .rw(spi_rw),
        .addr(spi_addr),
        .wdata(spi_wdata),
        .ready(spi_ready),
        .rdata(spi_rdata),
        .sck(spi_sck),
        .cs_n(spi_cs_n),
        .mosi(spi_mosi),
        .miso(spi_miso)
    );

    localparam ARB_IDLE    = 2'd0,
               ARB_C0_REQ  = 2'd1,
               ARB_C0_RESP = 2'd2;
    
    reg [1:0] arb_state;

    // memory bus arbitration (single core)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            master_state <= MASTER_STATE_INIT;
            mmio_bank <= 0;
            oc_cache <= 0;
            core0_run_en <= 0;
            spi_req <= 0;
            arb_state <= ARB_IDLE;
            c0_mem_ready <= 0;
        end else begin
            c0_mem_ready <= 0;

            case (arb_state)
                ARB_IDLE: begin
                    if (c0_mem_req) begin
                        if (c0_mem_rw && c0_mem_addr == 16'h00FF) begin
                            mmio_bank <= c0_mem_wdata;
                            c0_mem_ready <= 1;
                        end else if (c0_mem_rw && c0_mem_addr == 16'h00FE) begin
                            oc_cache <= c0_mem_wdata;
                            c0_mem_ready <= 1;
                        end else if (!c0_mem_rw && c0_mem_addr == 16'h00FE) begin
                            c0_mem_rdata <= oc_cache;
                            c0_mem_ready <= 1;
                        end else if (c0_mem_rw && c0_mem_addr == 16'h00FC) begin
                            // former simd entry mmio: single core completes the cycle only
                            c0_mem_ready <= 1;
                        end else begin
                            spi_req <= 1;
                            spi_rw <= c0_mem_rw;
                            spi_addr <= {{2'b00, mmio_bank}, c0_mem_addr};
                            spi_wdata <= c0_mem_wdata;
                            arb_state <= ARB_C0_REQ;
                        end
                    end
                end

                ARB_C0_REQ: begin
                    if (spi_ready && spi_req) begin
                        spi_req <= 0;
                        c0_mem_rdata <= spi_rdata;
                        arb_state <= ARB_C0_RESP;
                    end
                end

                ARB_C0_RESP: begin
                    c0_mem_ready <= 1;
                    arb_state <= ARB_IDLE;
                end

                default: arb_state <= ARB_IDLE;
            endcase

            // fsm execution flow rules
            if (master_state == MASTER_STATE_INIT) begin
                core0_run_en <= 1;
                master_state <= MASTER_STATE_RUN;
            end
        end
    end

endmodule
