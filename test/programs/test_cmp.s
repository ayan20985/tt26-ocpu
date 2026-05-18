; test_cmp.s
; verifies CMP # (immediate) sets only flags, not A.
; CMP computes (A - operand) but writes flags only:
;   Z = (A == operand)
;   C = (A >= operand)         (no borrow)
;   N = result bit 7
;
; sequence:
;   A = 0x50
;   CMP #$50   -> Z=1, C=1, N=0  ; A unchanged
;   CMP #$40   -> Z=0, C=1, N=0  ; A > op
;   CMP #$60   -> Z=0, C=0, N=1  ; A < op (result 0x50-0x60 = 0xF0)
; final flags reflect the last CMP (Z=0, C=0, N=1) and A=0x50.

.page 0
    LDA #$50        ; A = 0x50
    CMP #$50        ; Z=1, C=1, N=0
    CMP #$40        ; Z=0, C=1, N=0
    CMP #$60        ; Z=0, C=0, N=1 -- last flag state
    HLT
