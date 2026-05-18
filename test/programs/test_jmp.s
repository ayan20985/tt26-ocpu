; test_jmp.s
; verifies intra-page JMP. without JMP, slot 2 would set A to 0xFF.
; jumping over slot 2 keeps A at the pre-jump value of 0x42.

.page 0
    LDA #$42        ; slot 0  A = 0x42
    JMP done        ; slot 1  pc <- target slot
    LDA #$FF        ; slot 2  must be skipped
done:
    HLT             ; slot 3
