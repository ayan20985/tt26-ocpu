`default_nettype none

// minimal top for ospi-only area experiments; full design lives in old-src/project_full.v
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

    wire       ospiReady;
    wire [5:0] ospiRdata;
    wire       ospiSck;
    wire       ospiCsN;
    wire [7:0] ospiIoO;
    wire [7:0] ospiIoI;
    wire [7:0] ospiIoOe;

    assign ospiIoI = uio_in;

    (* keep_hierarchy *)
    ospi_memory uOspi (
        .clk(clk),
        .rst_n(rst_n),
        .req(1'b0),
        .rw(1'b0),
        .addr(24'b0),
        .wdata(6'b0),
        .ready(ospiReady),
        .rdata(ospiRdata),
        .sck(ospiSck),
        .cs_n(ospiCsN),
        .io_o(ospiIoO),
        .io_i(ospiIoI),
        .io_oe(ospiIoOe)
    );

    wire foldCtl = ^{ospiSck, ospiCsN, ospiIoO, ospiIoOe};
    wire foldMeta = ^{ospiReady, ospiRdata};

    assign uo_out[0] = foldCtl;
    assign uo_out[1] = foldMeta ^ foldCtl;
    assign uo_out[2] = ospiIoO[0] ^ ospiIoO[4];
    assign uo_out[3] = ospiIoO[1] ^ ospiIoO[5];
    assign uo_out[4] = ospiIoO[2] ^ ospiIoO[6];
    assign uo_out[5] = ospiIoO[3] ^ ospiIoO[7];
    assign uo_out[6] = foldMeta;
    assign uo_out[7] = ena ^ ^{ui_in};

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

endmodule
