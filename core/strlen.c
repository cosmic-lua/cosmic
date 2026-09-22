/* strlen, a byte at a time.
 *
 * Zig 0.16.0 links its own strlen ahead of musl's (lib/c/string.zig):
 * a vectorized scan that reads sixteen bytes at a time regardless of
 * where the terminator falls, so it reads past the end of the mapping
 * when a string ends within a page's last fifteen bytes and the next
 * page is not mapped -- the same bug that reached strnlen through
 * musl's printf (core/strnlen.c) reaches plain strlen through direct
 * callers such as vfs.c's vfs_full_pathname and cosmic_vfs_register,
 * both measuring a caller-supplied artifact path of unpredictable
 * length. Defined here, in the core ahead of libc, it never reads a
 * byte past the terminator. core/strlen_test.c holds the case. */
#include <stddef.h>
#include <string.h>

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n] != '\0') n++;
  return n;
}
