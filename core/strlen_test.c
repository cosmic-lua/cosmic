#define _DARWIN_C_SOURCE 1
#define _POSIX_C_SOURCE 200809L

/* Exact semantics plus the libc call path that exposed the pinned Zig 0.16.0
 * implementation. The guard-page case runs in a child so a regression is
 * reported as a retained wait status rather than taking down the test driver. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(MAP_ANONYMOUS)
#define COSMIC_MAP_ANONYMOUS MAP_ANONYMOUS
#elif defined(MAP_ANON)
#define COSMIC_MAP_ANONYMOUS MAP_ANON
#else
#error "this host has no anonymous mmap flag"
#endif

typedef size_t (*unbounded_length)(const char *);
static unbounded_length volatile call_strlen = strlen;

static int guarded(void) {
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) return 2;
  char *pages = mmap(NULL, 2 * (size_t)page, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | COSMIC_MAP_ANONYMOUS, -1, 0);
  if (pages == MAP_FAILED) return 2;
  if (munmap(pages + page, (size_t)page) != 0) return 2;

  /* A string may end exactly at the guard boundary: the terminator is
   * the last byte of the mapped page, and the page after it is
   * unmapped, so any read past it faults. */
  char *bounded = pages + page - 32;
  memset(bounded, 'x', 32);
  bounded[31] = '\0';
  if (call_strlen(bounded) != 31) return 1;

  /* The terminator itself can be the very last byte of the mapping. */
  char *edge = pages + page - 1;
  *edge = '\0';
  if (call_strlen(edge) != 0) return 1;

  /* snprintf reaches libc's real %s measurement path. */
  static const char text[] = "build.fix.rule_test";
  char *s = pages + page - sizeof text;
  memcpy(s, text, sizeof text);
  char out[64];
  int n = snprintf(out, sizeof out, "@%s", s);
  if (n != (int)sizeof text || strcmp(out + 1, text) != 0) return 1;
  if (call_strlen(s) != sizeof text - 1) return 1;
  return 0;
}

int main(void) {
  pid_t child = fork();
  if (child < 0) return 2;
  if (child == 0) _exit(guarded());
  int status = 0;
  if (waitpid(child, &status, 0) != child) return 2;
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return 1;
  puts("strlen: PASS (guarded page-boundary and snprintf child)");
  return 0;
}
