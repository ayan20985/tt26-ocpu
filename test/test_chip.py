"""
test_chip.py - cocotb chip-top test for tt_um_ocpu.

drives the FULL chip (src/project.v) via its real Tiny Tapeout pins
through tb_chip.v. validates the silicon-side OSPI slave end-to-end:

  * new pin map (SCK/CS_N/page_done/page_loading on ui_in[0..3])
  * CS_N active-low polarity fix in ospi_memory.v
  * iRAM byte-pair loading (addr[0]=LO/HI, addr[2:1]=slot)
  * page-handshake protocol on real pins

this is the lowest-level "does the chip work over OSPI" test. the
existing test.py suite bypasses the OSPI slave entirely (writes
straight into iram_regfile), so this file is the only thing that
actually exercises the silicon's OSPI path.
"""

from __future__ import annotations
import os
import sys
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import ocpu_asm  # noqa: E402


CLOCK_PERIOD_NS = 40   # 25 MHz (matches config.json CLOCK_PERIOD)
SCK_HALF_CYCLES = 4    # clk cycles per SCK half-period

# matches SLOT_BITS in src/iram_regfile.v / src/ocpu_core.v.
SLOTS_PER_PAGE = 4


# -------------------------------------------------------------------------
# python-side OSPI master that pokes the chip pins directly
# -------------------------------------------------------------------------
class ChipOspiMaster:
    """Drives the OSPI master end of the chip's slave port. assumes the
    chip-top tb wires SCK to ui_in[0], CS_N to ui_in[1], page_done to
    ui_in[2], page_loading to ui_in[3], and the 8-bit OSPI data bus to
    uio_in/uio_out."""

    def __init__(self, dut, log=None):
        self.dut = dut
        self.log = log or dut._log
        self._ui = 0  # local mirror of ui_in so we can change one bit at a time

    # ---- pin helpers ----
    def _setUi(self, bit: int, val: int) -> None:
        if val:
            self._ui |= (1 << bit)
        else:
            self._ui &= ~(1 << bit)
        self.dut.ui_in.value = self._ui

    def setSck(self, v: int) -> None:        self._setUi(0, v)
    def setCsN(self, v: int) -> None:        self._setUi(1, v)
    def setPageDone(self, v: int) -> None:   self._setUi(2, v)
    def setPageLoading(self, v: int) -> None:self._setUi(3, v)

    # ---- initial conditions ----
    def initSignals(self):
        d = self.dut
        # idle bus: SCK=0, CS_N=1, page handshake low; uio data 0.
        self._ui = 0b0000_0010   # CS_N=1
        d.ui_in.value  = self._ui
        d.uio_in.value = 0
        d.ena.value    = 1
        d.rst_n.value  = 0

    async def releaseReset(self, cycles: int = 20):
        for _ in range(cycles):
            await RisingEdge(self.dut.clk)
        self.dut.rst_n.value = 1

    # ---- OSPI burst primitive ----
    async def burst(self, cmd: int, addr: int,
                    wdata: int = 0, is_read: bool = False) -> int:
        """Run one full 5-byte OSPI transaction. returns the slave-driven
        data byte (only meaningful for reads)."""
        bytes_out = [
            cmd & 0xFF,
            (addr >> 16) & 0xFF,
            (addr >>  8) & 0xFF,
            (addr >>  0) & 0xFF,
            wdata & 0xFF,
        ]

        # assert CS_N low, give the slave a half-period to see it
        self.setCsN(0)
        self.setSck(0)
        await ClockCycles(self.dut.clk, SCK_HALF_CYCLES)

        rdata = 0
        for byte_idx, b in enumerate(bytes_out):
            # falling half: drive the byte on uio_in. for the data byte
            # of a read, stop driving (slave will drive uio_out).
            if byte_idx == 4 and is_read:
                self.dut.uio_in.value = 0  # master tri-state surrogate
            else:
                self.dut.uio_in.value = b
            self.setSck(0)
            await ClockCycles(self.dut.clk, SCK_HALF_CYCLES)

            # rising half: SCK goes high. slave samples on this edge
            # (or, for read byte 4, master samples slave's uio_out).
            self.setSck(1)
            await ClockCycles(self.dut.clk, SCK_HALF_CYCLES)
            if byte_idx == 4 and is_read:
                rdata = int(self.dut.uio_out.value) & 0xFF

        # de-assert CS_N
        self.setSck(0)
        self.setCsN(1)
        self.dut.uio_in.value = 0
        await ClockCycles(self.dut.clk, SCK_HALF_CYCLES * 2)
        return rdata

    async def write(self, addr: int, data: int) -> None:
        await self.burst(cmd=0x02, addr=addr, wdata=data, is_read=False)

    async def read(self, addr: int) -> int:
        return await self.burst(cmd=0x03, addr=addr, wdata=0, is_read=True)

    # ---- higher-level: load a single iRAM slot ----
    async def writeSlot(self, slot: int, word: int) -> None:
        """Load a 16-bit instruction word into iRAM slot. takes TWO OSPI
        writes per slot: LO byte at addr {slot,0}, then HI byte at
        addr {slot,1}. the chip latches the LO byte and commits the
        full 16-bit word on the HI write."""
        lo = word & 0xFF
        hi = (word >> 8) & 0xFF
        loAddr = (slot << 1) | 0x0
        hiAddr = (slot << 1) | 0x1
        await self.write(loAddr, lo)
        await self.write(hiAddr, hi)

    async def loadPage(self, instrs: list[int]) -> None:
        """Load a full SLOTS_PER_PAGE-slot page. pads with NOPs as needed."""
        nop = ocpu_asm.NOP_WORD
        page = (instrs + [nop] * SLOTS_PER_PAGE)[:SLOTS_PER_PAGE]
        # tell the chip we're loading (asserts page_loading on ui_in[3])
        self.setPageLoading(1)
        await ClockCycles(self.dut.clk, 2)
        for slot, word in enumerate(page):
            await self.writeSlot(slot, word)
        # signal page_done (1-cycle pulse) and drop page_loading
        self.setPageDone(1)
        await ClockCycles(self.dut.clk, 2)
        self.setPageDone(0)
        self.setPageLoading(0)
        await ClockCycles(self.dut.clk, 2)


# -------------------------------------------------------------------------
# tests
# -------------------------------------------------------------------------
@cocotb.test()
async def test_chip_ospi_load_and_run(dut):
    """End-to-end OSPI integration test: load a single-page program
    consisting of `LDA #$5A; HLT` over real OSPI bursts, verify the
    chip executes and asserts is_halted (uo_out[2])."""

    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit='ns').start())

    m = ChipOspiMaster(dut)
    m.initSignals()
    await m.releaseReset(20)

    # build the page: LDA #$5A, HLT, then 6 NOPs as filler.
    # encodings come from ocpu_asm - assemble a tiny source so we don't
    # hand-encode here.
    src = (
        ".page 0\n"
        "LDA #$5A\n"
        "HLT\n"
    )
    tmpPath = os.path.join(HERE, '_tmp_chip_prog.s')
    with open(tmpPath, 'w') as f:
        f.write(src)
    try:
        asm = ocpu_asm.assembleFile(tmpPath)
    finally:
        os.unlink(tmpPath)
    page0 = asm.pageWords()[0]
    dut._log.info(f"page0 words = {[f'{w:04x}' for w in page0]}")

    # the chip wakes up in ST_PAGE_REQ and waits for page_loading + page_done
    await m.loadPage(page0)

    # let the chip execute. the HLT instruction parks it in ST_HALTED,
    # which surfaces on uo_out[2].
    is_halted_bit = 1 << 2
    deadline = 2000
    halted = False
    for _ in range(deadline):
        await RisingEdge(dut.clk)
        if int(dut.uo_out.value) & is_halted_bit:
            halted = True
            break
    assert halted, "chip did not reach HLT within deadline cycles"
    dut._log.info(f"chip halted after OSPI page load (uo_out={int(dut.uo_out.value):08b})")


@cocotb.test()
async def test_chip_ospi_readback(dut):
    """Write SLOTS_PER_PAGE distinct 16-bit instruction words into iRAM via
    OSPI write bursts, then read each byte back via OSPI read bursts and
    verify the bytes match. exercises both the byte-pair write path AND
    the iRAM->OSPI readback mux."""

    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit='ns').start())

    m = ChipOspiMaster(dut)
    m.initSignals()
    await m.releaseReset(20)

    # SLOTS_PER_PAGE arbitrary 16-bit words with distinct hi/lo bytes
    all_words = [0x1234, 0x5678, 0x9ABC, 0xDEF0,
                 0x0F1E, 0x2D3C, 0x4B5A, 0x6978]
    words = all_words[:SLOTS_PER_PAGE]

    # hold page_loading high so the chip stays in ST_PAGE_WAIT-ish region
    # and doesn't try to start executing partially-loaded code mid-test.
    m.setPageLoading(1)
    await ClockCycles(dut.clk, 4)

    for slot, w in enumerate(words):
        await m.writeSlot(slot, w)

    # now read every byte back. addr[2:1]=slot, addr[0]=lo(0)/hi(1).
    for slot, expected in enumerate(words):
        lo = await m.read((slot << 1) | 0)
        hi = await m.read((slot << 1) | 1)
        got = (hi << 8) | lo
        assert got == expected, (
            f"iRAM slot {slot} readback mismatch: got 0x{got:04x}, "
            f"expected 0x{expected:04x} (lo=0x{lo:02x}, hi=0x{hi:02x})"
        )
    dut._log.info(
        f"all {SLOTS_PER_PAGE} slots verified end-to-end over OSPI "
        f"write+read")


@cocotb.test()
async def test_chip_smod_writeback(dut):
    """Validate the SMOD writeback contract over real OSPI:
        1. load a tiny program that does LDA #$A5; SMOD slot 2; HLT
        2. let it run to HLT
        3. OSPI-read the LO/HI bytes of iRAM slot 2 and assert SMOD
           rewrote the low byte to 0xA5 (the value of A).

    this exercises the full readback path the external FPGA uses to
    persist modified instruction pages back to its program store. note
    the per-slot dirty-bit FFs were removed for area; the FPGA reference
    model now writes back every slot unconditionally on each page swap,
    so there is no longer a 0xFD0000 readback to consult."""

    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit='ns').start())

    m = ChipOspiMaster(dut)
    m.initSignals()
    await m.releaseReset(20)

    # build the program. SMOD takes a slot index in its imm field and
    # writes A into the LOW byte of that slot. with 4-slot pages we pick
    # slot 2 (between LDA at slot 0 and HLT at slot 3, leaving room).
    src = (
        ".page 0\n"
        "LDA #$A5\n"
        "SMOD 2, $00\n"
        "HLT\n"
    )
    tmpPath = os.path.join(HERE, '_tmp_chip_smod.s')
    with open(tmpPath, 'w') as f:
        f.write(src)
    try:
        asm = ocpu_asm.assembleFile(tmpPath)
    finally:
        os.unlink(tmpPath)
    page0 = asm.pageWords()[0]
    original_slot2 = page0[2]  # the SMOD instruction word itself
    dut._log.info(
        f"page0 = {[f'{w:04x}' for w in page0]} "
        f"(slot 2 starts as 0x{original_slot2:04x})"
    )

    await m.loadPage(page0)

    # wait for HLT
    is_halted_bit = 1 << 2
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if int(dut.uo_out.value) & is_halted_bit:
            break
    else:
        raise AssertionError("chip did not reach HLT within deadline")

    # OSPI-read iRAM slot 2. the SMOD contract is:
    #   * the LOW byte of the target slot is overwritten with A (here 0xA5)
    #   * the HIGH byte is concurrently overwritten with whatever
    #     iram_rd_data[15:8] is at the time the SMOD executes - that's
    #     the HI byte of the slot the CPU is currently FETCHING (PC+1),
    #     not the target slot. this is a known CPU quirk: SMOD is
    #     primarily a self-modify hook for the LOW byte (the imm field
    #     of the instruction), and we ignore the HI side-effect.
    lo = await m.read((2 << 1) | 0)
    hi = await m.read((2 << 1) | 1)
    new_word = (hi << 8) | lo
    assert lo == 0xA5, (
        f"SMOD should have rewritten slot-2 LO to 0xA5 but got 0x{lo:02x} "
        f"(full readback 0x{new_word:04x})"
    )
    dut._log.info(
        f"SMOD writeback OK: slot 2 LO=0x{lo:02x} (HI=0x{hi:02x} carries "
        f"the next-fetch slot's HI byte)"
    )
