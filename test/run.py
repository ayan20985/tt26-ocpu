"""
run.py - portable cocotb runner for the tt26-ocpu validation suite.

uses cocotb_tools.runner (cocotb >= 2.0) so we do not need GNU make
on PATH. equivalent to `make -B` inside this directory.

usage (from any cwd):
    python test/run.py
    python test/run.py --test test_branch
    python test/run.py --sim verilator
    python test/run.py --gates path/to/gate_level_netlist.v
"""
from __future__ import annotations
import argparse
import os
import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    here = Path(__file__).resolve().parent
    srcDir = (here / '..' / 'src').resolve()

    p = argparse.ArgumentParser(description="cocotb runner for tt26-ocpu")
    p.add_argument('--sim', default='icarus', choices=['icarus', 'verilator'],
                   help="simulator backend (default: icarus)")
    p.add_argument('--test', default=None,
                   help="run only one test by name (e.g. test_indy)")
    p.add_argument('--gates', default=None,
                   help="path to gate_level_netlist.v for GL simulation")
    p.add_argument('--keep', action='store_true',
                   help="reuse existing sim_build directory")
    p.add_argument('--program', default=None,
                   help="run a single user program (.hex from build_c.ps1). "
                        "shortcut for `--test test_user_program` with "
                        "OCPU_USER_HEX set in the environment.")
    p.add_argument('--max-cycles', type=int, default=None,
                   help="cycle budget for --program (default 50000)")
    p.add_argument('--chip', action='store_true',
                   help="run the chip-top OSPI integration tests instead of "
                        "the core tests. uses tb_chip.v + test_chip.py and "
                        "instantiates the full tt_um_ocpu with real pins.")
    args = p.parse_args(argv)

    # plumb --program through the OCPU_USER_HEX env var that
    # test_user_program reads
    if args.program:
        hexPath = Path(args.program).resolve()
        if not hexPath.exists():
            print(f"error: program file does not exist: {hexPath}",
                  file=sys.stderr)
            return 2
        os.environ['OCPU_USER_HEX'] = str(hexPath)
        if args.max_cycles is not None:
            os.environ['OCPU_USER_MAX_CYCLES'] = str(args.max_cycles)
        # force the test filter so we only run the user-program test
        args.test = 'test_user_program'

    # make sure iverilog is on PATH for this process if the user installed it
    # to the default location without adding it to PATH globally.
    iverilogDefault = Path(r"C:\iverilog\bin")
    if args.sim == 'icarus' and iverilogDefault.exists():
        os.environ['PATH'] = str(iverilogDefault) + os.pathsep + os.environ.get('PATH', '')

    # make the assembler / tools importable from test.py
    toolsDir = (here / '..' / 'tools').resolve()
    sys.path.insert(0, str(toolsDir))
    os.environ['PYTHONPATH'] = (
        str(toolsDir) + os.pathsep + os.environ.get('PYTHONPATH', '')
    )

    from cocotb_tools.runner import get_runner

    runner = get_runner(args.sim)

    if args.chip:
        # chip-top integration: full tt_um_ocpu via tb_chip.v + test_chip.py
        sources = [
            srcDir / 'iram_regfile.v',
            srcDir / 'ocpu_core.v',
            srcDir / 'ospi_memory.v',
            srcDir / 'project.v',
            here  / 'tb_chip.v',
        ]
        topModule  = 'tb_chip'
        testModule = 'test_chip'
        subdir = 'chip'
    else:
        # core-isolation: ocpu_core + iram_regfile + tb.v
        sources = [srcDir / 'iram_regfile.v', srcDir / 'ocpu_core.v']
        sources.append(here / 'tb.v')
        topModule  = 'tb'
        testModule = 'test'
        subdir = ''

    defines = {}
    if args.gates:
        sources = [Path(args.gates).resolve()] + sources
        defines.update(GL_TEST=1, FUNCTIONAL=1, USE_POWER_PINS=1)

    buildLeaf = args.sim + ('_gl' if args.gates else '_rtl')
    if subdir:
        buildLeaf = buildLeaf + '_' + subdir
    buildDir = here / 'sim_build' / buildLeaf

    runner.build(
        sources=[str(p) for p in sources],
        hdl_toplevel=topModule,
        defines=defines,
        build_dir=str(buildDir),
        always=not args.keep,
    )

    testFilter = args.test if args.test else None
    results = runner.test(
        hdl_toplevel=topModule,
        test_module=testModule,
        test_dir=str(here),
        testcase=testFilter,
        build_dir=str(buildDir),
        results_xml='results.xml',
    )
    print(f"\nresults xml: {results}")

    # parse the xml to report a one-line summary
    try:
        import xml.etree.ElementTree as ET
        root = ET.parse(results).getroot()
        nTests = nFail = nErr = 0
        for tc in root.iter('testcase'):
            nTests += 1
            for child in tc:
                if child.tag == 'failure': nFail += 1
                if child.tag == 'error':   nErr  += 1
        print(f"summary: {nTests} test(s), {nFail} failure(s), {nErr} error(s)")
        return 0 if (nFail == 0 and nErr == 0) else 1
    except Exception as e:
        print(f"could not parse {results}: {e}")
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
