#!/usr/bin/env python3

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TESTS_DIR = ROOT / "tests"
ASM = ROOT / "ocpu_asm.py"


def read_kv(path):
    data = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def parse_int(text):
    text = text.strip()
    if text.startswith("0x"):
        return int(text, 16)
    return int(text, 10)


def run_cmd(cmd):
    result = subprocess.run(cmd, check=False)
    return result.returncode


def main():
    sim = ROOT / "ocpu_sim"
    if not sim.exists():
        sim = ROOT / "ocpu_sim.exe"
    if not sim.exists():
        print("error: ocpu_sim not found. build it with make sim")
        return 1

    failures = 0
    tests = sorted(TESTS_DIR.glob("*.ocpu"))
    if not tests:
        print("no tests found")
        return 1

    for ocpu_path in tests:
        test_path = ocpu_path.with_suffix(".test")
        if not test_path.exists():
            print(f"missing test file for {ocpu_path.name}")
            failures += 1
            continue

        expected = read_kv(test_path)
        mach_path = ocpu_path.with_suffix(".mach")
        out_path = ocpu_path.with_suffix(".out")

        rc = run_cmd([sys.executable, str(ASM), str(ocpu_path), str(mach_path)])
        if rc != 0:
            print(f"assemble failed for {ocpu_path.name}")
            failures += 1
            continue

        max_cycles = expected.get("max_cycles", "100000")
        load_addr = expected.get("load_addr")
        stop_pc = expected.get("stop_pc")

        cmd = [str(sim), "-m", str(mach_path), "-o", str(out_path), "-c", str(max_cycles)]
        if load_addr is not None:
            cmd += ["-a", load_addr]
        if stop_pc is not None:
            cmd += ["-p", stop_pc]

        rc = run_cmd(cmd)
        if rc != 0:
            print(f"sim failed for {ocpu_path.name}")
            failures += 1
            continue

        actual = read_kv(out_path)
        for key, value in expected.items():
            if key in {"max_cycles", "load_addr", "stop_pc"}:
                continue
            if key not in actual:
                print(f"missing key {key} in {out_path.name}")
                failures += 1
                break
            if parse_int(actual[key]) != parse_int(value):
                print(f"mismatch {ocpu_path.name} {key} expected {value} got {actual[key]}")
                failures += 1
                break
        else:
            print(f"pass {ocpu_path.name}")

    if failures:
        print(f"failures {failures}")
        return 1
    print("all tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
