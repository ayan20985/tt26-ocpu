CXX ?= g++
CC ?= gcc
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
LDFLAGS ?=
LIBS ?=

VERILATOR ?= verilator
VFLAGS = --cc --exe \
	-Wall -Wno-fatal \
	-Wno-EOFNEWLINE \
	-Wno-DECLFILENAME \
	-Wno-WIDTHEXPAND \
	-Wno-WIDTHTRUNC \
	-Wno-UNUSEDSIGNAL \
	-Wno-UNUSEDPARAM \
	-Wno-PINMISSING \
	-I.. \
	-I../src \
	-DOCPU_SIM \
	--Mdir obj_dir \
	-CFLAGS "$(CXXFLAGS)"

TOP ?= tt_um_ocpu
SRC_DIR = ../src
SV_SRCS = $(wildcard $(SRC_DIR)/*.sv)
V_SRCS = $(wildcard $(SRC_DIR)/*.v)
HARDENING_DIR = ../for-hardening
CPP_SRCS = ocpu_sim_main.cpp spi_emulator.c
SV2V ?= /c/sv2v/sv2v.exe

SPI_EMU_TEST_SRCS = spi_emulator_test.c spi_emulator.c

all: sim

convert_sv:
	@mkdir -p $(HARDENING_DIR)
	@if [ -n "$(SV_SRCS)" ]; then \
		for sv_file in $(SV_SRCS); do \
			base=$$(basename $$sv_file .sv); \
			echo "Converting $$sv_file to Verilog..."; \
			$(SV2V) -DOCPU_SIM $$sv_file > $(HARDENING_DIR)/$$base.v; \
		done; \
	fi
	@for v_file in $(V_SRCS); do \
		cp $$v_file $(HARDENING_DIR)/; \
	done

sim: convert_sv $(CPP_SRCS)
	$(VERILATOR) $(VFLAGS) \
		$(wildcard $(HARDENING_DIR)/*.v) \
		$(CPP_SRCS) \
		--top-module $(TOP) \
		-o ocpu_sim
	$(MAKE) -C obj_dir -f V$(TOP).mk
	@if [ -f obj_dir/ocpu_sim ]; then cp obj_dir/ocpu_sim .; \
	elif [ -f obj_dir/ocpu_sim.exe ]; then cp obj_dir/ocpu_sim.exe .; fi

clean:
	rm -rf obj_dir $(HARDENING_DIR)
	rm -f ocpu_sim ocpu_sim.exe

spi_emu_check: $(SPI_EMU_TEST_SRCS) spi_emulator.h
	$(CC) -std=c11 -O2 -Wall -Wextra -o $@ spi_emulator_test.c spi_emulator.c $(LDFLAGS)

.PHONY: all sim clean spi_emu_check
