; sample 6502 input for translator smoke test
; (handwritten ca65 syntax)

main:
    LDA #$05
    STA $40
    LDX #$00
loop:
    INC $40
    INX
    CPX #$04
    BNE loop
    RTS
