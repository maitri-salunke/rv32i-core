// libc.c - the few libc routines our bare-metal programs need.
// putchar() writes to the simulation console (tb_core) or the UART (SoC),
// selected by the platform file linked in (console_sim.c / console_uart.c).
#include <stdio.h>
#include <string.h>
#include <stdint.h>

void *memcpy(void *d, const void *s, size_t n) {
  char *dp = d; const char *sp = s;
  while (n--) *dp++ = *sp++;
  return d;
}
void *memset(void *d, int c, size_t n) {
  char *dp = d;
  while (n--) *dp++ = (char)c;
  return d;
}
char *strcpy(char *d, const char *s) {
  char *r = d;
  while ((*d++ = *s++)) ;
  return r;
}
int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) { a++; b++; }
  return (unsigned char)*a - (unsigned char)*b;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

int puts(const char *s) { while (*s) putchar(*s++); putchar('\n'); return 0; }

static void put_uint(unsigned long v, unsigned base, int width, char pad) {
  char buf[12]; int i = 0;
  do { unsigned d = v % base; buf[i++] = d < 10 ? '0' + d : 'a' + d - 10; v /= base; } while (v);
  while (i < width && i < (int)sizeof buf) buf[i++] = pad;   // left pad (buf is reversed)
  while (i) putchar(buf[--i]);
}

int vprintf(const char *f, va_list ap) {
  for (; *f; f++) {
    if (*f != '%') { putchar(*f); continue; }
    f++;
    char pad = ' '; int width = 0;
    if (*f == '0') { pad = '0'; f++; }
    while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
    if (*f == 'l') f++;
    switch (*f) {
      case 'd': { long v = va_arg(ap, long);
                  if (v < 0) { putchar('-'); v = -v; width--; }
                  put_uint((unsigned long)v, 10, width, pad); break; }
      case 'u': put_uint(va_arg(ap, unsigned long), 10, width, pad); break;
      case 'x': put_uint(va_arg(ap, unsigned long), 16, width, pad); break;
      case 'c': putchar(va_arg(ap, int)); break;
      case 's': { const char *s = va_arg(ap, const char *); while (*s) putchar(*s++); break; }
      case '%': putchar('%'); break;
      default:  putchar('%'); putchar(*f); break;
    }
  }
  return 0;
}
int printf(const char *f, ...) { va_list ap; va_start(ap, f); vprintf(f, ap); va_end(ap); return 0; }

// Default trap handler: report the cause and stop with a failing exit code.
extern volatile uint64_t tohost;
__attribute__((weak)) uintptr_t handle_trap(uintptr_t mcause, uintptr_t mepc) {
  printf("unexpected trap mcause=%x mepc=%x\n", mcause, mepc);
  tohost = (0xdead << 1) | 1;
  for (;;) ;
  return mepc;
}
