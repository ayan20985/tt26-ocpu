; test_alu_imm.s
; immediate-mode ALU chain: ADD, AND, ORA, EOR.
; final A = (((0x05 + 0x03) & 0x0F) | 0x80) ^ 0x01 = 0x89

.page 0
    LDA #$05        ; A = 0x05
    ADD #$03        ; A = 0x08
    AND #$0F        ; A = 0x08  (mask kept low nibble)
    ORA #$80        ; A = 0x88  (set sign bit)
    EOR #$01        ; A = 0x89  (flip lsb)
    HLT
