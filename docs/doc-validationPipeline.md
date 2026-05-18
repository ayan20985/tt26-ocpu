# doc-validationPipeline

end-to-end test infrastructure for the tt26-ocpu cpu core.

## scope

the validation pipeline has two layers:

1. cocotb cpu-validation tests under `test/`. these instantiate
   `ocpu_core` and `iram_regfile` directly through a thin testbench
   (`test/tb.v`) and drive every external signal (page handshake, data
   memory, iram write port) from python. the cpu is exercised by a set
   of hand-written assembly programs in `test/programs/*.s` that the
   ocpu assembler (`tools/ocpu_asm.py`) compiles at runtime.

2. an optional c -> 6502 -> ocpu compilation pipeline under `tools/`
   that takes a c source file, runs it through cc65, post-processes
   the 6502 assembly with `tools/translate_6502.py`, and produces a
   .hex + .data.json pair that can be fed into the cocotb tests via
   `runProgram(..., 'foo.hex')`.

the cocotb path is the supported, validated path. the cc65 path is a
working skeleton; expect to extend the translator as you compile more
real c.

## prerequisites

| tool   | what for                         | install                      |
|--------|----------------------------------|------------------------------|
| python | cocotb + assembler               | from python.org              |
| cocotb | rtl test driver                  | `pip install -r test/requirements.txt` |
| icarus | verilog simulator                | windows installer; `iverilog` on PATH |
| gtkwave / surfer | wave viewer            | optional                     |
| cc65   | c -> 6502 assembler              | https://github.com/cc65/cc65/releases |
| verilator | optional, for the c-driver loop | brew / apt / windows tarball |

## tree

    src/                ocpu rtl
    test/
        tb.v            cpu-validation testbench top (instantiates ocpu_core)
        test_ocpu.py    cocotb tests + FpgaModel
        programs/       hand-written ocpu-isa programs
        Makefile        cocotb / iverilog build
    tools/
        ocpu_asm.py     custom-isa assembler (assemble / loadHex / loadData)
        translate_6502.py  6502 -> ocpu translator (microcode for non-mappable ops)
        build_c.ps1     full c -> .hex pipeline
        run_tests.ps1   run all cocotb tests (windows)
        run_tests.sh    run all cocotb tests (linux / mac)

## quick start

run the cpu validation suite (hand-written programs only, no cc65 needed):

    pwsh tools\run_tests.ps1

run a single test:

    pwsh tools\run_tests.ps1 -OneTest test_branch

gate-level run (needs `test/gate_level_netlist.v` from openlane):

    pwsh tools\run_tests.ps1 -Gates

compile and run a c program through the full pipeline:

    pwsh tools\build_c.ps1 -Source test\programs\c_src\sum_arr.c
    # then add a `@cocotb.test` in test/test_ocpu.py that calls
    #   await runProgram(dut, '.../sum_arr.hex')

## how `test/tb.v` differs from `src/project.v`

`project.v` is the chip top: it instantiates `ocpu_core`, `iram_regfile`,
and `ospi_memory`, and ties their ports to the tinytapeout uio_in/out
pins. `test/tb.v` deliberately leaves `ospi_memory` and `project.v` out
of the build and wires `ocpu_core` directly to:

* an `ext_iram_wr_*` port that the python `FpgaModel` uses to write
  instruction words into iram_regfile without going through any spi byte
  stream. this dodges the chip-side ospi peripheral entirely so cpu
  validation isn't blocked by ospi quirks.
* a simple `cpu_mem_ready` / `cpu_mem_rdata` pair driven from python with
  one-cycle latency, mirroring what the real external fpga eventually
  has to do.

the consequence: the cocotb test exercises 100% of `ocpu_core.v` and
`iram_regfile.v`, but does NOT exercise `ospi_memory.v` or `project.v`.
those need a separate test (see "known issues / chip-level ospi" below).

## the FpgaModel (test/test_ocpu.py)

mirrors what the real external fpga has to do:

* watches `dut.cpu.state` for `ST_PAGE_REQ` (5'd10). when entered:
    * if this is the very first request (initial boot) -> load page 0
    * if a `page_interrupt` pulse preceded the request -> load
      `currentPage + 1` (natural wrap after slot 7)
    * otherwise (FARJMP) -> load `ir_imm` as the target page
* runs the load by asserting `page_loading`, writing all 8 slot words
  via `ext_iram_wr_*`, then pulsing `page_done` for one cycle and
  deasserting `page_loading`.
* in parallel, services `cpu_mem_req` reads / writes against an in-process
  python dict (`fpga.dram`) with a one-cycle ready pulse. the initial
  dram image is the assembler's `.data` section.

## assembler (tools/ocpu_asm.py)

a small two-pass assembler with everything the current core implements:

* register / system ops with mnemonics matching info.md
* alu memory (`ADD addr`, etc.) and alu immediate (`ADD #imm`, etc.)
* abs / abs,X / (zp),Y addressing for LDA / STA
* abs / imm for LDX / LDY
* forward intra-page labels for `BR*` (offset 0..6 because the cpu
  evaluates the offset after pc has incremented to the next slot)
* intra-page labels for JMP / JSR (3-bit target slot)
* FARJMP <page>: switches to another instruction page
* SMOD <slot>, <byte>: cpu self-modify of iram slot
* `.page <n>` to align instruction stream on a fresh page boundary
* `.data <addr>` / `.byte` / `.word` / `.ascii` to populate the dram
  image that the cocotb FpgaModel preloads before reset is released

intentional limitations (these reflect the current core, not the
assembler):

* no shift mnemonic (ASL / LSR / ROL / ROR). the core has dead code for
  these but the decode tree never enters it. fix `ST_DECODE` in
  `ocpu_core.v` before adding shifts to the assembler.
* JSR / RTS pushes `pc + 1` where pc has already been incremented by
  ST_FETCH, so RTS resumes execution two slots after the JSR. write
  intervening NOPs accordingly (see `test/programs/test_stack.s`).

## 6502 -> ocpu translator (tools/translate_6502.py)

input is ca65 .s (what cc65 emits). output is ocpu .s (what the
assembler eats). the translator:

* maps the supported subset of 6502 directly (LDA / STA / ALU / branch
  / register / control flow).
* expands a few common patterns as microcode using only ops the core
  supports:
    * `INC addr` -> LDA addr; ADC #1; STA addr
    * `DEC addr` -> LDA addr; SBC #1; STA addr
    * `BIT addr` -> PHA; AND addr; PLA (Z flag only; N/V not modelled)
    * `LDA abs,Y` -> approximate via X swap (cc65 rarely emits this)
* switches the cpu's `data_page` when crossing the 256-byte boundary
  of a 16-bit absolute address by emitting `LDA #<hi>; STA_DP`.
* emits `; UNSUPPORTED ...` and a warning when an instruction has no
  microcode path (ASL / LSR / ROL / ROR / indirect-x indexed loads /
  unknown mnemonics). the downstream assembler will fail on these,
  which is intentional: cpu validation cannot drop instructions.

caveats that you will hit as soon as you compile non-trivial c:

* cc65's runtime stack helpers (`pushax`, `popa`, etc.) assume the
  full 6502 stack semantics, including 16-bit return addresses and
  stack pages at $0100..$01FF. our core only saves the low 3 bits of
  pc on JSR. you will need stack-page mapping (set `data_page = 1`
  in your entry stub) AND a different runtime, or a translator pass
  that synthesises full pc save/restore using a software stack.
* cc65 emits `JMP (vector)` indirect jumps and `BRK` for compiler-
  intrinsic calls. neither is supported.

## known issues / chip-level ospi

the chip wrapper (`src/project.v`) currently overlays sck/cs_n on
data lines:

    assign ospi_sck_i  = uio_in[0];
    assign ospi_cs_n_i = uio_in[1];
    assign ospi_io_i   = uio_in[7:0];

because `uio_in[0]` is both SCK *and* `io_i[0]`, every byte the ospi
slave latches on an SCK rising edge has bit 0 forced to 1 (since the
master must hold SCK high when sampling). the same is true for bit 1
against CS_N. that means:

* command 0x02 (write) cannot be transmitted -- the slave will only
  ever see commands with bit 0 set, so only 0x03 (read) survives.
* only bits 2..7 of each byte carry intentional payload (6 effective
  bits/byte).

this is a chip-level problem that does not affect the cpu core itself.
the cocotb tests in this directory deliberately bypass `ospi_memory.v`
and `project.v` for that reason. fixing the chip-level ospi requires
either (a) separating sck/cs_n onto pins that do *not* overlap io_i,
or (b) redefining the ospi protocol to use only the 6 carrier bits
per byte. neither is appropriate to do during cpu validation.

## bugs fixed during validation setup

the validation pass found three latent bugs in `ocpu_core.v` and fixed
them in place. all three involve the LDA / LDX / LDY family:

* `OP_LDA` in `ST_EXECUTE` was empty, so all memory-mode LDA variants
  (`LDA abs`, `LDA abs,X`, `LDA (zp),Y`) loaded the byte into `mdr`
  and never copied it into `A`. fixed by writing `A <= mdr` (and flag
  updates) for `ir_sub[1:0] != 2'b00`.
* `OP_LDX` and `OP_LDY` in `ST_EXECUTE` unconditionally wrote `mdr`
  into the register, clobbering the value `ST_DECODE` had just set
  from `ir_imm` for the immediate-mode variants. fixed by gating the
  mdr -> reg write on `ir_sub[0]`.

without these fixes none of the LDA / LDX / LDY paths would round-trip
correctly and the test suite would have looked uniformly broken.

## test coverage today

| file                          | covers                                       |
|-------------------------------|----------------------------------------------|
| test_lda_imm.s                | LDA / LDX / LDY immediate + N/Z flag         |
| test_alu_imm.s                | ADD / AND / ORA / EOR immediate chain        |
| test_branch.s                 | BEQ / BCS / BCC; forward intra-page; pages   |
| test_reg_ops.s                | TAX / INX / DEY + flag updates               |
| test_load_store.s             | STA abs, LDA abs, ADD #1, dram round trip    |
| test_stack.s                  | JSR / RTS + SP balance; PHA / PLA path       |
| test_page_wrap.s              | slot-7 wrap -> FpgaModel loads page 1 -> STA |
| test_indy.s                   | LDA (zp),Y dereference + index               |
| test_smod.s                   | SMOD sets dirty_bits[slot]                   |

what is NOT yet covered, and worth adding next:

* FARJMP target-page check (after `page_reg` is actually wired to the
  FARJMP imm; right now it never updates).
* CMP flag updates (Z + C) for unequal/equal/lt operands.
* SEI / CLI / SEC / CLC / CLV explicit flag-bit checks.
* multi-page programs that exercise FARJMP with a non-zero dirty bit
  going through the writeback path (requires extending the FpgaModel
  with an external dram tied to dirty_bits).
* an end-to-end `LDA_PG` test once the core actually updates page_reg.
