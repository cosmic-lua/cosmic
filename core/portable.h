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
 * A host program is the same pieces with no launcher and one core, the
 * running host's, at the very start of the file so that the kernel executes
 * it directly:
 *
 *   exact raw core, zero-filled to a 16 KiB boundary
 *   one 4 KiB manifest block with one entry, at offset 0
 *   SQLite database
 *   48-byte trailer whose magic is COSMIC_HOST_TRAILER_MAGIC
 *
 * It runs only where its core does, and cannot make portable programs.
 *
 * The target authority remains build.zig.  It compiles the release target
 * mask and release configuration id into portable.c; they are not repeated
 * here.  A later prefix may add (for example) a sanitized entry while the
 * three release entries remain required.
 */

#ifndef COSMIC_PORTABLE_H
#define COSMIC_PORTABLE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

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
#define COSMIC_HOST_TRAILER_MAGIC "CosmicH1"
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

#define COSMIC_ARTIFACT_PATH_CAPACITY 4096u

/* One portable artifact descriptor, owned until its database closes. */
struct cosmic_artifact {
  char logical_path[COSMIC_ARTIFACT_PATH_CAPACITY];
  int fd;
  uint64_t device;
  uint64_t inode;
  uint64_t file_size;
  struct cosmic_portable portable;
  /* A host program: the file is the running core itself. */
  int host;
  /* Whether the selected core range's bytes have been hashed against the
   * manifest: 0 not yet, 1 they match, -1 they differ. A portable start
   * checks at startup; a host program only when its identity is asked for. */
  int core_checked;
};

/*
 * Decodes and validates the file currently held open by fd.  target_id and
 * configuration_id are the running core's compiled fields.  On every error
 * this returns false, leaves all of *out zero, and optionally names the
 * rejected invariant through *error.  It returns true only after every range
 * is safe to use and `selected` matches the compiled fields.
 */
bool cosmic_portable_decode (int fd, uint32_t target_id,
                             uint32_t configuration_id,
                             struct cosmic_portable *out,
                             const char **error);

/*
 * Decodes and validates a host program held open by fd, the same way: one
 * entry, the compiled one, at offset 0. Its core's digest is not checked
 * here; see cosmic_artifact_core_matches.
 */
bool cosmic_host_decode (int fd, uint32_t target_id, uint32_t configuration_id,
                         struct cosmic_portable *out, const char **error);

/* Whether the file held open by fd ends in a host program trailer. */
bool cosmic_host_trailer (int fd);

void cosmic_artifact_init (struct cosmic_artifact *artifact);
void cosmic_artifact_close (struct cosmic_artifact *artifact);
/* Reads exactly `length` bytes at `offset` of the artifact into `into`:
 * false when they cannot all be read. */
bool cosmic_artifact_read (const struct cosmic_artifact *artifact, void *into,
                           size_t length, uint64_t offset);

#endif
