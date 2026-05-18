; test_indy.s
; LDA (zp),Y dereferences a 16-bit pointer stored at the zero page slot
; (here at addr 0x0020), then adds Y to it, and loads the resulting byte.
;
; pointer table (data_page = 0):
;   dram[0x0020] = 0x40   ; pointer low
;   dram[0x0021] = 0x00   ; pointer high     -> base addr 0x0040
;   dram[0x0042] = 0xCC   ; (base + Y=2)
; expected: A = 0xCC

.data $0020
    .byte $40, $00          ; little-endian 16-bit pointer to 0x0040
.data $0042
    .byte $CC               ; target byte at (base + 2)

.page 0
    LDY #$02                ; slot 0  Y = 2
    LDA ($20),Y             ; slot 1  A = dram[ dram[0x20..0x21] + Y ] = 0xCC
    HLT                     ; slot 2
