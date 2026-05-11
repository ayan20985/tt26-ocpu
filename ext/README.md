// External FPGA Modules
// =====================
// This folder contains Verilog code for the external FPGA that communicates
// with the tt26-ocpu ASIC via the OSPI (8-bit parallel) slave interface.

// OSPI Protocol (ASIC is slave, external FPGA is master)
// ======================================================
// The external FPGA drives the OSPI interface to:
//   1. Load instruction pages into iRAM (8 instructions per page)
//   2. Monitor the page_interrupt flag (CPU finished slot 7)
//   3. Coordinate page transitions via page_done handshake
//   4. Service CPU data memory requests via address-mapped registers
//   5. Read dirty bits before page swap to know which slots to write back
//
// Pin Mapping (from ASIC perspective):
//   uio_in[0]    = SCK (serial clock from master)
//   uio_in[1]    = CS_N (chip select from master, active low)
//   uio_in[7:0]  = IO_I (data in, from master to ASIC)
//   uio_out[7:0] = IO_O (data out, from ASIC to master)
//   uio_oe[7:0]  = output enable (ASIC drives when responding to a read)
//
//   uo_out[0] = page_interrupt (1-cycle pulse: slot-7 instruction just finished)
//   uo_out[1] = page_loading   (echo of uio_in[4], confirms CPU is waiting)
//   uo_out[2] = is_halted      (CPU stalled for any reason)
//   uo_out[3] = data_req       (CPU is waiting for a data memory transaction)
//
//   uio_in[3] = page_done    (FPGA pulses high: new page loaded, resume CPU)
//   uio_in[4] = page_loading (FPGA holds high while loading a page)

// OSPI Command Bytes
// ==================
//   0x02 = WRITE (cmd + 3 addr + 1 data)
//   0x03 = READ  (cmd + 3 addr + 1 data byte clocked out by master)

// Address Space
// =============
//   0x000000–0x000007 = iRAM slot 0..7 (read/write)
//   0xFE0000          = data_req status:  bit 0 = rw flag (0=read, 1=write)
//   0xFE0001          = data_req addr_hi: cpu_mem_addr[15:8]
//   0xFE0002          = data_req addr_lo: cpu_mem_addr[7:0]
//   0xFE0003          = data_req wdata:   cpu_mem_wdata (valid only on writes)
//   0xFE0100          = data_req ACK: write rdata here to unblock CPU
//                        (data byte → cpu_mem_rdata, pulses cpu_mem_ready 1 cycle)
//   0xFD0000          = dirty_bits[7:0] (slot N is dirty if bit N == 1)
//   0xFF0000          = page_reg (current instruction page number)

// Transaction Format
// ==================
// Master transmits 5 bytes per transaction (read or write):
//   Byte 0: Command (0x02 for write, 0x03 for read)
//   Byte 1: Address[23:16]
//   Byte 2: Address[15:8]
//   Byte 3: Address[7:0]
//   Byte 4: Data (master drives on write, slave drives on read)

// Paging Protocol
// ===============
// 1. CPU executes code from iRAM (8 instructions, PC 0..7)
// 2. After the slot-7 instruction finishes executing:
//    - page_interrupt asserts on uo_out[0] for 1 cycle
//    - CPU halts in ST_PAGE_REQ state; is_halted goes high
// 3. External FPGA sees page_interrupt and (optionally) reads page_reg
//    via OSPI read of 0xFF0000 to know which page just finished.
// 4. FPGA reads dirty_bits at 0xFD0000. For each bit N set, the FPGA must
//    read iRAM slot N (OSPI read of 0x00000N) and write the byte back to
//    external DRAM at offset (current_page * 8 + N).
// 5. FPGA asserts page_loading on uio_in[4] (tells CPU: loading in progress)
// 6. FPGA loads 8 instructions via OSPI WRITE transactions:
//      for i in 0..7:
//        send WRITE command to addr 0x00000i with instruction data byte
// 7. FPGA pulses page_done on uio_in[3] (tells CPU: new page ready)
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

// Implementation Guidance
// =======================
// 1. Create an FSM that monitors page_interrupt and data_req flags from ASIC
// 2. Page swap path:
//    a. On page_interrupt: read 0xFD0000 (dirty), 0xFF0000 (current_page)
//    b. For each dirty slot, OSPI-read slot data, write to external DRAM
//    c. Set page_loading=1 on uio_in[4]
//    d. Compute next_page = current_page + 1 (or whatever the CPU requested)
//    e. For i in 0..7: OSPI-write 0x00000i with instruction byte i
//    f. Pulse page_done on uio_in[3]
// 3. Data request path:
//    a. On data_req: read 0xFE0000–0xFE0002 (rw, addr_hi, addr_lo)
//    b. If write (rw=1): also read 0xFE0003 (wdata), do write in DRAM
//       If read  (rw=0): fetch byte from DRAM
//    c. OSPI-write 0xFE0100 with the result byte (ACK)
// 4. The two paths can be interleaved — service whichever is asserted.

// Example: ospi_master.v provides a template for the page-load FSM.
// You will need to extend it with the dirty-bit writeback scan and the
// data_req servicing path described above.
