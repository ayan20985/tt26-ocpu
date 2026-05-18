; test_smod.s
; verifies SMOD sets the dirty bit of the targeted iram slot.
; the iram regfile always sets bit[16] (dirty) on a CPU write regardless
; of the byte value, so we just have to ensure SMOD executes targeting
; slot 4. the cocotb test then reads dirty_bits and asserts bit 4 = 1.

.page 0
    LDA #$AB        ; A = 0xAB
    SMOD 4, $00     ; iram[4][7:0] <- A; dirty_bits[4] becomes 1
    HLT
