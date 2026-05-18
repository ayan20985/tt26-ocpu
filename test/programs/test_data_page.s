; test_data_page.s
; verifies LDA_DP / STA_DP - switching the high byte of the 16-bit data
; address used by abs / abs,X / (zp),Y loads and stores.
;
; preload dram[0x0044] = 0x11 and dram[0x0244] = 0x22.
; program:
;   LDA #$00; STA_DP    ; data_page = 0
;   LDA $44             ; A = dram[0x0044] = 0x11
;   LDA #$02; STA_DP    ; data_page = 2
;   LDA $44             ; A = dram[0x0244] = 0x22
;   LDA_DP              ; A = data_page = 0x02
;   HLT
; expected: A = 0x02

.data $0044
    .byte $11
.data $0244
    .byte $22

.page 0
    LDA #$00        ; slot 0
    STA_DP          ; slot 1  data_page = 0
    LDA $44         ; slot 2  A = 0x11
    LDA #$02        ; slot 3  (page wraps)

.page 1
    STA_DP          ; slot 0  data_page = 2
    LDA $44         ; slot 1  A = 0x22 (from page 2)
    LDA_DP          ; slot 2  A = data_page = 0x02
    HLT             ; slot 3
