// soc_test.c - SoC smoke test: APB UART (TX + internal loopback RX) and the
// APB timer interrupt through mip.MTIP -> trap -> handle_trap -> mret.
#include <stdio.h>
#include <stdint.h>
#include "rv_csr.h"

#define UART_BASE 0x10000000u
#define TMR_BASE  0x10001000u
#define REG(a)    (*(volatile uint32_t *)(a))
#define UART_DATA REG(UART_BASE + 0x00)
#define UART_STAT REG(UART_BASE + 0x04)
#define UART_CTRL REG(UART_BASE + 0x08)
#define UART_BAUD REG(UART_BASE + 0x0C)
#define TMR_COUNT REG(TMR_BASE + 0x0)
#define TMR_CMP   REG(TMR_BASE + 0x4)
#define TMR_CTRL  REG(TMR_BASE + 0x8)

#define ST_TX_FULL  (1u << 0)
#define ST_TX_EMPTY (1u << 1)
#define ST_RX_EMPTY (1u << 3)
#define ST_TX_BUSY  (1u << 4)

static void uart_drain(void) {
  while (!(UART_STAT & ST_TX_EMPTY) || (UART_STAT & ST_TX_BUSY)) ;
}

int putchar(int c) {
  while (UART_STAT & ST_TX_FULL) ;
  UART_DATA = (uint32_t)c;
  return c;
}

static volatile int ticks;
#define PERIOD 2000

uintptr_t handle_trap(uintptr_t mcause, uintptr_t mepc) {
  if (mcause == 0x80000007u) {           // machine timer interrupt
    ticks++;
    TMR_CMP = TMR_CMP + PERIOD;          // re-arm (also clears MATCH)
    return mepc;                         // interrupted insn did not execute
  }
  printf("unexpected trap %x at %x\n", mcause, mepc);
  return mepc + 4;
}

int main(void) {
  int errors = 0;
  UART_BAUD = 0;                          // 16 clocks per bit (fast sim)
  printf("rv32i_core SoC: hello over APB UART\n");

  // UART internal loopback: TX -> RX. LOOPBACK forces the txd pin high, so
  // let the pending text finish first and flush the RX FIFO.
  uart_drain();
  UART_CTRL = 0x13 | (1u << 9);           // TX_EN | RX_EN | LOOPBACK | RX_CLR
  const char *msg = "LOOP";
  for (int i = 0; msg[i]; i++) {
    UART_DATA = (uint32_t)msg[i];
    while (UART_STAT & ST_RX_EMPTY) ;
    uint32_t r = UART_DATA;
    if (r != (uint32_t)msg[i]) errors++;
  }
  uart_drain();
  UART_CTRL = 0x03;                       // loopback off
  printf("loopback: %d errors\n", errors);

  // Timer: counter advances, compare interrupt fires repeatedly
  TMR_CTRL = 0;
  TMR_COUNT = 0;
  TMR_CMP = PERIOD;
  TMR_CTRL = 0x3;                         // EN | IRQ_EN, prescale 0
  uint32_t c0 = TMR_COUNT, c1 = TMR_COUNT;
  if (c1 <= c0) errors++;
  set_csr(mie, 1u << 7);                  // MTIE
  set_csr(mstatus, 1u << 3);              // MIE
  while (ticks < 5) ;
  TMR_CTRL = 0;
  printf("timer: %d interrupts, count=%u\n", ticks, TMR_COUNT);

  printf(errors ? "SOC TEST FAIL\n" : "SOC TEST PASS\n");
  uart_drain();
  return errors;
}
