/* strnlen, a byte at a time.
 *
 * Zig 0.16.0 links its own strnlen ahead of musl's (lib/c/string.zig):
 * a vectorized scan over all `max` bytes that reads sixteen at a time,
 * so it reads past the terminator, and past the end of the mapping
 * when a string ends within a page's last fifteen bytes and the next
 * page is not mapped. musl's printf measures every `%s` with
 * strnlen(s, INT_MAX), so any heap string handed to snprintf or
 * fprintf could fault; a module name in store.c's chunk name did, in
 * one run of the suite out of a few under a re-entered tool. Defined
 * here, in the core ahead of libc, it never reads a byte past the
 * terminator or the bound. core/strnlen_test.c holds the case. */
#include <stddef.h>
#include <string.h>

size_t strnlen(const char *s, size_t max) {
  size_t n = 0;
  while (n < max && s[n] != '\0') n++;
  return n;
}
