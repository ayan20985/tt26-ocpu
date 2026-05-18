; test_smod.s
; verifies SMOD writes the cpu's accumulator into the LOW byte of the
; targeted iram slot. with the dirty-bit FFs removed for area, the test
; reads the slot's memory cell directly (via dut.iram.mem[N]) instead of
; consulting a dirty-bits vector.
;
; SMOD slot 2 -> iram[2][7:0] <- A. with A=0xAB the cocotb test then
; asserts dut.iram.mem[2] & 0xFF == 0xAB.

.page 0
    LDA #$AB        ; slot 0  A = 0xAB
    SMOD 2, $00     ; slot 1  iram[2][7:0] <- A
    HLT             ; slot 2
