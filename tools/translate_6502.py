"""
translate_6502.py
6502 (ca65) assembly  ->  ocpu custom isa assembly translator.

two-pass design
---------------
this translator is now substantial enough to handle the kind of output
cc65 emits for simple programs. it runs two passes over the source:

  pass 1 (layout):
    * tracks .segment directives ("CODE", "DATA", "BSS", "RODATA",
      "ZEROPAGE", anything else gets dropped into a generic bucket)
    * walks every line that emits bytes (.byte / .word / .ascii / .res
      / labelled instructions inside .segment CODE) and assigns each
      label its absolute 16-bit address based on the segment layout
      table below.

  pass 2 (codegen):
    * re-walks the source, this time emitting ocpu asm:
        - DATA / BSS bytes become `.data <addr>` + `.byte`/`.word` blocks
        - CODE instructions get translated mnemonic-by-mnemonic using
          the same rules as before, with symbolic operands resolved to
          their absolute address (then truncated to the low byte plus
          an implicit data_page switch when the high byte changes).

segment layout
--------------
chosen to fit comfortably under the 64 kB cpu address space while
leaving the zero-page-style $0000..$003F window free for assembler-
generated test data:

    ZEROPAGE  $0010..$001F   (cc65 temps; tmp1, ptr1, etc.)
    DATA      $0040..$007F   (initialised globals)
    BSS       $0080..$00FF   (uninitialised globals)
    RODATA    $0100..$01FF   (string literals)
    CODE      goes into the ocpu instruction-page stream (.page 0 ...)

these starts are configurable via translator command-line flags if you
want a different layout. anything that doesn't fit triggers a warning.

caveats
-------
this is still a "best effort" translator. it does NOT implement:
    * cc65's pushax / popa / staspidx / ldaxysp runtime helpers
    * 16-bit pointer arithmetic via sreg
    * indirect jumps (JMP (vector))
    * .macpack longbranch
when the input uses these, the translator emits ; UNSUPPORTED + a
warning and the downstream assembler will refuse to assemble. that is
intentional: cpu validation cannot drop instructions silently.
"""

from __future__ import annotations
import re
import sys
import argparse
from pathlib import Path
from dataclasses import dataclass, field

# pull page geometry from ocpu_asm so the auto-pager stays in sync with
# whatever the assembler / hardware currently use.
from ocpu_asm import SLOTS_PER_PAGE  # noqa: E402


# -------------------------------------------------------------------------
# segment layout
# -------------------------------------------------------------------------
DEFAULT_LAYOUT = {
    'ZEROPAGE': 0x0010,
    'DATA':     0x0040,
    'BSS':      0x0080,
    'RODATA':   0x0100,
}


# -------------------------------------------------------------------------
# parsing helpers
# -------------------------------------------------------------------------
LABEL_RE      = re.compile(r'^([A-Za-z_@][A-Za-z0-9_@]*):\s*(.*)$')
LINE_RE       = re.compile(r'^\s*(\S+)\s*(.*?)\s*(?:;.*)?$')
SYMBOL_RE     = re.compile(r'([A-Za-z_@][A-Za-z0-9_@]*)\s*([+\-]\s*\d+)?$')


def parseNumber(token: str) -> int:
    t = token.strip().lstrip('#')
    if t.startswith('$'):  return int(t[1:], 16)
    if t.startswith('0x'): return int(t[2:], 16)
    if t.startswith('%'):  return int(t[1:], 2)
    return int(t, 10)


def resolveOperand(tok: str, symbols: dict[str, int]) -> str:
    """convert a possibly-symbolic operand like '_arr+1' or '$0042'
    into a hex-prefixed numeric form ('$0043') that the rest of the
    translator can handle as a regular address. immediate prefixes (#)
    are preserved. unresolved symbols are returned unchanged so the
    downstream error message is meaningful."""
    if not tok:
        return tok
    tok = tok.strip()
    prefix = ''
    if tok.startswith('#'):
        prefix = '#'
        tok = tok[1:].strip()

    # numeric literal already
    if tok.startswith('$') or tok.startswith('0x') or tok.startswith('%') or tok.isdigit():
        return prefix + tok

    # try `name[+-]offset`
    m = re.match(r'^([A-Za-z_@][A-Za-z0-9_@]*)\s*([+\-]\s*\d+)?$', tok)
    if m:
        name = m.group(1)
        offstr = m.group(2)
        if name in symbols:
            value = symbols[name]
            if offstr:
                value += parseNumber(offstr.replace(' ', ''))
            value &= 0xFFFF
            return f"{prefix}${value:04x}"
    return prefix + tok  # leave it; downstream may diagnose


def parseAddrToken(tok: str) -> tuple[str, str]:
    """return ('mode', value-string) for one operand:
        'imm'      #$xx
        'absx'     addr,X
        'absy'     addr,Y
        'indy'     (addr),Y
        'indx'     (addr,X)
        'abs'      bare addr
        'none'     empty
    """
    tok = tok.strip()
    if not tok:                                          return ('none', '')
    if tok.startswith('#'):                              return ('imm',  tok[1:].strip())
    m = re.match(r'\(([^)]+)\)\s*,\s*[Yy]\s*$', tok);
    if m:                                                return ('indy', m.group(1).strip())
    m = re.match(r'\(\s*([^,)]+)\s*,\s*[Xx]\s*\)\s*$', tok)
    if m:                                                return ('indx', m.group(1).strip())
    m = re.match(r'(.+?)\s*,\s*[Xx]\s*$', tok)
    if m:                                                return ('absx', m.group(1).strip())
    m = re.match(r'(.+?)\s*,\s*[Yy]\s*$', tok)
    if m:                                                return ('absy', m.group(1).strip())
    return ('abs', tok)


# -------------------------------------------------------------------------
# state
# -------------------------------------------------------------------------
@dataclass
class TranslateState:
    output: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    lastDataPage: int | None = None
    brSkipCounter: int = 0
    symbols: dict[str, int] = field(default_factory=dict)
    layout: dict[str, int] = field(default_factory=lambda: dict(DEFAULT_LAYOUT))
    # set of code-segment labels we've already emitted into codeBuf
    # during pass 2. used to classify a branch target as forward (label
    # not yet seen -> native ocpu branch is fine) versus backward
    # (label already seen -> must use inverted-skip + JMP microcode).
    seenLabels: set[str] = field(default_factory=set)


def emit(state: TranslateState, line: str, comment: str | None = None):
    if comment:
        state.output.append(f"    {line:<24}; {comment}")
    else:
        state.output.append(f"    {line}")


def emitRaw(state: TranslateState, raw: str):
    state.output.append(raw)


# -------------------------------------------------------------------------
# pass 1: layout / symbol resolution
# -------------------------------------------------------------------------
def pass1Layout(text: str, layout: dict[str, int]) -> dict[str, int]:
    """walk the source. produce {label_name: absolute_address}. CODE
    labels get a placeholder address; we only need numeric addresses
    for DATA/BSS/RODATA/ZEROPAGE labels so the translator can fill in
    operand bytes. CODE labels stay symbolic so the downstream ocpu
    assembler resolves them as slot indices."""
    symbols: dict[str, int] = {}
    # per-segment write cursor
    cursor = dict(layout)
    cursor['CODE'] = 0  # ignored for symbols but tracked for completeness
    segment = 'CODE'
    pendingLabels: list[str] = []   # labels not yet bound (waiting for the
                                    # first byte-emitting line of the segment)

    for raw in text.splitlines():
        bare = raw.split(';', 1)[0].rstrip()
        if not bare.strip():
            continue
        # label on its own line, or 'label: body'
        m = LABEL_RE.match(bare.lstrip())
        if m:
            label, rest = m.group(1), m.group(2).strip()
            pendingLabels.append(label)
            if not rest:
                continue
            bare = rest
        stripped = bare.lstrip()

        # directives
        if stripped.startswith('.'):
            tokens = stripped.split(None, 1)
            dirc = tokens[0].lower()
            args = tokens[1] if len(tokens) > 1 else ''
            if dirc == '.segment':
                seg = args.strip().strip('"').upper()
                segment = seg
                if seg not in cursor:
                    cursor[seg] = layout.get(seg, 0x0200)
                # bind any pending labels to the new segment's cursor
                for lbl in pendingLabels:
                    if segment != 'CODE':
                        symbols[lbl] = cursor[segment]
                # only consume pending if we're in a data segment; in
                # CODE the labels are still pending until they apply to
                # the next instruction
                if segment != 'CODE':
                    pendingLabels = []
                continue

            if segment in ('CODE',) or dirc in ('.fopt', '.setcpu', '.smart',
                                                '.autoimport', '.case',
                                                '.debuginfo', '.importzp',
                                                '.export', '.forceimport',
                                                '.macpack', '.import',
                                                '.proc', '.endproc',
                                                '.exportzp',):
                # skip; these don't emit bytes
                if dirc == '.proc':
                    # .proc <name>: near
                    m2 = re.match(r'([A-Za-z_@][A-Za-z0-9_@]*)', args)
                    if m2:
                        pendingLabels.append(m2.group(1))
                continue

            # data-emitting directives
            if dirc == '.byte':
                # bind pending labels
                for lbl in pendingLabels:
                    symbols[lbl] = cursor[segment]
                pendingLabels = []
                n = len([a for a in args.split(',') if a.strip()])
                cursor[segment] += n
                continue
            if dirc == '.word':
                for lbl in pendingLabels:
                    symbols[lbl] = cursor[segment]
                pendingLabels = []
                n = len([a for a in args.split(',') if a.strip()])
                cursor[segment] += 2 * n
                continue
            if dirc == '.ascii':
                for lbl in pendingLabels:
                    symbols[lbl] = cursor[segment]
                pendingLabels = []
                m2 = re.search(r'"(.*)"', args)
                if m2:
                    cursor[segment] += len(bytes(m2.group(1), 'utf-8').decode('unicode_escape'))
                continue
            if dirc == '.res':
                # .res N[, fillByte]
                for lbl in pendingLabels:
                    symbols[lbl] = cursor[segment]
                pendingLabels = []
                parts = [a.strip() for a in args.split(',')]
                n = parseNumber(parts[0]) if parts else 0
                cursor[segment] += n
                continue
            continue  # unknown directive; ignore for layout

        # instruction line (CODE segment). bind any pending labels but
        # we do not assign them a numeric address - they remain symbolic
        # for the ocpu assembler to resolve as slot indices.
        # nothing further to do at layout time.
        pendingLabels = []

    return symbols


# -------------------------------------------------------------------------
# pass 2: codegen
# -------------------------------------------------------------------------
def maybeSwitchDataPage(state: TranslateState, addrTok: str):
    """if operand is a hex 16-bit address and its high byte differs from
    the last emitted data_page, emit microcode to switch."""
    if not addrTok.startswith('$'):
        return
    hex_part = addrTok[1:]
    try:
        val = int(hex_part, 16)
    except ValueError:
        return
    if val <= 0xFF:
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


def lowByte(addrTok: str) -> str:
    if addrTok.startswith('$'):
        try:
            v = int(addrTok[1:], 16) & 0xFF
            return f"${v:02x}"
        except ValueError:
            pass
    return addrTok


def translateInstruction(state: TranslateState, mnem: str, operand: str,
                         lineno: int):
    m = mnem.upper()
    # resolve symbols inside the operand BEFORE address-mode classification
    # so that addr-mode regexes see a clean hex literal.
    operand = operand.strip()
    if operand:
        # split out optional ',X' / ',Y' / surrounding parens, resolve the
        # bare symbol, and put the suffix back
        m_indy = re.match(r'\((.+?)\)\s*,\s*[Yy]\s*$', operand)
        m_indx = re.match(r'\((.+?)\s*,\s*[Xx]\)\s*$', operand)
        m_idx  = re.match(r'(.+?)\s*,\s*([XYxy])\s*$', operand)
        if m_indy:
            operand = '(' + resolveOperand(m_indy.group(1), state.symbols) + '),Y'
        elif m_indx:
            operand = '(' + resolveOperand(m_indx.group(1), state.symbols) + ',X)'
        elif m_idx:
            operand = resolveOperand(m_idx.group(1), state.symbols) + ',' + m_idx.group(2).upper()
        else:
            operand = resolveOperand(operand, state.symbols)

    mode, val = parseAddrToken(operand)
    src = f"6502: {mnem} {operand}".rstrip()

    # ---- LDA / LDX / LDY ----
    if m == 'LDA':
        if mode == 'imm':
            emit(state, f"LDA #{val}", src); return
        if mode == 'absx':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)},X", src); return
        if mode == 'indy':
            emit(state, f"LDA ({lowByte(val)}),Y", src); return
        if mode == 'absy':
            state.warnings.append(f"line {lineno}: LDA abs,Y not implemented")
            emit(state, f"; UNSUPPORTED LDA abs,Y {operand}"); return
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)}", src); return
        emit(state, f"; UNSUPPORTED LDA mode={mode} operand={operand}")
        state.warnings.append(f"line {lineno}: LDA mode {mode!r} not supported")
        return

    if m == 'LDX':
        if mode == 'imm':
            emit(state, f"LDX #{val}", src); return
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDX {lowByte(val)}", src); return
        emit(state, f"; UNSUPPORTED LDX mode={mode}")
        state.warnings.append(f"line {lineno}: LDX mode {mode!r} not supported")
        return

    if m == 'LDY':
        if mode == 'imm':
            emit(state, f"LDY #{val}", src); return
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDY {lowByte(val)}", src); return
        emit(state, f"; UNSUPPORTED LDY mode={mode}")
        state.warnings.append(f"line {lineno}: LDY mode {mode!r} not supported")
        return

    # ---- STA / STX / STY ----
    if m == 'STA':
        if mode == 'absx':
            maybeSwitchDataPage(state, val)
            emit(state, f"STA {lowByte(val)},X", src); return
        if mode == 'indy':
            emit(state, f"STA ({lowByte(val)}),Y", src); return
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"STA {lowByte(val)}", src); return
        emit(state, f"; UNSUPPORTED STA mode={mode}")
        state.warnings.append(f"line {lineno}: STA mode {mode!r} not supported")
        return

    if m in ('STX', 'STY'):
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"{m} {lowByte(val)}", src); return
        emit(state, f"; UNSUPPORTED {m} mode={mode}")
        state.warnings.append(f"line {lineno}: {m} mode {mode!r} not supported")
        return

    # ---- ALU ----
    aluMap = {'ADC':'ADC','SBC':'SBC','AND':'AND','ORA':'ORA','EOR':'EOR','CMP':'CMP'}
    if m in aluMap:
        op = aluMap[m]
        if mode == 'imm':
            emit(state, f"{op} #{val}", src); return
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"{op} {lowByte(val)}", src); return
        emit(state, f"; UNSUPPORTED {op} mode={mode}")
        state.warnings.append(f"line {lineno}: {op} mode {mode!r} not supported")
        return

    # ---- INC / DEC memory (microcode expansion) ----
    if m == 'INC':
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)}", src + "  (microcode 1/3)")
            emit(state, "ADC #$01",            "(microcode 2/3)")
            emit(state, f"STA {lowByte(val)}", "(microcode 3/3)")
            return
        emit(state, f"; UNSUPPORTED INC mode={mode}")
        state.warnings.append(f"line {lineno}: INC mode {mode!r} not supported")
        return
    if m == 'DEC':
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, f"LDA {lowByte(val)}", src + "  (microcode 1/3)")
            emit(state, "SBC #$01",            "(microcode 2/3)")
            emit(state, f"STA {lowByte(val)}", "(microcode 3/3)")
            return
        emit(state, f"; UNSUPPORTED DEC mode={mode}")
        state.warnings.append(f"line {lineno}: DEC mode {mode!r} not supported")
        return

    # ---- CPX / CPY: microcode via X/Y register save ----
    if m in ('CPX', 'CPY'):
        reg = 'X' if m == 'CPX' else 'Y'
        if mode == 'imm':
            emit(state, "PHA",                src + "  (microcode 1/4)")
            emit(state, f"T{reg}A",           f"(microcode 2/4 A <- {reg})")
            emit(state, f"CMP #{val}",        "(microcode 3/4)")
            emit(state, "PLA",                "(microcode 4/4)")
            return
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, "PHA",                 src + "  (microcode 1/4)")
            emit(state, f"T{reg}A",            f"(microcode 2/4 A <- {reg})")
            emit(state, f"CMP {lowByte(val)}", "(microcode 3/4)")
            emit(state, "PLA",                 "(microcode 4/4)")
            return
        emit(state, f"; UNSUPPORTED {m} mode={mode}")
        state.warnings.append(f"line {lineno}: {m} mode {mode!r} not supported")
        return

    # ---- register transfers and implied ----
    if m in ('TAX','TXA','TAY','TYA','INX','DEX','INY','DEY',
             'PHA','PLA','TSX','TXS','NOP',
             'SEC','CLC','SEI','CLI','CLV'):
        emit(state, m, src); return

    # ---- control flow ----
    if m == 'JMP':
        if mode == 'abs':
            emit(state, f"JMP {val}", src); return
        emit(state, f"; UNSUPPORTED JMP mode={mode}")
        state.warnings.append(f"line {lineno}: JMP mode {mode!r} not supported")
        return
    if m == 'JSR':
        emit(state, f"JSR {val}", src); return
    if m == 'RTS':
        emit(state, "RTS", src); return
    if m == 'RTI':
        emit(state, "RTI", src); return

    if m in ('BEQ','BNE','BCS','BCC','BMI','BPL'):
        # OCPU has native forward-only intra-page branches. for a 6502
        # forward branch we therefore emit a single ocpu branch and let
        # the assembler resolve the slot offset; for a 6502 backward
        # branch we have to synthesise inverted-condition skip + JMP
        # (which the auto-pager later turns into an inverted skip + a
        # FARJMP to the target's page if it has to cross pages).
        if val not in state.symbols and val in state.seenLabels:
            # target is a code label we've already passed in this stream
            # -> backward reference. emit the 3-line microcode form.
            invert = {'BEQ':'BNE','BNE':'BEQ','BCS':'BCC','BCC':'BCS',
                      'BMI':'BPL','BPL':'BMI'}[m]
            skipLabel = f"__br_skip_{state.brSkipCounter}"
            state.brSkipCounter += 1
            emit(state, f"{invert} {skipLabel}", src + "  (inverted)")
            emit(state, f"JMP {val}",             "(unconditional)")
            emitRaw(state, f"{skipLabel}:")
            return
        # forward (or external) branch: native ocpu branch is enough.
        emit(state, f"{m} {val}", src)
        return

    if m == 'BRK':
        emit(state, "HLT", src + "  (BRK -> HLT)"); return

    if m in ('ASL','LSR','ROL','ROR'):
        emit(state, f"; UNSUPPORTED {m}: shifts are dead code in current core")
        state.warnings.append(f"line {lineno}: {m} not implemented in core")
        return

    if m == 'BIT':
        if mode == 'abs':
            maybeSwitchDataPage(state, val)
            emit(state, "PHA",                  src + "  (microcode 1/3)")
            emit(state, f"AND {lowByte(val)}",  "(microcode 2/3, Z only)")
            emit(state, "PLA",                  "(microcode 3/3)")
            state.warnings.append(
                f"line {lineno}: BIT only sets Z (N/V not propagated)")
            return
        emit(state, f"; UNSUPPORTED BIT mode={mode}")
        state.warnings.append(f"line {lineno}: BIT mode {mode!r} not supported")
        return

    emit(state, f"; UNTRANSLATED: {mnem} {operand}")
    state.warnings.append(f"line {lineno}: unknown mnemonic {mnem!r}")


# -------------------------------------------------------------------------
# auto-pager - basic-block-aware page packing
# -------------------------------------------------------------------------
BRANCH_MNEMS = {'BEQ', 'BNE', 'BCS', 'BCC', 'BMI', 'BPL'}
BRANCH_INVERT = {'BEQ': 'BNE', 'BNE': 'BEQ',
                 'BCS': 'BCC', 'BCC': 'BCS',
                 'BMI': 'BPL', 'BPL': 'BMI'}


class _Atom:
    """one packable unit:
        kind = 'label'  : a label binding to the next instruction slot
        kind = 'instr'  : a single instruction line consuming 1 slot
        kind = 'branch' : a conditional branch; consumes 1 slot or 2 if
                          its target is determined to be on a different
                          page (in which case we emit an inverted branch
                          over a FARJMP).
        kind = 'jmp'    : an unconditional JMP; consumes 1 slot. if the
                          target is on a different page after placement
                          the emit step rewrites it to FARJMP.
        kind = 'jsr'    : an unconditional JSR; same-page only.
        kind = 'misc'   : passthrough line (comment / blank) - 0 slots.
    """
    __slots__ = ('kind', 'text', 'name', 'mnem', 'target', 'comment',
                 'slotCost')

    def __init__(self, kind, text='', name=None, mnem=None, target=None,
                 comment=''):
        self.kind     = kind
        self.text     = text
        self.name     = name
        self.mnem     = mnem
        self.target   = target
        self.comment  = comment
        self.slotCost = 0 if kind in ('label', 'misc') else 1


def _classifyAtoms(codeBuf: list[str]) -> list[_Atom]:
    """walk codeBuf and return a flat list of atoms. unrecognised lines
    are kept as 'misc' so they show up in the output verbatim."""
    atoms: list[_Atom] = []
    for line in codeBuf:
        raw = line
        stripped = line.strip()
        if not stripped or stripped.startswith(';'):
            atoms.append(_Atom('misc', text=raw))
            continue
        # label-only line
        if stripped.endswith(':') and ' ' not in stripped:
            atoms.append(_Atom('label', text=raw, name=stripped[:-1]))
            continue
        # parse mnemonic / operand / inline comment
        body, _, comment = stripped.partition(';')
        body = body.strip()
        parts = body.split(None, 1)
        if not parts:
            atoms.append(_Atom('misc', text=raw))
            continue
        mnem = parts[0].upper()
        operand = parts[1].strip() if len(parts) > 1 else ''
        # branch target?
        if mnem in BRANCH_MNEMS:
            atoms.append(_Atom('branch', text=raw, mnem=mnem,
                               target=operand, comment=comment))
        elif mnem == 'JMP':
            atoms.append(_Atom('jmp', text=raw, mnem=mnem,
                               target=operand, comment=comment))
        elif mnem == 'JSR':
            atoms.append(_Atom('jsr', text=raw, mnem=mnem,
                               target=operand, comment=comment))
        else:
            atoms.append(_Atom('instr', text=raw, mnem=mnem,
                               comment=comment))
    return atoms


def _cleanTarget(t: str) -> str:
    if not t: return ''
    return t.split(';')[0].split()[0].strip()


def autoPageBlocks(codeBuf: list[str], warnings: list[str]) -> list[str]:
    """slot-by-slot packer.

    rules:
      * the cpu naturally wraps from the last slot to slot 0 of the next
        page (via `page_interrupt`), so straight-line code spilling across
        pages does NOT require any explicit FARJMP. we only insert
        `.page N+1` directives at page boundaries.
      * conditional branches (`BR* target`) are *intra-page only*: their
        encoded offset is a SLOT_BITS-wide value added to pc within the
        same page. so before emitting a branch we look ahead to count
        slots until the target label; if it doesn't fit in the remaining
        slots of the current page, we expand the branch into a 2-slot
        sequence `<inverted-br> __local; FARJMP <target_page>;
        __local:`.  the 2-slot expansion forces the target page to be
        loaded fresh, so the target lands at slot 0 (which is exactly
        where FARJMP delivers control).
      * `JMP target` (unconditional) gets rewritten to `FARJMP <page>`
        when the target ends up on a different page.
      * `JSR target` cross-page is rejected - the cpu only saves the
        slot index (SLOT_BITS wide) on call, so a cross-page rts cannot
        reconstruct the right page.

    label-target invariant: any label that is the target of a cross-page
    branch / jmp must land at slot 0 of its page. we guarantee this by
    padding the current page with NOPs and starting a new page
    immediately before such a label."""
    atoms = _classifyAtoms(codeBuf)
    # forward-lookup: label name -> atom index
    labelAtomIdx: dict[str, int] = {
        a.name: i for i, a in enumerate(atoms) if a.kind == 'label'
    }
    # set of labels that need to be aligned to slot 0 of their page
    # (populated when we expand a branch into a 2-slot bridge)
    forceSlot0: set[str] = set()

    # pass 1: walk atoms, emitting (page, slot, line, atom). loops only
    # restart from scratch when a new constraint is added that may
    # invalidate earlier placements. retry budget (8) is independent of
    # page geometry.
    for tryIdx in range(8):
        out_entries: list[tuple[int, int, str, _Atom | None]] = []
        labelPlace: dict[str, tuple[int, int]] = {}
        page = 0
        slot = 0
        addedConstraint = False

        def addLine(text: str, atom: _Atom | None = None,
                    consumesSlot: bool = False):
            nonlocal page, slot
            out_entries.append((page, slot if consumesSlot else -1,
                                text, atom))
            if consumesSlot:
                slot += 1
                if slot == SLOTS_PER_PAGE:
                    page += 1
                    slot = 0

        def padPageWithNops(reason: str):
            nonlocal page, slot
            while slot < SLOTS_PER_PAGE:
                out_entries.append((page, slot,
                                    f"    NOP        ; {reason}", None))
                slot += 1
            page += 1
            slot = 0

        def slotsAhead(startIdx: int, endIdx: int) -> int:
            return sum(atoms[j].slotCost for j in range(startIdx, endIdx))

        for i, a in enumerate(atoms):
            if a.kind == 'misc':
                addLine(a.text)
                continue

            if a.kind == 'label':
                # force-align if a cross-page jumper targets this label
                if a.name in forceSlot0 and slot != 0:
                    padPageWithNops("align next label to slot 0")
                labelPlace[a.name] = (page, slot)
                addLine(a.text)
                continue

            if a.kind == 'branch':
                tgt = _cleanTarget(a.target)
                tgtIdx = labelAtomIdx.get(tgt)
                feasible = False
                if (tgtIdx is not None and tgtIdx > i
                        and tgt not in forceSlot0):
                    # forward branch and target hasn't already been
                    # pulled to slot 0 of a fresh page by an earlier
                    # bridge. count slot cost between branch and target;
                    # after the branch sits at `slot`, target must
                    # occupy a slot index <= 7. if the target is in
                    # forceSlot0, the packer pads the current page with
                    # NOPs so the target lands at slot 0 of a new page,
                    # which means a native intra-page branch from the
                    # current page can never reach it.
                    ahead = slotsAhead(i + 1, tgtIdx)
                    if slot + 1 + ahead <= SLOTS_PER_PAGE - 1:
                        feasible = True
                if feasible:
                    addLine(a.text, atom=a, consumesSlot=True)
                    continue
                # cross-page or backward branch: emit 2-slot bridge.
                # this needs the target to be at slot 0 of its page.
                if tgt not in forceSlot0:
                    forceSlot0.add(tgt)
                    addedConstraint = True
                # bridge needs the local skip label to live in the same
                # page as the inverted branch. layout is:
                #   slot K   : <inv-br> __brfix
                #   slot K+1 : FARJMP <tgt_page>
                #   slot K+2 : __brfix:  (the next real instruction)
                # so K+1 must be < SLOTS_PER_PAGE-1 (else __brfix would
                # wrap to page K+1 and the inverted branch becomes
                # cross-page).
                if slot + 2 > SLOTS_PER_PAGE - 1:
                    padPageWithNops("no room for branch bridge")
                inv = BRANCH_INVERT[a.mnem]
                skipLbl = f"__brfix_{i:x}"
                cmt = f"; (auto-inverted, cross-page {a.mnem} -> {tgt})"
                addLine(f"    {inv} {skipLbl}     {cmt}",
                        atom=a, consumesSlot=True)
                # placeholder; resolved in pass 2 once we know the page
                addLine(f"    __FARJMP_TO_{tgt}__        ; (auto-bridge)",
                        atom=None, consumesSlot=True)
                # local skip label (no slot cost)
                addLine(f"{skipLbl}:", atom=None, consumesSlot=False)
                # record this label as a runtime-only intra-page anchor
                labelPlace[skipLbl] = (page, slot)
                continue

            if a.kind == 'jmp':
                tgt = _cleanTarget(a.target)
                # if target is known to be cross-page (forceSlot0 set),
                # rewrite directly to FARJMP; cheaper than letting the
                # placeholder resolver do it.
                if slot == SLOTS_PER_PAGE:  # safety; should not happen
                    page += 1; slot = 0
                addLine(a.text, atom=a, consumesSlot=True)
                continue

            if a.kind == 'jsr':
                if slot == SLOTS_PER_PAGE:  # safety
                    page += 1; slot = 0
                addLine(a.text, atom=a, consumesSlot=True)
                continue

            # plain instruction
            if slot == SLOTS_PER_PAGE:
                page += 1; slot = 0
            addLine(a.text, atom=a, consumesSlot=True)

        # after this trial layout, look for cross-page JMPs whose target
        # is not yet at slot 0 of its page; mark them for forceSlot0 so
        # the next trial pads the source page and pulls the target to a
        # fresh page.
        for (entryPage, _, text, atom) in out_entries:
            if atom is None or atom.kind != 'jmp':
                continue
            tgt = _cleanTarget(atom.target)
            tp = labelPlace.get(tgt)
            if tp is not None and tp[0] != entryPage and tp[1] != 0:
                if tgt not in forceSlot0:
                    forceSlot0.add(tgt)
                    addedConstraint = True

        if not addedConstraint:
            break
    else:
        warnings.append("autoPageBlocks: layout did not converge after "
                        "8 iterations; some branches may still be "
                        "cross-page")

    # pass 2: walk out_entries, emit text. compute the current page from
    # the entry tuple so we can resolve cross-page JMP / JSR / placeholder
    # bridges.
    final: list[str] = []
    lastPage = -1
    for (entryPage, _, text, atom) in out_entries:
        if entryPage != lastPage:
            if lastPage >= 0:
                final.append("")
            final.append(f".page {entryPage}")
            lastPage = entryPage

        # resolve cross-page bridge placeholders inserted by branch expansion
        if '__FARJMP_TO_' in text:
            m = re.search(r'__FARJMP_TO_([A-Za-z_@][A-Za-z0-9_@]*)__', text)
            if m:
                tname = m.group(1)
                tp = labelPlace.get(tname)
                if tp is None:
                    warnings.append(
                        f"branch bridge: unknown target {tname!r}")
                    text = text.replace(
                        f"__FARJMP_TO_{tname}__",
                        f"; UNSUPPORTED bridge to unknown label {tname}")
                else:
                    if tp[1] != 0:
                        warnings.append(
                            f"branch bridge: target {tname} at slot "
                            f"{tp[1]} but FARJMP lands at slot 0; "
                            f"layout bug.")
                    text = text.replace(
                        f"__FARJMP_TO_{tname}__",
                        f"FARJMP ${tp[0]:02x}")
            final.append(text)
            continue

        if atom is not None and atom.kind == 'jmp':
            tgt = _cleanTarget(atom.target)
            tp = labelPlace.get(tgt)
            if tp is not None and tp[0] != entryPage:
                if tp[1] != 0:
                    warnings.append(
                        f"JMP {tgt}: target at page {tp[0]} slot {tp[1]} "
                        f"but FARJMP lands at slot 0; layout bug.")
                final.append(
                    f"    FARJMP ${tp[0]:02x}        "
                    f"; (rewritten from JMP {tgt}; cross-page)")
                continue

        if atom is not None and atom.kind == 'jsr':
            tgt = _cleanTarget(atom.target)
            tp = labelPlace.get(tgt)
            if tp is not None and tp[0] != entryPage:
                warnings.append(
                    f"JSR {tgt}: caller on page {entryPage}, target on "
                    f"page {tp[0]}. cpu only stacks the slot index, so "
                    f"cross-page RTS is unsafe. rejecting.")
                final.append(
                    f"    ; UNSUPPORTED cross-page JSR {tgt}")
                continue

        final.append(text)

    # also mark labels referenced by JMP cross-page as needing slot-0
    # alignment in subsequent runs (catch case where JMP target was
    # mid-page in pass 1). do a quick sanity pass: if any JMP rewrite
    # would point at a slot != 0, surface a warning so the user can
    # see what failed.
    return final


# -------------------------------------------------------------------------
# pass 2 driver
# -------------------------------------------------------------------------
def pass2Codegen(text: str, state: TranslateState, mainEntry: bool = False) -> None:
    """walk the source. data emissions go into a separate buffer that is
    prepended in front of the code stream - the ocpu assembler forbids
    `.byte` after the first `.page`, so all dram seeding must happen
    first."""
    segment = 'CODE'
    dataCursor = dict(state.layout)
    dataCursor['CODE'] = 0
    needDataHeader = True

    dataBuf: list[str] = []
    codeBuf: list[str] = []

    def putData(line: str):  dataBuf.append(line)
    # we temporarily redirect `state.output` to whichever buffer we want
    state.output = codeBuf  # default: code

    for lineno, raw in enumerate(text.splitlines(), start=1):
        bare = raw.split(';', 1)[0].rstrip()
        if not bare.strip():
            continue
        m = LABEL_RE.match(bare.lstrip())
        if m:
            label, rest = m.group(1), m.group(2).strip()
            if segment == 'CODE':
                codeBuf.append(f"{label}:")
                state.seenLabels.add(label)
            if not rest:
                continue
            bare = rest

        stripped = bare.lstrip()

        if stripped.startswith('.'):
            tokens = stripped.split(None, 1)
            dirc = tokens[0].lower()
            args = tokens[1] if len(tokens) > 1 else ''

            if dirc == '.segment':
                seg = args.strip().strip('"').upper()
                segment = seg
                if seg not in dataCursor:
                    dataCursor[seg] = state.layout.get(seg, 0x0200)
                needDataHeader = True
                continue

            if segment != 'CODE' and dirc in ('.byte', '.word', '.ascii', '.res'):
                if needDataHeader:
                    putData(f"    .data ${dataCursor[segment]:04x}"
                            f"            ; segment {segment}")
                    needDataHeader = False
                if dirc == '.byte':
                    parts = [a.strip() for a in args.split(',') if a.strip()]
                    putData("    .byte " + ", ".join(parts))
                    dataCursor[segment] += len(parts)
                elif dirc == '.word':
                    parts = [a.strip() for a in args.split(',') if a.strip()]
                    putData("    .word " + ", ".join(parts))
                    dataCursor[segment] += 2 * len(parts)
                elif dirc == '.ascii':
                    putData("    .ascii " + args)
                    m2 = re.search(r'"(.*)"', args)
                    if m2:
                        dataCursor[segment] += len(bytes(m2.group(1),
                                                  'utf-8').decode('unicode_escape'))
                elif dirc == '.res':
                    parts = [a.strip() for a in args.split(',')]
                    n = parseNumber(parts[0])
                    fill = parseNumber(parts[1]) if len(parts) > 1 else 0
                    putData("    .byte " + ", ".join([f"${fill:02x}"]*n))
                    dataCursor[segment] += n
                continue

            if dirc in ('.fopt', '.setcpu', '.smart', '.autoimport',
                        '.case', '.debuginfo', '.importzp', '.export',
                        '.forceimport', '.macpack', '.import',
                        '.exportzp', '.proc', '.endproc'):
                if dirc == '.proc':
                    m2 = re.match(r'([A-Za-z_@][A-Za-z0-9_@]*)', args)
                    if m2 and segment == 'CODE':
                        codeBuf.append(f"{m2.group(1)}:")
                        state.seenLabels.add(m2.group(1))
                continue

            codeBuf.append(f"    ; (passed-through {dirc} {args})")
            continue

        if segment != 'CODE':
            continue

        m2 = LINE_RE.match(stripped)
        if not m2:
            state.warnings.append(f"line {lineno}: could not parse: {raw!r}")
            continue
        translateInstruction(state, m2.group(1), m2.group(2), lineno)

    # cc65 entry-compat: JSR/RTS only saves the slot index (not the page),
    # so a JSR wrapper would break the moment _main spans pages. instead
    # we walk codeBuf in reverse and rewrite the LAST emitted `RTS` line
    # into `HLT`. control flows linearly through page 0..N and halts at
    # the natural end of _main.
    if mainEntry:
        for i in range(len(codeBuf) - 1, -1, -1):
            line = codeBuf[i]
            stripped = line.lstrip()
            if stripped.startswith('RTS'):
                # preserve original comment so the trace remains readable
                comment = ''
                if ';' in line:
                    comment = '; ' + line.split(';', 1)[1].strip() + ' (rewritten -> HLT)'
                codeBuf[i] = ("    HLT                     " + comment).rstrip()
                break

    # post-process: pack basic blocks into pages so we never split a
    # branch from its target label. relies on the cpu's natural slot-7
    # page wrap (page_interrupt) for sequential fall-through, so we do
    # NOT emit FARJMP instructions for plain straight-line page breaks.
    # cross-page JMP gets rewritten to FARJMP (legal because basic
    # blocks always start at slot 0 of a fresh page). cross-page
    # conditional branches are rewritten as `<inverted-br> __local;
    # FARJMP <target_page>` and re-packed (so the 2-slot expansion is
    # accounted for during placement). cross-page JSR is rejected - our
    # cpu only saves the slot index on call, so a cross-page return is
    # structurally impossible without a software-managed return page.
    pagedBuf = autoPageBlocks(codeBuf, state.warnings)

    header = [
        "; auto-generated by translate_6502.py",
        "; full pipeline: cc65 -> translate_6502 -> ocpu_asm",
    ]
    final = header + dataBuf + [''] + pagedBuf
    state.output = final


# -------------------------------------------------------------------------
# main entry
# -------------------------------------------------------------------------
def translateFile(source: str | Path,
                  layout: dict[str, int] | None = None,
                  mainEntry: bool = False) -> tuple[str, list[str]]:
    """if `mainEntry` is True, prepend `JSR _main / HLT` to page 0 so the
    cc65 calling convention (where _main returns into startup code that
    calls exit) is honoured by halting the cpu after _main rts'es. this
    makes a cc65-built C program self-contained for standalone runs."""
    text = Path(source).read_text(encoding='utf-8')
    state = TranslateState(layout=dict(layout) if layout else dict(DEFAULT_LAYOUT))
    state.symbols = pass1Layout(text, state.layout)
    pass2Codegen(text, state, mainEntry=mainEntry)
    return ('\n'.join(state.output) + '\n', state.warnings)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="cc65 6502 -> ocpu translator")
    p.add_argument('source', help="input .s file (ca65 syntax)")
    p.add_argument('-o', '--output', default=None,
                   help="output .s (ocpu syntax); default <source>.ocpu.s")
    p.add_argument('--data-base',    type=lambda s: int(s, 0),
                   default=DEFAULT_LAYOUT['DATA'])
    p.add_argument('--bss-base',     type=lambda s: int(s, 0),
                   default=DEFAULT_LAYOUT['BSS'])
    p.add_argument('--rodata-base',  type=lambda s: int(s, 0),
                   default=DEFAULT_LAYOUT['RODATA'])
    p.add_argument('--zeropage-base',type=lambda s: int(s, 0),
                   default=DEFAULT_LAYOUT['ZEROPAGE'])
    p.add_argument('--main-entry', action='store_true',
                   help="wrap _main with JSR/HLT so a cc65 program can run "
                        "standalone (otherwise the trailing rts pops "
                        "uninitialised stack and crashes)")
    args = p.parse_args(argv)

    layout = {
        'DATA':     args.data_base,
        'BSS':      args.bss_base,
        'RODATA':   args.rodata_base,
        'ZEROPAGE': args.zeropage_base,
    }
    text, warnings = translateFile(args.source, layout=layout,
                                   mainEntry=args.main_entry)
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
