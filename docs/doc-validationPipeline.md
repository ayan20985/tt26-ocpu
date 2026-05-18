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
| cocotb | rtl test driver (>= 2.0)         | `pip install -r test/requirements.txt` |
| icarus | verilog simulator                | `winget install Icarus.Verilog` (or windows installer) |
| gtkwave / surfer | wave viewer            | optional                     |
| cc65   | c -> 6502 assembler              | https://github.com/cc65/cc65/releases |
| verilator | optional alt simulator         | brew / apt / windows tarball |

note: the runner does NOT require GNU make. it uses cocotb 2.x's
python runner (`cocotb_tools.runner`). the icarus default install
location `C:\iverilog\bin` is added to PATH automatically by both
`tools/run_tests.ps1` and `test/run.py`.

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

    powershell.exe -ExecutionPolicy Bypass -File tools\run_tests.ps1

or directly:

    python test\run.py

run a single test:

    python test\run.py --test test_branch

gate-level run (needs `test/gate_level_netlist.v` from openlane):

    python test\run.py --gates test/gate_level_netlist.v

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

the consequence: this fast core regression exercises 100% of `ocpu_core.v`
and `iram_regfile.v`, but does NOT exercise `ospi_memory.v` or
`project.v`. those are exercised separately by the chip-top regression
(`python test/run.py --chip`, see "chip-level OSPI" section below)
which instantiates the full `tt_um_ocpu` and drives real OSPI bursts
from python.

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

## chip-level OSPI (silicon-side fixes)

three silicon-side bugs that previously blocked real-hardware operation
have now been fixed and are exercised by the chip-top regression
(`test/test_chip.py` against `test/tb_chip.v`, which instantiates the
full `tt_um_ocpu` top with real Tiny Tapeout pins):

1. **Pin-overlap fix** — SCK, CS_N, page_done, and page_loading have
   been moved off the `uio_in[7:0]` data bus onto the dedicated input
   bank `ui_in[0..3]`. previously `uio_in[0]/[1]` aliased `io_i[0]/[1]`,
   which made it impossible for the master to transmit any byte whose
   bit 0 was clear (e.g. the write command 0x02) because SCK had to be
   high during sampling. moving them to a non-bidirectional bank removes
   the alias entirely.

2. **CS_N polarity fix in `ospi_memory.v`** — the slave's main `always`
   block previously had `if (cs_sync)` (i.e. "if CS_N is HIGH"), so the
   slave only ever processed bytes while the chip was *deselected*. that
   has been flipped to `if (!cs_sync)` so the slave actually responds
   when CS_N is asserted. the slave also now (a) tri-states `io_oe`
   except during byte 4 of a *read* (preventing bus contention on writes)
   and (b) triggers `mem_read` on the byte-3 sample, not byte 4, so the
   upstream rdata mux has one full SCK half-period to deliver data before
   the master clocks byte 4.

3. **iRAM byte-pair loading** — the chip used to replicate the single
   OSPI byte onto both halves of the iRAM slot (`wr_pg_data <=
   {ospi_mem_wdata, ospi_mem_wdata}`), which meant only instructions
   with `hi == lo` could be loaded (so e.g. `HLT = 0xF000` could never
   be loaded). the address map now uses `addr[3:1]` for slot and
   `addr[0]` for LO/HI byte select: a single instruction load is two
   OSPI writes (LO first, latched internally, then HI which commits the
   full 16-bit word into the slot). 16 addresses, 0x000000..0x00000F.

after these fixes the chip can boot from cold reset, load a full page
over real OSPI, execute it, and the FPGA can read back dirty bits +
modified slots — all validated by `test/test_chip.py`:

* `test_chip_ospi_load_and_run`  — load `LDA #$5A; HLT` over OSPI, run, verify `is_halted`.
* `test_chip_ospi_readback`      — write 8 distinct 16-bit words, read back every byte, verify all match.
* `test_chip_smod_writeback`     — run a SMOD program, OSPI-read `dirty_bits` at `0xFD0000`, OSPI-read the modified slot, verify the writeback contract.

run them with:

    python test/run.py --chip

### running the full suite

    python test/run.py          # 25 core tests (bypasses ospi/project)
    python test/run.py --chip   # 3 chip-top tests (real ospi pins via tb_chip)

## cpu semantic quirks discovered during validation

beyond the bugs fixed below, two pre-existing cpu behaviours are worth
calling out for anyone writing programs / extending the tests:

* `ST_HALTED` is gated on `run_enable`. with `run_enable=1` the cpu
  spends a single cycle in `ST_HALTED` and falls back to `ST_FETCH`. so
  `HLT` alone does NOT permanently halt the cpu; the chip needs an
  external `run_enable=0` to actually stop. the testbench solves this by
  deasserting `run_enable` the cycle it observes `ST_HALTED`, pinning
  the cpu so the test can inspect final state.
* slot 7 of every iram page is special: any instruction fetched at slot
  7 sets `wrap_pending`, which is re-evaluated the next time `ST_FETCH`
  runs, forcing a page-swap then. this means control-flow instructions
  (`RTS`, `JMP`, `JSR`) MUST NOT live at slot 7 unless you actually want
  the page to swap immediately afterward. `HLT` happens to work at slot
  7 because the `ST_EXECUTE` last-write-wins ordering puts `ST_HALTED`
  after the wrap-pending state update. `test_stack.s` documents this
  in-line.

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

## current status

all 24 tests pass against icarus verilog 12.0 (rtl simulation):

    TESTS=24 PASS=24 FAIL=0 SKIP=0

this includes the full C compilation pipeline test `test_cc65_sum_arr`
that compiles `test/programs/c_src/sum_arr.c` end-to-end through cc65,
the 6502->ocpu translator, and the ocpu assembler, then runs the
resulting multi-page binary on the cpu and verifies the in-memory
result.

run with: `powershell.exe -ExecutionPolicy Bypass -File tools\run_tests.ps1`
or directly: `python test\run.py`.

### cc65 setup

drop the prebuilt windows snapshot zip (`cc65-snapshot-win32.zip` from
https://sourceforge.net/projects/cc65/files/) into the `cc65/` folder
at the repo root and `Expand-Archive` it so `cc65/bin/cc65.exe` exists.
the `build_c.ps1` script (and `translate_6502.py`) auto-discover the
binary in that location, in `%LOCALAPPDATA%\cc65\bin\`, or on `PATH`.

### what the translator handles (post cc65-pipeline work)

* full ca65 segment model: `.segment "DATA" / "BSS" / "RODATA" / "CODE"`
  with each segment laid out at a configurable base (`--data-base`,
  `--bss-base`, `--rodata-base`, `--zeropage-base`).
* `.byte` / `.word` / `.ascii` / `.res` directives in non-CODE segments
  are buffered up and emitted as `.data <addr>` blocks ahead of the
  instruction stream (the ocpu assembler forbids `.byte` after `.page`).
* symbolic operands with optional offset (`_arr+1`, `_sum`) are resolved
  to absolute 16-bit addresses, then truncated to the low byte plus an
  automatic `STA_DP` data-page switch when the high byte changes.
* `.proc <name>: near` / `.endproc` emit labels that the ocpu assembler
  resolves as slot indices.
* an auto-pager packs the instruction stream slot-by-slot, relying on
  the cpu's natural slot-7 wrap (via `page_interrupt`) for straight-
  line fall-through across page boundaries. forward `BR*` branches
  use the native intra-page form when the target fits in the same
  page; otherwise the branch is rewritten as a 2-slot
  `<inverted-br> __local; FARJMP <target_page>; __local:` bridge and
  the target label is force-aligned to slot 0 of a fresh page. cc65
  backward branches stay on the inverted-skip + JMP microcode path
  and the JMP is auto-rewritten to FARJMP when it crosses pages.
* cross-page `JSR` is rejected with a clear warning, because the cpu
  only saves the 3-bit slot on call — a cross-page `RTS` cannot
  reconstruct the right page.
* in `--main-entry` mode (default in `build_c.ps1`) the LAST emitted
  `RTS` is rewritten to `HLT`, which lets cc65's `_main`-returns-into-
  runtime convention work without a JSR wrapper. JSR/RTS only persist
  the 3-bit slot (no page) on this cpu, so a true cross-page wrapper
  is structurally impossible without a software return stack.

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
| test_cmp.s                    | CMP # / CMP addr flag effects                |
| test_adc_sbc.s                | ADC / SBC carry-in propagation               |
| test_alu_mem.s                | ADD / AND / ORA / EOR against dram           |
| test_branch_full.s            | BEQ / BNE / BMI / BPL counted in X           |
| test_reg_xfers.s              | TXA / TAY / TYA / DEX / INY transfers        |
| test_pha_pla.s                | PHA / PLA round trip; SP balance             |
| test_sp_ops.s                 | LDSP / TSX / TXS / STSP                      |
| test_load_abs.s               | LDX abs / LDY abs / STX / STY                |
| test_jmp.s                    | intra-page JMP                               |
| test_data_page.s              | LDA_DP / STA_DP data-page switching          |
| test_indexed.s                | LDA / STA abs,X                              |
| test_sta_indy.s               | STA (zp),Y indirect-Y store                  |
| test_sys_flags.s              | SEC / CLC / SEI / CLI explicit flag bits     |
| sample_6502.s + sum_arr.c     | translator + cc65 end-to-end pipelines       |

what is NOT yet covered, and worth adding next:

* FARJMP target-page check (after `page_reg` is actually wired to the
  FARJMP imm; right now it never updates).
* CMP flag updates (Z + C) for unequal/equal/lt operands.
* SEI / CLI / SEC / CLC / CLV explicit flag-bit checks.
* multi-page programs that exercise FARJMP with a non-zero dirty bit
  going through the writeback path (requires extending the FpgaModel
  with an external dram tied to dirty_bits).
* an end-to-end `LDA_PG` test once the core actually updates page_reg.
