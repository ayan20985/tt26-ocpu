; sample 6502 program for the translator pipeline end-to-end test.
; deliberately tiny so the microcode expansion still fits in one OCPU
; page (8 slots). exercises immediate, store, INC (microcoded), BRK->HLT.
;
; behaviour:
;   dram[0x40] starts at 0
;   incremented once via INC -> dram[0x40] = 1
;   halts.

main:
    LDA #$00
    STA $40                 ; dram[0x40] = 0
    INC $40                 ; (microcoded as LDA / ADC / STA) -> 1
    BRK
