; test_sta_indy.s
; verifies STA (zp),Y. pointer table at 0x0030 holds {0x50, 0x00} which
; resolves to base address 0x0050; with Y=3 the store targets 0x0053.

.data $0030
    .byte $50, $00          ; little-endian pointer to 0x0050

.page 0
    LDY #$03                ; slot 0  Y = 3
    LDA #$77                ; slot 1  A = 0x77
    STA ($30),Y             ; slot 2  dram[ dram[0x30..0x31] + Y ] = 0x77
    HLT                     ; slot 3
