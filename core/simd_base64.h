/* simdutf's base64 decoder, behind a C call for core/text.c. simdutf is
 * C++; core/simd_base64.cpp compiles its single-header amalgamation with only
 * the base64 part turned on, and with no C++ runtime: no exceptions, no
 * RTTI and no libc++. */

#ifndef COSMIC_SIMD_BASE64_H
#define COSMIC_SIMD_BASE64_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

  /* Decodes the `len` bytes at `text`, base64 in the standard alphabet or
   * the URL-safe one where `url`, into `out`, which holds `*outlen` bytes;
   * `padded` says the text carries `=` padding. simdutf skips ASCII white
   * space anywhere and refuses nonzero bits in the last character. Returns
   * 1 and sets `*outlen` to the bytes written, or 0 for anything simdutf
   * refused, including an `out` too short. */
  int cosmic_simdutf_unbase64 (const char *text, size_t len, char *out, size_t *outlen, int url, int padded);

#ifdef __cplusplus
}
#endif

#endif
