/* A byte found in a buffer a vector at a time, for the scans that cut
 * text into lines. musl's memchr reads a word at a step: a gigabyte of
 * JSON Lines (lines of 4.6 KB) cut at its newlines ran at 1.7 GB/s with
 * it, and at 12 to 15 GB/s with this scan, which reads 32 bytes at a
 * step as each core here is built to (AVX2 on x86-64, two NEON
 * registers on aarch64). On lines of 30 bytes or fewer the two run at
 * the same speed, about 1.5 GB/s, since the first 16 bytes are read one
 * at a time. */

#ifndef COSMIC_BYTES_H
#define COSMIC_BYTES_H

#include <stddef.h>
#include <string.h>

typedef unsigned char cosmic_bytes32 __attribute__((vector_size(32)));

/* The first byte `c` in s[0..n), or NULL where none is: memchr's answer.
 * All `n` bytes must be readable, even when `c` comes before the end. */
static inline const char *cosmic_find_byte (const char *s, int c, size_t n) {
  const unsigned char *p = (const unsigned char *)s, *end = p + n;
  unsigned char b = (unsigned char)c;
  /* A short line ends within its first bytes, which a byte at a time
   * finds sooner than a vector step and the bytes after it. */
  const unsigned char *head = (size_t)(end - p) > 16 ? p + 16 : end;
  for (; p < head; p++)
    if (*p == b) return (const char *)p;
  /* Two vectors a step until one holds `c`, then one, then a byte at a
   * time: the bytes left are fewer than 32, or the step that ended holds
   * `c`. */
  while ((size_t)(end - p) >= 64) {
    cosmic_bytes32 x, y;
    memcpy(&x, p, sizeof x);
    memcpy(&y, p + 32, sizeof y);
    cosmic_bytes32 hit = (cosmic_bytes32)(x == b) | (cosmic_bytes32)(y == b);
    if (__builtin_reduce_or(hit) != 0) break;
    p += 64;
  }
  while ((size_t)(end - p) >= 32) {
    cosmic_bytes32 x;
    memcpy(&x, p, sizeof x);
    if (__builtin_reduce_or((cosmic_bytes32)(x == b)) != 0) break;
    p += 32;
  }
  for (; p < end; p++)
    if (*p == b) return (const char *)p;
  return NULL;
}

#endif
