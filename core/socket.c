/*
 * The socket table core/socket.h declares.
 */

/* accept4, and SOCK_CLOEXEC with it, are extensions on Linux; macOS
 * has neither, and gets their effect through fcntl (`made`). */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "check.h"
#include "fail.h"
#include "lauxlib.h"
#include "process.h"
#include "socket.h"

/* Where the table at `index` says a socket is, in `*out` and `*length`:
 * 0, or the errno a caller meets at runtime (a path too long, or holding
 * a NUL). An address no correct program passes -- a kind the table does
 * not read, a path that is no string or is empty -- raises. Nothing is
 * left on the stack, and nothing of it is kept but the copy in `*out`. */
static int address_of (lua_State *L, int index, struct sockaddr_storage *out,
                       socklen_t *length) {
  memset(out, 0, sizeof *out);
  *length = 0;
  luaL_checktype(L, index, LUA_TTABLE);
  lua_getfield(L, index, "kind");
  const char *kind = lua_tostring(L, -1);
  if (kind == NULL || strcmp(kind, "unix") != 0) {
    return luaL_argerror(L, index, "kind must be \"unix\"");
  }
  lua_pop(L, 1);
  lua_getfield(L, index, "path");
  if (lua_type(L, -1) != LUA_TSTRING) return luaL_argerror(L, index, "path must be a string");
  const char *path = cosmic_path(L, lua_gettop(L));
  size_t size = lua_rawlen(L, -1);
  if (size == 0) return luaL_argerror(L, index, "path must not be empty");
  struct sockaddr_un *unix_address = (struct sockaddr_un *)out;
  int failure = 0;
  if (path == NULL) {
    failure = EINVAL;
  } else if (size >= sizeof unix_address->sun_path) {
    /* The kernel would take one that fills sun_path with no NUL after
     * it, which no other program could name back.
     * TODO: reach a socket file whose path is past sun_path through a
     * descriptor of its directory (bindat and connectat on macOS, the
     * directory's /proc/self/fd name on Linux), once a caller meets
     * one: a temporary directory under macOS's $TMPDIR leaves a name
     * there some 50 bytes. */
    failure = ENAMETOOLONG;
  } else {
    unix_address->sun_family = AF_UNIX;
    memcpy(unix_address->sun_path, path, size);
    *length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + size + 1);
  }
  lua_pop(L, 1);
  return failure;
}

/* Makes `fd` what every socket of the table is: closed on exec,
 * nonblocking, and, where a send cannot say so itself, answering EPIPE
 * rather than raising SIGPIPE. 0, or why not. */
static int made (int fd) {
#if !defined(SOCK_CLOEXEC)
  if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) return errno;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) return errno;
#endif
#if defined(SO_NOSIGPIPE)
  int on = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on) != 0) return errno;
#endif
  (void)fd;
  return 0;
}

/* A new stream socket of `family`, made as `made` says, or -1 with
 * errno set. */
static int stream_socket (int family) {
#if defined(SOCK_CLOEXEC)
  int fd = socket(family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
#else
  int fd = socket(family, SOCK_STREAM, 0);
#endif
  if (fd < 0) return -1;
  int failure = made(fd);
  if (failure != 0) {
    close(fd);
    errno = failure;
    return -1;
  }
  return fd;
}

/* Milliseconds on the monotonic clock. */
static int64_t now_ms (void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* The longest a wait sleeps before it asks again whether a guard caught
 * a signal. A signal that lands between that question and the sleep
 * only sets the guard's flag, so a sleep with no bound could outlast
 * it forever; each slice bounds how late it is seen, as core/http.c's
 * one-second polls and cosmic.child's do. */
#define SLICE_MS 100

/* The deadline argument `arg`'s timeout in milliseconds makes, on the
 * monotonic clock, or -1 for a timeout of -1, no limit. */
static int64_t deadline_of (lua_State *L, int arg) {
  lua_Integer timeout = luaL_checkinteger(L, arg);
  luaL_argcheck(L, timeout >= -1 && timeout <= INT_MAX, arg, "timeout is out of range");
  return timeout < 0 ? -1 : now_ms() + timeout;
}

/* How long a wait for `deadline` may sleep now: a slice at most, 0 once
 * it has passed. */
static int slice (int64_t deadline) {
  if (deadline < 0) return SLICE_MS;
  int64_t remaining = deadline - now_ms();
  if (remaining <= 0) return 0;
  return remaining < SLICE_MS ? (int)remaining : SLICE_MS;
}

/* Sleeps `*pause` milliseconds, doubling it up to a slice for the next
 * time, before a call that answered EAGAIN is asked again: 0 to ask
 * again, ETIMEDOUT once `deadline` has passed, EINTR once a guard has
 * caught a signal. */
static int paused (int64_t deadline, int64_t *pause) {
  if (cosmic_signal_caught()) return EINTR;
  int most = slice(deadline);
  if (most == 0) return ETIMEDOUT;
  int64_t ms = *pause < most ? *pause : most;
  *pause = *pause * 2 < SLICE_MS ? *pause * 2 : SLICE_MS;
  struct timespec ts = { (time_t)(ms / 1000), (long)(ms % 1000) * 1000000L };
  nanosleep(&ts, NULL);
  return cosmic_signal_caught() ? EINTR : 0;
}

COSMIC_SYSCALL(listen, 2) {
  struct sockaddr_storage address;
  socklen_t length = 0;
  int failure = address_of(L, 1, &address, &length);
  int backlog = cosmic_checkint(L, 2);
  luaL_argcheck(L, backlog >= 1, 2, "backlog must be at least 1");
  if (failure != 0) return cosmic_fail(L, failure);
  int fd = stream_socket(address.ss_family);
  if (fd < 0) return cosmic_fail(L, errno);
  if (bind(fd, (struct sockaddr *)&address, length) != 0 || listen(fd, backlog) != 0) {
    failure = errno;
    close(fd);
    return cosmic_fail(L, failure);
  }
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(accept, 1) {
  int listener = cosmic_checkfd(L, 1);
  int fd;
  do {
#if defined(SOCK_CLOEXEC)
    fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC | SOCK_NONBLOCK);
#else
    fd = accept(listener, NULL, NULL);
#endif
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) return cosmic_fail(L, errno);
  int failure = made(fd);
  if (failure != 0) {
    close(fd);
    return cosmic_fail(L, failure);
  }
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(connect, 2) {
  struct sockaddr_storage address;
  socklen_t length = 0;
  int failure = address_of(L, 1, &address, &length);
  int64_t deadline = deadline_of(L, 2);
  if (failure != 0) return cosmic_fail(L, failure);
  int fd = stream_socket(address.ss_family);
  if (fd < 0) return cosmic_fail(L, errno);
  /* A unix socket connects at once or answers EAGAIN, its listener's
   * backlog full, where a blocking one would wait: this waits in
   * slices, asking again, as `wait` does.
   * TODO: answer a connection still in progress (EINPROGRESS) with its
   * descriptor, and give its outcome through SO_ERROR once `wait` says
   * it is writable, once an address of a kind that connects over time
   * ("tcp") is read. */
  int64_t pause = 1;
  for (;;) {
    if (connect(fd, (struct sockaddr *)&address, length) == 0) break;
    failure = errno;
    if (failure == EAGAIN) failure = paused(deadline, &pause);
    if (failure != 0 && failure != EINTR) {
      close(fd);
      return cosmic_fail(L, failure);
    }
  }
  lua_pushinteger(L, fd);
  return 1;
}

COSMIC_SYSCALL(send, 2) {
  int fd = cosmic_checkfd(L, 1);
  size_t size;
  const char *data = luaL_checklstring(L, 2, &size);
#if defined(MSG_NOSIGNAL)
  const int flags = MSG_NOSIGNAL;
#else
  const int flags = 0;
#endif
  ssize_t sent;
  do {
    sent = send(fd, data, size, flags);
  } while (sent < 0 && errno == EINTR);
  if (sent < 0) return cosmic_fail(L, errno);
  lua_pushinteger(L, (lua_Integer)sent);
  return 1;
}

COSMIC_SYSCALL(shutdown, 2) {
  int fd = cosmic_checkfd(L, 1);
  static const char *const names[] = {"read", "write", "both", NULL};
  static const int hows[] = {SHUT_RD, SHUT_WR, SHUT_RDWR};
  int how = hows[luaL_checkoption(L, 2, NULL, names)];
  if (shutdown(fd, how) != 0) return cosmic_fail_effect(L, errno);
  return cosmic_ok(L);
}

COSMIC_SYSCALL(wait, 3) {
  int fd = cosmic_checkfd(L, 1);
  int writable = lua_toboolean(L, 2);
  int64_t deadline = deadline_of(L, 3);
  for (;;) {
    if (cosmic_signal_caught()) return cosmic_fail_effect(L, EINTR);
    int left = slice(deadline);
    struct pollfd watched = { fd, writable ? POLLOUT : POLLIN, 0 };
    int ready = poll(&watched, 1, left);
    if (ready > 0) return cosmic_ok(L);
    if (ready < 0 && errno != EINTR) return cosmic_fail_effect(L, errno);
    if (ready == 0 && left == 0) return cosmic_fail_effect(L, ETIMEDOUT);
  }
}

/* The table is filled from the header's own entries, as core/syscalls.c
 * fills its own. */
#undef COSMIC_SYSCALL
#undef COSMIC_CONSTANT
#define COSMIC_SYSCALL(name, arity)                                      \
  lua_pushcfunction(L, cosmic_sys_##name);                               \
  lua_setfield(L, -2, #name)
#define COSMIC_CONSTANT(name)                                            \
  lua_pushinteger(L, name);                                              \
  lua_setfield(L, -2, #name);

int cosmic_open_socket (lua_State *L) {
  lua_newtable(L);
#include "socket.h"
  return 1;
}
