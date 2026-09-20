/*
 * Cosmic portable artifact format, version 1.
 *
 * All integers are unsigned and big endian.  The file is:
 *
 *   16 KiB shell header
 *   16 KiB-aligned exact raw core slices, with zero-filled gaps
 *   one 4 KiB manifest block
 *   SQLite database
 *   48-byte trailer
 *
 * The manifest header is 32 bytes:
 *
 *   magic[8], version:u32, encoded_length:u32, prefix_length:u64,
 *   entry_count:u32, entry_length:u32
 *
 * Each 56-byte entry is:
 *
 *   target_id:u32, configuration_id:u32, offset:u64, length:u64,
 *   sha256[32]
 *
 * Entries occupy the start of the manifest block and the rest is zero.  The
 * fixed manifest block lets program(prefix, database) locate it without
 * searching bytes that belong to a core.  The trailer is:
 *
 *   magic[8], version:u32, encoded_length:u32,
 *   manifest_offset:u64, manifest_length:u64,
 *   database_offset:u64, database_length:u64
 *
 * The target authority remains build.zig.  It compiles the release target
 * mask and release configuration id into portable.c; they are not repeated
 * here.  A later prefix may add (for example) a sanitized entry while the
 * three release entries remain required.
 */

#ifndef COSMIC_PORTABLE_H
#define COSMIC_PORTABLE_H

#include <stdint.h>

#define COSMIC_PORTABLE_VERSION 1u
#define COSMIC_PORTABLE_SHELL_LENGTH UINT64_C(16384)
#define COSMIC_PORTABLE_CORE_ALIGNMENT UINT64_C(16384)
#define COSMIC_PORTABLE_MANIFEST_LENGTH UINT64_C(4096)
#define COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH 32u
#define COSMIC_PORTABLE_ENTRY_LENGTH 56u
#define COSMIC_PORTABLE_TRAILER_LENGTH UINT64_C(48)
#define COSMIC_PORTABLE_MAX_ENTRIES 8u
#define COSMIC_PORTABLE_SHA256_LENGTH 32u

#define COSMIC_PORTABLE_MANIFEST_MAGIC "CosmicM1"
#define COSMIC_PORTABLE_TRAILER_MAGIC "CosmicT1"
#define COSMIC_PORTABLE_MAGIC_LENGTH 8u

struct cosmic_portable_entry {
  uint32_t target_id;
  uint32_t configuration_id;
  uint64_t offset;
  uint64_t length;
  unsigned char sha256[COSMIC_PORTABLE_SHA256_LENGTH];
};

struct cosmic_portable {
  uint64_t prefix_length;
  uint64_t manifest_offset;
  uint64_t manifest_length;
  uint64_t database_offset;
  uint64_t database_length;
  uint32_t entry_count;
  struct cosmic_portable_entry entries[COSMIC_PORTABLE_MAX_ENTRIES];
  struct cosmic_portable_entry selected;
};

/*
 * Decodes and validates the file currently held open by fd.  target_id and
 * configuration_id are the running core's compiled fields.  On every error
 * this returns 0, leaves all of *out zero, and optionally names the rejected
 * invariant through *error.  It returns 1 only after every range is safe to
 * use and `selected` matches the compiled fields.
 */
int cosmic_portable_decode(int fd, uint32_t target_id,
                           uint32_t configuration_id,
                           struct cosmic_portable *out,
                           const char **error);

#endif
