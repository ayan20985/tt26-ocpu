CXX ?= g++
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
VSRCS = $(wildcard $(SRC_DIR)/*.v)
CPP_SRCS = ocpu_sim_main.cpp spi_emulator.c

all: sim

sim: $(VSRCS) $(CPP_SRCS)
	$(VERILATOR) $(VFLAGS) \
		$(VSRCS) \
		$(CPP_SRCS) \
		--top-module $(TOP) \
		-o ocpu_sim
	$(MAKE) -C obj_dir -f V$(TOP).mk
	@if [ -f obj_dir/ocpu_sim ]; then cp obj_dir/ocpu_sim .; \
	elif [ -f obj_dir/ocpu_sim.exe ]; then cp obj_dir/ocpu_sim.exe .; fi

clean:
	rm -rf obj_dir
	rm -f ocpu_sim ocpu_sim.exe

.PHONY: all sim clean
