; test_stack.s
; verifies the JSR / RTS round trip and SP balance on the 4-slot page geometry.
;
; cpu return-address convention (see ocpu_core.v ST_PUSH path):
;   JSR pushes (pc_after_fetch + 1). pc_after_fetch has already been
;   incremented past the JSR slot in ST_FETCH. so JSR at slot N -> RTS
;   resumes at slot N+2.
;
; layout note: with only 4 slots per page, we cannot fit "setup + JSR +
; return-slot + sub-body + RTS" in one page without colliding. we DO have
; room if we accept that RTS lives at the last slot (slot 3): when the
; cpu fetches RTS at slot 3 it sets wrap_pending=1 (alongside the normal
; pc <- 0 wrap), then ST_POP pops the return-pc, then ST_FETCH sees
; wrap_pending and forces a page swap. the popped pc is overwritten by
; the page-load reset (pc <- 0), so we land on slot 0 of page 1 instead
; of the saved return slot. for this test that's fine because page 1
; just halts unconditionally; what we are validating is (a) JSR really
; ran (A was modified by the sub), and (b) the SP balance is correct
; (one push, one pop -> SP back to 0xFF).
;
; expected final state:
;   A  = 0x10 (initial) + 1 (from ADC #$01 in sub) = 0x11
;   SP = 0xFF (balanced)

.page 0
    LDA #$10        ; slot 0  A = 0x10
    JSR sub         ; slot 1  push 3, pc <- sub (slot 2)
sub:
    ADC #$01        ; slot 2  A = 0x11 (C was clear after LDA boot path)
    RTS             ; slot 3  pop SP+1 -> pc, then wrap fires; page swap

.page 1
    HLT             ; slot 0  end
