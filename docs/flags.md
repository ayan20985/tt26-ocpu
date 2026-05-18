All core CPU tests (25):
python test/run.py

All chip/OSPI integration tests (3):
python test/run.py --chip

Everything in sequence (same as two passes; there isn’t one flag that merges both suites):
python test/run.py && python test/run.py --chip

Combine flags (examples):
# core, Verilator instead of Icarus
python test/run.py --sim verilator
# chip top, incremental build
python test/run.py --chip --keep --sim icarus
# one core test
python test/run.py --test test_smod
# one chip test
python test/run.py --chip --test test_chip_ospi_readback
# run a built .hex through core sim (implies test_user_program)
python test/run.py --program path/to/out.hex --max-cycles 100000

Gate-level (you supply the netlist):
python test/run.py --gates path\to\gate_level_netlist.v
# or chip:
python test/run.py --chip --gates path\to\gate_level_netlist.v