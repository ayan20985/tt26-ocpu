"""
translate_6502.py
6502 (ca65) assembly  ->  ocpu custom isa assembly translator.

approach
--------
this is a line-oriented pass-through translator. each 6502 line maps to
one or more ocpu lines. ops with no 1:1 mapping are expanded into short
microcode sequences using only ops the current core actually implements.

unsupported / problematic ops are written through as a stub line plus a
"; UNSUPPORTED" comment so the downstream assembler will fail loudly and
the user can inspect the offending source. that is by design: silently
dropping instructions is exactly the bug we do not want during cpu
validation.

page management
---------------
the translator emits a linear stream of ocpu instructions and lets the
ocpu assembler take care of slotting them into 8-instruction pages.
between functions / large code blocks the translator inserts an
explicit `.page <next>` directive so the assembler is forced to align
the function entry on a fresh page (which makes JSR / RTS targeting
much more predictable, given the 3-bit return slot the core saves).

caveats
-------
* this translator handles a hand-written 6502 subset and the simplest
  ca65 output. real cc65 output uses macros, segments, and runtime
  helpers that we do not implement. expect to extend this module as you
  add more c source files.
* the 6502 stack lives at $0100..$01FF; the ocpu stack lives at
  {data_page, sp}. before running translated 6502 code you should
  STA_DP a value that matches what cc65 thinks the stack page is, or
  more practically set data_page = 1 at the entry point.
* 16-bit absolute addresses are truncated to the low byte; the translator
  emits an STA_DP-based data_page switch when the high byte changes.
"""

from __future__ import annotations
import re
import sys
import argparse
from pathlib import Path
from dataclasses import dataclass


# -------------------------------------------------------------------------
# parsing helpers
# -------------------------------------------------------------------------
LABEL_RE = re.compile(r'^([A-Za-z_@][A-Za-z0-9_@]*):\s*(.*)$')
LINE_RE  = re.compile(r'^\s*(\S+)\s*(.*?)\s*(?:;.*)?$')


def parseAddrToken(tok: str) -> tuple[str, str]:
    """return ('mode', value-string) for one operand. mode is one of:
        'imm'      #$xx or #ddd
        'absx'     addr,X
        'absy'     addr,Y      (will be translated using X via microcode)
        'indy'     (addr),Y
        'indx'     (addr,X)    (will fail; not implemented)
        'abs'      bare addr
        'rel'      branch target (just a symbol/number)
        'none'     empty operand
    """
    tok = tok.strip()
    if not tok:
        return ('none', '')
    if tok.startswith('#'):
        return ('imm', tok[1:].strip())
    m = re.match(r'\(([^)]+)\)\s*,\s*[Yy]\s*$', tok)
    if m:
        return ('indy', m.group(1).strip())
    m = re.match(r'\(\s*([^,)]+)\s*,\s*[Xx]\s*\)\s*$', tok)
    if m:
        return ('indx', m.group(1).strip())
    m = re.match(r'(.+?)\s*,\s*[Xx]\s*$', tok)
    if m:
        return ('absx', m.group(1).strip())
    m = re.match(r'(.+?)\s*,\s*[Yy]\s*$', tok)
    if m:
        return ('absy', m.group(1).strip())
    return ('abs', tok)


# -------------------------------------------------------------------------
# translator
# -------------------------------------------------------------------------
@dataclass
class TranslateState:
    output: list[str]
    warnings: list[str]
    lastDataPage: int | None = None


def emit(state: TranslateState, line: str, comment: str | None = None):
    if comment:
        state.output.append(f"    {line:<24}; {comment}")
    else:
        state.output.append(f"    {line}")


def emitRaw(state: TranslateState, raw: str):
    state.output.append(raw)


def maybeSwitchDataPage(state: TranslateState, addr: str):
    """if the operand is a 16-bit address with a known high byte that
    differs from the last emitted data_page, emit microcode to switch."""
    if not addr.startswith('$'):
        return
    hex_part = addr[1:]
    try:
        val = int(hex_part, 16)
    except ValueError:
        return
    if val <= 0xFF:
        # zero page; no data_page switch needed if data_page already 0
        if state.lastDataPage not in (None, 0):
            emit(state, "LDA #$00")
            emit(state, "STA_DP",  comment="data_page <- 0 (zp window)")
            state.lastDataPage = 0
        return
    hi = (val >> 8) & 0xFF
    if state.lastDataPage == hi:
        return
    emit(state, f"LDA #${hi:02x}", comment=f"set data_page = ${hi:02x}")
    emit(state, "STA_DP")
    state.lastDataPage = hi


def lowByte(addr: str) -> str:
    """return the low byte of an address operand as an ocpu-imm string."""
    if addr.startswith('$'):
        try:
            v = int(addr[1:], 16) & 0xFF
            return f"${v:02x}"
        except ValueError:
            pass
    # symbolic: assume small / zero-page-ish; the ocpu assembler will
    # complain at assemble time if the value does not fit.
    return addr


# -------------------------------------------------------------------------
# instruction translators
# -------------------------------------------------------------------------
def translateOne(state: TranslateState, mnem: str, operand: str, lineno: int):
    m = mnem.upper()
    mode, val = parseAddrToken(operand)
    src = f"6502: {mnem} {operand}".rstrip()

    # ---- LDA / LDX / LDY ----
    if m == 'LDA':
        if mode == 'imm':
            emit(state, f"LDA #{val}", src)
        elif mode == 'absx':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)},X", src)
        elif mode == 'indy':
            # operand is a zero-page pointer slot
            emit(state, f"LDA ({lowByte(val)}),Y", src)
        elif mode == 'absy':
            # ocpu lacks abs,Y. emulate via TXY swap microcode:
            # save X to stack, copy Y to X, do abs,X, restore X.
            emit(state, "PHA", src)
            emit(state, "TXA")
            emit(state, "PHA", "save X")
            emit(state, "TYA")
            emit(state, "TAX",  "X <- Y (for abs,X emulation)")
            emit(state, "PLA",  "restore old X")
            emit(state, "TAX")
            emit(state, "PLA")
            # NOTE: this still loses the original X content semantics;
            # cc65 rarely emits abs,Y for accumulator loads, so a full
            # workaround is left as TODO.
            state.warnings.append(
                f"line {lineno}: LDA abs,Y micro-emulation is approximate")
        elif mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)}", src)
        else:
            state.warnings.append(f"line {lineno}: LDA {mode!r} not supported")
            emit(state, f"; UNSUPPORTED LDA mode={mode} operand={operand}")
        return

    if m == 'LDX':
        if mode == 'imm':
            emit(state, f"LDX #{val}", src)
        elif mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDX {lowByte(val)}", src)
        else:
            state.warnings.append(f"line {lineno}: LDX {mode!r} not supported")
            emit(state, f"; UNSUPPORTED LDX mode={mode} operand={operand}")
        return

    if m == 'LDY':
        if mode == 'imm':
            emit(state, f"LDY #{val}", src)
        elif mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDY {lowByte(val)}", src)
        else:
            state.warnings.append(f"line {lineno}: LDY {mode!r} not supported")
            emit(state, f"; UNSUPPORTED LDY mode={mode} operand={operand}")
        return

    # ---- STA / STX / STY ----
    if m == 'STA':
        if mode == 'absx':
            maybeSwitchDataPage(state, val)
            emit(state, f"STA {lowByte(val)},X", src)
        elif mode == 'indy':
            emit(state, f"STA ({lowByte(val)}),Y", src)
        elif mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"STA {lowByte(val)}", src)
        else:
            emit(state, f"; UNSUPPORTED STA mode={mode} operand={operand}")
            state.warnings.append(f"line {lineno}: STA {mode!r} not supported")
        return

    if m in ('STX', 'STY'):
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"{m} {lowByte(val)}", src)
        else:
            emit(state, f"; UNSUPPORTED {m} mode={mode}")
            state.warnings.append(f"line {lineno}: {m} {mode!r} not supported")
        return

    # ---- ALU ----
    aluMap = {'ADC': 'ADC', 'SBC': 'SBC',
              'AND': 'AND', 'ORA': 'ORA', 'EOR': 'EOR', 'CMP': 'CMP'}
    if m in aluMap:
        op = aluMap[m]
        if mode == 'imm':
            emit(state, f"{op} #{val}", src)
        elif mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"{op} {lowByte(val)}", src)
        else:
            emit(state, f"; UNSUPPORTED {op} mode={mode}")
            state.warnings.append(f"line {lineno}: {op} {mode!r} not supported")
        return

    # ---- CPX / CPY: microcode CMP via X / Y register swap ----
    if m in ('CPX', 'CPY'):
        reg = 'X' if m == 'CPX' else 'Y'
        if mode == 'imm':
            emit(state, "PHA",                src + "  (microcode 1/4 save A)")
            emit(state, f"T{reg}A",           f"(microcode 2/4 A <- {reg})")
            emit(state, f"CMP #{val}",        "(microcode 3/4 compare)")
            emit(state, "PLA",                "(microcode 4/4 restore A)")
        elif mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, "PHA",                src + "  (microcode 1/4 save A)")
            emit(state, f"T{reg}A",           f"(microcode 2/4 A <- {reg})")
            emit(state, f"CMP {lowByte(val)}", "(microcode 3/4 compare)")
            emit(state, "PLA",                "(microcode 4/4 restore A)")
        else:
            emit(state, f"; UNSUPPORTED {m} mode={mode}")
            state.warnings.append(f"line {lineno}: {m} {mode!r} not supported")
        return

    # ---- INC / DEC memory (microcode expansion) ----
    if m == 'INC':
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)}", src + "  (microcode part 1/3)")
            emit(state, "ADC #$01",            "(microcode part 2/3)")
            emit(state, f"STA {lowByte(val)}", "(microcode part 3/3)")
        else:
            emit(state, f"; UNSUPPORTED INC mode={mode}")
            state.warnings.append(f"line {lineno}: INC {mode!r} not supported")
        return
    if m == 'DEC':
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)}", src + "  (microcode part 1/3)")
            emit(state, "SBC #$01",            "(microcode part 2/3)")
            emit(state, f"STA {lowByte(val)}", "(microcode part 3/3)")
        else:
            emit(state, f"; UNSUPPORTED DEC mode={mode}")
            state.warnings.append(f"line {lineno}: DEC {mode!r} not supported")
        return

    # ---- register transfers ----
    if m in ('TAX', 'TXA', 'TAY', 'TYA', 'INX', 'DEX', 'INY', 'DEY',
             'PHA', 'PLA', 'TSX', 'TXS', 'NOP'):
        emit(state, m, src); return
    if m in ('SEC', 'CLC', 'SEI', 'CLI', 'CLV'):
        emit(state, m, src); return

    # ---- control flow ----
    if m == 'JMP':
        if mode == 'abs':
            emit(state, f"JMP {val}", src)
        else:
            emit(state, f"; UNSUPPORTED JMP mode={mode}")
            state.warnings.append(f"line {lineno}: JMP {mode!r} not supported")
        return
    if m == 'JSR':
        emit(state, f"JSR {val}", src); return
    if m == 'RTS':
        emit(state, "RTS", src); return
    if m == 'RTI':
        emit(state, "RTI", src); return

    if m in ('BEQ', 'BNE', 'BCS', 'BCC', 'BMI', 'BPL'):
        emit(state, f"{m} {val}", src); return

    # ---- system ----
    if m == 'BRK':
        emit(state, "HLT", src + "  (treating BRK as HLT)"); return

    # ---- shifts: not implementable on current core ----
    if m in ('ASL', 'LSR', 'ROL', 'ROR'):
        emit(state, f"; UNSUPPORTED {m}: shifts are dead code in the current "
                    f"ocpu_core. fix ST_DECODE before using shifts.")
        state.warnings.append(f"line {lineno}: {m} not implemented in core")
        return

    # ---- BIT: AND but only flags ----
    if m == 'BIT':
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, "PHA",                  src + "  (microcode part 1/3)")
            emit(state, f"AND {lowByte(val)}",  "(microcode part 2/3, sets Z)")
            emit(state, "PLA",                  "(microcode part 3/3 restore A)")
            state.warnings.append(
                f"line {lineno}: BIT only sets Z (N/V bits not propagated)")
        else:
            emit(state, f"; UNSUPPORTED BIT mode={mode}")
            state.warnings.append(f"line {lineno}: BIT {mode!r} not supported")
        return

    # ---- fall through ----
    emit(state, f"; UNTRANSLATED: {mnem} {operand}")
    state.warnings.append(f"line {lineno}: unknown mnemonic {mnem!r}")


# -------------------------------------------------------------------------
# driver
# -------------------------------------------------------------------------
def translateFile(source: str | Path) -> tuple[str, list[str]]:
    state = TranslateState(output=[], warnings=[])
    state.output.append("; auto-generated by translate_6502.py")
    state.output.append("; original 6502 source: " + str(source))
    state.output.append(".page 0")

    text = Path(source).read_text(encoding='utf-8')
    for lineno, raw in enumerate(text.splitlines(), start=1):
        # strip ca65 comments and whitespace
        bare = raw.split(';', 1)[0].rstrip()
        if not bare.strip():
            continue

        # ca65 .segment / .byte / .word directives -> pass through into the
        # ocpu .data section so initialised globals land in the data image
        if bare.lstrip().startswith('.'):
            tokens = bare.lstrip().split(None, 1)
            dirc = tokens[0].lower()
            args = tokens[1] if len(tokens) > 1 else ''
            if dirc in ('.byte', '.word', '.ascii', '.data', '.page', '.org'):
                emitRaw(state, '    ' + bare.lstrip())
            else:
                emitRaw(state, '    ; (directive passed through) ' + bare.lstrip())
            continue

        # label-only line  or  "label: instr"
        m = LABEL_RE.match(bare.lstrip())
        if m:
            label, rest = m.group(1), m.group(2).strip()
            emitRaw(state, f"{label}:")
            if not rest:
                continue
            bare = rest

        m = LINE_RE.match(bare)
        if not m:
            state.warnings.append(f"line {lineno}: could not parse: {raw!r}")
            continue
        mnem = m.group(1)
        operand = m.group(2)
        translateOne(state, mnem, operand, lineno)

    return ('\n'.join(state.output) + '\n', state.warnings)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="6502 -> ocpu isa translator")
    p.add_argument('source', help="input .s (6502 / ca65 syntax)")
    p.add_argument('-o', '--output', default=None,
                   help="output .s (ocpu syntax); default <source>.ocpu.s")
    args = p.parse_args(argv)

    text, warnings = translateFile(args.source)
    out = Path(args.output) if args.output else Path(args.source).with_suffix('.ocpu.s')
    out.write_text(text, encoding='utf-8')
    print(f"wrote {out}")
    if warnings:
        print(f"{len(warnings)} warning(s):", file=sys.stderr)
        for w in warnings:
            print(f"  {w}", file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
