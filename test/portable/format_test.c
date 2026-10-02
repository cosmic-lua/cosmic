#define _XOPEN_SOURCE 700

#include "portable.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PORTABLE_TEST_TARGET_ID
#define PORTABLE_TEST_TARGET_ID 1u
#endif
#ifndef PORTABLE_TEST_CONFIGURATION_ID
#define PORTABLE_TEST_CONFIGURATION_ID 1u
#endif

static void put32 (unsigned char *p, uint32_t value) {
  for (int i = 3; i >= 0; i--) {
    p[i] = (unsigned char)value;
    value >>= 8;
  }
}

static void put64 (unsigned char *p, uint64_t value) {
  for (int i = 7; i >= 0; i--) {
    p[i] = (unsigned char)value;
    value >>= 8;
  }
}

static int all_zero (const void *data, size_t length) {
  const unsigned char *p = data;
  for (size_t i = 0; i < length; i++) {
    if (p[i] != 0) return 0;
  }
  return 1;
}

static int write_all (int fd, const unsigned char *data, size_t length) {
  while (length > 0) {
    ssize_t put = write(fd, data, length);
    if (put <= 0) return 0;
    data += (size_t)put;
    length -= (size_t)put;
  }
  return 1;
}

static int decode_as (const unsigned char *data, size_t length,
                      enum cosmic_artifact_format format, int structural,
                      uint32_t target, uint32_t configuration,
                      struct cosmic_portable *decoded, const char **error) {
  char path[] = "/tmp/cosmic-format-test.XXXXXX";
  int fd = mkstemp(path);
  if (fd < 0) return -1;
  unlink(path);
  int written = write_all(fd, data, length);
  int result = -1;
  if (written) {
    if (structural)
      result = cosmic_artifact_decode(fd, format, decoded, error);
    else if (format == COSMIC_ARTIFACT_HOST)
      result = cosmic_host_decode(fd, target, configuration, decoded, error);
    else
      result = cosmic_portable_decode(fd, target, configuration, decoded, error);
  }
  close(fd);
  return result;
}

static int decode_bytes (const unsigned char *data, size_t length,
                         uint32_t target, uint32_t configuration,
                         struct cosmic_portable *decoded, const char **error) {
  return decode_as(data, length, COSMIC_ARTIFACT_PORTABLE, 0,
                    target, configuration, decoded, error);
}

static int expect_rejected (const char *name, const unsigned char *data,
                            size_t length) {
  struct cosmic_portable decoded;
  const char *error = NULL;
  memset(&decoded, 0xa5, sizeof decoded);
  int result = decode_bytes(data, length, PORTABLE_TEST_TARGET_ID,
                            PORTABLE_TEST_CONFIGURATION_ID, &decoded, &error);
  if (result < 0) {
    fprintf(stderr, "%s: could not make test file\n", name);
    return 0;
  }
  if (result != 0 || !all_zero(&decoded, sizeof decoded) || error == NULL) {
    fprintf(stderr, "%s: malformed artifact was accepted\n", name);
    return 0;
  }
  memset(&decoded, 0xa5, sizeof decoded);
  error = NULL;
  result = decode_as(data, length, COSMIC_ARTIFACT_PORTABLE, 1, 0, 0,
                      &decoded, &error);
  if (result != 0 || !all_zero(&decoded, sizeof decoded) || error == NULL) {
    fprintf(stderr, "%s: malformed structure was accepted\n", name);
    return 0;
  }
  return 1;
}

static unsigned char *copy_of (const unsigned char *data, size_t length) {
  unsigned char *copy = malloc(length);
  if (copy != NULL) memcpy(copy, data, length);
  return copy;
}

static int mutation (const char *name, const unsigned char *original,
                     size_t length, uint64_t offset,
                     const unsigned char *replacement, size_t replace_length) {
  unsigned char *changed = copy_of(original, length);
  if (changed == NULL || offset > length || replace_length > length - offset) {
    fprintf(stderr, "%s: %s\n", name,
            changed == NULL ? "out of memory" : "mutation is out of range");
    free(changed);
    return 0;
  }
  memcpy(changed + offset, replacement, replace_length);
  int ok = expect_rejected(name, changed, length);
  free(changed);
  return ok;
}

/* A format-valid one-core subset, with deliberately opaque core bytes and
 * digest: structural inspection establishes neither executable code nor
 * authenticity. No writer policy is used to produce this fixture. */
static unsigned char *one_core (enum cosmic_artifact_format format,
                                uint32_t target, uint32_t configuration,
                                size_t *length) {
  uint64_t offset = format == COSMIC_ARTIFACT_HOST ? 0 : COSMIC_PORTABLE_SHELL_LENGTH;
  uint64_t manifest = offset + COSMIC_PORTABLE_CORE_ALIGNMENT;
  uint64_t database = manifest + COSMIC_PORTABLE_MANIFEST_LENGTH;
  uint64_t trailer = database + 16;
  *length = (size_t)(trailer + COSMIC_PORTABLE_TRAILER_LENGTH);
  unsigned char *data = calloc(1, *length);
  if (data == NULL) return NULL;
  if (format == COSMIC_ARTIFACT_PORTABLE) memcpy(data, "#!/bin/sh\n", 10);
  memset(data + offset, 'x', 32);
  memcpy(data + manifest, COSMIC_PORTABLE_MANIFEST_MAGIC, 8);
  put32(data + manifest + 8, COSMIC_PORTABLE_VERSION);
  put32(data + manifest + 12, (uint32_t)COSMIC_PORTABLE_MANIFEST_LENGTH);
  put64(data + manifest + 16, database);
  put32(data + manifest + 24, 1);
  put32(data + manifest + 28, COSMIC_PORTABLE_ENTRY_LENGTH);
  unsigned char *entry = data + manifest + COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH;
  put32(entry, target);
  put32(entry + 4, configuration);
  put64(entry + 8, offset);
  put64(entry + 16, 32);
  memset(entry + 24, 0xa5, COSMIC_PORTABLE_SHA256_LENGTH);
  memcpy(data + database, "SQLite format 3\0", 16);
  memcpy(data + trailer, format == COSMIC_ARTIFACT_HOST ? COSMIC_HOST_TRAILER_MAGIC :
      COSMIC_PORTABLE_TRAILER_MAGIC, 8);
  put32(data + trailer + 8, COSMIC_PORTABLE_VERSION);
  put32(data + trailer + 12, (uint32_t)COSMIC_PORTABLE_TRAILER_LENGTH);
  put64(data + trailer + 16, manifest);
  put64(data + trailer + 24, COSMIC_PORTABLE_MANIFEST_LENGTH);
  put64(data + trailer + 32, database);
  put64(data + trailer + 40, 16);
  return data;
}

static int structural_cases (void) {
  const enum cosmic_artifact_format formats[] = { COSMIC_ARTIFACT_HOST, COSMIC_ARTIFACT_PORTABLE };
  const uint32_t targets[] = { PORTABLE_TEST_TARGET_ID, 64, UINT32_MAX };
  for (size_t f = 0; f < sizeof formats / sizeof formats[0]; f++) {
    for (size_t t = 0; t < sizeof targets / sizeof targets[0]; t++) {
      enum cosmic_artifact_format format = formats[f];
      uint32_t target = targets[t];
      uint32_t configuration = t == 0 ? PORTABLE_TEST_CONFIGURATION_ID : UINT32_MAX;
      size_t length;
      unsigned char *data = one_core(format, target, configuration, &length);
      if (data == NULL) return 0;
      struct cosmic_portable decoded;
      const char *error = "stale failure";
      memset(&decoded, 0xa5, sizeof decoded);
      int result = decode_as(data, length, format, 1, 0, 0, &decoded, &error);
      if (result != 1 || error != NULL || decoded.entry_count != 1 ||
          decoded.entries[0].target_id != target ||
          decoded.entries[0].configuration_id != configuration ||
          !all_zero(&decoded.selected, sizeof decoded.selected) ||
          !all_zero(decoded.entries + 1, sizeof decoded.entries - sizeof decoded.entries[0])) {
        fprintf(stderr, "one-core structure was not inspectable, format %d target %u\n", format, target);
        free(data);
        return 0;
      }
      uint64_t core_end = decoded.entries[0].offset + decoded.entries[0].length;
      result = decode_as(data, length, format, 0, PORTABLE_TEST_TARGET_ID,
                          PORTABLE_TEST_CONFIGURATION_ID, &decoded, &error);
      int matches = format == COSMIC_ARTIFACT_HOST && t == 0;
      if (result != matches || (matches && decoded.selected.target_id != target) ||
          (!matches && (!all_zero(&decoded, sizeof decoded) || error == NULL))) {
        fprintf(stderr, "one-core startup policy changed, format %d target %u\n", format, target);
        free(data);
        return 0;
      }
      /* Reuse an output from successful inspection, then force failure. */
      if (decode_as(data, length, format, 1, 0, 0, &decoded, NULL) != 1) {
        free(data);
        return 0;
      }
      data[core_end] = 1;
      result = decode_as(data, length, format, 1, 0, 0, &decoded, &error);
      if (result != 0 || !all_zero(&decoded, sizeof decoded) || error == NULL) {
        fprintf(stderr, "core padding accepted or stale inspection output retained\n");
        free(data);
        return 0;
      }
      data[core_end] = 0;
      result = decode_as(data, length, (enum cosmic_artifact_format)99, 1,
                          0, 0, &decoded, &error);
      if (result != 0 || !all_zero(&decoded, sizeof decoded) || error == NULL) {
        fprintf(stderr, "unknown structural format was accepted\n");
        free(data);
        return 0;
      }
      free(data);
    }
  }
  size_t length;
  unsigned char *not_leading = one_core(COSMIC_ARTIFACT_PORTABLE,
                                       PORTABLE_TEST_TARGET_ID,
                                       PORTABLE_TEST_CONFIGURATION_ID, &length);
  if (not_leading == NULL) return 0;
  memcpy(not_leading + length - COSMIC_PORTABLE_TRAILER_LENGTH,
         COSMIC_HOST_TRAILER_MAGIC, 8);
  struct cosmic_portable decoded;
  const char *error = NULL;
  int result = decode_as(not_leading, length, COSMIC_ARTIFACT_HOST, 1, 0, 0,
                          &decoded, &error);
  int ok = result == 0 && all_zero(&decoded, sizeof decoded) && error != NULL &&
           strcmp(error, "host program core does not start the file") == 0;
  free(not_leading);
  if (!ok) fprintf(stderr, "host inspection accepted a non-leading core\n");
  unsigned char *multiple = one_core(COSMIC_ARTIFACT_HOST,
                                    PORTABLE_TEST_TARGET_ID,
                                    PORTABLE_TEST_CONFIGURATION_ID, &length);
  if (multiple == NULL) return 0;
  uint64_t manifest = COSMIC_PORTABLE_CORE_ALIGNMENT;
  put32(multiple + manifest + 24, 2);
  unsigned char *first = multiple + manifest + COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH;
  memcpy(first + COSMIC_PORTABLE_ENTRY_LENGTH, first, COSMIC_PORTABLE_ENTRY_LENGTH);
  result = decode_as(multiple, length, COSMIC_ARTIFACT_HOST, 1, 0, 0, &decoded, &error);
  if (result != 0 || !all_zero(&decoded, sizeof decoded) || error == NULL ||
      strcmp(error, "a host program carries exactly one core") != 0) {
    fprintf(stderr, "host inspection accepted multiple cores\n");
    ok = 0;
  }
  free(multiple);
  return ok;
}

static int policy_mutation (const char *name, const unsigned char *original,
                            size_t length, uint64_t offset, uint32_t target) {
  unsigned char *data = copy_of(original, length);
  if (data == NULL) return 0;
  put32(data + offset, target);
  struct cosmic_portable decoded;
  const char *error = NULL;
  int inspected = decode_as(data, length, COSMIC_ARTIFACT_PORTABLE, 1, 0, 0,
                            &decoded, &error);
  int ok = inspected == 1 && all_zero(&decoded.selected, sizeof decoded.selected);
  int started = decode_bytes(data, length, PORTABLE_TEST_TARGET_ID,
                             PORTABLE_TEST_CONFIGURATION_ID, &decoded, &error);
  ok &= started == 0 && all_zero(&decoded, sizeof decoded) && error != NULL &&
        strcmp(error, "manifest is missing a required release core") == 0;
  if (!ok) fprintf(stderr, "%s: inspection and startup were not distinguished\n", name);
  free(data);
  return ok;
}

static int inspect (const char *path, enum cosmic_artifact_format format) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    perror(path);
    return 2;
  }
  struct cosmic_portable decoded;
  const char *error = NULL;
  if (!cosmic_artifact_decode(fd, format, &decoded, &error)) {
    fprintf(stderr, "format: %s\n", error == NULL ? "rejected" : error);
    close(fd);
    return 1;
  }
  close(fd);
  printf("prefix %llu manifest %llu %llu database %llu %llu entries %u\n",
         (unsigned long long)decoded.prefix_length,
         (unsigned long long)decoded.manifest_offset,
         (unsigned long long)decoded.manifest_length,
         (unsigned long long)decoded.database_offset,
         (unsigned long long)decoded.database_length, decoded.entry_count);
  for (uint32_t i = 0; i < decoded.entry_count; i++) {
    const struct cosmic_portable_entry *entry = &decoded.entries[i];
    printf("entry %u %u %llu %llu ", entry->target_id,
           entry->configuration_id, (unsigned long long)entry->offset,
           (unsigned long long)entry->length);
    for (unsigned j = 0; j < COSMIC_PORTABLE_SHA256_LENGTH; j++)
      printf("%02x", entry->sha256[j]);
    putchar('\n');
  }
  return 0;
}

static int self_test (const char *path) {
  int fd = open(path, O_RDONLY);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < 1) {
    fprintf(stderr, "%s: cannot open, or empty\n", path);
    return 2;
  }
  size_t length = (size_t)st.st_size;
  unsigned char *data = malloc(length);
  if (data == NULL) {
    fprintf(stderr, "%s: out of memory\n", path);
    return 2;
  }
  size_t got = 0;
  while (got < length) {
    ssize_t part = read(fd, data + got, length - got);
    if (part <= 0) {
      fprintf(stderr, "%s: short read\n", path);
      return 2;
    }
    got += (size_t)part;
  }
  close(fd);

  struct cosmic_portable decoded;
  const char *error = NULL;
  int valid = decode_bytes(data, length, PORTABLE_TEST_TARGET_ID,
                           PORTABLE_TEST_CONFIGURATION_ID, &decoded, &error);
  if (valid != 1 || decoded.entry_count != 3) {
    fprintf(stderr, "valid writer fixture rejected: %s\n",
            valid < 0 ? "could not make test file"
            : valid == 1 ? "entry count is not 3"
            : error == NULL ? "unknown" : error);
    free(data);
    return 1;
  }
  uint64_t trailer = length - COSMIC_PORTABLE_TRAILER_LENGTH;
  uint64_t manifest = decoded.manifest_offset;
  uint64_t first = manifest + COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH;
  uint64_t second = first + COSMIC_PORTABLE_ENTRY_LENGTH;
  uint64_t third = second + COSMIC_PORTABLE_ENTRY_LENGTH;
  int ok = structural_cases();
  unsigned char four[4];
  unsigned char eight[8];

#define MUTATE32(name, offset, value)                                           \
  do {                                                                          \
    put32(four, (value));                                                        \
    ok &= mutation((name), data, length, (offset), four, sizeof four);           \
  } while (0)
#define MUTATE64(name, offset, value)                                           \
  do {                                                                          \
    put64(eight, (value));                                                       \
    ok &= mutation((name), data, length, (offset), eight, sizeof eight);         \
  } while (0)

  unsigned char bad_magic = 'X';
  ok &= mutation("shell shebang", data, length, 2, &bad_magic, 1);
  ok &= mutation("trailer magic", data, length, trailer, &bad_magic, 1);
  MUTATE32("trailer version", trailer + 8, 2);
  MUTATE32("trailer encoded length", trailer + 12, 0x30000000u);
  MUTATE64("manifest offset overflow", trailer + 16, UINT64_MAX);
  MUTATE64("database length overflow", trailer + 40, UINT64_MAX);
  ok &= mutation("manifest magic", data, length, manifest, &bad_magic, 1);
  MUTATE32("manifest version", manifest + 8, 0x01000000u);
  MUTATE32("manifest encoded length", manifest + 12, 0x00100000u);
  MUTATE64("prefix length", manifest + 16, decoded.prefix_length - 1);
  MUTATE32("entry count bound", manifest + 24, 9);
  MUTATE32("entry encoded length", manifest + 28, 0x38000000u);
  MUTATE32("zero target", first, 0);
  MUTATE32("zero configuration", first + 4, 0);
  ok &= policy_mutation("byte-swapped target", data, length, first, 0x01000000u);
  MUTATE64("byte-swapped core offset", first + 8, UINT64_C(0x0040000000000000));
  ok &= mutation("duplicate core", data, length, second, data + first, 8);
  ok &= policy_mutation("missing required target", data, length, third, 4);
  ok &= mutation("overlapping cores", data, length, second + 8,
                 data + first + 8, 8);
  MUTATE64("core range overflow offset", first + 8, UINT64_MAX - 7);
  MUTATE64("core range overflow length", first + 16, UINT64_MAX);
  unsigned char one = 1;
  uint64_t manifest_padding = manifest + COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH +
      3 * COSMIC_PORTABLE_ENTRY_LENGTH;
  ok &= mutation("manifest padding", data, length, manifest_padding, &one, 1);
  /* The zero padding after a core, up to the next core or the manifest:
   * the first run of at least 16 bytes. A core whose length is a whole
   * multiple of the alignment has none after it. */
  uint64_t gap = 0;
  uint64_t gap_end = 0;
  for (uint32_t i = 0; i < decoded.entry_count && gap == 0; i++) {
    uint64_t end = decoded.entries[i].offset + decoded.entries[i].length;
    uint64_t next = i + 1 < decoded.entry_count ? decoded.entries[i + 1].offset
                                                : manifest;
    if (end + 16 < next) {
      gap = end;
      gap_end = next;
    }
  }
  if (gap == 0) {
    fprintf(stderr, "no core is followed by 16 bytes of padding\n");
    ok = 0;
  } else {
    ok &= mutation("core padding", data, length, gap, &one, 1);
  }
  ok &= mutation("database header", data, length, decoded.database_offset,
                 &bad_magic, 1);
  ok &= expect_rejected("truncation", data, length - 1);

  unsigned char *dishonest = copy_of(data, length);
  uint64_t dishonest_offset = gap;
  if (dishonest != NULL && gap != 0 && dishonest_offset + 16 < gap_end) {
    memcpy(dishonest + dishonest_offset, "SQLite format 3\0", 16);
    put64(dishonest + trailer + 32, dishonest_offset);
    put64(dishonest + trailer + 40, trailer - dishonest_offset);
    ok &= expect_rejected("valid SQLite header at dishonest offset",
                          dishonest, length);
  } else {
    fprintf(stderr, "valid SQLite header at dishonest offset: %s\n",
            dishonest == NULL ? "out of memory"
                              : "no core padding of 16 bytes to place it in");
    ok = 0;
  }
  free(dishonest);

  unsigned char *reordered = copy_of(data, length);
  if (reordered == NULL) {
    ok = 0;
  } else {
    memcpy(reordered + first, data + third, COSMIC_PORTABLE_ENTRY_LENGTH);
    memcpy(reordered + third, data + first, COSMIC_PORTABLE_ENTRY_LENGTH);
    int inspected = decode_as(reordered, length, COSMIC_ARTIFACT_PORTABLE,
                               1, 0, 0, &decoded, &error);
    if (inspected != 1 || !all_zero(&decoded.selected, sizeof decoded.selected)) {
      fprintf(stderr, "manifest entry order changed structural validity\n");
      ok = 0;
    }
    free(reordered);
  }

  memset(&decoded, 0xa5, sizeof decoded);
  error = NULL;
  int mismatch = decode_bytes(data, length, PORTABLE_TEST_TARGET_ID,
                              PORTABLE_TEST_CONFIGURATION_ID + 1,
                              &decoded, &error);
  if (mismatch != 0 || !all_zero(&decoded, sizeof decoded) || error == NULL) {
    fprintf(stderr, "compiled core mismatch was accepted\n");
    ok = 0;
  }

  free(data);
  if (!ok) return 1;
  puts("portable format: PASS (structural inspection, startup policy and malformed mutations)");
  return 0;
}

int main (int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--inspect") == 0)
    return inspect(argv[2], COSMIC_ARTIFACT_PORTABLE);
  if (argc == 3 && strcmp(argv[1], "--inspect-host") == 0)
    return inspect(argv[2], COSMIC_ARTIFACT_HOST);
  if (argc == 2) return self_test(argv[1]);
  fprintf(stderr, "usage: format-test [--inspect|--inspect-host] ARTIFACT\n");
  return 2;
}
