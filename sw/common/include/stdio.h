#ifndef RV_STDIO_H
#define RV_STDIO_H
#include <stdarg.h>
int putchar(int c);
int puts(const char *s);
int printf(const char *fmt, ...);
int vprintf(const char *fmt, va_list ap);
#endif
