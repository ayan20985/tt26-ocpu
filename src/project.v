default_nettype none

module tt_um_ocpu (
    input  wire [7:0] ui_in,    // dedicated inputs.
    output wire [7:0] uo_out,   // dedicated outputs.
    input  wire [7:0] uio_in,   // IO input path.
    output wire [7:0] uio_out,  // IO output path.
    output wire [7:0] uio_oe,   // IO enable path (active high, 0 is input, 1 is output).
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it.
    input  wire       clk,      // clock signal.
    input  wire       rst_n     // active low reset signal.
);

    // shared system registers
    reg [7:0] mmio_bank;     // mmio bank register for memory paging beyond 64kb.
    reg [7:0] oc_cache;      // overclocking diagnostic cache register.
    
    // master fsm setup
    localparam MASTER_STATE_INIT = 0,
               MASTER_STATE_RUN  = 1,
               MASTER_STATE_HALT = 2,
               MASTER_STATE_SIMD = 3;

    reg [1:0] master_state;
    
    wire core0_halted;
    wire core1_halted;
    
    reg core0_run_en;
    reg core1_run_en;

    wire [15:0] core0_pc, core1_pc;
    reg         force_pc_en;
    reg  [15:0] force_pc_val;
    
    // memory interface lines for cores
    wire        c0_mem_req,  c1_mem_req;
    wire        c0_mem_rw,   c1_mem_rw;
    wire [15:0] c0_mem_addr, c1_mem_addr;
    wire [7:0]  c0_mem_wdata, c1_mem_wdata;
    reg         c0_mem_ready, c1_mem_ready;
    reg  [7:0]  c0_mem_rdata, c1_mem_rdata;

    ocpu_core core0 (
        .clk(clk),
        .rst_n(rst_n),
        .run_enable(core0_run_en),
        .is_halted(core0_halted),
        .out_pc(core0_pc),
        .force_pc_en(force_pc_en),
        .force_pc_val(force_pc_val),
        .mem_req(c0_mem_req),
        .mem_rw(c0_mem_rw),
        .mem_addr(c0_mem_addr),
        .mem_wdata(c0_mem_wdata),
        .mem_ready(c0_mem_ready),
        .mem_rdata(c0_mem_rdata)
    );

    ocpu_core core1 (
        .clk(clk),
        .rst_n(rst_n),
        .run_enable(core1_run_en),
        .is_halted(core1_halted),
        .out_pc(core1_pc),
        .force_pc_en(force_pc_en),
        .force_pc_val(force_pc_val),
        .mem_req(c1_mem_req),
        .mem_rw(c1_mem_rw),
        .mem_addr(c1_mem_addr),
        .mem_wdata(c1_mem_wdata),
        .mem_ready(c1_mem_ready),
        .mem_rdata(c1_mem_rdata)
    );

    // spi fsm states and memory bus
    wire spi_miso = ui_in[0];
    wire spi_sck;
    wire spi_cs_n;
    wire spi_mosi;
    wire pll_ctrl = (mmio_bank[7]);
    
    assign uo_out[0] = spi_sck;
    assign uo_out[1] = spi_cs_n;
    assign uo_out[2] = spi_mosi;
    assign uo_out[3] = pll_ctrl;
    assign uo_out[7:4] = 4'b0000;
    
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;
    wire _unused_ok = &{ena, ui_in[7:1], uio_in};

    reg        spi_req;
    reg        spi_rw;
    reg [23:0] spi_addr;
    reg [7:0]  spi_wdata;
    wire       spi_ready;
    wire [7:0] spi_rdata;

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

    localparam ARB_IDLE         = 3'd0,
               ARB_C0_REQ       = 3'd1,
               ARB_C1_REQ       = 3'd2,
               ARB_SIMD_FETCH   = 3'd3,
               ARB_SIMD_DATA_C0 = 3'd4,
               ARB_SIMD_DATA_C1 = 3'd5;
    
    reg [2:0] arb_state;

    // memory bus arbitration framework
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            master_state <= MASTER_STATE_INIT;
            mmio_bank <= 0;
            oc_cache <= 0;
            core0_run_en <= 0;
            core1_run_en <= 0;
            spi_req <= 0;
            arb_state <= ARB_IDLE;
            force_pc_en <= 0;
            force_pc_val <= 0;
            c0_mem_ready <= 0;
            c1_mem_ready <= 0;
        end else begin
            c0_mem_ready <= 0;
            c1_mem_ready <= 0;
            force_pc_en <= 0;

            case (arb_state)
                ARB_IDLE: begin
                    if (master_state == MASTER_STATE_SIMD) begin
                        if (c0_mem_req && c1_mem_req) begin
                            // simd mode: wait for both to request
                            if (c0_mem_addr == c1_mem_addr && c0_mem_rw == c1_mem_rw) begin
                                // identical fetch/access
                                spi_req <= 1;
                                spi_rw <= c0_mem_rw;
                                spi_addr <= {mmio_bank, c0_mem_addr};
                                spi_wdata <= c0_mem_wdata;
                                arb_state <= ARB_SIMD_FETCH;
                            end else begin
                                // divergent data access
                                spi_req <= 1;
                                spi_rw <= c0_mem_rw;
                                spi_addr <= {mmio_bank, c0_mem_addr};
                                spi_wdata <= c0_mem_wdata;
                                arb_state <= ARB_SIMD_DATA_C0;
                            end
                        end
                    end else begin
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
                                // mmio hijack trigger to enter simd mode
                                master_state <= MASTER_STATE_SIMD;
                                force_pc_en <= 1;
                                force_pc_val <= core0_pc; // sync core1 to core0
                                c0_mem_ready <= 1;
                            end else begin
                                spi_req <= 1;
                                spi_rw <= c0_mem_rw;
                                spi_addr <= {mmio_bank, c0_mem_addr};
                                spi_wdata <= c0_mem_wdata;
                                arb_state <= ARB_C0_REQ;
                            end
                        end else if (c1_mem_req) begin
                            // core 1 standard accesses
                            if (c1_mem_rw && c1_mem_addr == 16'h00FF) begin
                                mmio_bank <= c1_mem_wdata;
                                c1_mem_ready <= 1;
                            end else if (c1_mem_rw && c1_mem_addr == 16'h00FE) begin
                                oc_cache <= c1_mem_wdata;
                                c1_mem_ready <= 1;
                            end else if (!c1_mem_rw && c1_mem_addr == 16'h00FE) begin
                                c1_mem_rdata <= oc_cache;
                                c1_mem_ready <= 1;
                            end else begin
                                spi_req <= 1;
                                spi_rw <= c1_mem_rw;
                                spi_addr <= {mmio_bank, c1_mem_addr};
                                spi_wdata <= c1_mem_wdata;
                                arb_state <= ARB_C1_REQ;
                            end
                        end
                    end
                end

                ARB_C0_REQ: begin
                    if (spi_ready && spi_req) begin
                        spi_req <= 0;
                        c0_mem_rdata <= spi_rdata;
                        c0_mem_ready <= 1;
                        arb_state <= ARB_IDLE;
                    end
                end

                ARB_C1_REQ: begin
                    if (spi_ready && spi_req) begin
                        spi_req <= 0;
                        c1_mem_rdata <= spi_rdata;
                        c1_mem_ready <= 1;
                        arb_state <= ARB_IDLE;
                    end
                end

                ARB_SIMD_FETCH: begin
                    if (spi_ready && spi_req) begin
                        spi_req <= 0;
                        c0_mem_rdata <= spi_rdata;
                        c1_mem_rdata <= spi_rdata;
                        c0_mem_ready <= 1;
                        c1_mem_ready <= 1; // lockstep alignment via matched ready signals
                        arb_state <= ARB_IDLE;
                    end
                end

                ARB_SIMD_DATA_C0: begin
                    if (spi_ready && spi_req) begin
                        spi_req <= 0;
                        c0_mem_rdata <= spi_rdata;
                        // wait, store but don't assert ready yet. pass token to c1.
                        spi_req <= 1;
                        spi_rw <= c1_mem_rw;
                        spi_addr <= {mmio_bank, c1_mem_addr};
                        spi_wdata <= c1_mem_wdata;
                        arb_state <= ARB_SIMD_DATA_C1;
                    end
                end

                ARB_SIMD_DATA_C1: begin
                    if (spi_ready && spi_req) begin
                        spi_req <= 0;
                        c1_mem_rdata <= spi_rdata;
                        // assert both ready exactly same time to preserve lockstep
                        c0_mem_ready <= 1;
                        c1_mem_ready <= 1;
                        arb_state <= ARB_IDLE;
                    end
                end
            endcase

            // fsm execution flow rules
            if (master_state == MASTER_STATE_INIT) begin
                core0_run_en <= 1;
                core1_run_en <= 1;
                master_state <= MASTER_STATE_RUN;
            end
        end
    end

endmodule
