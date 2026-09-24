#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE

#include "startup.h"

#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "crypto.h"
#include "executable.h"
#include "environment.h"


#ifndef COSMIC_TARGET_ID
#error "build.zig must define COSMIC_TARGET_ID"
#endif
#ifndef COSMIC_TARGET_NAME
#error "build.zig must define COSMIC_TARGET_NAME"
#endif
#ifndef COSMIC_CONFIGURATION_ID
#error "build.zig must define COSMIC_CONFIGURATION_ID"
#endif
#ifndef COSMIC_CONFIGURATION_NAME
#error "build.zig must define COSMIC_CONFIGURATION_NAME"
#endif

static const char *const portable_environment[] = {
  COSMIC_PORTABLE_ENV_ARTIFACT_FD,
  COSMIC_PORTABLE_ENV_CORE_FD,
  COSMIC_PORTABLE_ENV_TARGET_ID,
  COSMIC_PORTABLE_ENV_CONFIGURATION_ID,
  COSMIC_PORTABLE_ENV_CORE_OFFSET,
  COSMIC_PORTABLE_ENV_CORE_LENGTH,
  COSMIC_PORTABLE_ENV_CORE_SHA256,
};

static int decimal (const char *text, uint64_t maximum, uint64_t *out) {
  if (text == NULL || *text == '\0') return 0;
  uint64_t value = 0;
  size_t digits = 0;
  for (const unsigned char *p = (const unsigned char *)text; *p != 0; p++) {
    if (*p < '0' || *p > '9' || ++digits > 20) return 0;
    unsigned digit = *p - '0';
    if (value > (maximum - digit) / 10) return 0;
    value = value * 10 + digit;
  }
  *out = value;
  return 1;
}

static int hex_digest (const char *text,
                       unsigned char out[COSMIC_PORTABLE_SHA256_LENGTH]) {
  if (text == NULL) return 0;
  for (size_t i = 0; i < COSMIC_PORTABLE_SHA256_LENGTH; i++) {
    unsigned value = 0;
    for (unsigned half = 0; half < 2; half++) {
      unsigned char c = (unsigned char)text[i * 2 + half];
      unsigned digit;
      if (c >= '0' && c <= '9') digit = c - '0';
      else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
      else return 0;
      value = value * 16 + digit;
    }
    out[i] = (unsigned char)value;
  }
  return text[COSMIC_PORTABLE_SHA256_LENGTH * 2] == '\0';
}


static void compiled_startup (struct cosmic_startup *startup,
                              enum cosmic_startup_kind kind,
                              const char *artifact_path) {
  *startup = (struct cosmic_startup){
    .version = COSMIC_STARTUP_VERSION,
    .kind = kind,
    .target_id = COSMIC_TARGET_ID,
    .configuration_id = COSMIC_CONFIGURATION_ID,
    .target_name = COSMIC_TARGET_NAME,
    .configuration_name = COSMIC_CONFIGURATION_NAME,
    .artifact_path = artifact_path,
    .artifact_fd = -1,
    .core_fd = -1,
  };
}

bool cosmic_startup_has_private_environment (void) {
  for (size_t i = 0; i < sizeof portable_environment /
                              sizeof portable_environment[0]; i++) {
    if (getenv(portable_environment[i]) != NULL) return true;
  }
  return false;
}

void cosmic_startup_native (struct cosmic_startup *startup) {
  compiled_startup(startup, COSMIC_STARTUP_NATIVE, NULL);
  if (!cosmic_environment_clear_reserved(cosmic_startup_test_environment()))
    startup->contract_error = "reserved portable environment cannot be cleared";
}

void cosmic_startup_host (struct cosmic_startup *startup, int fd,
                          const char *path) {
  cosmic_startup_native(startup);
  startup->kind = COSMIC_STARTUP_HOST;
  startup->artifact_path = path;
  startup->artifact_fd = fd;
}

bool cosmic_artifact_core_matches (struct cosmic_artifact *artifact) {
  if (artifact == NULL || artifact->fd < 0) return false;
  if (artifact->core_checked == 0) {
    const struct cosmic_portable_entry *entry = &artifact->portable.selected;
    unsigned char digest[COSMIC_DIGEST_MAX];
    size_t length = 0;
    artifact->core_checked =
        cosmic_digest_fd("sha256", artifact->fd, entry->offset, entry->length,
                         digest, &length) == 0 &&
                length == COSMIC_PORTABLE_SHA256_LENGTH &&
                memcmp(digest, entry->sha256, length) == 0
            ? 1
            : -1;
  }
  return artifact->core_checked == 1;
}

void cosmic_startup_portable (struct cosmic_startup *startup,
                              const char *artifact_path) {
  compiled_startup(startup, COSMIC_STARTUP_PORTABLE, artifact_path);

  const char *values[7];
  for (size_t i = 0; i < sizeof values / sizeof values[0]; i++)
    values[i] = getenv(portable_environment[i]);

  uint64_t artifact_fd, core_fd, target, configuration, offset, length;
  if (!decimal(values[0], INT_MAX, &artifact_fd) || artifact_fd < 3)
    startup->contract_error = "portable artifact descriptor field is invalid";
  else if (!decimal(values[1], INT_MAX, &core_fd) || core_fd < 3)
    startup->contract_error = "portable core descriptor field is invalid";
  else if (artifact_fd == core_fd)
    startup->contract_error = "portable descriptor fields are equal";
  else if (!decimal(values[2], UINT32_MAX, &target) || target == 0)
    startup->contract_error = "portable launcher target field is invalid";
  else if (!decimal(values[3], UINT32_MAX, &configuration) ||
           configuration == 0)
    startup->contract_error =
        "portable launcher configuration field is invalid";
  else if (!decimal(values[4], UINT64_MAX, &offset))
    startup->contract_error = "portable launcher core offset is invalid";
  else if (!decimal(values[5], UINT64_MAX, &length) || length == 0)
    startup->contract_error = "portable launcher core length is invalid";
  else if (!hex_digest(values[6], startup->launcher_core_sha256))
    startup->contract_error = "portable launcher core digest is invalid";
  else {
    startup->artifact_fd = (int)artifact_fd;
    startup->core_fd = (int)core_fd;
    startup->launcher_target_id = (uint32_t)target;
    startup->launcher_configuration_id = (uint32_t)configuration;
    startup->launcher_core_offset = offset;
    startup->launcher_core_length = length;
  }

  if (!cosmic_environment_clear_reserved(cosmic_startup_test_environment()))
    startup->contract_error = "reserved portable environment cannot be cleared";
}

const char *cosmic_startup_validate (const struct cosmic_startup *startup) {
  if (startup == NULL) return "startup record is missing";
  if (startup->version != COSMIC_STARTUP_VERSION)
    return "startup record has an unsupported version";
  if (startup->kind != COSMIC_STARTUP_NATIVE &&
      startup->kind != COSMIC_STARTUP_PORTABLE &&
      startup->kind != COSMIC_STARTUP_HOST)
    return "startup record has an unknown kind";
  if (startup->target_id != COSMIC_TARGET_ID ||
      startup->target_name == NULL ||
      strcmp(startup->target_name, COSMIC_TARGET_NAME) != 0)
    return "startup target differs from the compiled target";
  if (startup->configuration_id != COSMIC_CONFIGURATION_ID ||
      startup->configuration_name == NULL ||
      strcmp(startup->configuration_name, COSMIC_CONFIGURATION_NAME) != 0)
    return "startup configuration differs from the compiled configuration";
  if (startup->kind == COSMIC_STARTUP_NATIVE && startup->artifact_path != NULL)
    return "native startup unexpectedly names an artifact";
  if (startup->kind != COSMIC_STARTUP_NATIVE &&
      (startup->artifact_path == NULL || startup->artifact_path[0] == '\0'))
    return "portable startup names no artifact";
  if (startup->contract_error != NULL) return startup->contract_error;
  return NULL;
}

/* A verified stamp: beside a cache entry named for the selected core, one
 * line of the entry's size, inode, and modification and change seconds --
 * the fields the launcher's stat prints, in its order. Startup writes it
 * after hashing the entry, once a second has passed since the entry last
 * changed, so any later write moves one of the times it records. While it
 * holds, neither the launcher nor startup hashes the entry again. */
static void stamp_line (const struct stat *core_stat, char *line, size_t room) {
  snprintf(line, room, "%llu|%llu|%lld|%lld\n",
           (unsigned long long)core_stat->st_size,
           (unsigned long long)core_stat->st_ino,
           (long long)core_stat->st_mtime, (long long)core_stat->st_ctime);
}

/* The stamp's path and its directory, when the executing core is the cache
 * entry the launcher names for this manifest entry; 0 for a core run from
 * anywhere else, which is always hashed and never stamped. */
static int stamp_path (const struct cosmic_portable_entry *entry,
                       const struct stat *core_stat, char *path, size_t room,
                       char *directory, size_t directory_room) {
  char core_path[COSMIC_ARTIFACT_PATH_CAPACITY];
  if (!cosmic_executable_path(core_path, sizeof core_path)) return 0;
  char *slash = strrchr(core_path, '/');
  if (slash == NULL || slash == core_path) return 0;
  char key[64 + 2 * COSMIC_PORTABLE_SHA256_LENGTH];
  int used = snprintf(key, sizeof key, "core-%u-%u-%llu-",
                      (unsigned)entry->target_id,
                      (unsigned)entry->configuration_id,
                      (unsigned long long)entry->length);
  if (used < 0 || (size_t)used + 2 * COSMIC_PORTABLE_SHA256_LENGTH >= sizeof key)
    return 0;
  for (unsigned i = 0; i < COSMIC_PORTABLE_SHA256_LENGTH; i++)
    snprintf(key + used + 2 * i, 3, "%02x", entry->sha256[i]);
  if (strcmp(slash + 1, key) != 0) return 0;
  struct stat path_stat;
  if (lstat(core_path, &path_stat) != 0 ||
      path_stat.st_dev != core_stat->st_dev ||
      path_stat.st_ino != core_stat->st_ino)
    return 0;
  *slash = '\0';
  used = snprintf(path, room, "%s/.verified-%s", core_path, key);
  if (used < 0 || (size_t)used >= room) return 0;
  used = snprintf(directory, directory_room, "%s", core_path);
  return used >= 0 && (size_t)used < directory_room;
}

static int stamp_holds (const char *path, const struct stat *core_stat) {
  char expected[96];
  stamp_line(core_stat, expected, sizeof expected);
  int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return 0;
  char found[sizeof expected];
  ssize_t length = read(fd, found, sizeof found - 1);
  close(fd);
  if (length <= 0) return 0;
  found[length] = '\0';
  return strcmp(found, expected) == 0;
}

/* Best effort: a read-only cache, or an entry changed within this second,
 * is simply hashed again next time. */
static void stamp_write (const char *path, const char *directory,
                         const struct stat *core_stat) {
  time_t now = time(NULL);
  if (now == (time_t)-1 || core_stat->st_ctime >= now ||
      core_stat->st_mtime >= now)
    return;
  char line[96];
  stamp_line(core_stat, line, sizeof line);
  char temporary[COSMIC_ARTIFACT_PATH_CAPACITY + 32];
  int used = snprintf(temporary, sizeof temporary, "%s/.verified.XXXXXX",
                      directory);
  if (used < 0 || (size_t)used >= sizeof temporary) return;
  int fd = mkstemp(temporary);
  if (fd < 0) return;
  size_t length = strlen(line);
  int written = write(fd, line, length) == (ssize_t)length;
  if (close(fd) != 0) written = 0;
  if (!written || rename(temporary, path) != 0) unlink(temporary);
}

static bool fail_adoption (struct cosmic_artifact *artifact, int core_fd,
                           int physical_fd, const char **error,
                           const char *why) {
  if (physical_fd >= 0) close(physical_fd);
  if (core_fd >= 0) close(core_fd);
  cosmic_artifact_close(artifact);
  if (error != NULL) *error = why;
  return false;
}

bool cosmic_startup_adopt (const struct cosmic_startup *startup,
                           struct cosmic_artifact *artifact,
                           const char **error) {
  cosmic_artifact_init(artifact);
  if (error != NULL) *error = NULL;
  if (startup->kind == COSMIC_STARTUP_NATIVE) return true;
  if (startup->kind == COSMIC_STARTUP_HOST) {
    /* The kernel executed this very file: there is no launcher's choice to
     * check it against. Its structure is checked here, and its core's digest
     * when something asks for the identity it names. */
    size_t host_length = strlen(startup->artifact_path);
    if (startup->artifact_path[0] != '/' ||
        host_length >= sizeof artifact->logical_path)
      return fail_adoption(artifact, -1, -1, error,
                           "host program path is not absolute, or too long");
    memcpy(artifact->logical_path, startup->artifact_path, host_length + 1);
    artifact->fd = startup->artifact_fd;
    artifact->host = 1;
    struct stat host_stat;
    if (fstat(artifact->fd, &host_stat) != 0 || !S_ISREG(host_stat.st_mode))
      return fail_adoption(artifact, -1, -1, error,
                           "host program is not a regular file");
    artifact->device = (uint64_t)host_stat.st_dev;
    artifact->inode = (uint64_t)host_stat.st_ino;
    artifact->file_size = (uint64_t)host_stat.st_size;
    const char *host_error = NULL;
    if (!cosmic_host_decode(artifact->fd, startup->target_id,
                            startup->configuration_id, &artifact->portable,
                            &host_error))
      return fail_adoption(artifact, -1, -1, error,
                           host_error == NULL ? "host program is invalid" :
                                                host_error);
    return true;
  }
  if (startup->artifact_path[0] != '/')
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "portable artifact path is not absolute");
  size_t path_length = strlen(startup->artifact_path);
  if (path_length >= sizeof artifact->logical_path)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "portable artifact path is too long");
  memcpy(artifact->logical_path, startup->artifact_path, path_length + 1);
  artifact->fd = startup->artifact_fd;

  struct stat artifact_stat;
  if (artifact->fd < 0 || fstat(artifact->fd, &artifact_stat) != 0 ||
      !S_ISREG(artifact_stat.st_mode) || artifact_stat.st_size < 0)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "retained artifact descriptor is not a regular file");
  artifact->device = (uint64_t)artifact_stat.st_dev;
  artifact->inode = (uint64_t)artifact_stat.st_ino;
  artifact->file_size = (uint64_t)artifact_stat.st_size;

  const char *decode_error = NULL;
  if (!cosmic_portable_decode(artifact->fd, startup->target_id,
                              startup->configuration_id,
                              &artifact->portable, &decode_error))
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         decode_error == NULL ? "portable artifact is invalid" :
                                                decode_error);

  const struct cosmic_portable_entry *selected = &artifact->portable.selected;
  if (startup->launcher_target_id != startup->target_id)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "launcher target differs from compiled target");
  if (startup->launcher_configuration_id != startup->configuration_id)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "launcher configuration differs from compiled configuration");
  if (selected->target_id != startup->launcher_target_id ||
      selected->configuration_id != startup->launcher_configuration_id)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "selected manifest identity differs from launcher");
  if (selected->offset != startup->launcher_core_offset)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "selected core offset differs from launcher");
  if (selected->length != startup->launcher_core_length)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "selected core length differs from launcher");
  if (memcmp(selected->sha256, startup->launcher_core_sha256,
             COSMIC_PORTABLE_SHA256_LENGTH) != 0)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "selected core digest differs from launcher");

  struct stat core_stat;
  if (startup->core_fd < 0 || fstat(startup->core_fd, &core_stat) != 0 ||
      !S_ISREG(core_stat.st_mode) || core_stat.st_size < 0)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "retained core descriptor is not a regular file");
  if ((uint64_t)core_stat.st_size != selected->length)
    return fail_adoption(artifact, startup->core_fd, -1, error,
                         "executing core length differs from manifest");
  char stamp[COSMIC_ARTIFACT_PATH_CAPACITY + 160];
  char stamp_directory[COSMIC_ARTIFACT_PATH_CAPACITY];
  int stamped = stamp_path(selected, &core_stat, stamp, sizeof stamp,
                           stamp_directory, sizeof stamp_directory);
  unsigned char digest[COSMIC_DIGEST_MAX];
  size_t digest_length = 0;
  if (stamped && stamp_holds(stamp, &core_stat)) {
    /* Hashed before, and not written since. */
  } else if (cosmic_digest_fd("sha256", startup->core_fd, 0, selected->length,
                              digest, &digest_length) != 0 ||
             digest_length != COSMIC_PORTABLE_SHA256_LENGTH ||
             memcmp(digest, selected->sha256, digest_length) != 0) {
    /* The launcher checks a cached core's kind, owner, mode and length but
     * leaves its digest to this one pass, so a cached core damaged in place
     * stops here. Name the entry: removing it lets the next launch extract
     * it again. */
    static char corrupt[COSMIC_ARTIFACT_PATH_CAPACITY + 96];
    char core_path[COSMIC_ARTIFACT_PATH_CAPACITY];
    if (cosmic_executable_path(core_path, sizeof core_path))
      snprintf(corrupt, sizeof corrupt,
               "executing core digest differs from manifest; remove %s "
               "to extract it again", core_path);
    else
      snprintf(corrupt, sizeof corrupt,
               "executing core digest differs from manifest; remove the "
               "cached core to extract it again");
    return fail_adoption(artifact, startup->core_fd, -1, error, corrupt);
  }
  if (stamped && digest_length != 0)
    stamp_write(stamp, stamp_directory, &core_stat);

  int physical_fd = cosmic_executable_fd();
  struct stat physical_stat;
  if (physical_fd < 0 || fstat(physical_fd, &physical_stat) != 0)
    return fail_adoption(artifact, startup->core_fd, physical_fd, error,
                         "physical executable identity is unavailable");
  if (physical_stat.st_dev != core_stat.st_dev ||
      physical_stat.st_ino != core_stat.st_ino)
    return fail_adoption(artifact, startup->core_fd, physical_fd, error,
                         "physical executable differs from retained core");
  close(physical_fd);
  close(startup->core_fd);

  int flags = fcntl(artifact->fd, F_GETFD);
  if (flags < 0 || fcntl(artifact->fd, F_SETFD, flags | FD_CLOEXEC) != 0)
    return fail_adoption(artifact, -1, -1, error,
                         "cannot mark retained artifact close-on-exec");
  artifact->core_checked = 1;
  return true;
}
