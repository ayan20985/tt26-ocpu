#!/usr/bin/env bash
# run all ocpu cocotb validation tests via the cocotb 2.x python runner.
# no `make` required.
#
# requirements:
#   - python with cocotb >= 2.0 (`pip install -r test/requirements.txt`)
#   - icarus verilog (or verilator)
#
# usage:
#   tools/run_tests.sh                            # all tests, icarus
#   tools/run_tests.sh -t test_indy               # single test
#   tools/run_tests.sh -g path/to/gl.v            # gate-level
#   tools/run_tests.sh -s verilator               # verilator backend
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${repo_root}/test/run.py"
[[ -f "$runner" ]] || { echo "test/run.py not found"; exit 2; }

one_test=""
gates=""
sim="icarus"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--test)  one_test="$2"; shift 2 ;;
        -g|--gates) gates="$2"; shift 2 ;;
        -s|--sim)   sim="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

py_args=( "$runner" --sim "$sim" )
[[ -n "$one_test" ]] && py_args+=( --test "$one_test" )
[[ -n "$gates"    ]] && py_args+=( --gates "$gates" )

echo "==> python ${py_args[*]}"
python "${py_args[@]}"
echo "==> all tests passed"
