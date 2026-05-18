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
; note: PLA must NOT live at the last slot of a page (the page-wrap
; would clobber the post-pop ST_FETCH). slot 0 of page 1 is safe.

.page 0
    LDA #$7B        ; slot 0
    PHA             ; slot 1  push A
    LDA #$00        ; slot 2  clobber A
    NOP             ; slot 3  filler                      (page wraps)

.page 1
    PLA             ; slot 0  pop -> A = 0x7B
    HLT             ; slot 1
