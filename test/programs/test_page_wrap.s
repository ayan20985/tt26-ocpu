; test_page_wrap.s
; verifies the page-load handshake. page 0 sets A and runs out the clock
; with NOPs so the cpu wraps to page 1, which stores A to dram[0x50] and
; halts. checking dram[0x50] = 0x5A confirms page 1 actually loaded.

.page 0
    LDA #$5A        ; slot 0  A = 0x5A
    NOP             ; slot 1
    NOP             ; slot 2
    NOP             ; slot 3  page wrap fires here

.page 1
    STA $50         ; slot 0  dram[0x0050] = 0x5A
    HLT             ; slot 1
