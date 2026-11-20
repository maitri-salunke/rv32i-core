#ifndef RV_STRING_H
#define RV_STRING_H
#include <stddef.h>
void  *memcpy(void *d, const void *s, size_t n);
void  *memset(void *d, int c, size_t n);
char  *strcpy(char *d, const char *s);
int    strcmp(const char *a, const char *b);
size_t strlen(const char *s);
#endif
