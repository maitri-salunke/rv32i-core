// console_sim.c - putchar for tb_core: a store to 0x1000_0000 is printed by the testbench.
int putchar(int c) { *(volatile unsigned *)0x10000000u = (unsigned)c; return c; }
