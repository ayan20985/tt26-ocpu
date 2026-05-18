#!/usr/bin/env bash
# run all ocpu cocotb validation tests.
# usage:
#   tools/run_tests.sh                       # run the whole suite
#   tools/run_tests.sh -t test_lda_imm       # run a single test
#   tools/run_tests.sh -g                    # gate-level simulation
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="${repo_root}/test"

gates=0
one_test=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--gates) gates=1; shift ;;
        -t|--test)  one_test="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$test_dir"

make_args=( -B )
if [[ "$gates" -eq 1 ]]; then
    make_args+=( "GATES=yes" )
fi
if [[ -n "$one_test" ]]; then
    export COCOTB_TESTCASE="$one_test"
fi

echo "==> running: make ${make_args[*]}"
make "${make_args[@]}"

results=$(find sim_build -name results.xml | head -n 1 || true)
if [[ -n "$results" ]]; then
    echo "==> results: $results"
fi
