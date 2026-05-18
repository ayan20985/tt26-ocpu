; test_lda_imm.s
; load-immediate into A/X/Y; final state checks register values and N flag.
; final SR.N should be 1 because the last LDY puts 0x80 (negative) into Y.

.page 0
    LDA #$42        ; A = 0x42
    LDX #$10        ; X = 0x10
    LDY #$80        ; Y = 0x80  (N=1, Z=0)
    HLT
