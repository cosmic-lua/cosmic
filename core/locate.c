#define _XOPEN_SOURCE 700

#include "locate.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <limits.h>
#include <mach-o/dyld.h>
#endif

/* The one call the two systems spell differently. */
int cosmic_executable_path(char *into, size_t room) {
#if defined(__APPLE__)
  char raw[PATH_MAX];
  uint32_t size = sizeof raw;
  if (_NSGetExecutablePath(raw, &size) != 0) {
    return 0;
  }
  char resolved[PATH_MAX];
  if (realpath(raw, resolved) == NULL) {
    return 0;
  }
  size_t len = strlen(resolved);
  if (len + 1 > room) {
    return 0;
  }
  memcpy(into, resolved, len + 1);
  return 1;
#else
  ssize_t len = readlink("/proc/self/exe", into, room - 1);
  if (len < 0) {
    return 0;
  }
  into[len] = '\0';
  return 1;
#endif
}

#define MACHO_MAGIC_64 0xfeedfacfu
#define MACHO_LC_CODE_SIGNATURE 0x1du

static int read_at(int fd, void *into, size_t len, int64_t at) {
  unsigned char *p = into;
  while (len > 0) {
    ssize_t got = pread(fd, p, len, (off_t)at);
    if (got <= 0) {
      return 0;
    }
    p += got;
    at += got;
    len -= (size_t)got;
  }
  return 1;
}

/* Decoded as unsigned throughout, so a top-bit byte never becomes a
 * signed left shift -- undefined behavior the standard leaves no
 * defined result for -- and never quietly turns into a small negative
 * offset either; it stays the huge unsigned value it is, and the range
 * check below rejects it outright. */
static uint64_t be64(const unsigned char *p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) {
    v = (v << 8) | (uint64_t)p[i];
  }
  return v;
}

static uint32_t le32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
         (uint32_t)p[3] << 24;
}

#define SQLITE_HEADER "SQLite format 3\0"
#define SQLITE_HEADER_LEN 16

/* Whether `offset` is where a database actually starts: SQLite's own
 * fixed 16-byte page-1 header. Anything else -- text, another format's
 * bytes, a stray marker -- is not a database, whatever the trailer
 * claims. */
static int looks_like_a_database(int fd, int64_t offset) {
  unsigned char header[SQLITE_HEADER_LEN];
  if (!read_at(fd, header, sizeof header, offset)) {
    return 0;
  }
  return memcmp(header, SQLITE_HEADER, SQLITE_HEADER_LEN) == 0;
}

/* Reads the trailer that ends at `end` and turns it into an attachment. */
static int trailer_at(int fd, int64_t end, int64_t file_size,
                      struct cosmic_attachment *out) {
  if (end < COSMIC_TRAILER_LEN) {
    return 0;
  }
  unsigned char trailer[COSMIC_TRAILER_LEN];
  if (!read_at(fd, trailer, sizeof trailer, end - COSMIC_TRAILER_LEN)) {
    return 0;
  }
  if (memcmp(trailer, COSMIC_MARKER, COSMIC_MARKER_LEN) != 0) {
    return 0;
  }
  uint64_t offset_u = be64(trailer + COSMIC_MARKER_LEN);
  uint64_t end_u = (uint64_t)(end - COSMIC_TRAILER_LEN);
  if (offset_u == 0 || offset_u >= end_u || offset_u > (uint64_t)file_size) {
    return 0;
  }
  int64_t offset = (int64_t)offset_u;
  int64_t length = end - COSMIC_TRAILER_LEN - offset;
  if (length <= 0) {
    return 0;
  }
  if (!looks_like_a_database(fd, offset)) {
    return 0;
  }
  out->offset = offset;
  out->length = length;
  return 1;
}

/* However many load commands a real Mach-O ever carries; a file naming
 * more is malformed or hostile, not merely large. */
#define MACHO_MAX_NCMDS 1024

/* Finds the code signature's file offset, which is where the trailer
 * ends on Mach-O. Returns 0 when the file is not a thin 64-bit Mach-O,
 * carries no signature, or its load commands do not add up: each one
 * at least 8 bytes and 8-aligned, the running total never past
 * `sizeofcmds`, and `sizeofcmds` itself never past the file. */
static int signature_offset(int fd, int64_t file_size, int64_t *out) {
  unsigned char header[32];
  if (!read_at(fd, header, sizeof header, 0)) {
    return 0;
  }
  if (le32(header) != MACHO_MAGIC_64) {
    return 0;
  }
  uint32_t ncmds = le32(header + 16);
  uint32_t sizeofcmds = le32(header + 20);
  if (ncmds == 0 || ncmds > MACHO_MAX_NCMDS ||
      sizeofcmds > (uint32_t)file_size) {
    return 0;
  }

  int64_t at = 32;
  uint32_t consumed = 0;
  for (uint32_t i = 0; i < ncmds; i++) {
    unsigned char command[16];
    if (!read_at(fd, command, sizeof command, at)) {
      return 0;
    }
    uint32_t cmd = le32(command);
    uint32_t cmdsize = le32(command + 4);
    if (cmdsize < 8 || cmdsize % 8 != 0) {
      return 0;
    }
    if (cmdsize > sizeofcmds - consumed) {
      return 0;
    }
    consumed += cmdsize;
    if (cmd == MACHO_LC_CODE_SIGNATURE) {
      *out = (int64_t)le32(command + 8);
      return 1;
    }
    at += cmdsize;
  }
  return 0;
}

int cosmic_locate(const char *path, struct cosmic_attachment *out) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    return -1;
  }
  struct stat st;
  if (fstat(fd, &st) != 0) {
    close(fd);
    return -1;
  }
  int64_t size = (int64_t)st.st_size;

  int found = trailer_at(fd, size, size, out);
  if (!found) {
    int64_t signature;
    if (signature_offset(fd, size, &signature) && signature <= size) {
      found = trailer_at(fd, signature, size, out);
    }
  }
  close(fd);
  return found;
}
