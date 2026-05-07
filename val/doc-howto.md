# ocpu validation flow

this folder contains a verilator based simulation harness and a small assembler for the ocpu core.

## quick start
1. build the simulator with `make sim`
2. run tests with `python run_tests.py`

## file layout
- ocpu_asm.py assembles .ocpu into .mach and writes a readable .mach.txt
- ocpu_sim_main.cpp and spi_emulator.c build the simulator
- tests/*.ocpu are assembly tests
- tests/*.test contain expected outputs

## test format
use key=value lines. keys are compared against the .out file.
- max_cycles sets an upper bound for the run
- stop_pc stops when core pc matches the value
- the core is single-core, so use core.* keys for register checks
- steps=1 enables a cycle-by-cycle trace in a .outsteps file

example:
core.a=0x07
core.pc=0x000f
max_cycles=200
stop_pc=0x000f

## notes
the spi model implements 0x03 reads and 0x02 writes and assumes mode 0 timing.
