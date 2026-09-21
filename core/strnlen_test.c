#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE

/* A string whose terminator is the last byte of a mapping, with nothing
 * mapped after it. printf's `%s` measures it with strnlen(s, INT_MAX);
 * a strnlen that reads blocks past the terminator faults here. */
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) return 2;
  char *pages = mmap(NULL, 2 * (size_t)page, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (pages == MAP_FAILED) return 2;
  if (munmap(pages + page, (size_t)page) != 0) return 2;
  static const char text[] = "build.fix.rule_test";
  char *s = pages + page - sizeof text;
  memcpy(s, text, sizeof text);
  char out[64];
  int n = snprintf(out, sizeof out, "@%s", s);
  if (n != (int)sizeof text || strcmp(out + 1, text) != 0) return 1;
  if (strnlen(s, 0x7fffffff) != sizeof text - 1) return 1;
  puts("strnlen: PASS (a string ending at the last byte of a mapping)");
  return 0;
}
