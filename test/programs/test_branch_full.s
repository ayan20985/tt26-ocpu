; test_branch_full.s
; exercises BEQ, BPL, BMI, BNE; counts taken branches in X.
;
; expected: 4 taken branches -> X = 4.
;
; layout: same sentinel-skip pattern as test_branch.s
; ("<set-flag>; BR* tgt; HLT-sentinel; tgt: INX") repeated four times,
; one branch per page. with 4-slot pages we need 4 branch pages + a
; final HLT page.

.page 0
    LDA #$00        ; slot 0  Z=1, N=0
    BEQ t1          ; slot 1  taken (Z=1), skip slot 2
    HLT             ; slot 2  sentinel
t1: INX             ; slot 3  X = 1                      (page wraps)

.page 1
    LDA #$01        ; slot 0  Z=0, N=0  (need a non-zero, non-negative)
    BPL t2          ; slot 1  taken (N=0), skip slot 2
    HLT             ; slot 2  sentinel
t2: INX             ; slot 3  X = 2                      (page wraps)

.page 2
    LDA #$80        ; slot 0  N=1
    BMI t3          ; slot 1  taken (N=1), skip slot 2
    HLT             ; slot 2  sentinel
t3: INX             ; slot 3  X = 3                      (page wraps)

.page 3
    LDA #$01        ; slot 0  Z=0
    BNE t4          ; slot 1  taken (Z=0), skip slot 2
    HLT             ; slot 2  sentinel
t4: INX             ; slot 3  X = 4                      (page wraps)

.page 4
    HLT             ; slot 0  final stop
