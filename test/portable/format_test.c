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

static void put32(unsigned char *p, uint32_t value) {
  for (int i = 3; i >= 0; i--) {
    p[i] = (unsigned char)value;
    value >>= 8;
  }
}

static void put64(unsigned char *p, uint64_t value) {
  for (int i = 7; i >= 0; i--) {
    p[i] = (unsigned char)value;
    value >>= 8;
  }
}

static int all_zero(const void *data, size_t length) {
  const unsigned char *p = data;
  for (size_t i = 0; i < length; i++) {
    if (p[i] != 0) return 0;
  }
  return 1;
}

static int write_all(int fd, const unsigned char *data, size_t length) {
  while (length > 0) {
    ssize_t put = write(fd, data, length);
    if (put <= 0) return 0;
    data += (size_t)put;
    length -= (size_t)put;
  }
  return 1;
}

static int decode_bytes(const unsigned char *data, size_t length,
                        uint32_t target, uint32_t configuration,
                        struct cosmic_portable *decoded,
                        const char **error) {
  char path[] = "/tmp/cosmic-format-test.XXXXXX";
  int fd = mkstemp(path);
  if (fd < 0) return -1;
  unlink(path);
  int written = write_all(fd, data, length);
  int result = written ? cosmic_portable_decode(
      fd, target, configuration, decoded, error) : -1;
  close(fd);
  return result;
}

static int expect_rejected(const char *name, const unsigned char *data,
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
  return 1;
}

static unsigned char *copy_of(const unsigned char *data, size_t length) {
  unsigned char *copy = malloc(length);
  if (copy != NULL) memcpy(copy, data, length);
  return copy;
}

static int mutation(const char *name, const unsigned char *original,
                    size_t length, uint64_t offset,
                    const unsigned char *replacement, size_t replace_length) {
  unsigned char *changed = copy_of(original, length);
  if (changed == NULL || offset > length || replace_length > length - offset) {
    free(changed);
    return 0;
  }
  memcpy(changed + offset, replacement, replace_length);
  int ok = expect_rejected(name, changed, length);
  free(changed);
  return ok;
}

static int inspect(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return 2;
  struct cosmic_portable decoded;
  const char *error = NULL;
  if (!cosmic_portable_decode(fd, PORTABLE_TEST_TARGET_ID,
                              PORTABLE_TEST_CONFIGURATION_ID,
                              &decoded, &error)) {
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

static int self_test(const char *path) {
  int fd = open(path, O_RDONLY);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) != 0 || st.st_size < 1) return 2;
  size_t length = (size_t)st.st_size;
  unsigned char *data = malloc(length);
  if (data == NULL) return 2;
  size_t got = 0;
  while (got < length) {
    ssize_t part = read(fd, data + got, length - got);
    if (part <= 0) return 2;
    got += (size_t)part;
  }
  close(fd);

  struct cosmic_portable decoded;
  const char *error = NULL;
  int valid = decode_bytes(data, length, PORTABLE_TEST_TARGET_ID,
                           PORTABLE_TEST_CONFIGURATION_ID, &decoded, &error);
  if (valid != 1 || decoded.entry_count != 3) {
    fprintf(stderr, "valid writer fixture rejected: %s\n",
            error == NULL ? "unknown" : error);
    free(data);
    return 1;
  }
  uint64_t trailer = length - COSMIC_PORTABLE_TRAILER_LENGTH;
  uint64_t manifest = decoded.manifest_offset;
  uint64_t first = manifest + COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH;
  uint64_t second = first + COSMIC_PORTABLE_ENTRY_LENGTH;
  uint64_t third = second + COSMIC_PORTABLE_ENTRY_LENGTH;
  int ok = 1;
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
  MUTATE32("byte-swapped target", first, 0x01000000u);
  MUTATE64("byte-swapped core offset", first + 8, UINT64_C(0x0040000000000000));
  ok &= mutation("duplicate core", data, length, second, data + first, 8);
  MUTATE32("missing required target", third, 4);
  ok &= mutation("overlapping cores", data, length, second + 8,
                 data + first + 8, 8);
  MUTATE64("core range overflow offset", first + 8, UINT64_MAX - 7);
  MUTATE64("core range overflow length", first + 16, UINT64_MAX);
  unsigned char one = 1;
  uint64_t manifest_padding = manifest + COSMIC_PORTABLE_MANIFEST_HEADER_LENGTH +
      3 * COSMIC_PORTABLE_ENTRY_LENGTH;
  ok &= mutation("manifest padding", data, length, manifest_padding, &one, 1);
  uint64_t first_end = decoded.entries[0].offset + decoded.entries[0].length;
  if (first_end < decoded.entries[1].offset)
    ok &= mutation("core padding", data, length, first_end, &one, 1);
  ok &= mutation("database header", data, length, decoded.database_offset,
                 &bad_magic, 1);
  ok &= expect_rejected("truncation", data, length - 1);

  unsigned char *dishonest = copy_of(data, length);
  uint64_t dishonest_offset = first_end;
  if (dishonest != NULL && dishonest_offset + 16 < decoded.entries[1].offset) {
    memcpy(dishonest + dishonest_offset, "SQLite format 3\0", 16);
    put64(dishonest + trailer + 32, dishonest_offset);
    put64(dishonest + trailer + 40, trailer - dishonest_offset);
    ok &= expect_rejected("valid SQLite header at dishonest offset",
                          dishonest, length);
  } else {
    ok = 0;
  }
  free(dishonest);

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
  puts("portable format: PASS (valid writer round trip and malformed mutations rejected)");
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--inspect") == 0) return inspect(argv[2]);
  if (argc == 2) return self_test(argv[1]);
  fprintf(stderr, "usage: format-test [--inspect] ARTIFACT\n");
  return 2;
}
