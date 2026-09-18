/*
 * The VFS that reads a database sitting at an offset inside another
 * file. It is how the runtime opens the database attached to its own
 * executable, and it knows nothing about ELF or Mach-O: the caller hands
 * it an offset and a length.
 */

#ifndef COSMIC_VFS_H
#define COSMIC_VFS_H

#include <stddef.h>
#include <stdint.h>

#include "sqlite3.h"

#define COSMIC_VFS_NAME "cosmic"

/* Registers the VFS. Safe to call more than once; it registers once. */
int cosmic_vfs_register(void);

/* Writes the `file:` URI that opens `path` at `offset` for `length`
 * bytes through this VFS, read-only and immutable. Returns 0 when the
 * URI does not fit in `room`. */
int cosmic_vfs_uri(char *into, size_t room, const char *path, int64_t offset,
                   int64_t length);

#endif
