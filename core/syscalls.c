/* The syscall table's process, time and data half, and the module. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700

#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#if defined(__linux__)
#include <sys/prctl.h>
#include <sys/syscall.h>
/* _XOPEN_SOURCE intentionally hides this libc escape hatch. It is used only
 * for close_range, whose wrapper musl does not expose. */
extern long syscall (long, ...);
#endif
#include <time.h>
#include <unistd.h>
#include <sys/utsname.h>

#include "check.h"
#include "coverage.h"
#include "fail.h"
#include "guard.h"
#include "lauxlib.h"
#include "executable.h"
#include "crypto.h"
#include "syscalls.h"
#include "portable.h"
#include "startup.h"
#include "store.h"

#if defined(__APPLE__)
#include <crt_externs.h>
#define COSMIC_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define COSMIC_ENVIRON environ
#endif

const char *cosmic_path (lua_State *L, int index) {
  size_t length;
  const char *value = luaL_checklstring(L, index, &length);
  if (memchr(value, '\0', length) != NULL) return NULL;
  return value;
}

COSMIC_SYSCALL(executable, 0) {
  lua_getfield(L, LUA_REGISTRYINDEX, COSMIC_LOGICAL_EXECUTABLE);
  if (lua_isstring(L, -1)) return 1;
  lua_pop(L, 1);
  char resolved[PATH_MAX];
  /* Cleared first: a failure that sets no errno of its own (a path too
   * long for the room) must not report whatever an earlier call left. */
  errno = 0;
  if (!cosmic_executable_path(resolved, sizeof resolved)) {
    int number = errno;
    return cosmic_fail(L, number == 0 ? ENAMETOOLONG : number);
  }
  lua_pushstring(L, resolved);
  return 1;
}

COSMIC_SYSCALL(getenv, 1) {
  const char *name = luaL_checkstring(L, 1);
  const char *value = getenv(name);
  if (value == NULL) {
    lua_pushnil(L);
  } else {
    lua_pushstring(L, value);
  }
  return 1;
}

COSMIC_SYSCALL(environ, 0) {
  lua_newtable(L);
  char **at = COSMIC_ENVIRON;
  for (; at != NULL && *at != NULL; at++) {
    const char *entry = *at;
    const char *split = entry;
    while (*split != '\0' && *split != '=') {
      split++;
    }
    if (*split != '=') {
      continue;
    }
    lua_pushlstring(L, entry, (size_t)(split - entry));
    lua_pushstring(L, split + 1);
    lua_settable(L, -3);
  }
  return 1;
}

COSMIC_SYSCALL(exit, 1) {
  int status = cosmic_optint(L, 1, 0);
  cosmic_coverage_report(); /* _exit runs no atexit handler */
  _exit(status); /* exits: the process boundary has no caller to return to */
}

COSMIC_SYSCALL(getpid, 0) {
  lua_pushinteger(L, (lua_Integer)getpid());
  return 1;
}

COSMIC_SYSCALL(getuid, 0) {
  lua_pushinteger(L, (lua_Integer)getuid());
  return 1;
}

COSMIC_SYSCALL(clock_gettime, 1) {
  int which = cosmic_checkint(L, 1);
  struct timespec now;
  if (clock_gettime((clockid_t)which, &now) != 0) {
    return cosmic_fail(L, errno);
  }
  lua_pushinteger(L, (lua_Integer)now.tv_sec * 1000000000 +
                         (lua_Integer)now.tv_nsec);
  return 1;
}

COSMIC_SYSCALL(nanosleep, 1) {
  lua_Integer nanoseconds = luaL_checkinteger(L, 1);
  if (nanoseconds < 0) {
    return luaL_argerror(L, 1, "the duration is negative");
  }
  struct timespec want = {
    .tv_sec = (time_t)(nanoseconds / 1000000000),
    .tv_nsec = (long)(nanoseconds % 1000000000),
  };
  struct timespec left;
  while (nanosleep(&want, &left) != 0) {
    if (errno != EINTR) {
      return cosmic_fail_effect(L, errno);
    }
    want = left;
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(isatty, 1) {
  int fd = cosmic_checkint(L, 1);
  lua_pushboolean(L, isatty(fd) == 1);
  return 1;
}

/* An algorithm nobody has heard of is an argument-shape error and
 * raises; the library refusing a hash it advertises is a bug, and
 * raises too. Neither is a runtime failure a caller could handle. */
static int hashed (lua_State *L, int status, const unsigned char *digest,
                   size_t len) {
  if (status == -1) {
    return luaL_argerror(L, 1, "no such digest algorithm");
  }
  if (status != 0) {
    return luaL_error(L, "the digest failed with status %d", status);
  }
  lua_pushlstring(L, (const char *)digest, len);
  return 1;
}

COSMIC_SYSCALL(digest, 2) {
  const char *name = luaL_checkstring(L, 1);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  unsigned char digest[COSMIC_DIGEST_MAX];
  size_t digest_len = 0;
  int status = cosmic_digest(name, data, len, digest, &digest_len);
  return hashed(L, status, digest, digest_len);
}

COSMIC_SYSCALL(hmac, 3) {
  const char *name = luaL_checkstring(L, 1);
  size_t key_len;
  const char *key = luaL_checklstring(L, 2, &key_len);
  size_t len;
  const char *data = luaL_checklstring(L, 3, &len);
  unsigned char mac[COSMIC_DIGEST_MAX];
  size_t mac_len = 0;
  int status = cosmic_hmac(name, key, key_len, data, len, mac, &mac_len);
  return hashed(L, status, mac, mac_len);
}

COSMIC_SYSCALL(entropy, 1) {
  lua_Integer count = luaL_checkinteger(L, 1);
  luaL_argcheck(L, count >= 0 && count <= COSMIC_ENTROPY_MAX, 1,
                "the count is negative or past 1 MiB");
  luaL_Buffer buffer;
  char *out = luaL_buffinitsize(L, &buffer, (size_t)count);
  int number = cosmic_entropy(out, (size_t)count);
  if (number != 0) {
    luaL_pushresultsize(&buffer, 0);
    lua_pop(L, 1);
    return cosmic_fail(L, number);
  }
  luaL_pushresultsize(&buffer, (size_t)count);
  return 1;
}

COSMIC_SYSCALL(umask, 1) {
  int mask = cosmic_checkint(L, 1);
  luaL_argcheck(L, mask >= 0 && mask <= 0777, 1, "the mask is not permission bits");
  lua_pushinteger(L, (lua_Integer)umask((mode_t)mask));
  return 1;
}

static const char *plain_string (lua_State *L, int index, const char *what) {
  if (lua_type(L, index) != LUA_TSTRING)
    luaL_error(L, "%s must be a string", what);
  size_t length;
  const char *value = lua_tolstring(L, index, &length);
  if (memchr(value, '\0', length) != NULL)
    luaL_error(L, "%s contains a NUL byte", what);
  return value;
}

/* Whether cosmic itself set SIGPIPE to be ignored, so that a program it
 * starts or becomes gets the default disposition back instead of
 * inheriting ours. */
static int sigpipe_ignored_here;

/* The argv and environment arrays are built from the Lua tables, which
 * stay on the stack and so keep every string alive until execve, which
 * frees nothing on success because nothing of this process remains.
 * Every argv entry must already be a string -- a number converted in
 * place would be a string nothing holds -- and everything that can
 * raise is checked before the arrays are allocated; each array is held
 * by a guard all the same, which frees it on every return. */
COSMIC_SYSCALL(execve, 3) {
  const char *path = plain_string(L, 1, "path");
  luaL_checktype(L, 2, LUA_TTABLE);
  luaL_checktype(L, 3, LUA_TTABLE);

  size_t count = lua_rawlen(L, 2);
  if (count > (size_t)LUA_MAXINTEGER ||
      count > SIZE_MAX / sizeof(char *) - 1)
    return luaL_argerror(L, 2, "argv is too large");
  for (size_t i = 1; i <= count; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    plain_string(L, -1, "argv entry");
    lua_pop(L, 1);
  }

  /* Each "NAME=value" entry is built by concatenation and kept in a
   * table on the stack, which is what keeps its bytes alive; the key
   * itself is left exactly as lua_next needs it. */
  lua_newtable(L);
  int entries = lua_gettop(L);
  lua_Integer variables = 0;
  lua_pushnil(L);
  while (lua_next(L, 3) != 0) {
    const char *name = plain_string(L, -2, "environment name");
    plain_string(L, -1, "environment value");
    if (*name == '\0' || strchr(name, '=') != NULL)
      return luaL_argerror(L, 3, "environment name is empty or contains '='");
    lua_pushvalue(L, -2);
    lua_pushliteral(L, "=");
    lua_pushvalue(L, -3);
    lua_concat(L, 3);
    lua_rawseti(L, entries, ++variables);
    lua_pop(L, 1);
  }

  struct cosmic_guard *argv_guard = cosmic_guard_push(L, free);
  struct cosmic_guard *envp_guard = cosmic_guard_push(L, free);
  char **argv = calloc(count + 1, sizeof *argv);
  argv_guard->resource = argv;
  char **envp = calloc((size_t)variables + 1, sizeof *envp);
  envp_guard->resource = envp;
  if (argv == NULL || envp == NULL) {
    return cosmic_fail_effect(L, ENOMEM);
  }
  for (size_t i = 1; i <= count; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    argv[i - 1] = (char *)lua_tostring(L, -1);
    lua_pop(L, 1);
  }
  for (lua_Integer i = 1; i <= variables; i++) {
    lua_rawgeti(L, entries, i);
    envp[i - 1] = (char *)lua_tostring(L, -1);
    lua_pop(L, 1);
  }

  /* The program this process becomes starts with SIGPIPE at its
   * default, as a spawned child does; ignored again if the exec fails. */
  char **given = cosmic_coverage_environment(envp);
  cosmic_coverage_report(); /* nothing of this image remains to report later */
  if (sigpipe_ignored_here) signal(SIGPIPE, SIG_DFL);
  execve(path, argv, given);
  int number = errno;
  if (sigpipe_ignored_here) signal(SIGPIPE, SIG_IGN);
  if (given != envp) free(given);
  return cosmic_fail_effect(L, number);
}

static void free_environment (char **envp, lua_Integer count) {
  if (envp == NULL) return;
  for (lua_Integer i = 0; i < count; i++) free(envp[i]);
  free(envp);
}

static int report_child_error (int fd, int number) {
  const char *at = (const char *)&number;
  size_t left = sizeof number;
  while (left > 0) {
    ssize_t put = write(fd, at, left);
    if (put < 0 && errno == EINTR) continue;
    if (put <= 0) return -1;
    at += put;
    left -= (size_t)put;
  }
  return 0;
}

/* The highest descriptor number a child may be handed besides stdio. */
#define CHILD_FD_MAX 255

/* Close every descriptor from `from` up. Cosmic-opened descriptors are
 * CLOEXEC already; this also closes foreign descriptors that are not. */
static void close_child_descriptors (int from, long limit) {
#if defined(__linux__) && defined(SYS_close_range)
  if (syscall(SYS_close_range, (unsigned)from, ~0u, 0u) == 0) return;
#endif
  for (int fd = from; fd < limit; fd++) close(fd);
}

COSMIC_SYSCALL(spawn, 9) {
  const char *path = plain_string(L, 1, "path");
  luaL_checktype(L, 2, LUA_TTABLE);
  if (!lua_isnoneornil(L, 3)) luaL_checktype(L, 3, LUA_TTABLE);
  const char *cwd = lua_isnoneornil(L, 4) ? NULL : plain_string(L, 4, "cwd");
  /* source[t] is the parent descriptor the child sees as t, or -1: for
   * 0..2 that means inherit, above that it means closed. */
  int source[CHILD_FD_MAX + 1];
  for (int i = 0; i <= CHILD_FD_MAX; i++) source[i] = -1;
  for (int i = 0; i < 3; i++) {
    if (lua_isnoneornil(L, 5 + i)) continue;
    if (!lua_isinteger(L, 5 + i))
      return luaL_argerror(L, 5 + i, "descriptor must be an integer");
    lua_Integer value = lua_tointeger(L, 5 + i);
    if (value < 0 || value > INT_MAX)
      return luaL_argerror(L, 5 + i, "descriptor is out of range");
    source[i] = (int)value;
  }
  int process_group = lua_toboolean(L, 8);
  int top = 2;
  if (!lua_isnoneornil(L, 9)) {
    luaL_checktype(L, 9, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, 9) != 0) {
      if (!lua_isinteger(L, -2) || !lua_isinteger(L, -1))
        return luaL_argerror(L, 9, "descriptors must map integers to integers");
      lua_Integer target = lua_tointeger(L, -2);
      lua_Integer value = lua_tointeger(L, -1);
      if (target < 3 || target > CHILD_FD_MAX)
        return luaL_argerror(L, 9, "a child descriptor must be 3 to 255");
      if (value < 0 || value > INT_MAX)
        return luaL_argerror(L, 9, "descriptor is out of range");
      source[target] = (int)value;
      if (target > top) top = (int)target;
      lua_pop(L, 1);
    }
  }
  for (int t = 0; t <= top; t++) {
    if (source[t] >= 0 && fcntl(source[t], F_GETFD) < 0)
      return cosmic_fail(L, errno);
  }
  long descriptor_limit = sysconf(_SC_OPEN_MAX);
  if (descriptor_limit < 0) descriptor_limit = 1024;

  size_t argc = lua_rawlen(L, 2);
  if (argc == 0) {
    return luaL_argerror(L, 2, "argv is empty");
  }
  if (argc > (size_t)LUA_MAXINTEGER ||
      argc > SIZE_MAX / sizeof(char *) - 1)
    return luaL_argerror(L, 2, "argv is too large");
  /* Validate everything that can raise before allocating native memory. */
  for (size_t i = 1; i <= argc; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    plain_string(L, -1, "argv entry");
    lua_pop(L, 1);
  }

  lua_Integer envc = 0;
  if (!lua_isnoneornil(L, 3)) {
    lua_pushnil(L);
    while (lua_next(L, 3) != 0) {
      const char *name = plain_string(L, -2, "environment name");
      plain_string(L, -1, "environment value");
      if (*name == '\0' || strchr(name, '=') != NULL)
        return luaL_argerror(L, 3, "environment name is empty or contains '='");
      envc++;
      lua_pop(L, 1);
    }
  }

  char **argv = calloc((size_t)argc + 1, sizeof *argv);
  if (argv == NULL) return cosmic_fail(L, ENOMEM);
  for (size_t i = 1; i <= argc; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i);
    argv[i - 1] = (char *)lua_tostring(L, -1);
    lua_pop(L, 1);
  }

  char **envp = COSMIC_ENVIRON;
  if (!lua_isnoneornil(L, 3)) {
    envp = calloc((size_t)envc + 1, sizeof *envp);
    if (envp == NULL) { free(argv); return cosmic_fail(L, ENOMEM); }
    lua_Integer at = 0;
    lua_pushnil(L);
    while (lua_next(L, 3) != 0) {
      size_t name_len, value_len;
      const char *name = lua_tolstring(L, -2, &name_len);
      const char *value = lua_tolstring(L, -1, &value_len);
      char *entry = malloc(name_len + value_len + 2);
      if (entry == NULL) {
        lua_pop(L, 2);
        free_environment(envp, at);
        free(argv);
        return cosmic_fail(L, ENOMEM);
      }
      memcpy(entry, name, name_len);
      entry[name_len] = '=';
      memcpy(entry + name_len + 1, value, value_len + 1);
      envp[at++] = entry;
      lua_pop(L, 1);
    }
  }

  int status_pipe[2];
  if (pipe(status_pipe) != 0) {
    int number = errno; if (!lua_isnoneornil(L, 3)) free_environment(envp, envc); free(argv);
    return cosmic_fail(L, number);
  }
  /* Move both ends clear of every descriptor the child is handed, so
   * closed parent stdio cannot make a pipe end collide with the
   * remapping below. */
  int promote_error = 0;
  int status_read = fcntl(status_pipe[0], F_DUPFD_CLOEXEC, top + 2);
  if (status_read < 0) promote_error = errno;
  int status_write = fcntl(status_pipe[1], F_DUPFD_CLOEXEC, top + 2);
  if (status_write < 0 && promote_error == 0) promote_error = errno;
  close(status_pipe[0]);
  close(status_pipe[1]);
  if (status_read < 0 || status_write < 0) {
    if (status_read >= 0) close(status_read);
    if (status_write >= 0) close(status_write);
    if (!lua_isnoneornil(L, 3)) free_environment(envp, envc);
    free(argv);
    return cosmic_fail(L, promote_error);
  }
  char **given = cosmic_coverage_environment(envp);
  pid_t pid = fork();
  if (pid == 0) {
    close(status_read);
    int failure = 0;
    /* dup2 onto a target can overwrite another mapping's source, so every
     * source is first pinned above everything the child is handed. A
     * source that is its own target is pinned too: the copy is what makes
     * the final dup2 clear CLOEXEC on it. Inherited stdio is left alone,
     * so a closed one stays closed. */
    int pinned[CHILD_FD_MAX + 1];
    for (int t = 0; t <= top; t++) {
      pinned[t] = -1;
      if (!failure && source[t] >= 0) {
        pinned[t] = fcntl(source[t], F_DUPFD_CLOEXEC, top + 2);
        if (pinned[t] < 0) failure = errno;
      }
    }
    /* The exec-status descriptor sits just above the child's own. */
    if (!failure && status_write != top + 1) {
      if (dup2(status_write, top + 1) < 0) failure = errno;
      else close(status_write);
    }
    int status_fd = failure ? status_write : top + 1;
    if (!failure && fcntl(status_fd, F_SETFD, FD_CLOEXEC) != 0) failure = errno;
    if (failure) {
      report_child_error(status_fd, failure);
      _exit(127);
    }
    if (process_group && setpgid(0, 0) != 0) failure = errno;
    if (!failure && cwd != NULL && chdir(cwd) != 0) failure = errno;
    if (!failure && sigpipe_ignored_here) signal(SIGPIPE, SIG_DFL);
    for (int t = 0; !failure && t <= top; t++) {
      if (pinned[t] >= 0) {
        if (dup2(pinned[t], t) < 0) failure = errno;
      } else if (t < 3) {
        /* An inherited stdio descriptor must be as safe for exec as a
         * mapped one. */
        int flags = fcntl(t, F_GETFD);
        if (flags >= 0) {
          if (fcntl(t, F_SETFD, flags & ~FD_CLOEXEC) != 0) failure = errno;
        } else if (errno != EBADF) {
          failure = errno;
        }
      } else {
        close(t);
      }
    }
    close_child_descriptors(top + 2, descriptor_limit);
    if (!failure) execve(path, argv, given);
    if (!failure) failure = errno;
    report_child_error(status_fd, failure);
    _exit(127);
  }
  int fork_error = errno;
  close(status_write);
  if (given != envp) free(given);
  if (!lua_isnoneornil(L, 3)) free_environment(envp, envc);
  free(argv);
  if (pid < 0) { close(status_read); return cosmic_fail(L, fork_error); }

  int child_error = 0;
  size_t received = 0;
  int read_error = 0;
  while (received < sizeof child_error) {
    ssize_t got = read(status_read, (char *)&child_error + received,
                       sizeof child_error - received);
    if (got > 0) { received += (size_t)got; continue; }
    if (got == 0) break;
    if (errno == EINTR) continue;
    read_error = errno;
    break;
  }
  close(status_read);
  if (received != 0 || read_error != 0) {
    int ignored; while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
    return cosmic_fail(L, received == sizeof child_error ? child_error :
                       (read_error != 0 ? read_error : EIO));
  }
  lua_pushinteger(L, (lua_Integer)pid);
  return 1;
}

COSMIC_SYSCALL(waitpid, 2) {
  lua_Integer value = luaL_checkinteger(L, 1);
  if (value == 0 || value < -INT_MAX || value > INT_MAX)
    return luaL_argerror(L, 1, "pid is out of range");
  pid_t pid = (pid_t)value;
  int nohang = lua_toboolean(L, 2);
  /* The answer and its keys are made before the wait, and filling a
   * table sized for them allocates nothing: a child the wait reaped
   * cannot be reaped again, so a raise after it would lose its status. */
  lua_createtable(L, 0, 3);
  lua_pushliteral(L, "signal");
  lua_pushliteral(L, "code");
  lua_pushliteral(L, "pid");
  int status;
  pid_t answer;
  do { answer = waitpid(pid, &status, nohang ? WNOHANG : 0); }
  while (answer < 0 && errno == EINTR);
  if (answer < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, answer);
  lua_rawset(L, -5);
  lua_pushinteger(L, answer > 0 && WIFEXITED(status) ? WEXITSTATUS(status) : -1);
  lua_rawset(L, -4);
  lua_pushinteger(L, answer > 0 && WIFSIGNALED(status) ? WTERMSIG(status) : -1);
  lua_rawset(L, -3);
  return 1;
}

COSMIC_SYSCALL(kill, 2) {
  lua_Integer pid_value = luaL_checkinteger(L, 1);
  lua_Integer signal_value = luaL_checkinteger(L, 2);
  if (pid_value == 0 || pid_value < -INT_MAX || pid_value > INT_MAX)
    return luaL_argerror(L, 1, "pid is out of range");
  if (signal_value < 0 || signal_value > INT_MAX)
    return luaL_argerror(L, 2, "signal is out of range");
  pid_t pid = (pid_t)pid_value;
  int signal = (int)signal_value;
  if (kill(pid, signal) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

static void set_decimal (lua_State *L, const char *name, uint64_t value) {
  char text[32];
  snprintf(text, sizeof text, "%llu", (unsigned long long)value);
  lua_pushstring(L, text);
  lua_setfield(L, -2, name);
}

COSMIC_SYSCALL(relaunch, 2) {
  lua_Integer artifact_to = luaL_checkinteger(L, 1);
  lua_Integer core_to = luaL_checkinteger(L, 2);
  if (artifact_to < 3 || artifact_to > 255 || core_to < 3 || core_to > 255 ||
      artifact_to == core_to)
    return luaL_argerror(L, 1, "the child descriptors must differ, from 3 to 255");
  const struct cosmic_artifact *artifact = cosmic_store_artifact(L);
  if (artifact == NULL) return cosmic_fail(L, ENOSYS);
  char physical[PATH_MAX];
  errno = 0; /* as for executable */
  if (!cosmic_executable_path(physical, sizeof physical)) {
    int number = errno;
    return cosmic_fail(L, number == 0 ? ENAMETOOLONG : number);
  }
  if (artifact->host) {
    /* A host program is its own launcher: executing it again is enough. */
    lua_createtable(L, 0, 2);
    lua_pushstring(L, physical);
    lua_setfield(L, -2, "path");
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "host");
    return 1;
  }
  const struct cosmic_portable_entry *selected = &artifact->portable.selected;
  lua_createtable(L, 0, 5);
  lua_pushstring(L, physical);
  lua_setfield(L, -2, "path");
  lua_pushstring(L, artifact->logical_path);
  lua_setfield(L, -2, "artifact");
  lua_pushinteger(L, artifact->fd);
  lua_setfield(L, -2, "artifact_fd");
  lua_createtable(L, 0, 7);
  set_decimal(L, COSMIC_PORTABLE_ENV_ARTIFACT_FD, (uint64_t)artifact_to);
  set_decimal(L, COSMIC_PORTABLE_ENV_CORE_FD, (uint64_t)core_to);
  set_decimal(L, COSMIC_PORTABLE_ENV_TARGET_ID, selected->target_id);
  set_decimal(L, COSMIC_PORTABLE_ENV_CONFIGURATION_ID, selected->configuration_id);
  set_decimal(L, COSMIC_PORTABLE_ENV_CORE_OFFSET, selected->offset);
  set_decimal(L, COSMIC_PORTABLE_ENV_CORE_LENGTH, selected->length);
  char digest[COSMIC_PORTABLE_SHA256_LENGTH * 2 + 1];
  for (size_t i = 0; i < COSMIC_PORTABLE_SHA256_LENGTH; i++)
    snprintf(digest + i * 2, 3, "%02x", selected->sha256[i]);
  lua_pushstring(L, digest);
  lua_setfield(L, -2, COSMIC_PORTABLE_ENV_CORE_SHA256);
  lua_setfield(L, -2, "environment");
  /* The descriptor is opened last, into a slot the table already has
   * room for, so no raise can come between it and the answer. */
  lua_pushliteral(L, "core_fd");
  int core_fd = cosmic_executable_fd();
  if (core_fd < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, core_fd);
  lua_rawset(L, -3);
  return 1;
}

COSMIC_SYSCALL(pipe, 0) {
  /* The answer and its keys are made before the pipe, and filling a
   * table sized for them allocates nothing: a raise after the pipe
   * would leak both ends. */
  lua_createtable(L, 0, 2);
  lua_pushliteral(L, "writer");
  lua_pushliteral(L, "reader");
  int ends[2];
  if (pipe(ends) != 0) return cosmic_fail(L, errno);
  /* One thread and no fork between these calls, so setting CLOEXEC
   * after the fact cannot leak an end into a child. */
  for (int i = 0; i < 2; i++) {
    if (fcntl(ends[i], F_SETFD, FD_CLOEXEC) != 0) {
      int number = errno;
      close(ends[0]);
      close(ends[1]);
      return cosmic_fail(L, number);
    }
  }
  lua_pushinteger(L, ends[0]);
  lua_rawset(L, -4);
  lua_pushinteger(L, ends[1]);
  lua_rawset(L, -3);
  return 1;
}

COSMIC_SYSCALL(dup, 1) {
  int fd = cosmic_checkint(L, 1);
  int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (copy < 0) return cosmic_fail(L, errno);
  /* Nothing between the copy and its push can raise: pushing an integer
   * allocates nothing, so the copy cannot leak. */
  lua_pushinteger(L, copy);
  return 1;
}

COSMIC_SYSCALL(dup2, 2) {
  int fd = cosmic_checkint(L, 1);
  int to = cosmic_checkint(L, 2);
  int made;
  do { made = dup2(fd, to); } while (made < 0 && errno == EINTR);
  if (made < 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(set_nonblocking, 2) {
  int fd = cosmic_checkint(L, 1);
  int on = lua_toboolean(L, 2);
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return cosmic_fail_effect(L, errno);
  flags = on ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK);
  if (fcntl(fd, F_SETFL, flags) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

#define POLL_MAX 1024

COSMIC_SYSCALL(poll, 3) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_Integer timeout = luaL_checkinteger(L, 3);
  if (timeout < -1 || timeout > INT_MAX)
    return luaL_argerror(L, 3, "timeout is out of range");
  lua_Integer count = (lua_Integer)lua_rawlen(L, 1);
  if (count > POLL_MAX) return luaL_argerror(L, 1, "too many descriptors");
  if ((lua_Integer)lua_rawlen(L, 2) != count)
    return luaL_argerror(L, 2, "one event mask per descriptor");
  struct pollfd fds[POLL_MAX];
  for (lua_Integer i = 0; i < count; i++) {
    lua_rawgeti(L, 1, i + 1);
    lua_rawgeti(L, 2, i + 1);
    if (!lua_isinteger(L, -2) || !lua_isinteger(L, -1))
      return luaL_argerror(L, 1, "descriptors and masks must be integers");
    lua_Integer fd = lua_tointeger(L, -2);
    lua_Integer events = lua_tointeger(L, -1);
    if (fd < -1 || fd > INT_MAX || events < 0 || events > SHRT_MAX)
      return luaL_argerror(L, 1, "descriptor or mask is out of range");
    fds[i].fd = (int)fd;
    fds[i].events = (short)events;
    fds[i].revents = 0;
    lua_pop(L, 2);
  }
  /* An interrupted wait answers as a wait that found nothing, so the
   * caller's loop gets to look at whatever the signal meant. */
  if (poll(fds, (nfds_t)count, (int)timeout) < 0) {
    if (errno != EINTR) return cosmic_fail(L, errno);
    for (lua_Integer i = 0; i < count; i++) fds[i].revents = 0;
  }
  lua_createtable(L, (int)count, 0);
  for (lua_Integer i = 0; i < count; i++) {
    lua_pushinteger(L, fds[i].revents);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

COSMIC_SYSCALL(subreaper, 0) {
#if defined(__linux__) && defined(PR_SET_CHILD_SUBREAPER)
  if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0)
    return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
#else
  return cosmic_fail_effect(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(ignore_sigpipe, 0) {
  struct sigaction previous;
  if (sigaction(SIGPIPE, NULL, &previous) != 0)
    return cosmic_fail_effect(L, errno);
  if (previous.sa_handler != SIG_DFL) return cosmic_ok(L);
  struct sigaction ignore;
  memset(&ignore, 0, sizeof ignore);
  ignore.sa_handler = SIG_IGN;
  sigemptyset(&ignore.sa_mask);
  if (sigaction(SIGPIPE, &ignore, NULL) != 0)
    return cosmic_fail_effect(L, errno);
  sigpipe_ignored_here = 1;
  return cosmic_ok(L);
}

COSMIC_SYSCALL(cpu_count, 0) {
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  lua_pushinteger(L, count < 1 ? 1 : (lua_Integer)count);
  return 1;
}

COSMIC_SYSCALL(uname, 0) {
  struct utsname info;
  if (uname(&info) != 0) {
    return cosmic_fail(L, errno);
  }
  lua_createtable(L, 0, 2);
  lua_pushstring(L, info.sysname);
  lua_setfield(L, -2, "sysname");
  lua_pushstring(L, info.machine);
  lua_setfield(L, -2, "machine");
  return 1;
}

static volatile sig_atomic_t child_cancelled;
static int child_signals_guarded;
static struct sigaction previous_int;
static struct sigaction previous_term;

static void catch_child_cancel (int number) {
  if (child_cancelled == 0) child_cancelled = number;
}

static void child_signal_set (sigset_t *set) {
  sigemptyset(set);
  sigaddset(set, SIGINT);
  sigaddset(set, SIGTERM);
}

COSMIC_SYSCALL(guard_child_signals, 0) {
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail_effect(L, errno);
  if (child_signals_guarded) {
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return cosmic_fail_effect(L, EBUSY);
  }
  struct sigaction action;
  action.sa_handler = catch_child_cancel;
  child_signal_set(&action.sa_mask);
  action.sa_flags = 0;
  child_cancelled = 0;
  if (sigaction(SIGINT, &action, &previous_int) != 0) {
    int number = errno;
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return cosmic_fail_effect(L, number);
  }
  if (sigaction(SIGTERM, &action, &previous_term) != 0) {
    int number = errno;
    sigaction(SIGINT, &previous_int, NULL);
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return cosmic_fail_effect(L, number);
  }
  child_signals_guarded = 1;
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0) {
    int number = errno;
    sigaction(SIGINT, &previous_int, NULL);
    sigaction(SIGTERM, &previous_term, NULL);
    child_signals_guarded = 0;
    return cosmic_fail_effect(L, number);
  }
  return cosmic_ok(L);
}

COSMIC_SYSCALL(unguard_child_signals, 0) {
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail(L, errno);
  if (!child_signals_guarded) {
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    lua_pushinteger(L, 0);
    return 1;
  }
  int first = 0;
  if (sigaction(SIGINT, &previous_int, NULL) != 0) first = errno;
  if (sigaction(SIGTERM, &previous_term, NULL) != 0 && first == 0) first = errno;
  int cancelled = child_cancelled;
  child_signals_guarded = 0;
  child_cancelled = 0;
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0 && first == 0)
    first = errno;
  if (first != 0) return cosmic_fail(L, first);
  lua_pushinteger(L, cancelled);
  return 1;
}

COSMIC_SYSCALL(cancelled_child_signal, 0) {
  sigset_t blocked, previous_mask;
  child_signal_set(&blocked);
  if (sigprocmask(SIG_BLOCK, &blocked, &previous_mask) != 0)
    return cosmic_fail(L, errno);
  int number = child_cancelled;
  child_cancelled = 0;
  if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) != 0)
    return cosmic_fail(L, errno);
  lua_pushinteger(L, number);
  return 1;
}

#define ENTRY(name) {#name, cosmic_sys_##name}

static const luaL_Reg table[] = {
  ENTRY(open),     ENTRY(open_temporary), ENTRY(close),
  ENTRY(read),     ENTRY(pread),          ENTRY(write),
  ENTRY(lseek),
  ENTRY(fstat),    ENTRY(stat),          ENTRY(lstat),
  ENTRY(mkdir),    ENTRY(rmdir),         ENTRY(unlink),
  ENTRY(rename),   ENTRY(chmod),         ENTRY(readdir),
  ENTRY(getcwd),   ENTRY(chdir),         ENTRY(realpath),
  ENTRY(mkdtemp),  ENTRY(executable),    ENTRY(getenv),
  ENTRY(environ),  ENTRY(exit),          ENTRY(getpid),
  ENTRY(getuid),   ENTRY(umask),         ENTRY(entropy),
  ENTRY(clock_gettime), ENTRY(nanosleep), ENTRY(isatty),
  ENTRY(digest),   ENTRY(hmac),          ENTRY(execve),
  ENTRY(spawn),
  ENTRY(waitpid),  ENTRY(kill),          ENTRY(guard_child_signals),
  ENTRY(unguard_child_signals), ENTRY(cancelled_child_signal),
  ENTRY(pipe),     ENTRY(dup),          ENTRY(dup2),
  ENTRY(set_nonblocking),  ENTRY(poll),
  ENTRY(subreaper), ENTRY(ignore_sigpipe),  ENTRY(cpu_count),
  ENTRY(relaunch), ENTRY(uname),
  ENTRY(symlink), ENTRY(readlink), ENTRY(utimens), ENTRY(fsync),
  ENTRY(ftruncate),
  {NULL, NULL},
};

struct constant {
  const char *name;
  lua_Integer value;
};

/* The numbers a caller passes back in. They come from this libc, so a
 * Teal module never carries a platform's constant of its own. */
static const struct constant constants[] = {
  {"O_RDONLY", O_RDONLY},
  {"O_WRONLY", O_WRONLY},
  {"O_RDWR", O_RDWR},
  {"O_CREAT", O_CREAT},
  {"O_EXCL", O_EXCL},
  {"O_TRUNC", O_TRUNC},
  {"O_APPEND", O_APPEND},
  {"SEEK_SET", SEEK_SET},
  {"SEEK_CUR", SEEK_CUR},
  {"SEEK_END", SEEK_END},
  {"CLOCK_REALTIME", CLOCK_REALTIME},
  {"CLOCK_MONOTONIC", CLOCK_MONOTONIC},
  {"ENOENT", ENOENT},
  {"EEXIST", EEXIST},
  {"EACCES", EACCES},
  {"EINTR", EINTR},
  {"EISDIR", EISDIR},
  {"ENOTDIR", ENOTDIR},
  {"ENOTEMPTY", ENOTEMPTY},
  {"EAGAIN", EAGAIN},
  {"EPIPE", EPIPE},
  {"EXDEV", EXDEV},
  {"ECHILD", ECHILD},
  {"ESRCH", ESRCH},
  {"EBADF", EBADF},
  {"ENOSYS", ENOSYS},
  {"EINVAL", EINVAL},
  {"SIGHUP", SIGHUP},
  {"SIGINT", SIGINT},
  {"SIGQUIT", SIGQUIT},
  {"SIGKILL", SIGKILL},
  {"SIGPIPE", SIGPIPE},
  {"SIGTERM", SIGTERM},
  {"SIGUSR1", SIGUSR1},
  {"POLLIN", POLLIN},
  {"POLLOUT", POLLOUT},
  {"POLLERR", POLLERR},
  {"POLLHUP", POLLHUP},
  {"POLLNVAL", POLLNVAL},
  {NULL, 0},
};

int cosmic_open_syscalls (lua_State *L) {
  luaL_newlib(L, table);
  for (const struct constant *c = constants; c->name != NULL; c++) {
    lua_pushinteger(L, c->value);
    lua_setfield(L, -2, c->name);
  }
  return 1;
}
