#include "vfs.h"

#include <string.h>

/* The base VFS does the real reading; this one only shifts offsets and
 * refuses every write. */
struct cosmic_file {
  sqlite3_file base;
  sqlite3_int64 offset;
  sqlite3_int64 length;
  sqlite3_file *lower;
};

static sqlite3_vfs *base_vfs(sqlite3_vfs *vfs) {
  return (sqlite3_vfs *)vfs->pAppData;
}

static int file_close(sqlite3_file *file) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  return f->lower->pMethods->xClose(f->lower);
}

static int file_read(sqlite3_file *file, void *buf, int amount,
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
    int rc = f->lower->pMethods->xRead(f->lower, buf, have, f->offset + at);
    memset((char *)buf + have, 0, (size_t)(amount - have));
    return rc == SQLITE_OK ? SQLITE_IOERR_SHORT_READ : rc;
  }
  return f->lower->pMethods->xRead(f->lower, buf, amount, f->offset + at);
}

static int file_write(sqlite3_file *file, const void *buf, int amount,
                      sqlite3_int64 at) {
  (void)file;
  (void)buf;
  (void)amount;
  (void)at;
  return SQLITE_READONLY;
}

static int file_truncate(sqlite3_file *file, sqlite3_int64 size) {
  (void)file;
  (void)size;
  return SQLITE_READONLY;
}

static int file_sync(sqlite3_file *file, int flags) {
  (void)file;
  (void)flags;
  return SQLITE_OK;
}

static int file_size(sqlite3_file *file, sqlite3_int64 *out) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  *out = f->length;
  return SQLITE_OK;
}

static int file_lock(sqlite3_file *file, int level) {
  (void)file;
  return level > SQLITE_LOCK_SHARED ? SQLITE_READONLY : SQLITE_OK;
}

static int file_unlock(sqlite3_file *file, int level) {
  (void)file;
  (void)level;
  return SQLITE_OK;
}

static int file_check_reserved(sqlite3_file *file, int *out) {
  (void)file;
  *out = 0;
  return SQLITE_OK;
}

static int file_control(sqlite3_file *file, int op, void *arg) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  if (op == SQLITE_FCNTL_VFSNAME) {
    *(char **)arg = sqlite3_mprintf(COSMIC_VFS_NAME "(%lld)", f->offset);
    return SQLITE_OK;
  }
  return SQLITE_NOTFOUND;
}

static int file_sector_size(sqlite3_file *file) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  return f->lower->pMethods->xSectorSize(f->lower);
}

static int file_characteristics(sqlite3_file *file) {
  struct cosmic_file *f = (struct cosmic_file *)file;
  return f->lower->pMethods->xDeviceCharacteristics(f->lower) |
         SQLITE_IOCAP_IMMUTABLE;
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

static int vfs_open(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *file,
                    int flags, int *out_flags) {
  sqlite3_vfs *lower_vfs = base_vfs(vfs);
  struct cosmic_file *f = (struct cosmic_file *)file;
  memset(f, 0, sizeof *f);
  f->lower = (sqlite3_file *)((char *)file + sizeof(struct cosmic_file));

  const char *offset = name == NULL ? NULL : sqlite3_uri_parameter(name, "off");
  if (offset == NULL) {
    /* Anything without an offset -- a temporary file, a journal -- is
     * the base VFS's business, and the caller sees its methods. */
    return lower_vfs->xOpen(lower_vfs, name, file, flags, out_flags);
  }

  f->offset = sqlite3_uri_int64(name, "off", 0);
  f->length = sqlite3_uri_int64(name, "len", 0);
  if (f->offset <= 0 || f->length <= 0) {
    return SQLITE_CANTOPEN;
  }

  int rc = lower_vfs->xOpen(lower_vfs, name, f->lower,
                            SQLITE_OPEN_READONLY | SQLITE_OPEN_MAIN_DB,
                            out_flags);
  if (rc != SQLITE_OK) {
    return rc;
  }
  if (out_flags != NULL) {
    *out_flags = SQLITE_OPEN_READONLY;
  }
  f->base.pMethods = &cosmic_io_methods;
  return SQLITE_OK;
}

static int vfs_delete(sqlite3_vfs *vfs, const char *name, int sync) {
  return base_vfs(vfs)->xDelete(base_vfs(vfs), name, sync);
}

static int vfs_access(sqlite3_vfs *vfs, const char *name, int flags, int *out) {
  return base_vfs(vfs)->xAccess(base_vfs(vfs), name, flags, out);
}

static int vfs_full_pathname(sqlite3_vfs *vfs, const char *name, int room,
                             char *out) {
  return base_vfs(vfs)->xFullPathname(base_vfs(vfs), name, room, out);
}

static int vfs_randomness(sqlite3_vfs *vfs, int amount, char *out) {
  return base_vfs(vfs)->xRandomness(base_vfs(vfs), amount, out);
}

static int vfs_sleep(sqlite3_vfs *vfs, int micros) {
  return base_vfs(vfs)->xSleep(base_vfs(vfs), micros);
}

static int vfs_current_time(sqlite3_vfs *vfs, double *out) {
  return base_vfs(vfs)->xCurrentTime(base_vfs(vfs), out);
}

static int vfs_last_error(sqlite3_vfs *vfs, int room, char *out) {
  return base_vfs(vfs)->xGetLastError(base_vfs(vfs), room, out);
}

int cosmic_vfs_register(void) {
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
static int append_escaped(char *into, size_t room, size_t *at, const char *s) {
  static const char hex[] = "0123456789ABCDEF";
  for (; *s != '\0'; s++) {
    unsigned char c = (unsigned char)*s;
    int plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c == '/' || c == '-' || c == '_' ||
                c == '.' || c == '~';
    if (plain) {
      if (*at + 1 >= room) {
        return 0;
      }
      into[(*at)++] = (char)c;
    } else {
      if (*at + 3 >= room) {
        return 0;
      }
      into[(*at)++] = '%';
      into[(*at)++] = hex[c >> 4];
      into[(*at)++] = hex[c & 15];
    }
  }
  into[*at] = '\0';
  return 1;
}

int cosmic_vfs_uri(char *into, size_t room, const char *path, int64_t offset,
                   int64_t length) {
  size_t at = 0;
  const char *scheme = "file:";
  size_t scheme_len = strlen(scheme);
  if (scheme_len + 1 >= room) {
    return 0;
  }
  memcpy(into, scheme, scheme_len);
  at = scheme_len;
  if (!append_escaped(into, room, &at, path)) {
    return 0;
  }
  char tail[96];
  sqlite3_snprintf((int)sizeof tail, tail,
                   "?vfs=" COSMIC_VFS_NAME "&mode=ro&immutable=1"
                   "&off=%lld&len=%lld",
                   (long long)offset, (long long)length);
  size_t written = strlen(tail);
  if (at + written + 1 > room) {
    return 0;
  }
  memcpy(into + at, tail, written + 1);
  return 1;
}
