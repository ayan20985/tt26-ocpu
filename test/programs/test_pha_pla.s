; test_pha_pla.s
; pushes a value, clobbers A, then pops it back.
;
; sequence:
;   LDA #$7B  -> A = 0x7B
;   PHA        -> push 0x7B onto stack; sp = 0xFE
;   LDA #$00  -> A = 0x00 (Z=1)
;   PLA        -> A = 0x7B (popped); sp = 0xFF
; expected: A = 0x7B, SP = 0xFF (balanced)
;
; note: PLA must NOT live at slot 7 (page wrap clobbers the post-pop
; ST_FETCH). HLT at slot 7 is fine.

.page 0
    LDA #$7B        ; slot 0
    PHA             ; slot 1  push A
    LDA #$00        ; slot 2  clobber A
    PLA             ; slot 3  pop -> A = 0x7B
    NOP             ; slot 4
    NOP             ; slot 5
    NOP             ; slot 6
    HLT             ; slot 7
