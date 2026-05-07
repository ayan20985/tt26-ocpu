`default_nettype none

// minimal top for qspi-only area experiments; full design lives in old-src/project_full.v
module tt_um_ocpu (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire       qspiReady;
    wire [5:0] qspiRdata;
    wire       qspiSck;
    wire       qspiCsN;
    wire [3:0] qspiIoO;
    wire [3:0] qspiIoI;
    wire [3:0] qspiIoOe;

    // io data nibbles for read phases; keep ui_in[7] low if you do not want bus transactions.
    assign qspiIoI = ui_in[3:0];

    // req must not be a constant 0: otherwise the whole fsm is unreachable and yosys replaces
    // spi / qspi / ospi with the same constant network (identical gds blobs).
    wire memReq = ui_in[7];

    (* keep_hierarchy *)
    qspi_memory uQspi (
        .clk(clk),
        .rst_n(rst_n),
        .req(memReq),
        .rw(1'b0),
        .addr(24'b0),
        .wdata(6'b0),
        .ready(qspiReady),
        .rdata(qspiRdata),
        .sck(qspiSck),
        .cs_n(qspiCsN),
        .io_o(qspiIoO),
        .io_i(qspiIoI),
        .io_oe(qspiIoOe)
    );

    wire foldCtl = ^{qspiSck, qspiCsN, qspiIoO, qspiIoOe};
    wire foldMeta = ^{qspiReady, qspiRdata};

    assign uo_out[0] = foldCtl;
    assign uo_out[1] = foldMeta ^ foldCtl;
    assign uo_out[2] = qspiIoO[0] ^ qspiIoO[2];
    assign uo_out[3] = qspiIoO[1] ^ qspiIoO[3];
    assign uo_out[4] = qspiSck;
    assign uo_out[5] = qspiCsN;
    assign uo_out[6] = foldMeta;
    assign uo_out[7] = ena ^ ^{ui_in[6:4], uio_in};

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

endmodule
