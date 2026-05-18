"""
test.py
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
from cocotb.triggers import RisingEdge

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

    # run until halted or timeout.
    # ST_HALTED auto-exits when run_enable is high (see ocpu_core.v
    # ST_HALTED branch), so the moment we see it we deassert run_enable
    # to pin the cpu in the halted state. that lets the test inspect
    # final register values without race conditions.
    halted = False
    for cyc in range(maxCycles):
        await RisingEdge(dut.clk)
        if _val(dut.cpu.state) == ST_HALTED:
            dut.run_enable.value = 0
            halted = True
            # give one more cycle to let any pending writes settle
            await RisingEdge(dut.clk)
            break

    if not halted:
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
    # X counts the number of taken branches; should be exactly 3
    assert _val(dut.cpu.x) == 3, f"X={_val(dut.cpu.x)} but want 3 branch hits"


@cocotb.test()
async def test_reg_ops(dut):
    """register transfers + INX/DEX/INY/DEY flag updates."""
    await runProgram(dut, _progPath('test_reg_ops.s'))
    assert _val(dut.cpu.a) == 0x7F, f"A=0x{_val(dut.cpu.a):02x}, want 0x7F"
    assert _val(dut.cpu.x) == 0x80, f"X=0x{_val(dut.cpu.x):02x}, want 0x80"
    assert _val(dut.cpu.y) == 0x00, f"Y=0x{_val(dut.cpu.y):02x}, want 0x00"
    sr = _val(dut.cpu.sr)
    assert (sr >> 2) & 1 == 1, f"N flag should be 1 after INX (sr={sr:05b})"


@cocotb.test()
async def test_load_store(dut):
    """LDA abs / STA abs round trip through the dram model."""
    fpga = await runProgram(dut, _progPath('test_load_store.s'))
    assert fpga.dram.get(0x0042) == 0x37, \
        f"dram[0x42] = {fpga.dram.get(0x0042)!r}, want 0x37"
    assert fpga.dram.get(0x0043) == 0x38, \
        f"dram[0x43] = {fpga.dram.get(0x0043)!r}, want 0x38"
    assert _val(dut.cpu.a) == 0x38, f"A = {_val(dut.cpu.a):02x}, want 0x38"


@cocotb.test()
async def test_stack(dut):
    """JSR / RTS return + SP balance.
    one call adds 1 to A; we expect 0x10 + 1 = 0x11 with sp restored.
    (the program intentionally avoids placing RTS at slot 7, which would
    trigger the page-wrap behaviour; see test_stack.s for the why.)"""
    await runProgram(dut, _progPath('test_stack.s'))
    assert _val(dut.cpu.a) == 0x11, f"A=0x{_val(dut.cpu.a):02x}, want 0x11"
    assert _val(dut.cpu.sp) == 0xFF, f"SP=0x{_val(dut.cpu.sp):02x}, want 0xFF"


@cocotb.test()
async def test_page_wrap(dut):
    """program spans 2 pages; verifies the page-load handshake fires after slot 7."""
    fpga = await runProgram(dut, _progPath('test_page_wrap.s'))
    assert fpga.dram.get(0x0050) == 0x5A, \
        f"dram[0x50] = {fpga.dram.get(0x0050)!r}, want 0x5A (page 1 never ran)"
    assert fpga.pagesLoaded >= 2, \
        f"only loaded {fpga.pagesLoaded} pages, expected >=2"


@cocotb.test()
async def test_indy(dut):
    """LDA (zp),Y indirect-Y load through the dram pointer table."""
    await runProgram(dut, _progPath('test_indy.s'))
    assert _val(dut.cpu.a) == 0xCC, f"A=0x{_val(dut.cpu.a):02x}, want 0xCC"


@cocotb.test()
async def test_smod(dut):
    """SMOD writes the cpu's accumulator into the imm field of an iram slot
    and the dirty bit for that slot becomes set."""
    await runProgram(dut, _progPath('test_smod.s'))
    db = _val(dut.dirty_bits)
    assert (db >> 4) & 1 == 1, \
        f"dirty_bits = {db:08b}; slot-4 bit should be set after SMOD"


# -------------------------------------------------------------------------
# extended coverage: one test per isa family. each program is documented
# in its own .s file with the expected post-halt state.
# -------------------------------------------------------------------------

@cocotb.test()
async def test_cmp(dut):
    """CMP # sets only flags, leaves A unchanged."""
    await runProgram(dut, _progPath('test_cmp.s'))
    assert _val(dut.cpu.a) == 0x50, f"A=0x{_val(dut.cpu.a):02x}, want 0x50"
    sr = _val(dut.cpu.sr)
    # last CMP was A(0x50) - 0x60 -> result 0xF0: Z=0, C=0, N=1
    assert (sr >> 0) & 1 == 0, f"C flag should be 0 after CMP (sr={sr:05b})"
    assert (sr >> 1) & 1 == 0, f"Z flag should be 0 after CMP (sr={sr:05b})"
    assert (sr >> 2) & 1 == 1, f"N flag should be 1 after CMP (sr={sr:05b})"


@cocotb.test()
async def test_adc_sbc(dut):
    """ADC / SBC respect carry-in; SUB does not."""
    await runProgram(dut, _progPath('test_adc_sbc.s'))
    assert _val(dut.cpu.a) == 0x11, f"A=0x{_val(dut.cpu.a):02x}, want 0x11"


@cocotb.test()
async def test_alu_mem(dut):
    """ALU operations against a memory operand (data_page=0)."""
    await runProgram(dut, _progPath('test_alu_mem.s'))
    assert _val(dut.cpu.a) == 0x00, f"A=0x{_val(dut.cpu.a):02x}, want 0x00"
    sr = _val(dut.cpu.sr)
    assert (sr >> 1) & 1 == 1, f"Z flag should be 1 after EOR -> 0 (sr={sr:05b})"


@cocotb.test()
async def test_branch_full(dut):
    """four taken branches: BEQ, BPL, BMI, BNE. counted in X."""
    await runProgram(dut, _progPath('test_branch_full.s'))
    assert _val(dut.cpu.x) == 4, f"X={_val(dut.cpu.x)} but want 4 taken branches"


@cocotb.test()
async def test_reg_xfers(dut):
    """TXA / TAY / TYA / DEX / INY transfers + post-update flag effects."""
    await runProgram(dut, _progPath('test_reg_xfers.s'))
    assert _val(dut.cpu.a) == 0x33, f"A=0x{_val(dut.cpu.a):02x}, want 0x33"
    assert _val(dut.cpu.x) == 0x32, f"X=0x{_val(dut.cpu.x):02x}, want 0x32"
    assert _val(dut.cpu.y) == 0x34, f"Y=0x{_val(dut.cpu.y):02x}, want 0x34"


@cocotb.test()
async def test_pha_pla(dut):
    """PHA pushes A; PLA pops it back. SP must balance to 0xFF."""
    await runProgram(dut, _progPath('test_pha_pla.s'))
    assert _val(dut.cpu.a) == 0x7B, f"A=0x{_val(dut.cpu.a):02x}, want 0x7B"
    assert _val(dut.cpu.sp) == 0xFF, f"SP=0x{_val(dut.cpu.sp):02x}, want 0xFF"


@cocotb.test()
async def test_sp_ops(dut):
    """LDSP / TSX / TXS / STSP move the stack pointer through A and X."""
    await runProgram(dut, _progPath('test_sp_ops.s'))
    assert _val(dut.cpu.a)  == 0x40, f"A=0x{_val(dut.cpu.a):02x}, want 0x40"
    assert _val(dut.cpu.x)  == 0x40, f"X=0x{_val(dut.cpu.x):02x}, want 0x40"
    assert _val(dut.cpu.sp) == 0x40, f"SP=0x{_val(dut.cpu.sp):02x}, want 0x40"


@cocotb.test()
async def test_load_abs(dut):
    """LDX abs / LDY abs / STX / STY round trip through dram."""
    fpga = await runProgram(dut, _progPath('test_load_abs.s'))
    assert _val(dut.cpu.x) == 0xAA, f"X=0x{_val(dut.cpu.x):02x}, want 0xAA"
    assert _val(dut.cpu.y) == 0xBB, f"Y=0x{_val(dut.cpu.y):02x}, want 0xBB"
    assert fpga.dram.get(0x0020) == 0xAA, \
        f"dram[0x20] = {fpga.dram.get(0x0020)!r}, want 0xAA"
    assert fpga.dram.get(0x0021) == 0xBB, \
        f"dram[0x21] = {fpga.dram.get(0x0021)!r}, want 0xBB"


@cocotb.test()
async def test_jmp(dut):
    """JMP skips intervening slots that would otherwise overwrite A."""
    await runProgram(dut, _progPath('test_jmp.s'))
    assert _val(dut.cpu.a) == 0x42, f"A=0x{_val(dut.cpu.a):02x}, want 0x42"


@cocotb.test()
async def test_data_page(dut):
    """STA_DP / LDA_DP switch the high byte of all 16-bit data addresses."""
    await runProgram(dut, _progPath('test_data_page.s'))
    assert _val(dut.cpu.a) == 0x02, \
        f"A=0x{_val(dut.cpu.a):02x}, want 0x02 (data_page value)"


@cocotb.test()
async def test_indexed(dut):
    """LDA abs,X reads from base+X; STA abs,X writes there."""
    fpga = await runProgram(dut, _progPath('test_indexed.s'))
    assert _val(dut.cpu.a) == 0xDE, f"A=0x{_val(dut.cpu.a):02x}, want 0xDE"
    assert fpga.dram.get(0x0042) == 0xDE, \
        f"dram[0x42] = {fpga.dram.get(0x0042)!r}, want 0xDE"


@cocotb.test()
async def test_sta_indy(dut):
    """STA (zp),Y dereferences a 16-bit pointer and writes at base+Y."""
    fpga = await runProgram(dut, _progPath('test_sta_indy.s'))
    assert fpga.dram.get(0x0053) == 0x77, \
        f"dram[0x53] = {fpga.dram.get(0x0053)!r}, want 0x77 (0x77 at 0x50+Y=3)"


@cocotb.test()
async def test_pipeline_6502(dut):
    """end-to-end translator test: a hand-written 6502 source goes through
    translate_6502.py and ocpu_asm.py, and the resulting .hex is loaded by
    the FpgaModel and executed on the cpu.

    the program initialises dram[0x40] to 0 then runs INC $40 (which the
    translator expands as LDA / ADC / STA). expected: dram[0x40] = 1."""
    fpga = await runProgram(
        dut, _progPath(os.path.join('c_src', 'sample_6502.hex')))
    assert fpga.dram.get(0x0040) == 0x01, \
        f"dram[0x40] = {fpga.dram.get(0x0040)!r}, want 0x01"


def _dumpFinalState(dut, fpga: 'FpgaModel') -> None:
    """print a complete snapshot of the cpu after halt:
      - cpu registers and status bits
      - the current iram contents (the page the cpu was sitting in at HLT)
      - every iram page the FpgaModel ever shipped to the cpu (i.e. the
        full program image, because each FARJMP / wrap re-flashes an
        entire page from `fpga.pages`)
      - the entire dram dict the FpgaModel observed (initial .data image
        plus everything the program wrote at runtime)
    intended to be readable on a console rather than parsed; it goes
    through dut._log so it lands in the cocotb log and on stdout.
    """
    log = dut._log
    a  = _val(dut.cpu.a);  x = _val(dut.cpu.x);  y = _val(dut.cpu.y)
    sp = _val(dut.cpu.sp); sr = _val(dut.cpu.sr)
    pageReg  = _val(dut.cpu.page_reg)
    dataPage = _val(dut.cpu.data_page)
    pc       = _val(dut.cpu.pc)
    # SR layout (matches src/ocpu_core.v): {I, N, V, Z, C} from msb downwards
    cFlag = (sr >> 0) & 1
    zFlag = (sr >> 1) & 1
    nFlag = (sr >> 2) & 1
    vFlag = (sr >> 3) & 1
    iFlag = (sr >> 4) & 1

    log.info("=" * 72)
    log.info("FINAL CPU STATE")
    log.info("=" * 72)
    log.info(f"  A={a:02x}  X={x:02x}  Y={y:02x}  SP={sp:02x}  PC=slot{pc}")
    log.info(f"  page_reg={pageReg:02x}  data_page={dataPage:02x}")
    log.info(f"  flags: N={nFlag} V={vFlag} Z={zFlag} C={cFlag} I={iFlag} "
             f"(sr=0b{sr:05b})")

    log.info(" ")
    log.info("IRAM (current page, 8 slots, 16-bit words)")
    log.info("-" * 72)
    for slot in range(8):
        try:
            word = int(dut.iram.mem[slot].value) & 0xFFFF
        except Exception:
            word = 0
        op  = (word >> 12) & 0xF
        sub = (word >>  8) & 0xF
        imm = (word >>  0) & 0xFF
        log.info(f"  slot {slot}: {word:04x}  (op={op:x} sub={sub:x} "
                 f"imm={imm:02x})")

    log.info(" ")
    log.info(f"PROGRAM IMAGE (all {len(fpga.pages)} page(s) shipped to cpu)")
    log.info("-" * 72)
    for pidx, page in enumerate(fpga.pages):
        words = "  ".join(f"{w & 0xFFFF:04x}" for w in page)
        log.info(f"  page {pidx}: {words}")

    log.info(" ")
    if not fpga.dram:
        log.info("DRAM: (empty - program neither read nor wrote any address)")
    else:
        log.info(f"DRAM ({len(fpga.dram)} byte(s); addr -> value)")
        log.info("-" * 72)
        for addr in sorted(fpga.dram.keys()):
            log.info(f"  ${addr:04x}: {fpga.dram[addr]:02x}  "
                     f"({fpga.dram[addr]:3d})")
    log.info("=" * 72)


@cocotb.test()
async def test_user_program(dut):
    """run an arbitrary C / 6502 / ocpu binary supplied via env var.

    triggered by setting `OCPU_USER_HEX` to a `.hex` produced by
    tools\\build_c.ps1 (or directly by tools\\ocpu_asm.py). on halt the
    test dumps every register, the current iram page, the full program
    image, and the entire dram dictionary so the user can see exactly
    what their program produced. without the env var this test is a
    no-op so it stays out of the way during normal regression runs.
    """
    hexPath = os.environ.get('OCPU_USER_HEX', '').strip()
    if not hexPath:
        dut._log.info(
            "test_user_program: OCPU_USER_HEX not set, skipping. "
            "set it to a .hex path (or use tools\\run_c.ps1) to run.")
        return
    if not os.path.exists(hexPath):
        raise AssertionError(
            f"OCPU_USER_HEX={hexPath!r} but the file does not exist")

    maxCycles = int(os.environ.get('OCPU_USER_MAX_CYCLES', '50000'))
    dut._log.info(f"running user program: {hexPath} (max {maxCycles} cycles)")
    fpga = await runProgram(dut, hexPath, maxCycles=maxCycles)
    _dumpFinalState(dut, fpga)


@cocotb.test()
async def test_cc65_sum_arr(dut):
    """end-to-end C -> binary pipeline: sum_arr.c is compiled by cc65,
    translated to ocpu by translate_6502.py, assembled by ocpu_asm.py,
    and the resulting multi-page binary is run on the cpu.

    sum_arr.c initialises _sum = 0 and accumulates _arr[0..3] = {1,2,3,4}
    into _sum. expected final value of _sum (BSS, address $0080) = 10.

    this test exercises:
      - data segment seeding (.data $0040 with _arr)
      - BSS segment seeding (.data $0080 with _sum)
      - auto-paging across three iram pages (FARJMP transitions)
      - cc65 calling convention compat (trailing RTS rewritten -> HLT)
    if cc65 has not been installed yet the .hex won't exist and the
    test is skipped so the rest of the suite stays green.
    """
    hexPath = _progPath(os.path.join('c_src', 'sum_arr.hex'))
    if not os.path.exists(hexPath):
        dut._log.warning(
            f"skipping cc65 pipeline test: {hexPath} not found. "
            f"run tools/build_c.ps1 first to compile sum_arr.c.")
        return
    fpga = await runProgram(dut, hexPath, maxCycles=15000)
    got = fpga.dram.get(0x0080)
    assert got == 0x0A, (
        f"dram[$0080] (_sum) = {got!r}, want 0x0A "
        f"(sum of {{1,2,3,4}})")


@cocotb.test()
async def test_sys_flags(dut):
    """SEC / CLC / SEI / CLI directly manipulate SR bits."""
    await runProgram(dut, _progPath('test_sys_flags.s'))
    sr = _val(dut.cpu.sr)
    # final state: C=0 (CLC was last carry op), I=1 (SEI), N=0, Z=0
    assert (sr >> 0) & 1 == 0, f"C should be 0 (sr={sr:05b})"
    assert (sr >> 4) & 1 == 1, f"I should be 1 (sr={sr:05b})"
