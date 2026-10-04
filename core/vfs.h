/*
 * The VFS that reads a database sitting at an offset inside another
 * file. The caller hands it the retained descriptor, offset, and length from
 * the validated portable artifact.
 */

#ifndef COSMIC_VFS_H
#define COSMIC_VFS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "sqlite3.h"

#define COSMIC_VFS_NAME "cosmic"

/* Registers the VFS and the one (path, fd, offset, length) it will
 * open, once, as the main database: `path` must later match exactly,
 * and the bytes are read from `fd` between `offset` and `length`, which
 * come from here, never from a URI. The first open that succeeds
 * consumes the four, so no later connection reaches the range again.
 * Only startup registers: a second call replaces the four, opening the
 * door again, and the VFS itself registers once.
 * Returns SQLite's own status: SQLITE_OK, or why it refused. */
int cosmic_vfs_register (const char *path, int fd, int64_t offset,
                         int64_t length);

/* Writes the `file:` URI that opens `path` through this VFS, read-only
 * and immutable. `path` must be the one [`cosmic_vfs_register`] was given.
 * Returns false when the URI does not fit in `room`. */
bool cosmic_vfs_uri (char *into, size_t room, const char *path);

/* Independent inspection backing. Creation takes ownership of fd only on
 * success. The caller owns one reference; each opened SQLite file owns
 * another. No filename can acquire a reference outside these C calls. */
struct cosmic_inspection;
struct cosmic_inspection *cosmic_inspection_create (int fd, int64_t offset,
                                                     int64_t length);
void cosmic_inspection_release (struct cosmic_inspection *backing);
int cosmic_inspection_open (struct cosmic_inspection *backing, sqlite3 **db);
int cosmic_inspection_attach (struct cosmic_inspection *backing, sqlite3 *db,
                               const char *schema);

#endif
