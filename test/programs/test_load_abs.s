; test_load_abs.s
; exercises absolute loads for X / Y and absolute stores for X / Y.
;
; preload dram[0x10] = 0xAA, dram[0x11] = 0xBB.
; program:
;   LDX $10   -> X = 0xAA
;   LDY $11   -> Y = 0xBB
;   STX $20   -> dram[0x20] = 0xAA
;   STY $21   -> dram[0x21] = 0xBB
;   LDA #$CC
;   HLT

.data $0010
    .byte $AA, $BB

.page 0
    LDX $10         ; slot 0  X <- dram[0x10] = 0xAA
    LDY $11         ; slot 1  Y <- dram[0x11] = 0xBB
    STX $20         ; slot 2  dram[0x20] = 0xAA
    STY $21         ; slot 3  dram[0x21] = 0xBB         (page wraps)

.page 1
    LDA #$CC        ; slot 0
    HLT             ; slot 1
