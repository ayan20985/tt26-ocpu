# doc-runYourOwnC

a single command runs your own C code on the ocpu rtl and dumps the
final cpu / iram / dram state.

## one-shot workflow

1. open `test/programs/c_src/user.c` and write your program. the file
   ships with a worked sum example.
2. from the repo root, run:

       pwsh tools\run_c.ps1

3. scroll up in the output to the `FINAL CPU STATE` block. it contains:

   * registers `A`, `X`, `Y`, `SP`, the program-counter slot, plus
     `page_reg` and `data_page`.
   * the flag bits `N`, `V`, `Z`, `C`, `I` (and the raw `sr`).
   * the iram page the cpu was sitting in when `HLT` executed
     (16-bit slot words, decoded into `op / sub / imm` for readability).
   * every iram page the FpgaModel ever shipped to the cpu — that is,
     the full program image in load order, including auto-generated
     `FARJMP` slot-7 page bridges.
   * every dram byte the program touched (initial `.data` image plus
     every write the program performed at runtime), sorted by address
     in decimal and hex.

## options

| flag                         | purpose                                       |
|------------------------------|-----------------------------------------------|
| `-Source <file.c>`           | compile a different c source                  |
| `-NoBuild`                   | re-run the existing `.hex` without recompiling|
| `-MaxCycles <n>`             | bump the sim cycle budget (default 50000)     |

example: compile and run the existing 6502 sample without invoking cc65
at all:

    pwsh tools\run_c.ps1 -Source test\programs\c_src\sample_6502.s -NoBuild

(the runner doesn't care whether the `.hex` came from c or from
hand-written 6502 or hand-written ocpu — it just loads it.)

## what the example program does

`user.c` sums 1..5 into a global `total` and increments `count` once
per addend. all variables are globals (cc65 places them in the BSS
segment which the translator lays out at `$0080`). after the run the
dump shows:

    DRAM (2 byte(s); addr -> value)
      $0080: 0f  ( 15)        -> total
      $0081: 05  (  5)        -> count

## what the c side supports

| feature                                                     | status     |
|-------------------------------------------------------------|------------|
| globals: `unsigned char foo;` and `unsigned char arr[N];`   | works      |
| arithmetic: `+`, `-`, `&`, `|`, `^`                         | works      |
| comparisons + `if` / `else` (auto-bridged across pages)     | works      |
| unrolled fixed-count loops (copy-paste the body)            | works      |
| indexed arrays with literal indices: `arr[3] = arr[5];`     | works      |
| local variables, function parameters                        | **no**     |
| `for (i = ...; i < N; i++)` style loops                     | **no**     |
| `*`, `/`, `%`, `<<`, `>>`                                   | **no**     |
| 16-bit ints, pointers, your own helper functions            | **no**     |

### why the "no" items are missing

* **locals and counted loops.** cc65 lowers function-local variables
  and `for` loop counters onto a software stack accessed through
  `c_sp` indirect-Y stores. that storage model relies on cc65's
  runtime helpers (`pushax`, `popa`, `decsp1`, `incsp1`, ...) which
  this project does not link. extending the translator to model that
  runtime is the next chunk of compiler work.

* **mul / div / mod / shift.** these are *not* 6502 instructions
  either: cc65 emits `jsr mulax`, `jsr divax`, `jsr shrax1`, etc.,
  which are subroutines in cc65's runtime library. our cpu cannot
  host that library because (a) there is no barrel shifter in the
  rtl (the ALU has dead code for ASL/LSR/ROL/ROR that ST_DECODE
  never reaches — this would be a silicon change, not a software
  one) and (b) the runtime helpers assume a 256-byte 6502 stack
  page and 16-bit pointer registers we don't have. so even if a
  hardware shifter existed, we'd still be missing the link-time
  support.

* **pointers and 16-bit ints.** cc65 spreads 16-bit values across an
  `A`/`X` pair and uses `sreg`/`ptr1`/`tmp1` as scratch pointer
  registers in zero page. our cpu is single-accumulator, and the
  translator does not yet track register pairs.

write c that stays in the "works" column and the pipeline should
just go.

## extending past `user.c`

`tools/run_c.ps1` only invokes `build_c.ps1` on a single file. if you
want to assemble several `.c` files together you'll need to call
`cl65` (cc65's linker driver) yourself — that path is not wired up
today because it brings in cc65's runtime crt0 which our cpu can't
host yet.
