; test_branch_full.s
; exercises BEQ, BPL, BMI, BNE; counts taken branches in X.
;
; expected: 4 taken branches -> X = 4.

.page 0
    LDX #$00        ; slot 0  X = 0
    LDA #$00        ; slot 1  Z = 1, N = 0
    BEQ t1          ; slot 2  taken (Z=1)
    NOP             ; slot 3  skipped
t1: INX             ; slot 4  X = 1
    BPL t2          ; slot 5  taken (N=0 from prior LDA)
    NOP             ; slot 6  skipped
t2: INX             ; slot 7  X = 2 -- page wraps

.page 1
    LDA #$80        ; slot 0  N = 1
    BMI t3          ; slot 1  taken (N=1)
    NOP             ; slot 2  skipped
t3: INX             ; slot 3  X = 3
    BNE t4          ; slot 4  taken (Z=0 because X was set to non-zero)
    NOP             ; slot 5  skipped
t4: INX             ; slot 6  X = 4
    HLT             ; slot 7
