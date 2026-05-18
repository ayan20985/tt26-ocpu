; test_branch.s
; three taken forward branches (BEQ, BCS, BCC), each skipping a HLT sentinel.
; final X counts the number of taken branches (expected = 3).
;
; layout note: with 4-slot pages, the only viable single-skip pattern is
; "<set-flag>; BR* tgt; HLT-sentinel; tgt: <work>" with the target at
; slot 3 of the current page (offset = 1). after the work slot fires,
; the page wraps naturally and the next page sets up the following test.

.page 0
    LDA #$00        ; slot 0  set Z=1
    BEQ b1          ; slot 1  taken (Z=1), skip slot 2
    HLT             ; slot 2  sentinel; never executed if branch worked
b1: INX             ; slot 3  X = 1  (page wraps after this slot)

.page 1
    SEC             ; slot 0  C = 1
    BCS b2          ; slot 1  taken (C=1), skip slot 2
    HLT             ; slot 2  sentinel
b2: INX             ; slot 3  X = 2  (page wraps after this slot)

.page 2
    CLC             ; slot 0  C = 0
    BCC b3          ; slot 1  taken (C=0), skip slot 2
    HLT             ; slot 2  sentinel
b3: INX             ; slot 3  X = 3  (page wraps after this slot)

.page 3
    HLT             ; slot 0  final stop
