/* simdutf compiled into the core with only base64 decoding and encoding
 * turned on (the SIMDUTF_FEATURE_* flags build.zig passes), and the C call
 * core/simd_base64.h declares. One translation unit: the amalgamation is
 * included here, so its flags and this file's are the same compile. */

#include "simdutf.cpp"

#include "simd_base64.h"

extern "C" int cosmic_simdutf_unbase64 (const char *text, size_t len, char *out, size_t *outlen, int url, int padded) {
  simdutf::base64_options options = url
    ? (padded ? simdutf::base64_url_with_padding : simdutf::base64_url)
    : (padded ? simdutf::base64_default : simdutf::base64_default_no_padding);
  size_t room = *outlen;
  simdutf::result r = simdutf::base64_to_binary_safe(text, len, out, room, options,
    simdutf::last_chunk_handling_options::strict, false);
  if (r.error != simdutf::error_code::SUCCESS) return 0;
  *outlen = room;
  return 1;
}
