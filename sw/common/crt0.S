# crt0.S - bare-metal start-up for rv32i_core programs.
# Sets up sp/gp, clears .bss, installs trap_entry, calls main(), then reports
# main's return value through tohost: tohost = (ret << 1) | 1 (riscv-tests style).
    .section .text.init
    .globl _start
_start:
    la   sp, __stack_top
    .option push
    .option norelax
    la   gp, __global_pointer$
    .option pop
    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  la   t0, trap_entry
    csrw mtvec, t0
    call main
    slli a0, a0, 1
    ori  a0, a0, 1
    la   t0, tohost
    sw   a0, 0(t0)
3:  j    3b

# Trap entry: save caller-saved registers, call handle_trap(mcause, mepc),
# which returns the PC to resume at.
    .align 2
    .globl trap_entry
trap_entry:
    addi sp, sp, -64
    sw ra,  0(sp);  sw t0,  4(sp);  sw t1,  8(sp);  sw t2, 12(sp)
    sw a0, 16(sp);  sw a1, 20(sp);  sw a2, 24(sp);  sw a3, 28(sp)
    sw a4, 32(sp);  sw a5, 36(sp);  sw a6, 40(sp);  sw a7, 44(sp)
    sw t3, 48(sp);  sw t4, 52(sp);  sw t5, 56(sp);  sw t6, 60(sp)
    csrr a0, mcause
    csrr a1, mepc
    call handle_trap
    csrw mepc, a0
    lw ra,  0(sp);  lw t0,  4(sp);  lw t1,  8(sp);  lw t2, 12(sp)
    lw a0, 16(sp);  lw a1, 20(sp);  lw a2, 24(sp);  lw a3, 28(sp)
    lw a4, 32(sp);  lw a5, 36(sp);  lw a6, 40(sp);  lw a7, 44(sp)
    lw t3, 48(sp);  lw t4, 52(sp);  lw t5, 56(sp);  lw t6, 60(sp)
    addi sp, sp, 64
    mret

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .align 6
    .globl fromhost
fromhost: .dword 0
