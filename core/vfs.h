/*
 * The VFS that reads a database sitting at an offset inside another
 * file. The caller hands it the retained descriptor, offset, and length from
 * the validated portable artifact.
 */

#ifndef COSMIC_VFS_H
#define COSMIC_VFS_H

#include <stddef.h>
#include <stdint.h>

#include "sqlite3.h"

#define COSMIC_VFS_NAME "cosmic"

/* Registers the VFS and the one (path, offset, length) triple it will
 * ever open as the main database: `path` must later match exactly, and
 * `offset`/`length` come from here, never from a URI. Safe to call more
 * than once; the triple is replaced and the VFS itself registers once. */
int cosmic_vfs_register(const char *path, int fd, int64_t offset,
                        int64_t length);

/* Writes the `file:` URI that opens `path` through this VFS, read-only
 * and immutable. `path` must be the one `cosmic_vfs_register` was given.
 * Returns 0 when the URI does not fit in `room`. */
int cosmic_vfs_uri(char *into, size_t room, const char *path);

#endif
