#ifndef SPI_EMULATOR_H
#define SPI_EMULATOR_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct spi_emu_t {
    uint8_t *mem;
    size_t mem_size;
    uint8_t miso;
    uint8_t prev_sck;
    uint8_t prev_cs;
    uint8_t bit_index;
    uint32_t cmd_addr;
    uint8_t data_in;
    uint8_t data_out;
    uint32_t addr;
    uint8_t is_write;
} spi_emu_t;

void spi_emu_init(spi_emu_t *emu, uint8_t *mem, size_t mem_size);
uint8_t spi_emu_step(spi_emu_t *emu, uint8_t cs_n, uint8_t sck, uint8_t mosi);

#ifdef __cplusplus
}
#endif

#endif
