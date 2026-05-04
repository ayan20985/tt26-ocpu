<!---
This file is used to generate your project datasheet. Please fill in the information below and delete any unused sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than 512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## desc
quick and dirty repo at the LatchUp Conference, will refurbish repo for a proper submission.

## minimized MIPS-adjacent OCPU instruction set
the instruction set of the minimized MIPS-adjacent cpu is as follows:

0000 ldi imm      ; load immediate value into accumulator (a = imm)
0001 lda addr     ; load accumulator from memory (a = memory[addr])
0010 sta addr     ; store accumulator to memory (memory[addr] = a)
0011 lda [addr]   ; load accumulator from indirect address (a = memory[memory[addr]])
0100 sta [addr]   ; store accumulator to indirect address (memory[memory[addr]] = a)
0101 add addr     ; add memory to accumulator (a = a + memory[addr])
0110 adc addr     ; add memory and carry to accumulator (a = a + memory[addr] + carry)
0111 nand addr    ; bitwise nand accumulator and memory (a = ~(a & memory[addr]))
1000 shr          ; shift accumulator right by 1 bit
1001 jmp addr     ; jump to address
1010 jz addr      ; jump if accumulator is zero
1011 jc addr      ; jump if carry flag is set
1100 call addr    ; call subroutine (push pc, jump to addr)
1101 ret          ; return from subroutine (pop pc)
1110 push         ; push accumulator to stack
1111 pop          ; pop from stack to accumulator

## minimized 6502 OCPU instruction set (CISC)
this 8-bit opcode instruction set is heavily paired-down but explicitly mapped to the core 6502 architecture. by including the x and y registers in hardware, we natively support the 6502's indexed addressing modes, which are heavily used by C compilers for arrays and pointers.

memory & immediate operations:
- `lda #imm` / `ldx #imm` / `ldy #imm`  ; load immediate (a/x/y = imm)
- `lda addr` / `ldx addr` / `ldy addr`  ; load from memory
- `sta addr` / `stx addr` / `sty addr`  ; store to memory
- `lda addr,x` / `sta addr,x`           ; absolute x-indexed (target = addr + x)
- `lda (addr),y` / `sta (addr),y`       ; indirect y-indexed (target = memory[addr] + y)

alu (math & logic):
- `adc addr`     ; add with carry (a = a + memory[addr] + c)
- `sbc addr`     ; subtract with carry (a = a - memory[addr] - !c)
- `and addr`     ; bitwise and (a = a & memory[addr])
- `eor addr`     ; exclusive or (a = a ^ memory[addr])
- `ora addr`     ; bitwise or (a = a | memory[addr])
- `asl`          ; arithmetic shift left (shifts accumulator, pushes MSB to carry)
- `lsr`          ; logical shift right (shifts accumulator, pushes LSB to carry)
- `inx` / `dex`  ; increment / decrement x
- `iny` / `dey`  ; increment / decrement y

register transfers:
- `tax` / `txa`  ; transfer a to x / x to a
- `tay` / `tya`  ; transfer a to y / y to a

status flags & control:
- `sec` / `clc`  ; set / clear carry flag
- `sei` / `cli`  ; set / clear interrupt disable
- `page imm`     ; non-standard 6502: sets mapping page for >256B external serial memory 

control flow & subroutines:
- `jmp addr`     ; unconditional jump
- `beq addr`     ; branch on result zero (zero flag set)
- `bne addr`     ; branch on not zero (zero flag clear)
- `bcs addr`     ; branch on carry set
- `bcc addr`     ; branch on carry clear
- `jsr addr`     ; jump to subroutine (pushes PC to stack)
- `rts`          ; return from subroutine (pops PC)
- `rti`          ; return from interrupt (pops SR, then PC)
- `pha` / `pla`  ; push accumulator / pull accumulator

## features
- the programmer-visible registers include an 8-bit accumulator (a), index registers (x, y), and an 8-bit stack pointer (SP).
- the internal datapath consists of a program counter (PC), instruction register (IR), and memory data register (MDR).
- the peripheral registers include an 8-bit page register along with interrupt vector and enable registers.
- the control FSM is a multi-cycle state machine that takes advantage of the accumulator-based datapath. this drastically minimizes the sequential logic area footprint.
- the primary instruction and data memory operates externally via QSPI, SPI, or UART to conserve logic area and highly constrained ASIC pins. the FSM incorporates wait states to handle serial data fetching directly into the MDR and IR.
- the controllable target PLL behaves independently so the CPU clock speed can be dynamically governed externally to control power draw and test frequency bounds.

