`default_nettype none
`timescale 1ns / 1ps

// tb_chip.v
// =========
// chip-top testbench that wraps the FULL tt_um_ocpu (src/project.v),
// driving its real Tiny Tapeout pins. used by test/test_chip.py to
// validate the OSPI slave end-to-end with the new pin map and the
// CS_N polarity fix.
//
// every pin is exposed as a wire/reg here so the python driver can
// reach it via plain `dut.<name>` access without descending into the
// dut hierarchy.

module tb_chip;
    initial begin
        $dumpfile("tb_chip.fst");
        $dumpvars(0, tb_chip);
    end

    // -- clock / reset / enable --
    reg clk;
    reg rst_n;
    reg ena;

    // -- dedicated input bank (drives SCK, CS_N, page_done, page_loading) --
    // bit assignments (matches src/project.v):
    //   ui_in[0] = SCK
    //   ui_in[1] = CS_N
    //   ui_in[2] = page_done
    //   ui_in[3] = page_loading
    //   ui_in[7:4] = reserved (0)
    reg [7:0] ui_in;

    // -- dedicated output bank (status flags) --
    wire [7:0] uo_out;

    // -- bidirectional bank (OSPI 8-bit data) --
    // uio_in[7:0]  : master -> slave bytes on write (and address bytes on read)
    // uio_out[7:0] : slave -> master byte 4 on read
    // uio_oe[7:0]  : slave's tri-state control
    reg  [7:0] uio_in;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;

    // -- the dut: full chip top --
    // when running gate-level (GL_TEST + USE_POWER_PINS) the synthesized
    // netlist of tt_um_ocpu exposes VPWR/VGND ports that must be tied,
    // otherwise every cell evaluates to X and uo_out/uio_out are
    // unreadable. tie them here so the same testbench works for both
    // RTL and GL simulation.
`ifdef GL_TEST
    wire VPWR = 1'b1;
    wire VGND = 1'b0;
`endif

    tt_um_ocpu dut (
`ifdef GL_TEST
        .VPWR    (VPWR),
        .VGND    (VGND),
`endif
        .ui_in   (ui_in),
        .uo_out  (uo_out),
        .uio_in  (uio_in),
        .uio_out (uio_out),
        .uio_oe  (uio_oe),
        .ena     (ena),
        .clk     (clk),
        .rst_n   (rst_n)
    );

endmodule
