#define _XOPEN_SOURCE 700

#include "vfs.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>

/* The retained descriptor does the reading; this VFS shifts its database
 * range and refuses every write. */
struct cosmic_file {
  sqlite3_file base;
  sqlite3_int64 offset;
  sqlite3_int64 length;
  int fd;
};

static sqlite3_vfs *base_vfs (sqlite3_vfs *vfs) {
  return (sqlite3_vfs *)vfs->pAppData;
}

static int file_close (sqlite3_file *file) {
  (void)file;
  return SQLITE_OK; /* the retained descriptor is borrowed until DB close */
}

static int retained_read (int fd, void *buf, int amount, sqlite3_int64 at) {
  unsigned char *p = buf;
  int left = amount;
  while (left > 0) {
    ssize_t got = pread(fd, p, (size_t)left, (off_t)at);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) return SQLITE_IOERR_READ;
    p += (size_t)got;
    left -= (int)got;
    at += (sqlite3_int64)got;
  }
  return SQLITE_OK;
}

static int file_read (sqlite3_file *file, void *buf, int amount,
                      sqlite3_int64 at) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  if (at < 0 || at > f->length) {
    memset(buf, 0, (size_t)amount);
    return SQLITE_IOERR_SHORT_READ;
  }
  sqlite3_int64 room = f->length - at;
  if (room < amount) {
    /* A short read is reported, with the tail zeroed, the way SQLite
     * expects; it means the database is truncated, not that we failed. */
    int have = (int)room;
    int rc = retained_read(f->fd, buf, have, f->offset + at);
    memset((char *)buf + have, 0, (size_t)(amount - have));
    return rc == SQLITE_OK ? SQLITE_IOERR_SHORT_READ : rc;
  }
  return retained_read(f->fd, buf, amount, f->offset + at);
}

static int file_write (sqlite3_file *file, const void *buf, int amount,
                       sqlite3_int64 at) {
  (void)file;
  (void)buf;
  (void)amount;
  (void)at;
  return SQLITE_READONLY;
}

static int file_truncate (sqlite3_file *file, sqlite3_int64 size) {
  (void)file;
  (void)size;
  return SQLITE_READONLY;
}

static int file_sync (sqlite3_file *file, int flags) {
  (void)file;
  (void)flags;
  return SQLITE_OK;
}

static int file_size (sqlite3_file *file, sqlite3_int64 *out) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  *out = f->length;
  return SQLITE_OK;
}

static int file_lock (sqlite3_file *file, int level) {
  (void)file;
  return level > SQLITE_LOCK_SHARED ? SQLITE_READONLY : SQLITE_OK;
}

static int file_unlock (sqlite3_file *file, int level) {
  (void)file;
  (void)level;
  return SQLITE_OK;
}

static int file_check_reserved (sqlite3_file *file, int *out) {
  (void)file;
  *out = 0;
  return SQLITE_OK;
}

static int file_control (sqlite3_file *file, int op, void *arg) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  if (op == SQLITE_FCNTL_VFSNAME) {
    *(char **)arg = sqlite3_mprintf(COSMIC_VFS_NAME "(%lld)", f->offset);
    return SQLITE_OK;
  }
  return SQLITE_NOTFOUND;
}

static int file_sector_size (sqlite3_file *file) {
  (void)file;
  return 4096;
}

static int file_characteristics (sqlite3_file *file) {
  (void)file;
  return SQLITE_IOCAP_IMMUTABLE;
}

static const sqlite3_io_methods cosmic_io_methods = {
  .iVersion = 1,
  .xClose = file_close,
  .xRead = file_read,
  .xWrite = file_write,
  .xTruncate = file_truncate,
  .xSync = file_sync,
  .xFileSize = file_size,
  .xLock = file_lock,
  .xUnlock = file_unlock,
  .xCheckReservedLock = file_check_reserved,
  .xFileControl = file_control,
  .xSectorSize = file_sector_size,
  .xDeviceCharacteristics = file_characteristics,
};

/* The one artifact range this VFS ever opens, fixed at registration from the
 * validated retained descriptor and never taken from a URI: `off=`/`len=`
 * parameter is refused rather than honored, and a path that is not this
 * one exact artifact is refused too. There is exactly one door. */
static char registered_path[4096];
static sqlite3_int64 registered_offset;
static sqlite3_int64 registered_length;
static int registered_fd = -1;

static int vfs_open (sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *file,
                     int flags, int *out_flags) {
  sqlite3_vfs *lower_vfs = base_vfs(vfs);
  struct cosmic_file *f = (struct cosmic_file *)file;
  memset(f, 0, sizeof *f);
  f->fd = -1;

  if (name != NULL && (sqlite3_uri_parameter(name, "off") != NULL ||
                        sqlite3_uri_parameter(name, "len") != NULL)) {
    return SQLITE_CANTOPEN;
  }

  if ((flags & SQLITE_OPEN_MAIN_DB) == 0) {
    /* Anything that is not the main database file -- a temporary file,
     * a journal -- is the base VFS's business, and the caller sees its
     * methods. */
    return lower_vfs->xOpen(lower_vfs, name, file, flags, out_flags);
  }

  if (name == NULL || registered_path[0] == '\0' ||
      strcmp(name, registered_path) != 0) {
    return SQLITE_CANTOPEN;
  }

  f->offset = registered_offset;
  f->length = registered_length;
  f->fd = registered_fd;
  if (f->fd < 0 || f->offset <= 0 || f->length <= 0) {
    return SQLITE_CANTOPEN;
  }
  if (out_flags != NULL) {
    *out_flags = SQLITE_OPEN_READONLY;
  }
  f->base.pMethods = &cosmic_io_methods;
  return SQLITE_OK;
}

static int vfs_delete (sqlite3_vfs *vfs, const char *name, int sync) {
  return base_vfs(vfs)->xDelete(base_vfs(vfs), name, sync);
}

static int vfs_access (sqlite3_vfs *vfs, const char *name, int flags, int *out) {
  return base_vfs(vfs)->xAccess(base_vfs(vfs), name, flags, out);
}

static int vfs_full_pathname (sqlite3_vfs *vfs, const char *name, int room,
                              char *out) {
  /* The logical artifact spelling is an opaque database key. Normalizing
   * `/./` or a symlink alias here would make xOpen reject the same retained
   * file, and reopening the normalized pathname would break adoption. */
  if (name != NULL && registered_path[0] != '\0' &&
      strcmp(name, registered_path) == 0) {
    size_t length = strlen(name);
    if (length + 1 > (size_t)room) return SQLITE_CANTOPEN;
    memcpy(out, name, length + 1);
    return SQLITE_OK;
  }
  return base_vfs(vfs)->xFullPathname(base_vfs(vfs), name, room, out);
}

static int vfs_randomness (sqlite3_vfs *vfs, int amount, char *out) {
  return base_vfs(vfs)->xRandomness(base_vfs(vfs), amount, out);
}

static int vfs_sleep (sqlite3_vfs *vfs, int micros) {
  return base_vfs(vfs)->xSleep(base_vfs(vfs), micros);
}

static int vfs_current_time (sqlite3_vfs *vfs, double *out) {
  return base_vfs(vfs)->xCurrentTime(base_vfs(vfs), out);
}

static int vfs_last_error (sqlite3_vfs *vfs, int room, char *out) {
  return base_vfs(vfs)->xGetLastError(base_vfs(vfs), room, out);
}

int cosmic_vfs_register (const char *path, int fd, int64_t offset,
                         int64_t length) {
  if (strlen(path) >= sizeof registered_path) {
    return SQLITE_ERROR;
  }
  memcpy(registered_path, path, strlen(path) + 1);
  registered_offset = (sqlite3_int64)offset;
  registered_length = (sqlite3_int64)length;
  registered_fd = fd;

  if (sqlite3_vfs_find(COSMIC_VFS_NAME) != NULL) {
    return SQLITE_OK;
  }
  sqlite3_vfs *lower = sqlite3_vfs_find(NULL);
  if (lower == NULL) {
    return SQLITE_ERROR;
  }

  /* SQLite's VFS registry holds the pointer for the life of the
   * process, so this one object is static; it is written once, before
   * any database is opened, and read-only after. */
  static sqlite3_vfs vfs;
  vfs = (sqlite3_vfs){
    .iVersion = 1,
    .szOsFile = (int)sizeof(struct cosmic_file) + lower->szOsFile,
    .mxPathname = lower->mxPathname,
    .zName = COSMIC_VFS_NAME,
    .pAppData = lower,
    .xOpen = vfs_open,
    .xDelete = vfs_delete,
    .xAccess = vfs_access,
    .xFullPathname = vfs_full_pathname,
    .xRandomness = vfs_randomness,
    .xSleep = vfs_sleep,
    .xCurrentTime = vfs_current_time,
    .xGetLastError = vfs_last_error,
  };
  return sqlite3_vfs_register(&vfs, 0);
}

/* Percent-encodes what a `file:` URI cannot carry literally. */
static bool append_escaped (char *into, size_t room, size_t *at, const char *s) {
  static const char hex[] = "0123456789ABCDEF";
  for (; *s != '\0'; s++) {
    unsigned char c = (unsigned char)*s;
    int plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c == '/' || c == '-' || c == '_' ||
                c == '.' || c == '~';
    if (plain) {
      if (*at + 1 >= room) {
        return false;
      }
      into[(*at)++] = (char)c;
    } else {
      if (*at + 3 >= room) {
        return false;
      }
      into[(*at)++] = '%';
      into[(*at)++] = hex[c >> 4];
      into[(*at)++] = hex[c & 15];
    }
  }
  into[*at] = '\0';
  return true;
}

bool cosmic_vfs_uri (char *into, size_t room, const char *path) {
  size_t at = 0;
  const char *scheme = "file:";
  size_t scheme_len = strlen(scheme);
  if (scheme_len + 1 >= room) {
    return false;
  }
  memcpy(into, scheme, scheme_len);
  at = scheme_len;
  if (!append_escaped(into, room, &at, path)) {
    return false;
  }
  /* No off= or len=: the VFS never trusts a URI for those. The one triple it
   * honors was registered from the validated retained artifact. */
  static const char tail[] = "?vfs=" COSMIC_VFS_NAME "&mode=ro&immutable=1";
  size_t written = sizeof tail - 1;
  if (at + written + 1 > room) {
    return false;
  }
  memcpy(into + at, tail, written + 1);
  return true;
}
