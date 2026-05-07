`default_nettype none

// minimal top for spi-only area experiments; full design lives in old-src/project_full.v
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

    wire       spiReady;
    wire [5:0] spiRdata;
    wire       spiSck;
    wire       spiCsN;
    wire       spiMosi;
    wire       spiMiso;

    assign spiMiso = ui_in[0];

    (* keep_hierarchy *)
    spi_memory uSpi (
        .clk(clk),
        .rst_n(rst_n),
        .req(1'b0),
        .rw(1'b0),
        .addr(24'b0),
        .wdata(6'b0),
        .ready(spiReady),
        .rdata(spiRdata),
        .sck(spiSck),
        .cs_n(spiCsN),
        .mosi(spiMosi),
        .miso(spiMiso)
    );

    wire foldCtl = ^{spiSck, spiCsN, spiMosi, spiMiso};
    wire foldMeta = ^{spiReady, spiRdata};

    assign uo_out[0] = foldCtl;
    assign uo_out[1] = foldMeta ^ foldCtl;
    assign uo_out[2] = spiMosi ^ spiSck;
    assign uo_out[3] = spiCsN ^ spiMiso;
    assign uo_out[4] = spiSck;
    assign uo_out[5] = spiCsN;
    assign uo_out[6] = foldMeta;
    assign uo_out[7] = ena ^ ^{ui_in[7:1], uio_in};

    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

endmodule
