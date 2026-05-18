"""
test_ocpu.py
cocotb test suite for the tt26-ocpu core.

architecture
------------
tb.v wires `ocpu_core` and `iram_regfile` together exactly the way
project.v does, but exposes the page-handshake signals, the iram write
port, and the data-memory bus directly to the testbench. this file
implements the "external fpga" side of those signals in python:

    * `FpgaModel.servePages` watches the cpu's state register. whenever
      the cpu enters ST_PAGE_REQ it loads the appropriate 8-instruction
      page into iram via the external write port, then pulses page_done.
      it figures out which page to load by tracking page_interrupt for
      wraps and decoding ir_imm for FARJMP.

    * `FpgaModel.serveDataMem` watches mem_req and answers reads/writes
      with a 1-cycle latency through a python dict-backed dram.

each `@cocotb.test` function loads a program from `test/programs/*.s`,
boots the cpu, runs to HLT, and asserts on the register / memory state.
"""

from __future__ import annotations
import os
import sys
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly, ClockCycles, Combine, with_timeout
from cocotb.result import TestSuccess

# allow importing the assembler from tools/
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import ocpu_asm  # noqa: E402


# -------------------------------------------------------------------------
# constants mirrored from src/ocpu_core.v
# -------------------------------------------------------------------------
ST_RESET     = 0
ST_FETCH     = 1
ST_DECODE    = 2
ST_EXECUTE   = 3
ST_MEM_READ  = 4
ST_MEM_WRITE = 5
ST_IND_Y1    = 6
ST_IND_Y2    = 7
ST_PUSH      = 8
ST_POP       = 9
ST_PAGE_REQ  = 10
ST_PAGE_WAIT = 11
ST_HALTED    = 12

OP_FARJMP = 0xB

CLOCK_PERIOD_NS = 40  # 25 MHz, matches config.json CLOCK_PERIOD


# -------------------------------------------------------------------------
# helpers for safely reading cocotb signal values
# -------------------------------------------------------------------------
def _val(sig) -> int:
    """return a signal value as int, treating x/z as 0."""
    try:
        return int(sig.value)
    except Exception:
        # any unresolved bits -> treat as 0 (so we keep moving until reset
        # propagates)
        return 0


# -------------------------------------------------------------------------
# fpga model
# -------------------------------------------------------------------------
class FpgaModel:
    """Drives the page-handshake and data-memory ports of `tb` to look
    like the external FPGA the chip is paired with on the real board."""

    def __init__(self, dut, pages: list[list[int]],
                 dataImage: dict[int, int] | None = None,
                 log=None):
        self.dut = dut
        self.pages = pages              # pages[i] = list of 8 instruction words
        self.dram: dict[int, int] = dict(dataImage or {})
        self.currentPage = 0
        self.pagesLoaded = 0            # how many times we have loaded a page
        self._pagesDone = False
        self.log = log or dut._log

    # ---- initial signal drive ----
    def initSignals(self):
        d = self.dut
        d.rst_n.value           = 0
        d.run_enable.value      = 1
        d.page_done.value       = 0
        d.page_loading.value    = 0
        d.ext_iram_wr_en.value  = 0
        d.ext_iram_wr_slot.value= 0
        d.ext_iram_wr_data.value= 0
        d.cpu_mem_ready.value   = 0
        d.cpu_mem_rdata.value   = 0

    async def releaseReset(self, cycles: int = 10):
        d = self.dut
        for _ in range(cycles):
            await RisingEdge(d.clk)
        d.rst_n.value = 1

    # ---- page service ----
    async def _loadPage(self, pageIdx: int):
        """Drive the page-handshake protocol for `pageIdx`:
            1. assert page_loading
            2. write all 8 slot words via ext_iram_wr_*
            3. pulse page_done
            4. deassert page_loading
        the cpu sits in ST_PAGE_REQ until it sees page_loading, then in
        ST_PAGE_WAIT until it sees page_done, then resumes at slot 0.
        """
        d = self.dut
        if pageIdx >= len(self.pages):
            self.log.warning(f"fpga: page {pageIdx} not in program "
                             f"({len(self.pages)} pages); filling with NOPs")
            page = [ocpu_asm.NOP_WORD] * 8
        else:
            page = self.pages[pageIdx]

        # raise page_loading
        d.page_loading.value = 1
        await RisingEdge(d.clk)

        # write the 8 instructions
        for slot in range(8):
            d.ext_iram_wr_en.value   = 1
            d.ext_iram_wr_slot.value = slot
            d.ext_iram_wr_data.value = page[slot] & 0xFFFF
            await RisingEdge(d.clk)
        d.ext_iram_wr_en.value = 0

        # pulse page_done for one cycle
        d.page_done.value = 1
        await RisingEdge(d.clk)
        d.page_done.value = 0
        d.page_loading.value = 0
        self.pagesLoaded += 1
        self.log.info(f"fpga: loaded page {pageIdx} "
                      f"(total loads = {self.pagesLoaded})")

    async def servePages(self):
        """coroutine: forever wait for the cpu to enter ST_PAGE_REQ, then
        compute which page to load and run the handshake."""
        d = self.dut
        prevPageInt = 0
        while True:
            await RisingEdge(d.clk)
            state = _val(d.cpu.state)
            pageInt = _val(d.page_interrupt)

            # debounce: only fire when we *enter* ST_PAGE_REQ
            if state != ST_PAGE_REQ:
                prevPageInt = pageInt
                continue

            # decide which page to load
            if self.pagesLoaded == 0:
                target = 0
            elif prevPageInt == 1 or pageInt == 1:
                # natural wrap after slot 7
                target = self.currentPage + 1
            else:
                # FARJMP: target page sits in ir_imm
                irOp = _val(d.cpu.ir_op)
                irImm = _val(d.cpu.ir_imm)
                if irOp == OP_FARJMP:
                    target = irImm
                    self.log.info(f"fpga: FARJMP detected, target page {target}")
                else:
                    # treat as sequential as a safe fallback
                    target = self.currentPage + 1

            await self._loadPage(target)
            self.currentPage = target
            prevPageInt = 0

    # ---- data memory service ----
    async def serveDataMem(self):
        """coroutine: one-cycle-latency dram responder.

        the cpu's mem-bus handshake is: rise mem_req with addr/rw/wdata,
        wait for mem_ready pulse, then lower mem_req. we mirror what the
        real FPGA does (no snapshotting; addr/wdata are stable while
        req is high).
        """
        d = self.dut
        prevReady = 0
        while True:
            await RisingEdge(d.clk)
            req = _val(d.cpu_mem_req)
            ready = _val(d.cpu_mem_ready)
            # only respond on the edge of a fresh request (not while ready
            # is still high from the previous transaction)
            if req == 1 and ready == 0 and prevReady == 0:
                addr = _val(d.cpu_mem_addr) & 0xFFFF
                rw   = _val(d.cpu_mem_rw)
                if rw == 0:
                    val = self.dram.get(addr, 0)
                    d.cpu_mem_rdata.value = val
                    d.cpu_mem_ready.value = 1
                    self.log.debug(f"dram[{addr:04x}] -> {val:02x}")
                else:
                    val = _val(d.cpu_mem_wdata) & 0xFF
                    self.dram[addr] = val
                    d.cpu_mem_ready.value = 1
                    self.log.debug(f"dram[{addr:04x}] <- {val:02x} (write)")
                # one-cycle ready pulse
                await RisingEdge(d.clk)
                d.cpu_mem_ready.value = 0
            prevReady = ready


# -------------------------------------------------------------------------
# program runner
# -------------------------------------------------------------------------
async def runProgram(dut, sourcePath: str,
                     maxCycles: int = 5000,
                     verbose: bool = False) -> FpgaModel:
    """assemble, boot, and run `sourcePath` until the cpu halts.
    returns the FpgaModel so the caller can inspect dram afterwards.
    accepts either a .s (assembly source) or .hex (pre-assembled image,
    optionally paired with a sibling .data.json data image).
    """
    if str(sourcePath).endswith('.hex'):
        pages = ocpu_asm.loadHexFile(sourcePath)
        dataPath = str(sourcePath).removesuffix('.hex') + '.data.json'
        dataImage = ocpu_asm.loadDataFile(dataPath) if os.path.exists(dataPath) else {}
    else:
        asm = ocpu_asm.assembleFile(sourcePath)
        pages = asm.pageWords()
        dataImage = asm.dataImage
    fpga = FpgaModel(dut, pages, dataImage=dataImage, log=dut._log)

    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit='ns').start())
    fpga.initSignals()
    await fpga.releaseReset(5)

    cocotb.start_soon(fpga.servePages())
    cocotb.start_soon(fpga.serveDataMem())

    # run until halted or timeout
    haltedCycles = 0
    for cyc in range(maxCycles):
        await RisingEdge(dut.clk)
        if _val(dut.cpu.state) == ST_HALTED:
            haltedCycles += 1
            if haltedCycles >= 2:
                break
        else:
            haltedCycles = 0

    if haltedCycles < 2:
        raise AssertionError(
            f"cpu did not halt within {maxCycles} cycles "
            f"(state={_val(dut.cpu.state)})")

    dut._log.info(
        f"halted: a={_val(dut.cpu.a):02x} x={_val(dut.cpu.x):02x} "
        f"y={_val(dut.cpu.y):02x} sp={_val(dut.cpu.sp):02x} "
        f"sr={_val(dut.cpu.sr):02b}")
    return fpga


def _progPath(name: str) -> str:
    return os.path.join(HERE, 'programs', name)


# -------------------------------------------------------------------------
# tests
# -------------------------------------------------------------------------
@cocotb.test()
async def test_lda_imm(dut):
    """LDA / LDX / LDY immediates + N/Z flag behaviour."""
    await runProgram(dut, _progPath('test_lda_imm.s'))
    assert _val(dut.cpu.a) == 0x42, f"A=0x{_val(dut.cpu.a):02x}, want 0x42"
    assert _val(dut.cpu.x) == 0x10, f"X=0x{_val(dut.cpu.x):02x}, want 0x10"
    assert _val(dut.cpu.y) == 0x80, f"Y=0x{_val(dut.cpu.y):02x}, want 0x80"
    # last load was LDY #0x80 -> N=1, Z=0
    sr = _val(dut.cpu.sr)
    assert (sr >> 2) & 1 == 1, f"N flag should be 1 (sr={sr:05b})"
    assert (sr >> 1) & 1 == 0, f"Z flag should be 0 (sr={sr:05b})"


@cocotb.test()
async def test_alu_imm(dut):
    """ALU immediates: ADD/SUB/AND/ORA/EOR with carry handling."""
    await runProgram(dut, _progPath('test_alu_imm.s'))
    # program ends with A = (((0x05 + 0x03) & 0x0F) | 0x80) ^ 0x01 = 0x89
    assert _val(dut.cpu.a) == 0x89, f"A=0x{_val(dut.cpu.a):02x}, want 0x89"


@cocotb.test()
async def test_branch(dut):
    """forward branches BEQ/BNE/BCS/BCC; verify Z and C flag-driven control."""
    await runProgram(dut, _progPath('test_branch.s'))
    # program writes 0xAA to dram[0x0010] only if all branches behaved
    fpga_dram_marker = 0xAA
    # X counts the number of taken branches; should be exactly 3
    assert _val(dut.cpu.x) == 3, f"X={_val(dut.cpu.x)} but want 3 branch hits"


@cocotb.test()
async def test_reg_ops(dut):
    """register transfers + INX/DEX/INY/DEY flag updates."""
    await runProgram(dut, _progPath('test_reg_ops.s'))
    assert _val(dut.cpu.a) == 0x7F, f"A=0x{_val(dut.cpu.a):02x}, want 0x7F"
    assert _val(dut.cpu.x) == 0x80, f"X=0x{_val(dut.cpu.x):02x}, want 0x80"
    assert _val(dut.cpu.y) == 0x00, f"Y=0x{_val(dut.cpu.y):02x}, want 0x00"
    # final flag check: after INX of 0x7F -> X=0x80, N=1 Z=0
    sr = _val(dut.cpu.sr)
    assert (sr >> 2) & 1 == 1, f"N flag should be 1 after INX (sr={sr:05b})"


@cocotb.test()
async def test_load_store(dut):
    """LDA abs / STA abs round trip through the dram model."""
    fpga = await runProgram(dut, _progPath('test_load_store.s'))
    # store 0x37 to dram[0x0042], read back, store +1 to dram[0x0043]
    assert fpga.dram.get(0x0042) == 0x37, \
        f"dram[0x42] = {fpga.dram.get(0x0042)!r}, want 0x37"
    assert fpga.dram.get(0x0043) == 0x38, \
        f"dram[0x43] = {fpga.dram.get(0x0043)!r}, want 0x38"
    assert _val(dut.cpu.a) == 0x38, f"A = {_val(dut.cpu.a):02x}, want 0x38"


@cocotb.test()
async def test_stack(dut):
    """PHA / PLA round trip and JSR / RTS return."""
    await runProgram(dut, _progPath('test_stack.s'))
    # the subroutine adds 1 to A; main calls it twice starting from 0x10
    assert _val(dut.cpu.a) == 0x12, f"A=0x{_val(dut.cpu.a):02x}, want 0x12"
    # sp should be back at 0xff (balanced stack)
    assert _val(dut.cpu.sp) == 0xFF, f"SP=0x{_val(dut.cpu.sp):02x}, want 0xFF"


@cocotb.test()
async def test_page_wrap(dut):
    """program spans 2 pages; verifies the page-load handshake fires after slot 7."""
    fpga = await runProgram(dut, _progPath('test_page_wrap.s'))
    # the program writes a sentinel byte 0x5A to dram[0x0050] from page 1
    assert fpga.dram.get(0x0050) == 0x5A, \
        f"dram[0x50] = {fpga.dram.get(0x0050)!r}, want 0x5A (page 1 never ran)"
    assert fpga.pagesLoaded >= 2, \
        f"only loaded {fpga.pagesLoaded} pages, expected >=2"


@cocotb.test()
async def test_indy(dut):
    """LDA (zp),Y indirect-Y load through the dram pointer table."""
    fpga = await runProgram(dut, _progPath('test_indy.s'))
    # the program loads pointer table at 0x0020 = {0x40, 0x00} -> deref 0x0040+y
    assert _val(dut.cpu.a) == 0xCC, f"A=0x{_val(dut.cpu.a):02x}, want 0xCC"


@cocotb.test()
async def test_smod(dut):
    """SMOD writes the cpu's accumulator into the imm field of an iram slot
    and the dirty bit for that slot becomes set."""
    await runProgram(dut, _progPath('test_smod.s'))
    db = _val(dut.dirty_bits)
    # SMOD targets slot 4 in the program
    assert (db >> 4) & 1 == 1, \
        f"dirty_bits = {db:08b}; slot-4 bit should be set after SMOD"
