; test_sp_ops.s
; exercises the stack pointer register operations:
;   LDSP #imm  -> SP = imm
;   TSX        -> X = SP
;   TXS        -> SP = X
;   STSP       -> A = SP
;
; sequence:
;   LDSP #$80      ; SP = 0x80
;   TSX            ; X = 0x80
;   LDX #$40       ; X = 0x40
;   TXS            ; SP = 0x40
;   STSP           ; A = 0x40
; expected: A = 0x40, X = 0x40, SP = 0x40

.page 0
    LDSP #$80       ; slot 0  SP = 0x80
    TSX             ; slot 1  X = 0x80
    LDX #$40        ; slot 2  X = 0x40
    TXS             ; slot 3  SP = 0x40                  (page wraps)

.page 1
    STSP            ; slot 0  A = 0x40
    HLT             ; slot 1
