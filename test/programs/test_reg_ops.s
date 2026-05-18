; test_reg_ops.s
; verifies TAX/INX/DEY flag updates.
; final state: A=0x7F, X=0x80, Y=0x00, SR.N=1 (set by the INX that crossed
; the 0x7F -> 0x80 boundary, which was the most recent flag-touching op).

.page 0
    LDY #$01        ; Y = 0x01
    DEY             ; Y = 0x00, Z=1, N=0
    LDA #$7F        ; A = 0x7F
    TAX             ; X = 0x7F, flags from A: N=0, Z=0
    INX             ; X = 0x80, N=1, Z=0
    HLT
