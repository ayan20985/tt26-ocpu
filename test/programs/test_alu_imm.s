; test_alu_imm.s
; immediate-mode ALU chain: ADD, AND, ORA, EOR. spans two 4-slot pages,
; relying on natural page wrap between page 0 and page 1.
; final A = (((0x05 + 0x03) & 0x0F) | 0x80) ^ 0x01 = 0x89

.page 0
    LDA #$05        ; slot 0  A = 0x05
    ADD #$03        ; slot 1  A = 0x08
    AND #$0F        ; slot 2  A = 0x08  (mask kept low nibble)
    ORA #$80        ; slot 3  A = 0x88  (set sign bit; page wraps here)

.page 1
    EOR #$01        ; slot 0  A = 0x89  (flip lsb)
    HLT             ; slot 1
