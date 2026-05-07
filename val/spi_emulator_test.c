#include "spi_emulator.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

/*
 * clocks one spi read command framing bit on miso/msck/csn lines,
 * mirroring verilog mode 0: mosi sampled on sck rises; miso settles on falls.
 */
static void clock_mosi_bit(spi_emu_t *emu, uint8_t mosi_bit) {
    (void)spi_emu_step(emu, 0, 0, mosi_bit);
    (void)spi_emu_step(emu, 0, 1, mosi_bit);
    (void)spi_emu_step(emu, 0, 0, mosi_bit);
}

static void run_decode_read(spi_emu_t *emu, uint8_t *mem, size_t mem_size, uint32_t addr24,
                            uint32_t *addr_out, uint8_t *data_out_sample) {
    spi_emu_init(emu, mem, mem_size);
    uint32_t pkt = (uint32_t)(0x03u << 24) | (addr24 & 0xffffff);

    /* cs high then low to arm (prev_cs starts 1 after init). */
    (void)spi_emu_step(emu, 1, 0, 0);

    uint8_t mosi_dummy = 0;
    (void)spi_emu_step(emu, 0, 0, mosi_dummy);

    for (unsigned i = 0; i < 32; i++) {
        uint8_t mosi = (uint8_t)((pkt >> (31 - i)) & 1);
        clock_mosi_bit(emu, mosi);
    }

    spi_emu_capture_after_cmd_addr(emu, addr_out, data_out_sample);
}

int main(void) {
    size_t nbytes = (size_t)(1 << 16);
    uint8_t *mem = (uint8_t *)calloc(nbytes, 1);
    if (!mem) {
        fputs("spi_emu_check: malloc failed\n", stderr);
        return 1;
    }

    spi_emu_t emu;

    mem[0x09] = 0x8d;
    mem[0x0020u] = 0x02;

    uint32_t decoded;
    uint8_t samp;

    run_decode_read(&emu, mem, nbytes, 0x0020u, &decoded, &samp);
    if (decoded != 0x0020u || samp != 0x02) {
        fprintf(stderr, "spi_emu_check: read $20 expected addr=0x20 data=0x02 got addr=0x%x data=0x%02x\n",
                (unsigned)decoded, (unsigned)samp);
        free(mem);
        return 1;
    }

    run_decode_read(&emu, mem, nbytes, 0x09u, &decoded, &samp);
    if (decoded != 0x09u || samp != 0x8d) {
        fprintf(stderr, "spi_emu_check: read $9 expected addr=0x09 data=0x8d got addr=0x%x data=0x%02x\n",
                (unsigned)decoded, (unsigned)samp);
        free(mem);
        return 1;
    }

    free(mem);
    fputs("spi_emu_check: pass\n", stdout);
    return 0;
}
