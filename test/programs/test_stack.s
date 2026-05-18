; test_stack.s
; calls a tiny "add 1 to A" subroutine twice via JSR / RTS.
;
; note on the JSR/RTS return-address convention used by the current core:
;   the core pushes (pc_after_fetch + 1), which is two slots past the JSR
;   itself. that means RTS resumes execution two slots after the JSR,
;   skipping one slot. this matches info.md ("Push PC+1 to stack") given
;   that pc has already been incremented during ST_FETCH. the inert NOP
;   slots in this program account for that skip.
;
; final A = 0x10 + 1 + 1 = 0x12, SP balanced back to 0xFF.

.page 0
    LDA #$10        ; slot 0  A = 0x10
    JSR sub         ; slot 1  call; return lands on slot 3
    NOP             ; slot 2  skipped on return (see note above)
    JSR sub         ; slot 3  call again; return lands on slot 5
    NOP             ; slot 4  skipped on return
    HLT             ; slot 5  done, A = 0x12, SP = 0xFF
sub:
    ADC #$01        ; slot 6  A += 1
    RTS             ; slot 7  pop saved pc -> resume at caller+2
