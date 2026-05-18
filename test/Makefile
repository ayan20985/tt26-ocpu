# Makefile
# cocotb driver for the tt26-ocpu cpu-validation testbench.
# See https://docs.cocotb.org/en/stable/quickstart.html for cocotb basics.

SIM ?= icarus
FST ?= -fst                                  # use the more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src

# the cpu-validation testbench in tb.v instantiates ocpu_core + iram_regfile
# directly, so we only need those two source files (plus tb.v) for the
# rtl path. project.v / ospi_memory.v are not part of this testbench.
PROJECT_SOURCES = iram_regfile.v ocpu_core.v macros/names.v

ifneq ($(GATES),yes)

# RTL simulation: drives the cpu-core directly via tb.v
SIM_BUILD	= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = test

else

# Gate level simulation: only the flattened tt_um_ocpu netlist is available,
# so use the chip-level tb (tb_chip.v) and the chip cocotb tests.
SIM_BUILD	= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
VERILOG_SOURCES += $(PWD)/tb_chip.v
TOPLEVEL = tb_chip
COCOTB_TEST_MODULES = test_chip

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# include cocotb's make rules
include $(shell cocotb-config --makefiles)/Makefile.sim
