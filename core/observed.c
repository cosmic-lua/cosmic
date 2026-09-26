/* The syscall table's log (core/observed.h), which the observed
 * bindings of core/syscalls.c and core/syscalls_fs.c keep their records
 * in. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "fail.h"
#include "fault.h"
#include "lauxlib.h"
#include "memory.h"
#include "observed.h"

/* What the table's queries answered while observing is on
 * (core/observed.h): the log build.filesystem_observations drains, with
 * `observed`, into the reads of the test running, and turns on and off
 * with `observe`. Each record is of what a query was asked and
 * answered, whoever called it -- a module that took the call before a
 * capture began, or a Teal function over it -- in one buffer on the
 * core's own heap. Nothing here calls Lua: a record is bytes, turned
 * into Lua values only when drained. */

/* The calls a record is kept of, each a query that changes nothing and
 * answers `value|nil, error, errno`: one whose record cannot be kept
 * fails as memory does, having changed nothing, rather than answer what
 * no key will hold. `path` when its first argument is a path, which is
 * kept whole, from the working directory the call was made in when it
 * is relative. */
static const struct observed_call {
  const char *name;
  bool path;
} observed_calls[] = {
  [COSMIC_OBSERVED_GETCWD] = {"getcwd", false},
  [COSMIC_OBSERVED_EXECUTABLE] = {"executable", false},
  [COSMIC_OBSERVED_LSTAT] = {"lstat", true},
  [COSMIC_OBSERVED_READLINK] = {"readlink", true},
  [COSMIC_OBSERVED_REALPATH] = {"realpath", true},
};

/* A record is the call's index and its count of answers, then its path
 * when it takes one, then each answer, each value a tag and its bytes:
 * `n` nil, `b` a boolean, `i` an integer, `s` a string (its length,
 * then its bytes), `T` a table (its keys and values, one level deep,
 * then `e`), and `?` a value no record holds. `last` is where the last
 * record kept starts: a record the same as it is not kept again. */
static struct {
  char *bytes;
  size_t length;
  size_t room;
  size_t last;
} observing;

bool cosmic_observing;

static bool log_put (const void *data, size_t size) {
  if (size == 0) return true;
  if (size > SIZE_MAX - observing.length) return false;
  size_t need = observing.length + size;
  if (need > observing.room) {
    size_t room = observing.room == 0 ? 256 : observing.room;
    while (room < need) room = room > SIZE_MAX / 2 ? need : room * 2;
    char *grown = COSMIC_FAULT("observed_log")
                      ? NULL
                      : cosmic_realloc(observing.bytes, room);
    if (grown == NULL) return false;
    observing.bytes = grown;
    observing.room = room;
  }
  memcpy(observing.bytes + observing.length, data, size);
  observing.length = need;
  return true;
}

static bool log_string (const char *text, size_t length) {
  return log_put("s", 1) && log_put(&length, sizeof length) &&
         log_put(text, length);
}

/* Logs the value at `index`; a table only at the top, as a flat one of
 * scalars: what the observed calls answer. */
static bool log_value (lua_State *L, int index, bool nested) {
  switch (lua_type(L, index)) {
    case LUA_TNIL:
    return log_put("n", 1);
    case LUA_TBOOLEAN: {
      char value[2] = {'b', (char)lua_toboolean(L, index)};
      return log_put(value, sizeof value);
    }
    case LUA_TNUMBER: {
      if (!lua_isinteger(L, index)) return log_put("?", 1);
      lua_Integer value = lua_tointeger(L, index);
      return log_put("i", 1) && log_put(&value, sizeof value);
    }
    case LUA_TSTRING: {
      size_t length;
      const char *text = lua_tolstring(L, index, &length);
      return log_string(text, length);
    }
    case LUA_TTABLE: {
      if (nested) return log_put("?", 1);
      /* Refused rather than raised: a raise would leave half a record. */
      if (!lua_checkstack(L, 2)) return false;
      int table = lua_absindex(L, index);
      if (!log_put("T", 1)) return false;
      lua_pushnil(L);
      while (lua_next(L, table) != 0) {
        bool kept = log_value(L, -2, true) && log_value(L, -1, true);
        lua_pop(L, 1);
        if (!kept) {
          lua_pop(L, 1);
          return false;
        }
      }
      return log_put("e", 1);
    }
    default:
    return log_put("?", 1);
  }
}

/* Logs the path a call was given, absolute: a relative one after the
 * working directory it was made in, or as given when that cannot be
 * told, which the drain's reader takes for a path no key holds. */
static bool log_path (lua_State *L) {
  if (lua_type(L, 1) != LUA_TSTRING) return log_put("n", 1);
  size_t length;
  const char *path = lua_tolstring(L, 1, &length);
  char here[PATH_MAX];
  if ((length > 0 && path[0] == '/') || getcwd(here, sizeof here) == NULL) {
    return log_string(path, length);
  }
  size_t prefix = strcmp(here, "/") == 0 ? 0 : strlen(here);
  if (length > SIZE_MAX - prefix - 1) return false;
  size_t whole = prefix + 1 + length;
  return log_put("s", 1) && log_put(&whole, sizeof whole) &&
         log_put(here, prefix) && log_put("/", 1) && log_put(path, length);
}

int cosmic_observed_call (lua_State *L, enum cosmic_observed_call call,
                          lua_CFunction query) {
  int count = query(L);
  size_t start = observing.length;
  unsigned char header[2] = {(unsigned char)call, (unsigned char)count};
  bool kept = log_put(header, sizeof header);
  if (kept && observed_calls[call].path) kept = log_path(L);
  for (int i = count; kept && i >= 1; i--) {
    kept = log_value(L, -i, false);
  }
  if (!kept) {
    observing.length = start;
    lua_pop(L, count);
    return cosmic_fail(L, ENOMEM);
  }
  size_t size = observing.length - start;
  if (start - observing.last == size &&
      memcmp(observing.bytes + observing.last, observing.bytes + start, size) ==
          0) {
    observing.length = start;
  } else {
    observing.last = start;
  }
  return count;
}

/* Turns the log on or off; what it holds stays until drained. */
static int observe (lua_State *L) {
  luaL_checktype(L, 1, LUA_TBOOLEAN);
  cosmic_observing = lua_toboolean(L, 1);
  return 0;
}

/* Pushes the value logged at `at` and answers where the next one
 * starts. `whole` turns false for a value no record holds, which is
 * pushed as nil, or left out of its table. */
static size_t push_logged (lua_State *L, size_t at, bool *whole) {
  char tag = observing.bytes[at++];
  switch (tag) {
    case 'b':
    lua_pushboolean(L, observing.bytes[at] != 0);
    return at + 1;
    case 'i': {
      lua_Integer value;
      memcpy(&value, observing.bytes + at, sizeof value);
      lua_pushinteger(L, value);
      return at + sizeof value;
    }
    case 's': {
      size_t length;
      memcpy(&length, observing.bytes + at, sizeof length);
      at += sizeof length;
      lua_pushlstring(L, observing.bytes + at, length);
      return at + length;
    }
    case 'T':
    lua_createtable(L, 0, 16);
    while (observing.bytes[at] != 'e') {
      bool pair = observing.bytes[at] != '?';
      at = push_logged(L, at, whole);
      pair = pair && observing.bytes[at] != '?';
      at = push_logged(L, at, whole);
      if (pair) {
        lua_rawset(L, -3);
      } else {
        lua_pop(L, 2);
      }
    }
    return at + 1;
    case '?':
    *whole = false;
    lua_pushnil(L);
    return at;
    default:
    lua_pushnil(L);
    return at;
  }
}

/* Every record logged since the last drain, in the order made, each
 * `{call = name, path = path, n = count, ...}`, its answers from 1 to
 * `n`, and `partial = true` when one of them held what no record can.
 * The log is emptied once the list is made: a failure making it keeps
 * every record. */
static int observed (lua_State *L) {
  luaL_checkstack(L, 8, NULL);
  lua_createtable(L, 0, 0);
  lua_Integer made = 0;
  size_t at = 0;
  while (at < observing.length) {
    const struct observed_call *call =
        &observed_calls[(unsigned char)observing.bytes[at]];
    int count = (unsigned char)observing.bytes[at + 1];
    at += 2;
    bool whole = true;
    lua_createtable(L, count, 4);
    lua_pushstring(L, call->name);
    lua_setfield(L, -2, "call");
    if (call->path) {
      at = push_logged(L, at, &whole);
      lua_setfield(L, -2, "path");
    }
    lua_pushinteger(L, count);
    lua_setfield(L, -2, "n");
    for (int i = 1; i <= count; i++) {
      at = push_logged(L, at, &whole);
      lua_rawseti(L, -2, i);
    }
    if (!whole) {
      lua_pushboolean(L, 1);
      lua_setfield(L, -2, "partial");
    }
    lua_rawseti(L, -2, ++made);
  }
  cosmic_free(observing.bytes);
  observing.bytes = NULL;
  observing.length = 0;
  observing.room = 0;
  observing.last = 0;
  return 1;
}

int cosmic_open_observed (lua_State *L) {
  lua_createtable(L, 0, 7);
  lua_pushcfunction(L, observe);
  lua_setfield(L, -2, "observe");
  lua_pushcfunction(L, observed);
  lua_setfield(L, -2, "observed");
  /* The queries themselves, past the log: the observer's own
   * questions are none of the test's. */
  lua_pushcfunction(L, cosmic_query_getcwd);
  lua_setfield(L, -2, "getcwd");
  lua_pushcfunction(L, cosmic_query_executable);
  lua_setfield(L, -2, "executable");
  lua_pushcfunction(L, cosmic_query_lstat);
  lua_setfield(L, -2, "lstat");
  lua_pushcfunction(L, cosmic_query_readlink);
  lua_setfield(L, -2, "readlink");
  lua_pushcfunction(L, cosmic_query_realpath);
  lua_setfield(L, -2, "realpath");
  return 1;
}
