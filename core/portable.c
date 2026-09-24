#define _XOPEN_SOURCE 700

#include "portable.h"

#include <errno.h>
#include <limits.h>
#include <stddef.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef COSMIC_PORTABLE_REQUIRED_TARGET_MASK
#error "build.zig must define COSMIC_PORTABLE_REQUIRED_TARGET_MASK"
#endif
#ifndef COSMIC_PORTABLE_RELEASE_CONFIGURATION_ID
#error "build.zig must define COSMIC_PORTABLE_RELEASE_CONFIGURATION_ID"
#endif

#define SQLITE_HEADER "SQLite format 3\0"
#define SQLITE_HEADER_LENGTH 16u

static bool reject (struct cosmic_portable *out, const char **error,
                    const char *why) {
  memset(out, 0, sizeof *out);
  if (error != NULL) *error = why;
  return false;
}

static bool read_at (int fd, void *into, size_t length, uint64_t offset) {
  unsigned char *p = into;
  if (offset > (uint64_t)INT64_MAX) return false;
  while (length > 0) {
    ssize_t got = pread(fd, p, length, (off_t)offset);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) return false;
    p += (size_t)got;
    length -= (size_t)got;
    offset += (uint64_t)got;
  }
  return true;
}

void cosmic_artifact_init (struct cosmic_artifact *artifact) {
  memset(artifact, 0, sizeof *artifact);
  artifact->fd = -1;
}

void cosmic_artifact_close (struct cosmic_artifact *artifact) {
  if (artifact != NULL && artifact->fd >= 0) close(artifact->fd);
  if (artifact != NULL) cosmic_artifact_init(artifact);
}

bool cosmic_artifact_read (const struct cosmic_artifact *artifact, void *into,
                           size_t length, uint64_t offset) {
  return artifact != NULL && artifact->fd >= 0 &&
         read_at(artifact->fd, into, length, offset);
}

static uint32_t be32 (const unsigned char *p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
         (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

static uint64_t be64 (const unsigned char *p) {
  uint64_t value = 0;
  for (unsigned i = 0; i < 8; i++) value = value << 8 | (uint64_t)p[i];
  return value;
}

static bool range_ends_at_or_before (uint64_t offset, uint64_t length,
                                     uint64_t limit) {
  return offset <= limit && length <= limit - offset;
}

static bool align_core (uint64_t value, uint64_t *aligned) {
  uint64_t remainder = value % COSMIC_PORTABLE_CORE_ALIGNMENT;
  uint64_t padding = remainder == 0 ? 0 :
      COSMIC_PORTABLE_CORE_ALIGNMENT - remainder;
  if (value > UINT64_MAX - padding) return false;
  *aligned = value + padding;
  return true;
}

static bool zero_range (int fd, uint64_t offset, uint64_t length) {
  unsigned char bytes[4096];
  while (length > 0) {
    size_t take = length < sizeof bytes ? (size_t)length : sizeof bytes;
    if (!read_at(fd, bytes, take, offset)) return false;
    for (size_t i = 0; i < take; i++) {
      if (bytes[i] != 0) return false;
    }
    offset += take;
    length -= take;
  }
  return true;
}

bool cosmic_host_trailer (int fd) {
  struct stat st;
  unsigned char magic[COSMIC_PORTABLE_MAGIC_LENGTH];
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
      (uint64_t)st.st_size < COSMIC_PORTABLE_TRAILER_LENGTH)
    return false;
  return read_at(fd, magic, sizeof magic,
                 (uint64_t)st.st_size - COSMIC_PORTABLE_TRAILER_LENGTH) &&
         memcmp(magic, COSMIC_HOST_TRAILER_MAGIC, sizeof magic) == 0;
}

/* The trailer and the one manifest block both formats share: reads them,
 * checks every field but the trailer magic's meaning, and fills the ranges
 * and entries. `first_core` is the least offset a core may start at. */
static bool decode_blocks (int fd, const char *trailer_magic, uint64_t first_core,
                           struct cosmic_portable *decoded,
                           struct cosmic_portable *out, const char **error) {
  unsigned char trailer[COSMIC_PORTABLE_TRAILER_LENGTH];
  unsigned char manifest[COSMIC_PORTABLE_MANIFEST_LENGTH];
  unsigned char header[SQLITE_HEADER_LENGTH];
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0)
    return reject(out, error, "artifact size is unavailable");
  uint64_t file_length = (uint64_t)st.st_size;
  if (file_length > (uint64_t)INT64_MAX)
    return reject(out, error, "artifact is too large");
  if (file_length < first_core + COSMIC_PORTABLE_MANIFEST_LENGTH +
                        SQLITE_HEADER_LENGTH + COSMIC_PORTABLE_TRAILER_LENGTH)
    return reject(out, error, "artifact is truncated");
  uint64_t trailer_offset = file_length - COSMIC_PORTABLE_TRAILER_LENGTH;
  if (!read_at(fd, trailer, sizeof trailer, trailer_offset))
    return reject(out, error, "trailer cannot be read");
  if (memcmp(trailer, trailer_magic, COSMIC_PORTABLE_MAGIC_LENGTH) != 0)
    return reject(out, error, "trailer magic differs");
  if (be32(trailer + 8) != COSMIC_PORTABLE_VERSION)
    return reject(out, error, "trailer version is unsupported");
  if (be32(trailer + 12) != COSMIC_PORTABLE_TRAILER_LENGTH)
    return reject(out, error, "trailer length differs");
  decoded->manifest_offset = be64(trailer + 16);
  decoded->manifest_length = be64(trailer + 24);
  decoded->database_offset = be64(trailer + 32);
  decoded->database_length = be64(trailer + 40);
  if (decoded->manifest_length != COSMIC_PORTABLE_MANIFEST_LENGTH)
    return reject(out, error, "manifest block length differs");
  if (!range_ends_at_or_before(decoded->manifest_offset,
                               decoded->manifest_length, trailer_offset) ||
      decoded->manifest_offset + decoded->manifest_length !=
          decoded->database_offset)
    return reject(out, error, "manifest range differs from database offset");
  if (!range_ends_at_or_before(decoded->database_offset,
                               decoded->database_length, trailer_offset) ||
      decoded->database_offset + decoded->database_length != trailer_offset)
    return reject(out, error, "database range differs from trailer offset");
  if (decoded->manifest_offset < first_core ||
      decoded->manifest_offset % COSMIC_PORTABLE_CORE_ALIGNMENT != 0)
    return reject(out, error, "manifest offset is not aligned after the cores");
  if (!read_at(fd, manifest, sizeof manifest, decoded->manifest_offset))
    return reject(out, error, "manifest cannot be read");
  if (memcmp(manifest, COSMIC_PORTABLE_MANIFEST_MAGIC,
             COSMIC_PORTABLE_MAGIC_LENGTH) != 0)
    return reject(out, error, "manifest magic differs");
  if (be32(manifest + 8) != COSMIC_PORTABLE_VERSION)
    return reject(out, error, "manifest version is unsupported");
  if (be32(manifest + 12) != COSMIC_PORTABLE_MANIFEST_LENGTH)
    return reject(out, error, "manifest encoded length differs");
  decoded->prefix_length = be64(manifest + 16);
  decoded->entry_count = be32(manifest + 24);
  if (be32(manifest + 28) != COSMIC_PORTABLE_ENTRY_LENGTH)
    return reject(out, error, "manifest entry length differs");
  if (decoded->prefix_length != decoded->database_offset ||
      decoded->prefix_length !=
          decoded->manifest_offset + decoded->manifest_length)
    return reject(out, error, "manifest prefix length differs");
  if (decoded->entry_count == 0 ||
      decoded->entry_count > COSMIC_PORTABLE_MAX_ENTRIES)
    return reject(out, error, "manifest entry count is outside its bound");
  uint64_t used = COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH +
                  (uint64_t)decoded->entry_count * COSMIC_PORTABLE_ENTRY_LENGTH;
  if (used > decoded->manifest_length)
    return reject(out, error, "manifest entries exceed their block");
  if (!zero_range(fd, decoded->manifest_offset + used,
                  decoded->manifest_length - used))
    return reject(out, error, "manifest padding is not zero");
  for (uint32_t i = 0; i < decoded->entry_count; i++) {
    const unsigned char *raw = manifest +
        COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH +
        (uint64_t)i * COSMIC_PORTABLE_ENTRY_LENGTH;
    struct cosmic_portable_entry *entry = &decoded->entries[i];
    entry->target_id = be32(raw);
    entry->configuration_id = be32(raw + 4);
    entry->offset = be64(raw + 8);
    entry->length = be64(raw + 16);
    memcpy(entry->sha256, raw + 24, COSMIC_PORTABLE_SHA256_LENGTH);
    if (entry->target_id == 0 || entry->configuration_id == 0)
      return reject(out, error, "manifest entry identity is zero");
    if (entry->offset < first_core ||
        entry->offset % COSMIC_PORTABLE_CORE_ALIGNMENT != 0 ||
        entry->length == 0 ||
        !range_ends_at_or_before(entry->offset, entry->length,
                                 decoded->manifest_offset))
      return reject(out, error, "core range is outside the aligned prefix");
  }
  if (decoded->database_length < SQLITE_HEADER_LENGTH ||
      !read_at(fd, header, sizeof header, decoded->database_offset) ||
      memcmp(header, SQLITE_HEADER, SQLITE_HEADER_LENGTH) != 0)
    return reject(out, error, "database header differs from SQLite");
  return true;
}

bool cosmic_host_decode (int fd, uint32_t target_id, uint32_t configuration_id,
                         struct cosmic_portable *out, const char **error) {
  struct cosmic_portable decoded;
  if (out == NULL) return false;
  memset(out, 0, sizeof *out);
  if (error != NULL) *error = NULL;
  memset(&decoded, 0, sizeof decoded);
  if (target_id == 0 || configuration_id == 0)
    return reject(out, error, "compiled target or configuration is zero");
  if (!decode_blocks(fd, COSMIC_HOST_TRAILER_MAGIC, 0, &decoded, out, error))
    return false;
  if (decoded.entry_count != 1)
    return reject(out, error, "a host program carries exactly one core");
  const struct cosmic_portable_entry *entry = &decoded.entries[0];
  if (entry->target_id != target_id ||
      entry->configuration_id != configuration_id)
    return reject(out, error, "host program core differs from the compiled identity");
  uint64_t expected;
  if (entry->offset != 0 || !align_core(entry->length, &expected) ||
      decoded.manifest_offset != expected)
    return reject(out, error, "host program core does not start the file");
  if (!zero_range(fd, entry->length, expected - entry->length))
    return reject(out, error, "host program core padding is not zero");
  decoded.selected = *entry;
  *out = decoded;
  return true;
}

bool cosmic_portable_decode (int fd, uint32_t target_id,
                             uint32_t configuration_id,
                             struct cosmic_portable *out,
                             const char **error) {
  struct cosmic_portable decoded;
  unsigned char trailer[COSMIC_PORTABLE_TRAILER_LENGTH];
  unsigned char manifest[COSMIC_PORTABLE_MANIFEST_LENGTH];
  unsigned char header[SQLITE_HEADER_LENGTH];
  unsigned char shebang[] = "#!/bin/sh\n";
  struct stat st;
  uint64_t file_length;
  uint64_t trailer_offset;
  uint64_t required_seen = 0;
  int selected = -1;

  if (out == NULL) return false;
  memset(out, 0, sizeof *out);
  if (error != NULL) *error = NULL;
  memset(&decoded, 0, sizeof decoded);

  if (target_id == 0 || configuration_id == 0)
    return reject(out, error, "compiled target or configuration is zero");
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0)
    return reject(out, error, "artifact size is unavailable");
  file_length = (uint64_t)st.st_size;
  if (file_length > (uint64_t)INT64_MAX)
    return reject(out, error, "artifact is too large");
  if (file_length < COSMIC_PORTABLE_SHELL_LENGTH +
                        COSMIC_PORTABLE_MANIFEST_LENGTH +
                        SQLITE_HEADER_LENGTH +
                        COSMIC_PORTABLE_TRAILER_LENGTH)
    return reject(out, error, "artifact is truncated");
  trailer_offset = file_length - COSMIC_PORTABLE_TRAILER_LENGTH;
  if (!read_at(fd, trailer, sizeof trailer, trailer_offset))
    return reject(out, error, "trailer cannot be read");
  if (memcmp(trailer, COSMIC_PORTABLE_TRAILER_MAGIC,
             COSMIC_PORTABLE_MAGIC_LENGTH) != 0)
    return reject(out, error, "trailer magic differs");
  if (be32(trailer + 8) != COSMIC_PORTABLE_VERSION)
    return reject(out, error, "trailer version is unsupported");
  if (be32(trailer + 12) != COSMIC_PORTABLE_TRAILER_LENGTH)
    return reject(out, error, "trailer length differs");

  decoded.manifest_offset = be64(trailer + 16);
  decoded.manifest_length = be64(trailer + 24);
  decoded.database_offset = be64(trailer + 32);
  decoded.database_length = be64(trailer + 40);
  if (decoded.manifest_length != COSMIC_PORTABLE_MANIFEST_LENGTH)
    return reject(out, error, "manifest block length differs");
  if (!range_ends_at_or_before(decoded.manifest_offset,
                               decoded.manifest_length, trailer_offset) ||
      decoded.manifest_offset + decoded.manifest_length !=
          decoded.database_offset)
    return reject(out, error, "manifest range differs from database offset");
  if (!range_ends_at_or_before(decoded.database_offset,
                               decoded.database_length, trailer_offset) ||
      decoded.database_offset + decoded.database_length != trailer_offset)
    return reject(out, error, "database range differs from trailer offset");
  if (decoded.manifest_offset < COSMIC_PORTABLE_SHELL_LENGTH ||
      decoded.manifest_offset % COSMIC_PORTABLE_CORE_ALIGNMENT != 0)
    return reject(out, error, "manifest offset is not aligned after the shell");

  if (!read_at(fd, shebang, sizeof shebang - 1, 0) ||
      memcmp(shebang, "#!/bin/sh\n", sizeof shebang - 1) != 0)
    return reject(out, error, "shell header has no portable shebang");
  if (!read_at(fd, manifest, sizeof manifest, decoded.manifest_offset))
    return reject(out, error, "manifest cannot be read");
  if (memcmp(manifest, COSMIC_PORTABLE_MANIFEST_MAGIC,
             COSMIC_PORTABLE_MAGIC_LENGTH) != 0)
    return reject(out, error, "manifest magic differs");
  if (be32(manifest + 8) != COSMIC_PORTABLE_VERSION)
    return reject(out, error, "manifest version is unsupported");
  if (be32(manifest + 12) != COSMIC_PORTABLE_MANIFEST_LENGTH)
    return reject(out, error, "manifest encoded length differs");
  decoded.prefix_length = be64(manifest + 16);
  decoded.entry_count = be32(manifest + 24);
  if (be32(manifest + 28) != COSMIC_PORTABLE_ENTRY_LENGTH)
    return reject(out, error, "manifest entry length differs");
  if (decoded.prefix_length != decoded.database_offset ||
      decoded.prefix_length !=
          decoded.manifest_offset + decoded.manifest_length)
    return reject(out, error, "manifest prefix length differs");
  if (decoded.entry_count == 0 ||
      decoded.entry_count > COSMIC_PORTABLE_MAX_ENTRIES)
    return reject(out, error, "manifest entry count is outside its bound");

  uint64_t used = COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH +
                  (uint64_t)decoded.entry_count * COSMIC_PORTABLE_ENTRY_LENGTH;
  if (used > decoded.manifest_length)
    return reject(out, error, "manifest entries exceed their block");
  if (!zero_range(fd, decoded.manifest_offset + used,
                  decoded.manifest_length - used))
    return reject(out, error, "manifest padding is not zero");

  for (uint32_t i = 0; i < decoded.entry_count; i++) {
    const unsigned char *raw = manifest +
        COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH +
        (uint64_t)i * COSMIC_PORTABLE_ENTRY_LENGTH;
    struct cosmic_portable_entry *entry = &decoded.entries[i];
    entry->target_id = be32(raw);
    entry->configuration_id = be32(raw + 4);
    entry->offset = be64(raw + 8);
    entry->length = be64(raw + 16);
    memcpy(entry->sha256, raw + 24, COSMIC_PORTABLE_SHA256_LENGTH);
    if (entry->target_id == 0 || entry->configuration_id == 0)
      return reject(out, error, "manifest entry identity is zero");
    if (entry->offset < COSMIC_PORTABLE_SHELL_LENGTH ||
        entry->offset % COSMIC_PORTABLE_CORE_ALIGNMENT != 0 ||
        entry->length == 0 ||
        !range_ends_at_or_before(entry->offset, entry->length,
                                 decoded.manifest_offset))
      return reject(out, error, "core range is outside the aligned prefix");
    for (uint32_t j = 0; j < i; j++) {
      const struct cosmic_portable_entry *other = &decoded.entries[j];
      if (entry->target_id == other->target_id &&
          entry->configuration_id == other->configuration_id)
        return reject(out, error, "manifest has a duplicate core identity");
      if (entry->offset < other->offset + other->length &&
          other->offset < entry->offset + entry->length)
        return reject(out, error, "manifest core ranges overlap");
    }
    if (entry->configuration_id ==
            COSMIC_PORTABLE_RELEASE_CONFIGURATION_ID &&
        entry->target_id < 64 &&
        (COSMIC_PORTABLE_REQUIRED_TARGET_MASK &
         (UINT64_C(1) << entry->target_id)) != 0)
      required_seen |= UINT64_C(1) << entry->target_id;
    if (entry->target_id == target_id &&
        entry->configuration_id == configuration_id)
      selected = (int)i;
  }
  if (required_seen != COSMIC_PORTABLE_REQUIRED_TARGET_MASK)
    return reject(out, error, "manifest is missing a required release core");
  if (selected < 0)
    return reject(out, error, "manifest has no core for the compiled identity");

  /* Validate every inter-core gap independent of manifest entry order. */
  uint64_t after = COSMIC_PORTABLE_SHELL_LENGTH;
  for (uint32_t n = 0; n < decoded.entry_count; n++) {
    int next = -1;
    for (uint32_t i = 0; i < decoded.entry_count; i++) {
      if (decoded.entries[i].offset >= after &&
          (next < 0 || decoded.entries[i].offset <
                           decoded.entries[(uint32_t)next].offset))
        next = (int)i;
    }
    if (next < 0)
      return reject(out, error, "core ranges cannot be ordered");
    const struct cosmic_portable_entry *entry =
        &decoded.entries[(uint32_t)next];
    uint64_t expected;
    if (!align_core(after, &expected) || entry->offset != expected)
      return reject(out, error, "core range does not use minimal alignment");
    if (!zero_range(fd, after, expected - after))
      return reject(out, error, "core alignment padding is not zero");
    after = entry->offset + entry->length;
  }
  uint64_t expected_manifest;
  if (!align_core(after, &expected_manifest) ||
      decoded.manifest_offset != expected_manifest)
    return reject(out, error, "manifest does not follow minimal core padding");
  if (!zero_range(fd, after, expected_manifest - after))
    return reject(out, error, "final core padding is not zero");

  if (decoded.database_length < SQLITE_HEADER_LENGTH ||
      !read_at(fd, header, sizeof header, decoded.database_offset) ||
      memcmp(header, SQLITE_HEADER, SQLITE_HEADER_LENGTH) != 0)
    return reject(out, error, "database header differs from SQLite");

  decoded.selected = decoded.entries[(uint32_t)selected];
  *out = decoded;
  return true;
}
