; test_load_store.s
; round-trip a byte through the dram model: store 0x37 to addr 0x0042,
; read it back, increment, store to 0x0043. final A = 0x38.
; data_page resets to 0 so abs addresses use {0x00, imm}.

.page 0
    LDA #$37        ; A = 0x37
    STA $42         ; dram[0x0042] = 0x37
    LDA $42         ; A = dram[0x0042] = 0x37
    ADD #$01        ; A = 0x38
    STA $43         ; dram[0x0043] = 0x38
    HLT
