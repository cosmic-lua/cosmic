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

typedef size_t (*bounded_length)(const char *, size_t);
static bounded_length volatile call_strnlen = strnlen;

static int guarded(void) {
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) return 2;
  char *pages = mmap(NULL, 2 * (size_t)page, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | COSMIC_MAP_ANONYMOUS, -1, 0);
  if (pages == MAP_FAILED) return 2;
  if (munmap(pages + page, (size_t)page) != 0) return 2;

  /* max == 0 must not dereference even an inaccessible address. */
  if (call_strnlen(pages + page, 0) != 0) return 1;

  /* An unterminated span may end exactly at the guard boundary. */
  char *bounded = pages + page - 32;
  memset(bounded, 'x', 32);
  if (call_strnlen(bounded, 32) != 32) return 1;
  bounded[0] = '\0';
  if (call_strnlen(bounded, 32) != 0) return 1;
  bounded[15] = '\0';
  if (call_strnlen(bounded + 1, 31) != 14) return 1;

  /* snprintf reaches libc's real %s measurement path. */
  static const char text[] = "build.fix.rule_test";
  char *s = pages + page - sizeof text;
  memcpy(s, text, sizeof text);
  char out[64];
  int n = snprintf(out, sizeof out, "@%s", s);
  if (n != (int)sizeof text || strcmp(out + 1, text) != 0) return 1;
  if (call_strnlen(s, 0x7fffffff) != sizeof text - 1) return 1;
  return 0;
}

int main(void) {
  pid_t child = fork();
  if (child < 0) return 2;
  if (child == 0) _exit(guarded());
  int status = 0;
  if (waitpid(child, &status, 0) != child) return 2;
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return 1;
  puts("strnlen: PASS (bounded semantics and guarded snprintf child)");
  return 0;
}
