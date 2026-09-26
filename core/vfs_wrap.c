#include "vfs_wrap.h"

#include <stddef.h>

sqlite3_vfs *cosmic_vfs_base (sqlite3_vfs *vfs) {
  return (sqlite3_vfs *)vfs->pAppData;
}

static int forward_delete (sqlite3_vfs *vfs, const char *name, int sync) {
  sqlite3_vfs *base = cosmic_vfs_base(vfs);
  return base->xDelete(base, name, sync);
}

static int forward_access (sqlite3_vfs *vfs, const char *name, int flags,
                           int *out) {
  sqlite3_vfs *base = cosmic_vfs_base(vfs);
  return base->xAccess(base, name, flags, out);
}

static int forward_full_pathname (sqlite3_vfs *vfs, const char *name,
                                  int room, char *out) {
  sqlite3_vfs *base = cosmic_vfs_base(vfs);
  return base->xFullPathname(base, name, room, out);
}

static int forward_randomness (sqlite3_vfs *vfs, int amount, char *out) {
  sqlite3_vfs *base = cosmic_vfs_base(vfs);
  return base->xRandomness(base, amount, out);
}

static int forward_sleep (sqlite3_vfs *vfs, int micros) {
  sqlite3_vfs *base = cosmic_vfs_base(vfs);
  return base->xSleep(base, micros);
}

/* The base's own xCurrentTime is NULL: the build omits what is
 * deprecated, and SQLite asks a VFS of version 2 this instead. */
static int forward_current_time (sqlite3_vfs *vfs, sqlite3_int64 *out) {
  sqlite3_vfs *base = cosmic_vfs_base(vfs);
  return base->xCurrentTimeInt64(base, out);
}

static int forward_last_error (sqlite3_vfs *vfs, int room, char *out) {
  sqlite3_vfs *base = cosmic_vfs_base(vfs);
  return base->xGetLastError(base, room, out);
}

sqlite3_vfs cosmic_vfs_wrapping (
    sqlite3_vfs *base, const char *name, int extra,
    int (*open)(sqlite3_vfs *, sqlite3_filename, sqlite3_file *, int, int *)) {
  if (base == NULL || base->iVersion < 2 || base->xCurrentTimeInt64 == NULL)
    return (sqlite3_vfs){ .zName = NULL };
  return (sqlite3_vfs){
    .iVersion = 2,
    .szOsFile = extra + base->szOsFile,
    .mxPathname = base->mxPathname,
    .zName = name,
    .pAppData = base,
    .xOpen = open,
    .xDelete = forward_delete,
    .xAccess = forward_access,
    .xFullPathname = forward_full_pathname,
    .xRandomness = forward_randomness,
    .xSleep = forward_sleep,
    .xGetLastError = forward_last_error,
    .xCurrentTimeInt64 = forward_current_time,
  };
}
