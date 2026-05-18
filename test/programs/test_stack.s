; test_stack.s
; verifies the JSR / RTS round trip and SP balance.
;
; cpu return-address convention (see ocpu_core.v ST_PUSH path):
;   JSR pushes (pc_after_fetch + 1), and pc_after_fetch has already been
;   incremented past the JSR slot. so JSR at slot N -> RTS resumes at
;   slot N+2 (one NOP slot is "skipped").
;
; layout note: RTS MUST NOT live at slot 7. slot 7 instructions always
; trigger a page-swap after they execute (the `wrap_pending` flag is set
; in ST_FETCH and re-evaluated when ST_FETCH next runs, which after RTS
; lands BEFORE the returned-to slot fetches). so we put the subroutine
; at slots 5..6 with HLT at slot 3, leaving slot 7 free for padding.
;
; expected final state:
;   A  = 0x10 (initial) + 1 (from ADC #$01) = 0x11
;   SP = 0xFF (balanced: one JSR push, one RTS pop)

.page 0
    LDA #$10        ; slot 0  A = 0x10
    JSR sub         ; slot 1  call; pushes 3; return lands on slot 3
    NOP             ; slot 2  skipped on return
    HLT             ; slot 3  done after sub returns
    NOP             ; slot 4  padding
sub:
    ADC #$01        ; slot 5  A += 1 (C is clear at boot)
    RTS             ; slot 6  pop saved pc -> pc = 3
    NOP             ; slot 7  padding; never executed
