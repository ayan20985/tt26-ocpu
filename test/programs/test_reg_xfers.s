; test_reg_xfers.s
; exercises TXA, TAY, TYA, DEX, INY.
;
; sequence:
;   LDX #$33 -> X = 0x33
;   TXA       -> A = 0x33
;   TAY       -> Y = 0x33
;   LDA #$55 -> A = 0x55
;   TYA       -> A = 0x33  (copy back)
;   DEX       -> X = 0x32
;   INY       -> Y = 0x34
; expected: A=0x33, X=0x32, Y=0x34

.page 0
    LDX #$33        ; slot 0
    TXA             ; slot 1  A = 0x33
    TAY             ; slot 2  Y = 0x33
    LDA #$55        ; slot 3
    TYA             ; slot 4  A = 0x33
    DEX             ; slot 5  X = 0x32
    INY             ; slot 6  Y = 0x34
    HLT             ; slot 7
