; test_indexed.s
; exercises LDA abs,X and STA abs,X with X = 2.
;
; preload dram[0x0032] = 0xDE.
; program:
;   LDX #$02      ; X = 2
;   LDA $30,X     ; A = dram[0x30 + 2] = 0xDE
;   STA $40,X     ; dram[0x42] = 0xDE
;   HLT

.data $0032
    .byte $DE

.page 0
    LDX #$02        ; slot 0
    LDA $30,X       ; slot 1  A = dram[0x32] = 0xDE
    STA $40,X       ; slot 2  dram[0x42] = 0xDE
    HLT             ; slot 3
