#include "Vtt_um_ocpu.h"
#include "verilated.h"
#include "spi_emulator.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static vluint64_t sim_time = 0;
double sc_time_stamp() {
    return static_cast<double>(sim_time);
}

static void print_usage(const char *argv0) {
    std::printf("usage: %s -m <file.mach> -o <file.out> [-c cycles] [-a load_addr] [-p stop_pc] [-s file.outsteps] [-b file.buslog]\n", argv0);
}

static bool parse_u32(const char *text, uint32_t *value) {
    if (!text || !value) {
        return false;
    }
    char *end = nullptr;
    unsigned long parsed = std::strtoul(text, &end, 0);
    if (!end || *end != '\0') {
        return false;
    }
    *value = static_cast<uint32_t>(parsed);
    return true;
}

static void tick(Vtt_um_ocpu *top, spi_emu_t *emu, uint64_t *cycles) {
    top->clk = 0;
    top->eval();
    uint8_t sck = static_cast<uint8_t>(top->uo_out & 0x01);
    uint8_t cs_n = static_cast<uint8_t>((top->uo_out >> 1) & 0x01);
    uint8_t mosi = static_cast<uint8_t>((top->uo_out >> 2) & 0x01);
    uint8_t miso = spi_emu_step(emu, cs_n, sck, mosi);
    top->ui_in = static_cast<uint8_t>((top->ui_in & 0xfe) | (miso & 0x01));

    top->clk = 1;
    top->eval();
    sck = static_cast<uint8_t>(top->uo_out & 0x01);
    cs_n = static_cast<uint8_t>((top->uo_out >> 1) & 0x01);
    mosi = static_cast<uint8_t>((top->uo_out >> 2) & 0x01);
    miso = spi_emu_step(emu, cs_n, sck, mosi);
    top->ui_in = static_cast<uint8_t>((top->ui_in & 0xfe) | (miso & 0x01));

    sim_time++;
    *cycles = *cycles + 1;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    const char *mach_path = nullptr;
    const char *out_path = nullptr;
    const char *steps_path = nullptr;
    const char *buslog_path = nullptr;
    uint64_t max_cycles = 100000;
    uint32_t load_addr = 0;
    uint32_t stop_pc = 0xffffffffu;

    for (int i = 1; i < argc; i++) {
        if (std::strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
            mach_path = argv[++i];
        } else if (std::strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            out_path = argv[++i];
        } else if (std::strcmp(argv[i], "-c") == 0 && i + 1 < argc) {
            max_cycles = static_cast<uint64_t>(std::strtoull(argv[++i], nullptr, 0));
        } else if (std::strcmp(argv[i], "-a") == 0 && i + 1 < argc) {
            if (!parse_u32(argv[++i], &load_addr)) {
                std::fprintf(stderr, "error: invalid load address\n");
                return 1;
            }
        } else if (std::strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            if (!parse_u32(argv[++i], &stop_pc)) {
                std::fprintf(stderr, "error: invalid stop pc\n");
                return 1;
            }
        } else if (std::strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            steps_path = argv[++i];
        } else if (std::strcmp(argv[i], "-b") == 0 && i + 1 < argc) {
            buslog_path = argv[++i];
        } else {
            print_usage(argv[0]);
            return 1;
        }
    }

    if (!mach_path || !out_path) {
        print_usage(argv[0]);
        return 1;
    }

    std::vector<uint8_t> memory(1u << 24, 0);

    std::ifstream mach_file(mach_path, std::ios::binary);
    if (!mach_file) {
        std::fprintf(stderr, "error: cannot open machine file\n");
        return 1;
    }
    mach_file.seekg(0, std::ios::end);
    std::streamsize size = mach_file.tellg();
    mach_file.seekg(0, std::ios::beg);
    if (size < 0) {
        std::fprintf(stderr, "error: invalid machine file size\n");
        return 1;
    }
    if (static_cast<uint32_t>(size) + load_addr > memory.size()) {
        std::fprintf(stderr, "error: machine file too large for memory\n");
        return 1;
    }
    mach_file.read(reinterpret_cast<char *>(&memory[load_addr]), size);

    spi_emu_t emu;
    spi_emu_init(&emu, memory.data(), memory.size());

    Vtt_um_ocpu *top = new Vtt_um_ocpu();
    top->ena = 1;
    top->clk = 0;
    top->rst_n = 0;
    top->ui_in = 0;
    top->uio_in = 0;

    uint64_t cycles = 0;
    for (int i = 0; i < 4; i++) {
        tick(top, &emu, &cycles);
    }
    top->rst_n = 1;

    FILE *steps = nullptr;
    FILE *buslog = nullptr;
    if (steps_path) {
        steps = std::fopen(steps_path, "w");
        if (!steps) {
            std::fprintf(stderr, "error: cannot open outsteps file\n");
            return 1;
        }
        std::fprintf(steps, "cycle,pc,ir,a,x,y,sp,sr\n");
    }

    if (buslog_path) {
        buslog = std::fopen(buslog_path, "w");
        if (!buslog) {
            std::fprintf(stderr, "error: cannot open buslog file\n");
            return 1;
        }
        std::fprintf(buslog, "cycle,addr,data\n");
    }

    uint8_t prev_cs_n = 1;

    while (cycles < max_cycles) {
        tick(top, &emu, &cycles);
        if (buslog) {
            uint8_t cs_n = static_cast<uint8_t>((top->uo_out >> 1) & 0x01);
            if (prev_cs_n == 0 && cs_n == 1) {
                uint32_t addr = 0;
                uint8_t data = 0;
                spi_emu_capture_after_cmd_addr(&emu, &addr, &data);
                std::fprintf(
                    buslog,
                    "%llu,0x%06x,0x%02x\n",
                    static_cast<unsigned long long>(cycles),
                    static_cast<unsigned>(addr),
                    static_cast<unsigned>(data)
                );
            }
            prev_cs_n = cs_n;
        }
        if (steps) {
            std::fprintf(
                steps,
                "%llu,0x%04x,0x%02x,0x%02x,0x%02x,0x%02x,0x%02x,0x%02x\n",
                static_cast<unsigned long long>(cycles),
                static_cast<unsigned>(top->dbg_pc),
                static_cast<unsigned>(top->dbg_ir),
                static_cast<unsigned>(top->dbg_a),
                static_cast<unsigned>(top->dbg_x),
                static_cast<unsigned>(top->dbg_y),
                static_cast<unsigned>(top->dbg_sp),
                static_cast<unsigned>(top->dbg_sr)
            );
        }
        if (stop_pc != 0xffffffffu) {
            if (static_cast<uint32_t>(top->dbg_pc) == stop_pc) {
                break;
            }
        }
    }

    FILE *out = std::fopen(out_path, "w");
    if (!out) {
        std::fprintf(stderr, "error: cannot open out file\n");
        return 1;
    }

    std::fprintf(out, "core.a=0x%02x\n", static_cast<unsigned>(top->dbg_a));
    std::fprintf(out, "core.x=0x%02x\n", static_cast<unsigned>(top->dbg_x));
    std::fprintf(out, "core.y=0x%02x\n", static_cast<unsigned>(top->dbg_y));
    std::fprintf(out, "core.sp=0x%02x\n", static_cast<unsigned>(top->dbg_sp));
    std::fprintf(out, "core.sr=0x%02x\n", static_cast<unsigned>(top->dbg_sr));
    std::fprintf(out, "core.ir=0x%02x\n", static_cast<unsigned>(top->dbg_ir));
    std::fprintf(out, "core.pc=0x%04x\n", static_cast<unsigned>(top->dbg_pc));

    std::fprintf(out, "mmio.bank=0x%02x\n", static_cast<unsigned>(top->dbg_mmio_bank));
    std::fprintf(out, "mmio.cache=0x%02x\n", static_cast<unsigned>(top->dbg_oc_cache));
    std::fprintf(out, "cycles=%llu\n", static_cast<unsigned long long>(cycles));

    std::fclose(out);
    if (steps) {
        std::fclose(steps);
    }
    if (buslog) {
        std::fclose(buslog);
    }

    top->final();
    delete top;
    return 0;
}
