#include "Vtt_um_ocpu.h"
#include "verilated.h"
#include "spi_emulator.h"
#include <cstdio>
int main() {
    Vtt_um_ocpu top;
    spi_emu_t emu;
    uint8_t mem[65536] = {0};
    mem[0] = 0xA9; mem[1] = 0x03; mem[2] = 0xAA; mem[3] = 0xE8; mem[4] = 0xA9; mem[5] = 0x05;
    mem[6] = 0x6D; mem[7] = 0x20; mem[8] = 0x00; mem[9] = 0x8D; mem[10] = 0x21; mem[11] = 0x00;
    mem[12] = 0x4C; mem[13] = 0x0F; mem[14] = 0x00; mem[0x20] = 0x02;
    spi_emu_init(&emu, mem, 65536);
    top.ena = 1; top.rst_n = 0; top.clk = 0;
    for(int i=0; i<4; i++) {
        top.clk=0; top.eval();
        top.clk=1; top.eval();
    }
    top.rst_n = 1;
    for(int i=0; i<2000; i++) {
        top.clk=0; top.eval();
        uint8_t sck = top.uo_out & 1;
        uint8_t cs_n = (top.uo_out >> 1) & 1;
        uint8_t mosi = (top.uo_out >> 2) & 1;
        uint8_t miso = spi_emu_step(&emu, cs_n, sck, mosi);
        top.ui_in = miso;
        
        top.clk=1; top.eval();
        sck = top.uo_out & 1;
        cs_n = (top.uo_out >> 1) & 1;
        mosi = (top.uo_out >> 2) & 1;
        miso = spi_emu_step(&emu, cs_n, sck, mosi);
        top.ui_in = miso;
        
        if(emu.bit_index == 32 && emu.prev_sck == 0 && sck == 1) {
            printf("SPI emulator decoded addr: %06x\n", emu.addr);
        }
    }
    return 0;
}
