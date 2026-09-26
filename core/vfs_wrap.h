/*
 * A VFS that wraps another: the one registered over SQLite's default
 * for every connection `cosmic.sqlite` opens (core/sqlite.c) and the
 * one that reads the binary's own database (core/vfs.c). Each keeps the
 * VFS it wraps in `pAppData` and hands it every call it does not
 * handle itself.
 */

#ifndef COSMIC_VFS_WRAP_H
#define COSMIC_VFS_WRAP_H

#include "sqlite3.h"

/* The VFS `vfs` wraps. */
sqlite3_vfs *cosmic_vfs_base (sqlite3_vfs *vfs);

/* A version-2 VFS named `name` over `base`, forwarding every call to it
 * but `xOpen`, whose files are `extra` bytes larger than the base's; a
 * caller replaces any other call it handles itself. NULL `base`, or one
 * older than version 2 or without xCurrentTimeInt64, cannot be wrapped:
 * the answer's zName is then NULL. */
sqlite3_vfs cosmic_vfs_wrapping (
    sqlite3_vfs *base, const char *name, int extra,
    int (*open)(sqlite3_vfs *, sqlite3_filename, sqlite3_file *, int, int *));

#endif
