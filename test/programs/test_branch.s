; test_branch.s
; three taken forward branches (BEQ, BCS, BCC), each skipping a HLT sentinel.
; final X counts the number of taken branches (expected = 3).

.page 0
    LDX #$00        ; slot 0  X = 0
    LDA #$00        ; slot 1  set Z=1
    BEQ b1          ; slot 2  taken (Z=1)
    HLT             ; slot 3  sentinel; never executed if branch worked
b1: INX             ; slot 4  X = 1
    LDA #$01        ; slot 5  set Z=0 (not needed but clears flags)
    NOP             ; slot 6
    NOP             ; slot 7  page wrap, fpga loads page 1

.page 1
    SEC             ; slot 0  C = 1
    BCS b2          ; slot 1  taken (C=1)
    HLT             ; slot 2  sentinel
b2: INX             ; slot 3  X = 2
    CLC             ; slot 4  C = 0
    BCC b3          ; slot 5  taken (C=0)
    HLT             ; slot 6  sentinel
b3: INX             ; slot 7  X = 3, page wrap

.page 2
    HLT             ; final stop
