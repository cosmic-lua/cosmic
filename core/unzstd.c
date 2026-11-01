/*
** unzstd: decode one range of a file as one zstd frame onto standard output.
**
**   unzstd <fd> <offset> <stored> <length> > bytes
**
** <fd> is an inherited descriptor, 3 to 9, open on a regular file (the
** portable artifact the launcher holds). The program reads the <stored>
** bytes at <offset> with pread(2), which neither uses nor moves the
** descriptor's file offset, and writes the <length> bytes they decode to.
** All four are decimal and are held to their range: a descriptor outside 3
** to 9 or not on a regular file, a number that does not fit 63 bits, a
** <length> of zero or over COSMIC_UNZSTD_MAX_LENGTH, and an offset and a
** stored length whose sum does not fit are refused.
**
** The range must hold exactly one zstd frame, and nothing after it: not
** a second frame, a skippable frame or any other byte. The frame must
** declare its content size, equal to <length>, and carry a checksum, which
** the decoder verifies; its window must be within COSMIC_UNZSTD_WINDOW_LOG
** (core/unzstd.h). The program never writes more than <length> bytes,
** so a hostile range cannot fill a disk, and is bounded in memory: the
** decoder's state sits in a fixed workspace sized for that window, and
** nothing is allocated.
**
** Any failure ends in a one-line message on standard error and a nonzero
** status: 1 the range is not the frame the arguments name (including a
** range that runs past the end of the file), 2 usage, 3 a failed read,
** write or allocation. The caller still checks the size and digest of what
** was written, which this program does not replace.
**
** Only libzstd's decoder and libc are used, so the program links static
** against musl and against libSystem on macOS. It is not part of the core:
** it is built apart, for each target at the architecture's baseline CPU.
*/

#define _POSIX_C_SOURCE 200809L
#define ZSTD_STATIC_LINKING_ONLY

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <zstd.h>

#include "unzstd.h"

#define STATUS_DATA 1
#define STATUS_USAGE 2
#define STATUS_IO 3

static unsigned char in_buf[1u << 16];
static unsigned char out_buf[1u << 17];
/* The decoder's state for a window of COSMIC_UNZSTD_WINDOW_LOG: the window
** itself, a block of input and of output, and the tables, with room over.
** Untouched pages of it cost nothing. */
static unsigned char workspace[((size_t)1 << COSMIC_UNZSTD_WINDOW_LOG) + ((size_t)1 << 20)]
  __attribute__((aligned(16)));

static void say (const char *text) {
  size_t left = strlen(text);
  while (left > 0) {
    ssize_t n = write(STDERR_FILENO, text, left);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return;
    text += n;
    left -= (size_t)n;
  }
}

static _Noreturn void die (int status, const char *what, const char *detail) {
  say("unzstd: ");
  say(what);
  if (detail != NULL) {
    say(": ");
    say(detail);
  }
  say("\n");
  _exit(status);
}

/* The decimal number `text` names, or dies: digits only, no sign or
** space, and at most `limit`. */
static uint64_t parse_number (const char *text, uint64_t limit, const char *name) {
  uint64_t value = 0;
  if (*text == '\0') die(STATUS_USAGE, name, "is empty");
  for (; *text != '\0'; text++) {
    if (*text < '0' || *text > '9') die(STATUS_USAGE, name, "is not a decimal number");
    uint64_t digit = (uint64_t)(*text - '0');
    if (digit > limit || value > (limit - digit) / 10) die(STATUS_USAGE, name, "is out of range");
    value = value * 10 + digit;
  }
  return value;
}

static void write_all (const unsigned char *data, size_t size) {
  while (size > 0) {
    ssize_t n = write(STDOUT_FILENO, data, size);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) die(STATUS_IO, "cannot write the output", strerror(errno));
    data += n;
    size -= (size_t)n;
  }
}

/* Fills `in_buf` with the `want` bytes of `fd` at `offset`, or dies. A
** short file is the caller's range being wrong, not a failed read. */
static void read_range (int fd, uint64_t offset, size_t want) {
  size_t have = 0;
  while (have < want) {
    ssize_t n = pread(fd, in_buf + have, want - have, (off_t)(offset + have));
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) die(STATUS_IO, "cannot read the input", strerror(errno));
    if (n == 0) die(STATUS_DATA, "the file ends inside the stored range", NULL);
    have += (size_t)n;
  }
}

/* Dies unless the frame header at the start of `in_buf`, `got` bytes of
** it, is the one frame this program decodes to `length` bytes. */
static void check_header (size_t got, uint64_t length) {
  ZSTD_FrameHeader header;
  size_t needed = ZSTD_getFrameHeader(&header, in_buf, got);
  if (ZSTD_isError(needed)) die(STATUS_DATA, "bad frame header", ZSTD_getErrorName(needed));
  if (needed != 0) die(STATUS_DATA, "truncated frame header", NULL);
  if (header.frameType != ZSTD_frame) die(STATUS_DATA, "a skippable frame", NULL);
  if (header.frameContentSize != length)
    die(STATUS_DATA, "the frame does not declare the content size the length names", NULL);
  if (!header.checksumFlag) die(STATUS_DATA, "the frame has no checksum", NULL);
  if (header.windowSize > ((unsigned long long)1 << COSMIC_UNZSTD_WINDOW_LOG))
    die(STATUS_DATA, "the frame's window is too large", NULL);
}

int main (int argc, char **argv) {
  if (argc != 5) die(STATUS_USAGE, "usage: unzstd <fd> <offset> <stored> <length> > bytes", NULL);
  int fd = (int)parse_number(argv[1], 9, "the descriptor");
  if (fd < 3) die(STATUS_USAGE, "the descriptor", "is not 3 to 9");
  uint64_t offset = parse_number(argv[2], (uint64_t)INT64_MAX, "the offset");
  uint64_t stored = parse_number(argv[3], (uint64_t)INT64_MAX, "the stored length");
  uint64_t remaining = parse_number(argv[4], (uint64_t)INT64_MAX, "the length");
  if (stored > (uint64_t)INT64_MAX - offset) die(STATUS_USAGE, "the stored range", "is out of range");
  if (remaining == 0 || remaining > COSMIC_UNZSTD_MAX_LENGTH) die(STATUS_USAGE, "the length", "is out of range");
  if (stored == 0) die(STATUS_DATA, "the stored range is empty", NULL);
  struct stat info;
  if (fstat(fd, &info) != 0) die(STATUS_IO, "cannot examine the descriptor", strerror(errno));
  if (!S_ISREG(info.st_mode)) die(STATUS_USAGE, "the descriptor", "is not a regular file");

  /* A static decoder never allocates: a frame that needs more than the
  ** workspace holds fails to decode. */
  if (ZSTD_estimateDStreamSize((size_t)1 << COSMIC_UNZSTD_WINDOW_LOG) > sizeof workspace)
    die(STATUS_IO, "the decoder does not fit its workspace", NULL);
  ZSTD_DCtx *context = ZSTD_initStaticDCtx(workspace, sizeof workspace);
  if (context == NULL) die(STATUS_IO, "cannot start the decoder", NULL);
  if (ZSTD_isError(ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, COSMIC_UNZSTD_WINDOW_LOG)))
    die(STATUS_IO, "cannot set the window limit", NULL);

  /* What the decoder last said is owed: zero only once the frame has
  ** ended, whole and verified. */
  size_t owed = 1;
  uint64_t checked = remaining;
  int first = 1;
  while (stored > 0) {
    size_t got = sizeof in_buf;
    if (stored < got) got = (size_t)stored;
    read_range(fd, offset, got);
    offset += got;
    stored -= got;
    if (first) check_header(got, checked);
    first = 0;
    ZSTD_inBuffer in = {in_buf, got, 0};
    ZSTD_outBuffer out;
    do {
      /* One byte past what is left, so an excess shows without being
      ** written; never past the buffer. */
      size_t room = sizeof out_buf;
      if (remaining < room) room = (size_t)remaining + 1;
      out.dst = out_buf;
      out.size = room;
      out.pos = 0;
      owed = ZSTD_decompressStream(context, &out, &in);
      if (ZSTD_isError(owed)) die(STATUS_DATA, "corrupt frame", ZSTD_getErrorName(owed));
      if (out.pos > remaining) die(STATUS_DATA, "the frame decodes to more than the length", NULL);
      write_all(out_buf, out.pos);
      remaining -= out.pos;
      if (owed == 0) {
        if (in.pos < in.size || stored > 0) die(STATUS_DATA, "bytes after the frame", NULL);
        break;
      }
      /* A full buffer may leave output the decoder holds, though the
      ** input is used up. */
    } while (in.pos < in.size || out.pos == out.size);
  }
  if (owed != 0) die(STATUS_DATA, "truncated frame", NULL);
  if (remaining != 0) die(STATUS_DATA, "the frame decodes to less than the length", NULL);
  if (close(STDOUT_FILENO) != 0) die(STATUS_IO, "cannot finish the output", strerror(errno));
  return 0;
}
