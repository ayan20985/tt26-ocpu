; test_alu_mem.s
; exercises ALU operations against a memory operand (data_page = 0,
; operand address = imm). preloads dram[0x20] = 0x33 and runs a
; sequence of ALU ops; final A = 0x00, Z=1 (after EOR).

.data $0020
    .byte $33

.page 0
    LDA #$05        ; slot 0  A = 0x05
    ADD $20         ; slot 1  A = 0x05 + 0x33 = 0x38
    AND $20         ; slot 2  A = 0x38 & 0x33 = 0x30
    ORA $20         ; slot 3  A = 0x30 | 0x33 = 0x33     (page wraps)

.page 1
    EOR $20         ; slot 0  A = 0x33 ^ 0x33 = 0x00
    HLT             ; slot 1
