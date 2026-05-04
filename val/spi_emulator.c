#include "spi_emulator.h"
#include <string.h>

static uint8_t spi_emu_read(const spi_emu_t *emu, uint32_t addr) {
    if (addr < emu->mem_size) {
        return emu->mem[addr];
    }
    return 0;
}

static void spi_emu_write(spi_emu_t *emu, uint32_t addr, uint8_t data) {
    if (addr < emu->mem_size) {
        emu->mem[addr] = data;
    }
}

void spi_emu_init(spi_emu_t *emu, uint8_t *mem, size_t mem_size) {
    memset(emu, 0, sizeof(*emu));
    emu->mem = mem;
    emu->mem_size = mem_size;
    emu->prev_cs = 1;
}

uint8_t spi_emu_step(spi_emu_t *emu, uint8_t cs_n, uint8_t sck, uint8_t mosi) {
    if (emu->prev_cs == 0 && cs_n == 1) {
        emu->bit_index = 0;
        emu->cmd_addr = 0;
        emu->data_in = 0;
        emu->data_out = 0;
        emu->is_write = 0;
        emu->miso = 0;
    }

    if (cs_n == 1) {
        emu->prev_sck = sck;
        emu->prev_cs = cs_n;
        return emu->miso;
    }

    if (emu->prev_sck == 0 && sck == 1) {
        if (emu->bit_index < 32) {
            emu->cmd_addr = (emu->cmd_addr << 1) | (mosi & 1);
        } else if (emu->bit_index < 40) {
            if (emu->is_write) {
                emu->data_in = (uint8_t)((emu->data_in << 1) | (mosi & 1));
            }
        }

        emu->bit_index++;

        if (emu->bit_index == 32) {
            uint8_t cmd = (uint8_t)((emu->cmd_addr >> 24) & 0xff);
            emu->addr = emu->cmd_addr & 0xffffff;
            emu->is_write = (cmd == 0x02);
            emu->data_out = spi_emu_read(emu, emu->addr);
        }

        if (emu->bit_index == 40 && emu->is_write) {
            spi_emu_write(emu, emu->addr, emu->data_in);
        }
    }

    if (emu->prev_sck == 1 && sck == 0) {
        if (!emu->is_write && emu->bit_index >= 32 && emu->bit_index < 40) {
            uint8_t data_bit = (uint8_t)(emu->bit_index - 32);
            uint8_t shift = (uint8_t)(7 - data_bit);
            emu->miso = (uint8_t)((emu->data_out >> shift) & 1);
        } else {
            emu->miso = 0;
        }
    }

    emu->prev_sck = sck;
    emu->prev_cs = cs_n;
    return emu->miso;
}
