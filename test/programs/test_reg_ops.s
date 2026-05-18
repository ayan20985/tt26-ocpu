; test_reg_ops.s
; verifies TAX/INX/DEY flag updates.
; final state: A=0x7F, X=0x80, Y=0x00, SR.N=1 (set by the INX that crossed
; the 0x7F -> 0x80 boundary, which was the most recent flag-touching op).

.page 0
    LDY #$01        ; slot 0  Y = 0x01
    DEY             ; slot 1  Y = 0x00, Z=1, N=0
    LDA #$7F        ; slot 2  A = 0x7F
    TAX             ; slot 3  X = 0x7F, flags from A: N=0, Z=0 (page wraps)

.page 1
    INX             ; slot 0  X = 0x80, N=1, Z=0
    HLT             ; slot 1
