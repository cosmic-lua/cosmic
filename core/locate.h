/*
 * Where the attached database sits inside the running executable.
 *
 * The attach appends the database to the core image and writes a
 * trailer: the marker below, then the database's start offset as eight
 * big-endian bytes. On ELF the trailer is the last 25 bytes of the file.
 * On Mach-O it sits immediately before the code signature, because arm64
 * macOS refuses a binary with bytes after its signature.
 */

#ifndef COSMIC_LOCATE_H
#define COSMIC_LOCATE_H

#include <stddef.h>
#include <stdint.h>

/* Deliberately not SQLite's own appendvfs marker, so a stray appended
 * database is never mistaken for one of ours. */
#define COSMIC_MARKER "Start-Of-Cosmic--"
#define COSMIC_MARKER_LEN 17
#define COSMIC_TRAILER_LEN (COSMIC_MARKER_LEN + 8)

struct cosmic_attachment {
  int64_t offset;
  int64_t length;
};

/* Writes the running executable's own path. Returns 1 on success and 0
 * when it does not fit or the system will not say. */
int cosmic_executable_path(char *into, size_t room);

/* Opens the physical executable for private portable identity binding. */
int cosmic_executable_fd(void);

/* Fills `out` and returns 1 when the file carries a database, 0 when it
 * carries none, and -1 when the file could not be read at all. */
int cosmic_locate(int fd, struct cosmic_attachment *out);
int cosmic_locate_path(const char *path, struct cosmic_attachment *out);

#endif
