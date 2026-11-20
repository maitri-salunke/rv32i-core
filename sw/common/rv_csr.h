#ifndef RV_CSR_H
#define RV_CSR_H
#define read_csr(reg) ({ unsigned long __v; __asm__ volatile ("csrr %0, " #reg : "=r"(__v)); __v; })
#define write_csr(reg, val) ({ __asm__ volatile ("csrw " #reg ", %0" :: "rK"(val)); })
#define set_csr(reg, bit) ({ unsigned long __v; __asm__ volatile ("csrrs %0, " #reg ", %1" : "=r"(__v) : "rK"(bit)); __v; })
#endif
