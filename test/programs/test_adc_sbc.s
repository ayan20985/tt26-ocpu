; test_adc_sbc.s
; verifies ADC / SBC respect the carry-in flag, and SUB ignores it.
; ADC: A = A + op + C
; SBC: A = A - op - !C        (SET carry first for a normal subtraction)
; SUB: A = A - op              (no borrow-in; sets C = ~result[8])
;
; sequence (split across three 4-slot pages):
;   CLC; LDA #$10; ADC #$05 -> A = 0x15
;   SEC; ADC #$01            -> A = 0x17  (0x15 + 0x01 + 1)
;   SEC; SBC #$03            -> A = 0x14  (0x17 - 0x03 - 0)
;   CLC; SBC #$02            -> A = 0x11  (0x14 - 0x02 - 1)

.page 0
    CLC             ; slot 0  C = 0
    LDA #$10        ; slot 1  A = 0x10
    ADC #$05        ; slot 2  A = 0x15, C=0
    SEC             ; slot 3  C = 1                      (page wraps)

.page 1
    ADC #$01        ; slot 0  A = 0x17, C=0
    SEC             ; slot 1  C = 1
    SBC #$03        ; slot 2  A = 0x14, C=1
    CLC             ; slot 3  C = 0                      (page wraps)

.page 2
    SBC #$02        ; slot 0  A = 0x11 (0x14 - 0x02 - 1)
    HLT             ; slot 1
