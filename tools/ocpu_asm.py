"""
ocpu_asm.py
two-pass assembler for the tt26-ocpu custom isa.

instruction word layout (matches src/ocpu_core.v):
    [15:12] = op (4 bits)
    [11:8]  = sub (4 bits)
    [7:0]   = imm (8 bits)

programs are organised as SLOTS_PER_PAGE-instruction pages (currently 4).
the cpu fetches each page into the iram, runs slots 0..SLOTS_PER_PAGE-1,
and pulses page_interrupt after the last slot so the test FPGA model can
load the next page.

assembler features:
    * intra-page labels resolved as imm[SLOT_BITS-1:0] (slot 0..N-1) for JMP / JSR
    * BR* labels resolved as a SLOT_BITS-bit forward slot offset (current-slot-
      relative, because the cpu evaluates `pc <= pc + ir_imm[SLOT_BITS-1:0]`
      for taken branches and we choose to support forward-only on the
      assembler side)
    * cross-page labels handled by FARJMP (page index lives in imm[7:0]) but
      no automatic emit; emit FARJMP explicitly when crossing pages
    * .page <n> directive aligns the assembler to page n, padding the previous
      page with NOPs as needed
    * .org <slot> directive aligns within the current page (padding with NOPs)
    * .ascii / .byte / .word directives for data placement when used inside
      data pages (read by LDA abs through the data memory bus)
    * # prefix denotes an immediate; $ denotes hex; default base is decimal

mnemonic mapping (op, sub, imm meaning):
    LDA #imm        op=0x0 sub=0x0 imm=value
    LDA <addr>      op=0x0 sub=0x1 imm=addr_low                       (abs)
    LDA <addr>,X    op=0x0 sub=0x2 imm=addr_low                       (abs+X)
    LDA (<addr>),Y  op=0x0 sub=0x3 imm=addr_low                       ((zp),Y)
    STA <addr>      op=0x1 sub=0x0 imm=addr_low                       (abs)
    STA <addr>,X    op=0x1 sub=0x1 imm=addr_low                       (abs+X)
    STA (<addr>),Y  op=0x1 sub=0x2 imm=addr_low                       ((zp),Y)
    LDX #imm        op=0x2 sub=0x0 imm=value
    LDX <addr>      op=0x2 sub=0x1 imm=addr_low
    LDY #imm        op=0x3 sub=0x0 imm=value
    LDY <addr>      op=0x3 sub=0x1 imm=addr_low
    STX <addr>      op=0x4 sub=0x0 imm=addr_low
    STY <addr>      op=0x5 sub=0x0 imm=addr_low

    ALU memory ops (op=0x6, operand fetched from {data_page, imm}):
      ADD <addr>   sub=0x0       ADC <addr>   sub=0x1
      SUB <addr>   sub=0x2       SBC <addr>   sub=0x3
      AND <addr>   sub=0x4       ORA <addr>   sub=0x5
      EOR <addr>   sub=0x6       CMP <addr>   sub=0x7

    ALU immediate ops (op=0x6, sub[3]=1, operand = imm):
      ADD #imm     sub=0x8       ADC #imm     sub=0x9
      SUB #imm     sub=0xA       SBC #imm     sub=0xB
      AND #imm     sub=0xC       ORA #imm     sub=0xD
      EOR #imm     sub=0xE       CMP #imm     sub=0xF

    branches (op=0x7, imm low SLOT_BITS bits = forward slot offset within page):
      BEQ sub=0x0  BNE sub=0x1  BCS sub=0x2  BCC sub=0x3
      BMI sub=0x4  BPL sub=0x5

    control flow:
      JMP <slot>     op=0x8 sub=0 imm[SLOT_BITS-1:0]=target slot
      JSR <slot>     op=0x9 sub=0 imm[SLOT_BITS-1:0]=target slot
      RTS            op=0xA
      FARJMP <page>  op=0xB sub=0 imm=target page  (relative=0, abs=8 in sub)

    register ops (op=0xC, sub selects operation):
      TAX 0  TXA 1  TAY 2  TYA 3
      INX 4  DEX 5  INY 6  DEY 7
      PHA 8  PLA 9  TSX A  TXS B
      NOP F

    page/sp ops (op=0xD):
      LDA_DP sub=0  STA_DP sub=1  LDA_PG sub=2  LDSP #imm sub=3  STSP sub=4

    self-modify iram (op=0xE):
      SMOD <slot>    sub[SLOT_BITS-1:0]=slot  imm=value to patch into iram[slot][7:0]

    system (op=0xF, sub selects):
      HLT 0  SEI 1  CLI 2  SEC 3  CLC 4  CLV 5  RTI 6

note: ASL/LSR are listed in info.md but the current core decode never enters
those paths (the if-tree in ST_DECODE never reaches them) so they are NOT
exposed by this assembler. if you want them, fix ocpu_core.v first.
"""

from __future__ import annotations
import re
import sys
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

# -------------------------------------------------------------------------
# page geometry. must match SLOT_BITS in src/iram_regfile.v / src/ocpu_core.v.
# -------------------------------------------------------------------------
SLOT_BITS      = 2
SLOTS_PER_PAGE = 1 << SLOT_BITS  # 4
SLOT_MASK      = SLOTS_PER_PAGE - 1  # 0x3
# largest legal forward intra-page branch offset. the cpu does
#   pc_after = pc_taken + offset
# where pc_taken == ins.slot + 1 (already wrapped mod SLOTS_PER_PAGE in
# ST_FETCH). we require target slot > ins.slot and target slot <=
# SLOTS_PER_PAGE-1, which yields offsets in 0..SLOTS_PER_PAGE-2.
MAX_BRANCH_OFFSET = SLOTS_PER_PAGE - 2  # 2

# -------------------------------------------------------------------------
# opcode tables
# -------------------------------------------------------------------------
OP_LDA, OP_STA, OP_LDX, OP_LDY = 0x0, 0x1, 0x2, 0x3
OP_STX, OP_STY, OP_ALU, OP_BR = 0x4, 0x5, 0x6, 0x7
OP_JMP, OP_JSR, OP_RTS, OP_FARJMP = 0x8, 0x9, 0xA, 0xB
OP_REG, OP_LDSP, OP_SMOD, OP_SYS = 0xC, 0xD, 0xE, 0xF

REG_SUB = {
    'TAX': 0x0, 'TXA': 0x1, 'TAY': 0x2, 'TYA': 0x3,
    'INX': 0x4, 'DEX': 0x5, 'INY': 0x6, 'DEY': 0x7,
    'PHA': 0x8, 'PLA': 0x9, 'TSX': 0xA, 'TXS': 0xB,
    'NOP': 0xF,
}

SYS_SUB = {
    'HLT': 0x0, 'SEI': 0x1, 'CLI': 0x2, 'SEC': 0x3,
    'CLC': 0x4, 'CLV': 0x5, 'RTI': 0x6,
}

BR_SUB = {
    'BEQ': 0x0, 'BNE': 0x1, 'BCS': 0x2, 'BCC': 0x3,
    'BMI': 0x4, 'BPL': 0x5,
}

ALU_MEM_SUB = {
    'ADD': 0x0, 'ADC': 0x1, 'SUB': 0x2, 'SBC': 0x3,
    'AND': 0x4, 'ORA': 0x5, 'EOR': 0x6, 'CMP': 0x7,
}

ALU_IMM_SUB = {
    'ADD': 0x8, 'ADC': 0x9, 'SUB': 0xA, 'SBC': 0xB,
    'AND': 0xC, 'ORA': 0xD, 'EOR': 0xE, 'CMP': 0xF,
}

LDSP_SUB = {
    'LDA_DP': 0x0, 'STA_DP': 0x1, 'LDA_PG': 0x2,
    'LDSP': 0x3, 'STSP': 0x4,
}


# -------------------------------------------------------------------------
# intermediate representation
# -------------------------------------------------------------------------
@dataclass
class Instr:
    """One assembled instruction slot. Either a fully resolved word or a
    pending-symbol reference that the second pass will patch."""
    page: int
    slot: int
    word: int = 0
    pending_label: Optional[str] = None
    pending_kind: Optional[str] = None  # 'jmp', 'jsr', 'branch', 'farjmp'
    source_line: int = 0
    source_text: str = ""


@dataclass
class Symbol:
    page: int
    slot: int


class AsmError(Exception):
    pass


# -------------------------------------------------------------------------
# helpers
# -------------------------------------------------------------------------
def parseNumber(token: str) -> int:
    """parse a numeric token. accepts decimal, $hex, 0xhex, %binary."""
    t = token.strip().lstrip('#')
    if t.startswith('$'):
        return int(t[1:], 16)
    if t.startswith('0x') or t.startswith('0X'):
        return int(t[2:], 16)
    if t.startswith('%'):
        return int(t[1:], 2)
    return int(t, 10)


def encodeWord(op: int, sub: int, imm: int) -> int:
    if not (0 <= op <= 0xF):
        raise AsmError(f"op {op} out of range")
    if not (0 <= sub <= 0xF):
        raise AsmError(f"sub {sub} out of range")
    imm &= 0xFF
    return ((op & 0xF) << 12) | ((sub & 0xF) << 8) | imm


# encode NOP via OP_REG / REG_NOP so the bit pattern is well-defined
NOP_WORD = encodeWord(OP_REG, REG_SUB['NOP'], 0)


# -------------------------------------------------------------------------
# main assembler
# -------------------------------------------------------------------------
class Assembler:
    def __init__(self):
        self.slots: list[Instr] = []
        self.symbols: dict[str, Symbol] = {}
        self.curPage = 0
        self.curSlot = 0
        # data memory initial image: 16-bit addr -> byte
        self.dataImage: dict[int, int] = {}
        # cursor for data directives when assembling into a data page
        self.dataCursor: Optional[int] = None
        self.inDataSection = False

    # ----- emit helpers -----
    def emit(self, word: int, lineno: int, text: str,
             pending_label: Optional[str] = None,
             pending_kind: Optional[str] = None) -> None:
        if self.inDataSection:
            raise AsmError(f"line {lineno}: instruction inside data section: {text}")
        if self.curSlot >= SLOTS_PER_PAGE:
            raise AsmError(
                f"line {lineno}: page {self.curPage} overflow at slot "
                f"{self.curSlot}; pages are exactly {SLOTS_PER_PAGE} slots "
                f"wide. use .page or FARJMP to move into the next page."
            )
        self.slots.append(Instr(
            page=self.curPage, slot=self.curSlot,
            word=word, pending_label=pending_label,
            pending_kind=pending_kind,
            source_line=lineno, source_text=text,
        ))
        self.curSlot += 1

    def padPageWithNops(self):
        while self.curSlot < SLOTS_PER_PAGE:
            self.slots.append(Instr(
                page=self.curPage, slot=self.curSlot,
                word=NOP_WORD,
                source_line=0, source_text='(auto-NOP padding)',
            ))
            self.curSlot += 1

    # ----- directives -----
    def directivePage(self, args: list[str], lineno: int):
        if len(args) != 1:
            raise AsmError(f"line {lineno}: .page expects exactly one argument")
        nextPage = parseNumber(args[0])
        if nextPage < self.curPage or (nextPage == self.curPage and self.curSlot != 0):
            raise AsmError(
                f"line {lineno}: .page {nextPage} would move backwards "
                f"(currently page {self.curPage} slot {self.curSlot})"
            )
        # pad the in-flight page with NOPs to align next page on a slot-0 boundary
        if self.curSlot != 0:
            self.padPageWithNops()
            self.curPage += 1
            self.curSlot = 0
        # if there is a gap between pages, fill with NOP-only pages
        while self.curPage < nextPage:
            self.padPageWithNops()
            self.curPage += 1
            self.curSlot = 0
        self.inDataSection = False

    def directiveOrg(self, args: list[str], lineno: int):
        if len(args) != 1:
            raise AsmError(f"line {lineno}: .org expects exactly one argument")
        slot = parseNumber(args[0])
        if not (0 <= slot < SLOTS_PER_PAGE):
            raise AsmError(
                f"line {lineno}: .org slot must be 0..{SLOTS_PER_PAGE - 1}")
        if slot < self.curSlot:
            raise AsmError(f"line {lineno}: .org would move backwards")
        while self.curSlot < slot:
            self.slots.append(Instr(
                page=self.curPage, slot=self.curSlot,
                word=NOP_WORD,
                source_line=lineno, source_text='(auto-NOP from .org)',
            ))
            self.curSlot += 1

    def directiveData(self, args: list[str], lineno: int):
        # .data <addr>  switches into "data" mode that fills self.dataImage
        # subsequent .byte / .word / .ascii pile bytes into dram from <addr>.
        if len(args) != 1:
            raise AsmError(f"line {lineno}: .data expects an address")
        self.dataCursor = parseNumber(args[0]) & 0xFFFF
        self.inDataSection = True

    def directiveByte(self, args: list[str], lineno: int):
        if not self.inDataSection or self.dataCursor is None:
            raise AsmError(f"line {lineno}: .byte requires a preceding .data")
        for a in args:
            self.dataImage[self.dataCursor] = parseNumber(a) & 0xFF
            self.dataCursor = (self.dataCursor + 1) & 0xFFFF

    def directiveWord(self, args: list[str], lineno: int):
        # .word always emits low byte then high byte (little-endian) so the
        # (zp),Y addressing in OCPU finds the pointer the same way the 6502
        # does (low byte at zp, high byte at zp+1).
        if not self.inDataSection or self.dataCursor is None:
            raise AsmError(f"line {lineno}: .word requires a preceding .data")
        for a in args:
            v = parseNumber(a) & 0xFFFF
            self.dataImage[self.dataCursor] = v & 0xFF
            self.dataImage[(self.dataCursor + 1) & 0xFFFF] = (v >> 8) & 0xFF
            self.dataCursor = (self.dataCursor + 2) & 0xFFFF

    def directiveAscii(self, raw: str, lineno: int):
        if not self.inDataSection or self.dataCursor is None:
            raise AsmError(f"line {lineno}: .ascii requires a preceding .data")
        # strip the outer quotes only
        m = re.match(r'\s*"(.*)"\s*$', raw)
        if not m:
            raise AsmError(f'line {lineno}: .ascii needs a "quoted string"')
        text = bytes(m.group(1), 'utf-8').decode('unicode_escape')
        for c in text:
            self.dataImage[self.dataCursor] = ord(c) & 0xFF
            self.dataCursor = (self.dataCursor + 1) & 0xFFFF

    # ----- mnemonic decoding -----
    def assembleInstruction(self, mnemonic: str, operand: str, lineno: int, raw: str):
        m = mnemonic.upper()
        op = operand.strip()

        # --- LDA / STA family with addressing modes ---
        if m in ('LDA',):
            sub, imm, pending = self._decodeLoad(op, lineno, indyAllowed=True)
            self.emit(encodeWord(OP_LDA, sub, imm), lineno, raw, pending, 'imm')
            return
        if m == 'STA':
            sub, imm, pending = self._decodeStore(op, lineno, indyAllowed=True)
            self.emit(encodeWord(OP_STA, sub, imm), lineno, raw, pending, 'imm')
            return
        if m == 'LDX':
            sub, imm, pending = self._decodeLoad(op, lineno, indyAllowed=False, indexedAllowed=False)
            self.emit(encodeWord(OP_LDX, sub, imm), lineno, raw, pending, 'imm')
            return
        if m == 'LDY':
            sub, imm, pending = self._decodeLoad(op, lineno, indyAllowed=False, indexedAllowed=False)
            self.emit(encodeWord(OP_LDY, sub, imm), lineno, raw, pending, 'imm')
            return
        if m == 'STX':
            sub, imm, pending = self._decodeStore(op, lineno, indyAllowed=False, indexedAllowed=False)
            self.emit(encodeWord(OP_STX, sub, imm), lineno, raw, pending, 'imm')
            return
        if m == 'STY':
            sub, imm, pending = self._decodeStore(op, lineno, indyAllowed=False, indexedAllowed=False)
            self.emit(encodeWord(OP_STY, sub, imm), lineno, raw, pending, 'imm')
            return

        # --- ALU memory + immediate ---
        if m in ALU_MEM_SUB:
            if op.startswith('#'):
                sub = ALU_IMM_SUB[m]
                imm = parseNumber(op) & 0xFF
            else:
                sub = ALU_MEM_SUB[m]
                imm = parseNumber(op) & 0xFF
            self.emit(encodeWord(OP_ALU, sub, imm), lineno, raw)
            return

        # --- branches: imm low 3 bits = forward target slot ---
        if m in BR_SUB:
            sub = BR_SUB[m]
            if not op:
                raise AsmError(f"line {lineno}: {m} needs a target")
            # forward-only intra-page branch to a label
            self.emit(encodeWord(OP_BR, sub, 0), lineno, raw,
                      pending_label=op, pending_kind='branch')
            return

        # --- control flow ---
        if m == 'JMP':
            self.emit(encodeWord(OP_JMP, 0, 0), lineno, raw,
                      pending_label=op, pending_kind='jmp')
            return
        if m == 'JSR':
            self.emit(encodeWord(OP_JSR, 0, 0), lineno, raw,
                      pending_label=op, pending_kind='jsr')
            return
        if m == 'RTS':
            self.emit(encodeWord(OP_RTS, 0, 0), lineno, raw)
            return
        if m == 'FARJMP':
            # FARJMP <page-label-or-num>; sub[3]=0 (relative) for now, imm=page
            if not op:
                raise AsmError(f"line {lineno}: FARJMP needs a target page")
            try:
                page = parseNumber(op) & 0xFF
                self.emit(encodeWord(OP_FARJMP, 0, page), lineno, raw)
            except ValueError:
                self.emit(encodeWord(OP_FARJMP, 0, 0), lineno, raw,
                          pending_label=op, pending_kind='farjmp')
            return

        # --- register ops ---
        if m in REG_SUB:
            self.emit(encodeWord(OP_REG, REG_SUB[m], 0), lineno, raw)
            return

        # --- system ops ---
        if m in SYS_SUB:
            self.emit(encodeWord(OP_SYS, SYS_SUB[m], 0), lineno, raw)
            return

        # --- ldsp / page-reg ops ---
        if m == 'LDA_DP':
            self.emit(encodeWord(OP_LDSP, LDSP_SUB['LDA_DP'], 0), lineno, raw); return
        if m == 'STA_DP':
            self.emit(encodeWord(OP_LDSP, LDSP_SUB['STA_DP'], 0), lineno, raw); return
        if m == 'LDA_PG':
            self.emit(encodeWord(OP_LDSP, LDSP_SUB['LDA_PG'], 0), lineno, raw); return
        if m == 'LDSP':
            if not op.startswith('#'):
                raise AsmError(f"line {lineno}: LDSP requires #imm operand")
            self.emit(encodeWord(OP_LDSP, LDSP_SUB['LDSP'], parseNumber(op) & 0xFF),
                      lineno, raw); return
        if m == 'STSP':
            self.emit(encodeWord(OP_LDSP, LDSP_SUB['STSP'], 0), lineno, raw); return

        # --- SMOD slot, value ---
        if m == 'SMOD':
            parts = [p.strip() for p in op.split(',')]
            if len(parts) != 2:
                raise AsmError(f"line {lineno}: SMOD expects 'slot, value'")
            slot = parseNumber(parts[0]) & SLOT_MASK
            val = parseNumber(parts[1]) & 0xFF
            self.emit(encodeWord(OP_SMOD, slot, val), lineno, raw); return

        raise AsmError(f"line {lineno}: unknown mnemonic {m!r}")

    def _decodeLoad(self, op: str, lineno: int, indyAllowed: bool,
                    indexedAllowed: bool = True) -> tuple[int, int, Optional[str]]:
        op = op.strip()
        if not op:
            raise AsmError(f"line {lineno}: load requires an operand")
        # #imm immediate
        if op.startswith('#'):
            return (0x0, parseNumber(op) & 0xFF, None)
        # (zp),Y indirect-Y
        m = re.match(r'\(([^)]+)\)\s*,\s*[Yy]\s*$', op)
        if m:
            if not indyAllowed:
                raise AsmError(f"line {lineno}: (zp),Y not supported for this op")
            return (0x3, parseNumber(m.group(1)) & 0xFF, None)
        # abs,X
        m = re.match(r'(.+?)\s*,\s*[Xx]\s*$', op)
        if m:
            if not indexedAllowed:
                raise AsmError(f"line {lineno}: abs,X not supported for this op")
            return (0x2, parseNumber(m.group(1)) & 0xFF, None)
        # plain abs
        return (0x1, parseNumber(op) & 0xFF, None)

    def _decodeStore(self, op: str, lineno: int, indyAllowed: bool,
                     indexedAllowed: bool = True) -> tuple[int, int, Optional[str]]:
        op = op.strip()
        if not op:
            raise AsmError(f"line {lineno}: store requires an operand")
        # (zp),Y indirect-Y for STA only
        m = re.match(r'\(([^)]+)\)\s*,\s*[Yy]\s*$', op)
        if m:
            if not indyAllowed:
                raise AsmError(f"line {lineno}: (zp),Y not supported for this op")
            return (0x2, parseNumber(m.group(1)) & 0xFF, None)
        # abs,X
        m = re.match(r'(.+?)\s*,\s*[Xx]\s*$', op)
        if m:
            if not indexedAllowed:
                raise AsmError(f"line {lineno}: abs,X not supported for this op")
            return (0x1, parseNumber(m.group(1)) & 0xFF, None)
        # plain abs (sub=0 for STA, STX, STY)
        return (0x0, parseNumber(op) & 0xFF, None)

    # ----- driver -----
    def assembleLine(self, raw: str, lineno: int):
        # strip comments
        line = raw.split(';', 1)[0].rstrip()
        if not line.strip():
            return

        # split leading label "label:" off the line
        m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$', line)
        if m:
            label, rest = m.group(1), m.group(2)
            if label in self.symbols:
                raise AsmError(f"line {lineno}: duplicate label {label}")
            self.symbols[label] = Symbol(page=self.curPage, slot=self.curSlot)
            line = rest
            if not line.strip():
                return

        # directives
        stripped = line.strip()
        if stripped.startswith('.'):
            parts = stripped.split(None, 1)
            directive = parts[0].lower()
            argsRaw = parts[1] if len(parts) > 1 else ''
            argsList = [a.strip() for a in argsRaw.split(',')] if argsRaw else []
            if directive == '.page':
                self.directivePage(argsList, lineno); return
            if directive == '.org':
                self.directiveOrg(argsList, lineno); return
            if directive == '.data':
                self.directiveData(argsList, lineno); return
            if directive == '.byte':
                self.directiveByte(argsList, lineno); return
            if directive == '.word':
                self.directiveWord(argsList, lineno); return
            if directive == '.ascii':
                self.directiveAscii(argsRaw, lineno); return
            raise AsmError(f"line {lineno}: unknown directive {directive}")

        # plain instruction: "MNEM operand..."
        tokens = stripped.split(None, 1)
        mnemonic = tokens[0]
        operand = tokens[1] if len(tokens) > 1 else ''
        self.assembleInstruction(mnemonic, operand, lineno, stripped)

    def assembleText(self, text: str) -> None:
        for lineno, raw in enumerate(text.splitlines(), start=1):
            self.assembleLine(raw, lineno)
        # pad final page if partially filled
        if 0 < self.curSlot < SLOTS_PER_PAGE:
            self.padPageWithNops()

    # ----- second pass: patch label refs -----
    def resolve(self) -> None:
        for ins in self.slots:
            if ins.pending_label is None:
                continue
            label = ins.pending_label
            kind = ins.pending_kind
            if label not in self.symbols:
                raise AsmError(
                    f"line {ins.source_line}: unresolved label {label!r} "
                    f"(needed by {ins.source_text!r})"
                )
            tgt = self.symbols[label]

            if kind == 'farjmp':
                # FARJMP target is a page number
                ins.word = encodeWord(OP_FARJMP, 0, tgt.page & 0xFF)
                continue

            # all other label-relative ops are intra-page slot-indexed
            if tgt.page != ins.page:
                raise AsmError(
                    f"line {ins.source_line}: label {label!r} is on page "
                    f"{tgt.page} but ref is on page {ins.page}; use FARJMP"
                )

            if kind == 'jmp':
                ins.word = encodeWord(OP_JMP, 0, tgt.slot & SLOT_MASK)
            elif kind == 'jsr':
                ins.word = encodeWord(OP_JSR, 0, tgt.slot & SLOT_MASK)
            elif kind == 'branch':
                # cpu does: pc <= pc + ir_imm[SLOT_BITS-1:0]
                # at this point in execute, pc has already been incremented
                # to the next slot in ST_FETCH, so the effective branch math is
                #     pc_after = pc_taken + offset
                # where pc_taken == ins.slot + 1 (already wrapped if last slot).
                # we choose to ban backward and out-of-page branches.
                offset = tgt.slot - (ins.slot + 1)
                if not (0 <= offset <= MAX_BRANCH_OFFSET):
                    raise AsmError(
                        f"line {ins.source_line}: branch from slot {ins.slot} "
                        f"to slot {tgt.slot} ({label!r}) needs offset {offset}; "
                        f"only forward offsets 0..{MAX_BRANCH_OFFSET} are "
                        f"supported (page is {SLOTS_PER_PAGE} slots wide)."
                    )
                # extract sub from word, write imm = offset masked to SLOT_BITS
                sub = (ins.word >> 8) & 0xF
                ins.word = encodeWord(OP_BR, sub, offset & SLOT_MASK)
            else:
                raise AsmError(f"internal: unknown pending_kind {kind}")

    # ----- output -----
    def pageWords(self) -> list[list[int]]:
        """return list[page_index] -> SLOTS_PER_PAGE instruction words."""
        if not self.slots:
            return []
        npages = max(s.page for s in self.slots) + 1
        out = [[NOP_WORD] * SLOTS_PER_PAGE for _ in range(npages)]
        for s in self.slots:
            out[s.page][s.slot] = s.word
        return out

    def flatWords(self) -> list[int]:
        return [w for page in self.pageWords() for w in page]


def assembleFile(path: str | Path) -> Assembler:
    asm = Assembler()
    text = Path(path).read_text(encoding='utf-8')
    asm.assembleText(text)
    asm.resolve()
    return asm


def loadHexFile(path: str | Path) -> list[list[int]]:
    """load a .hex file (one 16-bit word per line, # lines are comments,
    page headers are written as `# page N`) into pages of SLOTS_PER_PAGE
    words each."""
    words: list[int] = []
    for raw in Path(path).read_text(encoding='utf-8').splitlines():
        s = raw.split('#', 1)[0].strip()
        if not s:
            continue
        words.append(int(s, 16) & 0xFFFF)
    # round up to a multiple of SLOTS_PER_PAGE
    while len(words) % SLOTS_PER_PAGE != 0:
        words.append(NOP_WORD)
    return [words[i:i + SLOTS_PER_PAGE]
            for i in range(0, len(words), SLOTS_PER_PAGE)]


def loadDataFile(path: str | Path) -> dict[int, int]:
    """load the {hex_addr: byte} json image dumped by --data-out."""
    import json
    raw = json.loads(Path(path).read_text(encoding='utf-8'))
    return {int(k, 16): int(v) & 0xFF for k, v in raw.items()}


# -------------------------------------------------------------------------
# cli
# -------------------------------------------------------------------------
def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="ocpu custom isa assembler")
    p.add_argument('source', help="input .s file")
    p.add_argument('-o', '--output', default=None,
                   help="output .hex file (one 16-bit word per line); "
                        "defaults to <source>.hex")
    p.add_argument('--data-out', default=None,
                   help="optional .json file with data-section image "
                        "{addr_hex: byte}")
    p.add_argument('--listing', action='store_true',
                   help="also print a listing to stdout")
    args = p.parse_args(argv)

    try:
        asm = assembleFile(args.source)
    except AsmError as e:
        print(f"ASM ERROR: {e}", file=sys.stderr)
        return 1

    out = Path(args.output) if args.output else Path(args.source).with_suffix('.hex')
    pages = asm.pageWords()
    with out.open('w', encoding='utf-8') as f:
        for pageIdx, page in enumerate(pages):
            f.write(f"# page {pageIdx}\n")
            for slot, word in enumerate(page):
                f.write(f"{word:04x}\n")
    print(f"wrote {len(pages)} page(s) ({len(pages)*8} instructions) to {out}")

    if args.data_out:
        import json
        with open(args.data_out, 'w', encoding='utf-8') as f:
            json.dump({f"{k:04x}": v for k, v in asm.dataImage.items()}, f, indent=2)
        print(f"wrote data image ({len(asm.dataImage)} bytes) to {args.data_out}")

    if args.listing:
        for ins in asm.slots:
            print(f"  p{ins.page:02d}s{ins.slot} = {ins.word:04x}  ; "
                  f"L{ins.source_line:3d}  {ins.source_text}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
