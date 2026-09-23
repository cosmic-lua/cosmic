/* Hand-written configuration for the vendored liblzma decoder subset,
 * in place of the autoconf/cmake-generated config.h upstream expects.
 * Turns on only what the decode path needs: the LZMA2 filter (and
 * LZMA1, which the range coder it reuses is built from), the delta and
 * x86/arm64 BCJ filters, and the CRC-32, CRC-64 and SHA-256 integrity
 * checks. The build's three targets (musl Linux x86_64/aarch64,
 * macOS aarch64) are all little-endian with 8-byte size_t and a
 * standards-conforming <stdint.h>/<stdbool.h>, so nothing here branches
 * on the host. */

#ifndef COSMIC_XZ_CONFIG_H
#define COSMIC_XZ_CONFIG_H

#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STRING_H 1
#define HAVE_MEMORY_H 1

#define SIZEOF_SIZE_T 8

#define HAVE_DECODERS 1
#define HAVE_DECODER_LZMA1 1
#define HAVE_DECODER_LZMA2 1
#define HAVE_DECODER_DELTA 1
#define HAVE_DECODER_X86 1
#define HAVE_DECODER_ARM64 1

#define HAVE_CHECK_CRC32 1
#define HAVE_CHECK_CRC64 1
#define HAVE_CHECK_SHA256 1

/* Every target here supports it; it is what lets crc32_small.c's table
 * build itself the first time it is used instead of the core calling
 * an explicit init function. */
#define HAVE_FUNC_ATTRIBUTE_CONSTRUCTOR 1

/* Keeps to the size-optimized, table-free CRC32/CRC64 (crc32_small.c /
 * crc64_small.c), which is the pair this tree vendors -- the large
 * precomputed-table versions are not. */
#define HAVE_SMALL 1

#define ASSUME_RAM 128

#endif
