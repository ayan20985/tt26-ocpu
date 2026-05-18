; test_reg_xfers.s
; exercises TXA, TAY, TYA, DEX, INY.
;
; sequence:
;   LDX #$33 -> X = 0x33
;   TXA       -> A = 0x33
;   TAY       -> Y = 0x33
;   LDA #$55 -> A = 0x55
;   TYA       -> A = 0x33
;   DEX       -> X = 0x32
;   INY       -> Y = 0x34
; expected: A=0x33, X=0x32, Y=0x34

.page 0
    LDX #$33        ; slot 0
    TXA             ; slot 1  A = 0x33
    TAY             ; slot 2  Y = 0x33
    LDA #$55        ; slot 3  A = 0x55                   (page wraps)

.page 1
    TYA             ; slot 0  A = 0x33
    DEX             ; slot 1  X = 0x32
    INY             ; slot 2  Y = 0x34
    HLT             ; slot 3
