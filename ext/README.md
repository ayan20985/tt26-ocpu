// External FPGA Modules
// =====================
// This folder contains Verilog code for the external FPGA that communicates
// with the tt26-ocpu ASIC via the OSPI (8-bit parallel) slave interface.

// OSPI Protocol (ASIC is slave, external FPGA is master)
// ======================================================
// The external FPGA drives the OSPI interface to:
//   1. Load instruction pages into iRAM (8 instructions per page, 2 bytes each)
//   2. Monitor the page_interrupt flag (CPU finished slot 7)
//   3. Coordinate page transitions via page_done handshake
//   4. Service CPU data memory requests via address-mapped registers
//   5. Read dirty bits before a page swap so it can write modified slots back

// Pin Mapping (from ASIC perspective)
// ====================================
// All four control signals live on the dedicated input bank (ui_in) so they
// can never alias the bidirectional OSPI data bus. This is a deliberate
// change from earlier revisions — on the prior chip layout SCK and CS_N
// shared bits 0 and 1 with the data bus, which made it impossible for the
// master to ever transmit a write command (0x02) because bit 0 was forced
// high whenever SCK was high during sampling.
//
//   ui_in[0]   = SCK         (serial clock from master)
//   ui_in[1]   = CS_N        (chip select from master, active low)
//   ui_in[2]   = page_done   (FPGA pulses high: new page loaded, resume CPU)
//   ui_in[3]   = page_loading(FPGA holds high while loading a page)
//   ui_in[7:4] = reserved (tied unused on the chip)
//
//   uio_in[7:0]  = IO_I[7:0] (data, from master to ASIC)
//   uio_out[7:0] = IO_O[7:0] (data, from ASIC to master)
//   uio_oe[7:0]  = output-enable, ASIC drives only during byte 4 of a read
//
//   uo_out[0] = page_interrupt (1-cycle pulse: slot-7 instruction just finished)
//   uo_out[1] = page_loading   (echo of ui_in[3], confirms CPU is waiting)
//   uo_out[2] = is_halted      (CPU stalled for any reason)
//   uo_out[3] = data_req       (CPU is waiting for a data memory transaction)

// OSPI Command Bytes
// ==================
//   0x02 = WRITE (cmd + 3 addr + 1 data)
//   0x03 = READ  (cmd + 3 addr + 1 data byte clocked out by slave)

// Address Space
// =============
//   0x000000–0x00000F  iRAM slot bytes (16 addresses for 8 slots * 2 bytes)
//                        addr[3:1] = slot index (0..7)
//                        addr[0]   = 0 -> LOW byte  (immediate, bits 7:0)
//                                    1 -> HIGH byte (opcode+sub, bits 15:8)
//                      a full instruction load is two writes: LOW byte first
//                      (latched internally), then HIGH byte (commits the
//                      full 16-bit word into the iRAM slot in the same cycle).
//   0xFE0000           data_req status:  bit 0 = rw flag (0=read, 1=write)
//   0xFE0001           data_req addr_hi: cpu_mem_addr[15:8]
//   0xFE0002           data_req addr_lo: cpu_mem_addr[7:0]
//   0xFE0003           data_req wdata:   cpu_mem_wdata (valid only on writes)
//   0xFE0100           data_req ACK: write rdata here to unblock CPU
//                        (data byte -> cpu_mem_rdata, pulses cpu_mem_ready 1 cycle)
//   0xFD0000           dirty_bits[7:0] (slot N is dirty if bit N == 1)
//   0xFF0000           page_reg (current instruction page number)

// Transaction Format
// ==================
// Master transmits 5 bytes per transaction (read or write):
//   Byte 0: Command (0x02 for write, 0x03 for read)
//   Byte 1: Address[23:16]
//   Byte 2: Address[15:8]
//   Byte 3: Address[7:0]
//   Byte 4: Data (master drives on write, slave drives on read)
//
// The slave samples io_i on SCK rising edges and decodes the cmd/addr after
// byte 3. For reads it then drives io_o during byte 4. CS_N must be held
// low across all 5 bytes and raised between transactions so the slave's
// internal byte counter resets cleanly.

// Paging Protocol
// ===============
// 1. CPU executes code from iRAM (8 instructions, PC 0..7)
// 2. After the slot-7 instruction finishes executing:
//    - page_interrupt asserts on uo_out[0] for 1 cycle
//    - CPU halts in ST_PAGE_REQ state; is_halted goes high
// 3. External FPGA sees page_interrupt and (optionally) reads page_reg
//    via OSPI read of 0xFF0000 to know which page just finished.
// 4. FPGA reads dirty_bits at 0xFD0000. For each bit N set, the FPGA must
//    read iRAM slot N (OSPI read of 0x00000{N*2+0} for LO and 0x00000{N*2+1}
//    for HI) and write both bytes back to external DRAM at offset
//    (current_page * 16 + slot * 2 + byte_idx).
// 5. FPGA asserts page_loading on ui_in[3] (tells CPU: loading in progress)
// 6. FPGA loads 8 instructions via OSPI WRITE transactions. each slot needs
//    TWO writes:
//      for slot in 0..7:
//        write LO byte to addr 0x00000{slot*2+0}
//        write HI byte to addr 0x00000{slot*2+1}
//    (the HI write is what actually commits the slot into iRAM.)
// 7. FPGA pulses page_done on ui_in[2] (tells CPU: new page ready)
// 8. CPU resumes execution at PC=0 with the new page loaded

// Data Memory Protocol
// ====================
// When the CPU executes LDA abs / STA / etc., it raises uo_out[3] (data_req).
// The FPGA must:
//   1. OSPI-read 0xFE0000 to get the rw flag (0=read, 1=write)
//   2. OSPI-read 0xFE0001 and 0xFE0002 to get the 16-bit target address
//   3. If rw=1: OSPI-read 0xFE0003 to get the byte to write; perform the
//      write in external DRAM; then OSPI-write 0xFE0100 with any byte to
//      acknowledge (the value is loaded into cpu_mem_rdata but ignored
//      by the CPU on writes).
//      If rw=0: read the byte from external DRAM, then OSPI-write 0xFE0100
//      with that byte. This pulses cpu_mem_ready for 1 cycle and unblocks
//      the CPU.
// The CPU drives addr/rw/wdata live the entire time it's stalled, so no
// snapshot is needed — just read them when ready.

// Reference Implementation
// =========================
//   ospi_master.v      — transactional OSPI master with req / ack handshake.
//                        hides the 5-byte burst and SCK toggling.
//   page_controller.v  — sits on top of ospi_master and implements the
//                        page-swap and data-memory protocols against a
//                        local program and data backing store.

// Implementation Notes
// ====================
// 1. ospi_master.v drives SCK and CS_N at SCK_DIV clk cycles per half-period.
//    increase SCK_DIV if your synth fmax forces a slower OSPI rate.
// 2. The chip's slave samples io_i in the chip's local clock domain, so
//    keeping SCK significantly slower than clk is necessary. clk:SCK ratio
//    of 8:1 (SCK_DIV=4) is sane and validated in simulation.
// 3. The two paths (page swap, data request) can be interleaved freely —
//    page_controller.v gives page swap priority because it unblocks all
//    future fetches; a stalled data_req only blocks one cpu instruction.
