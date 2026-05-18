; test_lda_imm.s
; load-immediate into A/X/Y; final state checks register values and N flag.
; final SR.N should be 1 because the last LDY puts 0x80 (negative) into Y.

.page 0
    LDA #$42        ; slot 0  A = 0x42
    LDX #$10        ; slot 1  X = 0x10
    LDY #$80        ; slot 2  Y = 0x80  (N=1, Z=0)
    HLT             ; slot 3
