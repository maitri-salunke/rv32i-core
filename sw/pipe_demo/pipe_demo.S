# pipe_demo.S - a short program for the pipeline diagram (scripts/pipeview.py).
# One loop, two iterations, chosen to show each hazard mechanism once per pass:
#   addi -> bne on x1      : RAW served by MEM->EX forwarding (no stall)
#   lw x3 -> add x4,x3,..  : load-use, 1-cycle stall + EX bubble, then WB->EX
#   bne (backward)         : predicted taken in ID (1 squashed fetch);
#                            on the last pass it falls through, so EX corrects
#                            the prediction (2 squashed instructions)
  .section .text.init
  .globl _start
_start:
  auipc x5, 0
  addi  x1, x0, 2           # loop counter
loop:
  lw    x3, 64(x5)          # load
  add   x4, x3, x1          # load-use on x3
  addi  x1, x1, -1
  bne   x1, x0, loop        # RAW on x1 (forwarded from MEM); backward branch
  addi  x6, x0, 1
  la    x7, tohost
  sw    x6, 0(x7)           # tohost = 1 -> PASS
1:j     1b

  .section .tohost, "aw"
  .align 6
  .globl tohost
tohost: .word 0
