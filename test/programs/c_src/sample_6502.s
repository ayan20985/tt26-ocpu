; sample 6502 program for the translator pipeline end-to-end test.
; the INC microcode expansion (LDA / ADC / STA) plus the surrounding ops
; spills past one 4-slot OCPU page, so the auto-pager in translate_6502.py
; will insert page boundaries automatically. exercises immediate, store,
; INC (microcoded), BRK->HLT.
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
