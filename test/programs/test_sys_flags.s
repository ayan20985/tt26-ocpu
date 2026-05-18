; test_sys_flags.s
; verifies SEC / CLC / SEI / CLI affect SR bits directly.
; SR bit layout (per ocpu_core.v reg [4:0] sr):
;   [0] = C, [1] = Z, [2] = N, [3] = unused, [4] = I
;
; sequence:
;   SEC -> C=1
;   SEI -> I=1
;   CLC -> C=0
;   (I still 1)
; final SR has I=1, C=0.

.page 0
    SEC             ; slot 0  C = 1
    SEI             ; slot 1  I = 1
    CLC             ; slot 2  C = 0
    HLT             ; slot 3
