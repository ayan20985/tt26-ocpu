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

    wire pll_ctrl = (mmio_bank[5]);

    // on-chip sram backing store (4k x 6); replaces off-chip spi for this top.
    reg [5:0] sramMem [0:4095];
    wire [11:0] sramAddr = c0_mem_addr[11:0];
    wire [5:0] sramRdata = sramMem[sramAddr];

    localparam ARB_IDLE    = 2'd0,
               ARB_C0_WAIT = 2'd1;

    reg [1:0] arb_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
        end else begin
            if (arb_state == ARB_IDLE && c0_mem_req && c0_mem_rw &&
                !(c0_mem_addr == 16'h00FF || c0_mem_addr == 16'h00FE || c0_mem_addr == 16'h00FC)) begin
                sramMem[sramAddr] <= c0_mem_wdata;
            end
        end
    end

    // gds-only instances: req tied low so fsm stays idle; outputs folded into uo_out so logic is retained.
    wire [3:0] gdsQspiIoI;
    wire [7:0] gdsOspiIoI;
    wire       gdsQspiReady;
    wire [5:0] gdsQspiRdata;
    wire       gdsQspiSck;
    wire       gdsQspiCsN;
    wire [3:0] gdsQspiIoO;
    wire [3:0] gdsQspiIoOe;

    wire       gdsOspiReady;
    wire [5:0] gdsOspiRdata;
    wire       gdsOspiSck;
    wire       gdsOspiCsN;
    wire [7:0] gdsOspiIoO;
    wire [7:0] gdsOspiIoOe;

    assign gdsQspiIoI = ui_in[3:0];
    assign gdsOspiIoI = uio_in[7:0];

    (* keep_hierarchy *)
    qspi_memory gds_qspi_macron (
        .clk(clk),
        .rst_n(rst_n),
        .req(1'b0),
        .rw(1'b0),
        .addr(24'b0),
        .wdata(6'b0),
        .ready(gdsQspiReady),
        .rdata(gdsQspiRdata),
        .sck(gdsQspiSck),
        .cs_n(gdsQspiCsN),
        .io_o(gdsQspiIoO),
        .io_i(gdsQspiIoI),
        .io_oe(gdsQspiIoOe)
    );

    (* keep_hierarchy *)
    ospi_memory gds_ospi_macron (
        .clk(clk),
        .rst_n(rst_n),
        .req(1'b0),
        .rw(1'b0),
        .addr(24'b0),
        .wdata(6'b0),
        .ready(gdsOspiReady),
        .rdata(gdsOspiRdata),
        .sck(gdsOspiSck),
        .cs_n(gdsOspiCsN),
        .io_o(gdsOspiIoO),
        .io_i(gdsOspiIoI),
        .io_oe(gdsOspiIoOe)
    );

    wire qspiFold = ^{gdsQspiSck, gdsQspiCsN, gdsQspiIoO, gdsQspiIoOe};
    wire ospiFold = ^{gdsOspiSck, gdsOspiCsN, gdsOspiIoO, gdsOspiIoOe};
    wire metaFold = ^{gdsQspiReady, gdsOspiReady, gdsQspiRdata, gdsOspiRdata};

    assign uo_out[0] = pll_ctrl ^ qspiFold;
    assign uo_out[1] = qspiFold ^ ospiFold;
    assign uo_out[2] = ospiFold ^ metaFold;
    assign uo_out[3] = pll_ctrl;
    assign uo_out[4] = gdsQspiSck ^ gdsOspiSck;
    assign uo_out[5] = gdsQspiCsN ^ gdsOspiCsN;
    assign uo_out[6] = ^{gdsQspiIoO, gdsOspiIoO[3:0]};
    assign uo_out[7] = metaFold ^ ^{gdsOspiIoO[7:4]};

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;
    wire _unused_ok = &{ena, ui_in[7:4], uio_in};
`ifdef OCPU_SIM
    assign dbg_mmio_bank = mmio_bank;
    assign dbg_oc_cache = oc_cache;
`endif

    // memory bus arbitration (single core) — mmio + on-chip sram
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            master_state <= MASTER_STATE_INIT;
            mmio_bank <= 0;
            oc_cache <= 0;
            core0_run_en <= 0;
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
                            arb_state <= ARB_C0_WAIT;
                        end else if (c0_mem_rw && c0_mem_addr == 16'h00FE) begin
                            oc_cache <= c0_mem_wdata;
                            c0_mem_ready <= 1;
                            arb_state <= ARB_C0_WAIT;
                        end else if (!c0_mem_rw && c0_mem_addr == 16'h00FE) begin
                            c0_mem_rdata <= oc_cache;
                            c0_mem_ready <= 1;
                            arb_state <= ARB_C0_WAIT;
                        end else if (c0_mem_rw && c0_mem_addr == 16'h00FC) begin
                            c0_mem_ready <= 1;
                            arb_state <= ARB_C0_WAIT;
                        end else if (!c0_mem_rw) begin
                            c0_mem_rdata <= sramRdata;
                            c0_mem_ready <= 1;
                            arb_state <= ARB_C0_WAIT;
                        end else begin
                            c0_mem_ready <= 1;
                            arb_state <= ARB_C0_WAIT;
                        end
                    end
                end

                ARB_C0_WAIT: begin
                    if (!c0_mem_req) begin
                        arb_state <= ARB_IDLE;
                    end
                end

                default: arb_state <= ARB_IDLE;
            endcase

            if (master_state == MASTER_STATE_INIT) begin
                core0_run_en <= 1;
                master_state <= MASTER_STATE_RUN;
            end
        end
    end

endmodule
