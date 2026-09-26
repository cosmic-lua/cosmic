/* The syscall table's log (core/observed.h): what its observed calls
 * were asked and answered while observing is on, which
 * build.filesystem_observations drains, with `observed`, into the reads
 * of the test running, and turns on and off with `observe`. Each record
 * is kept by the binding itself, whoever called it -- a module that took
 * the call before a capture began, or a Teal function over it -- in one
 * buffer of its own. Nothing here calls Lua on the way: a
 * record is bytes, turned into Lua values only when drained. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fail.h"
#include "fault.h"
#include "lauxlib.h"
#include "observed.h"

/* What a call's first argument is to its record. */
enum observed_argument {
  ARGUMENT_NONE, /* it takes none that is kept */
  ARGUMENT_PATH, /* a path: kept whole, a relative one from the working
                  * directory the call was made in */
  ARGUMENT_TEXT, /* a name, a URL: kept as given */
};

/* Whether a call's path is resolved beside its record, and how far. */
enum observed_resolution {
  RESOLVE_NONE,
  RESOLVE_FOLLOW, /* through a link its path ends in, as open and stat do */
  RESOLVE_LINK,   /* only as far as its last name, as lstat and readlink */
};

static const struct observed_call {
  const char *name;
  enum observed_argument argument;
  enum observed_resolution resolution;
} observed_calls[] = {
  [COSMIC_OBSERVED_GETCWD] = {"getcwd", ARGUMENT_NONE, RESOLVE_NONE},
  [COSMIC_OBSERVED_EXECUTABLE] = {"executable", ARGUMENT_NONE, RESOLVE_NONE},
  [COSMIC_OBSERVED_LSTAT] = {"lstat", ARGUMENT_PATH, RESOLVE_LINK},
  [COSMIC_OBSERVED_READLINK] = {"readlink", ARGUMENT_PATH, RESOLVE_LINK},
  [COSMIC_OBSERVED_REALPATH] = {"realpath", ARGUMENT_PATH, RESOLVE_FOLLOW},
  [COSMIC_OBSERVED_OPEN] = {"open", ARGUMENT_PATH, RESOLVE_FOLLOW},
  [COSMIC_OBSERVED_STAT] = {"stat", ARGUMENT_PATH, RESOLVE_FOLLOW},
  [COSMIC_OBSERVED_READDIR] = {"readdir", ARGUMENT_PATH, RESOLVE_FOLLOW},
  [COSMIC_OBSERVED_GETENV] = {"getenv", ARGUMENT_TEXT, RESOLVE_NONE},
  [COSMIC_OBSERVED_ENVIRON] = {"environ", ARGUMENT_NONE, RESOLVE_NONE},
  [COSMIC_OBSERVED_MKDIR] = {"mkdir", ARGUMENT_PATH, RESOLVE_NONE},
  [COSMIC_OBSERVED_MKDTEMP] = {"mkdtemp", ARGUMENT_PATH, RESOLVE_NONE},
  [COSMIC_OBSERVED_SPAWN] = {"spawn", ARGUMENT_TEXT, RESOLVE_NONE},
  [COSMIC_OBSERVED_HTTP] = {"http", ARGUMENT_TEXT, RESOLVE_NONE},
};

/* A record is the call's index and its count of answers, then its
 * argument when it keeps one, then its resolution when it has one,
 * then each answer, each value a tag and its bytes: `n` nil, `b` a
 * boolean, `i` an integer, `s` a string (its length, then its bytes),
 * `T` a table (its keys and values, one level deep, then `e`), and `?`
 * a value no record holds. `last` is where the last record kept
 * starts: a record the same as it is not kept again.
 *
 * The bytes are libc's, as the coverage collector's are, not the heap
 * core/memory.h counts: they are the observer's, kept for whatever call
 * a test makes, and a test that holds the core to what its own C
 * allocates and frees (`testing.c_heap`) is not held to them. Their
 * growth fails only at the fault point "observed_log". */
static struct {
  char *bytes;
  size_t length;
  size_t room;
  size_t last;
} observing;

bool cosmic_observing;

/* Which paths a record resolves, as `resolving` was told: none, every
 * absolute one, or every absolute one outside `tree` or climbing with
 * "..". */
static struct {
  enum { RESOLVING_NONE, RESOLVING_ALL, RESOLVING_OUTSIDE } which;
  char tree[PATH_MAX];
  size_t length;
} resolving;

/* Makes room for `size` more bytes. */
static bool log_room (size_t size) {
  if (size > SIZE_MAX - observing.length) return false;
  size_t need = observing.length + size;
  if (need > observing.room) {
    size_t room = observing.room == 0 ? 256 : observing.room;
    while (room < need) room = room > SIZE_MAX / 2 ? need : room * 2;
    char *grown = COSMIC_FAULT("observed_log")
                      ? NULL
                      : realloc(observing.bytes, room);
    if (grown == NULL) return false;
    observing.bytes = grown;
    observing.room = room;
  }
  return true;
}

static bool log_put (const void *data, size_t size) {
  if (size == 0) return true;
  if (!log_room(size)) return false;
  memcpy(observing.bytes + observing.length, data, size);
  observing.length += size;
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

/* Logs a path, absolute: a relative one after the working directory
 * the call was made in, or as given when that cannot be told, which
 * the drain's reader takes for a path no key holds. `*at` is where its
 * bytes start in the log. */
static bool log_path (const char *path, size_t length, size_t *at) {
  char here[PATH_MAX];
  if ((length > 0 && path[0] == '/') || getcwd(here, sizeof here) == NULL) {
    *at = observing.length + 1 + sizeof length;
    return log_string(path, length);
  }
  size_t prefix = strcmp(here, "/") == 0 ? 0 : strlen(here);
  if (length > SIZE_MAX - prefix - 1) return false;
  size_t whole = prefix + 1 + length;
  *at = observing.length + 1 + sizeof whole;
  return log_put("s", 1) && log_put(&whole, sizeof whole) &&
         log_put(here, prefix) && log_put("/", 1) && log_put(path, length);
}

/* The length of `text` without the slashes it ends in. */
static size_t unslashed (const char *text, size_t length) {
  while (length > 0 && text[length - 1] == '/') length--;
  return length;
}

/* Whether a name of `path` is "..": where it leads, only its
 * resolution can place. */
static bool climbs (const char *path, size_t length) {
  size_t from = 0;
  for (size_t at = 0; at <= length; at++) {
    if (at == length || path[at] == '/') {
      if (at - from == 2 && path[from] == '.' && path[from + 1] == '.')
        return true;
      from = at + 1;
    }
  }
  return false;
}

/* Whether `path` is `tree` or lies under it, name by name, as
 * `cosmic.fs`'s `within` answers. */
static bool within (const char *path, size_t length, const char *tree,
                    size_t tree_length) {
  size_t base = unslashed(tree, tree_length);
  if (base == 0) return length > 0 && path[0] == '/';
  if (unslashed(path, length) == base && memcmp(path, tree, base) == 0)
    return true;
  return length > base && memcmp(path, tree, base) == 0 && path[base] == '/';
}

/* Whether a record of `path` carries its resolution, as `observe` was
 * told: a relative path, one the working directory could not place,
 * has none. */
static bool resolved_here (const char *path, size_t length) {
  if (length == 0 || path[0] != '/') return false;
  switch (resolving.which) {
    case RESOLVING_ALL:
    return true;
    case RESOLVING_OUTSIDE:
    return climbs(path, length) ||
           !within(path, length, resolving.tree, resolving.length);
    default:
    return false;
  }
}

/* What an absolute `path` resolves to, links and all, as it is read:
 * realpath of it, or, when it is not there (a stat or an open of a
 * missing file is a read too), of its nearest existing ancestor, with
 * the missing names after it as written, "." and ".." included: the
 * first of them is missing, so nothing after it is reached, and the
 * answer is that ancestor's. `link` stops short of a link the path
 * ends in, as lstat and readlink do: the ancestor is sought from the
 * directory its last name is in -- unless that name is "." or "..", or
 * the path ends in "/", which the call follows. Puts the ancestor's
 * realpath in `room` and answers its length, 0 when not even "/"
 * resolves, and sets `*rest` to where the names after it start. */
static size_t resolution (const char *path, size_t length, bool link,
                          char room[PATH_MAX], size_t *rest) {
  size_t end = length;
  if (link && length > 0 && path[length - 1] != '/') {
    size_t name = length;
    while (name > 0 && path[name - 1] != '/') name--;
    size_t size = length - name;
    bool dots = (size == 1 && path[name] == '.') ||
                (size == 2 && path[name] == '.' && path[name + 1] == '.');
    if (!dots) {
      end = unslashed(path, name);
      if (end == 0) end = 1;
    }
  }
  char at[PATH_MAX];
  for (;;) {
    /* A prefix too long for realpath, or holding a NUL, which no path
     * does, resolves no more than a missing one. */
    if (end < sizeof at && memchr(path, '\0', end) == NULL) {
      memcpy(at, path, end);
      at[end] = '\0';
      if (realpath(at, room) != NULL) {
        *rest = end;
        return strlen(room);
      }
    }
    size_t trimmed = unslashed(path, end);
    if (trimmed == 0) return 0;
    size_t name = trimmed;
    while (name > 0 && path[name - 1] != '/') name--;
    end = unslashed(path, name);
    if (end == 0) end = 1;
  }
}

/* How long a resolution is: the ancestor, and each name after it that
 * is not empty, "/" before each -- the ancestor "/" counted as nothing
 * when a name follows it. */
static size_t resolution_length (const char *room, size_t found,
                                 const char *path, size_t rest,
                                 size_t length, size_t *prefix) {
  size_t names = 0;
  size_t from = rest;
  for (size_t at = rest; at <= length; at++) {
    if (at == length || path[at] == '/') {
      if (at > from) names += 1 + (at - from);
      from = at + 1;
    }
  }
  *prefix = (names > 0 && found == 1 && room[0] == '/') ? 0 : found;
  return *prefix + names;
}

/* Writes the resolution `resolution_length` measured into `out`. */
static void resolution_write (char *out, const char *room, size_t prefix,
                              const char *path, size_t rest, size_t length) {
  memcpy(out, room, prefix);
  out += prefix;
  size_t from = rest;
  for (size_t at = rest; at <= length; at++) {
    if (at == length || path[at] == '/') {
      if (at > from) {
        *out++ = '/';
        memcpy(out, path + from, at - from);
        out += at - from;
      }
      from = at + 1;
    }
  }
}

/* Logs what the path logged at `at`, `length` bytes, resolves to now:
 * `n` when this record carries no resolution, and "" when it resolves
 * to nothing.
 * TODO: resolve by the call itself, not beside it (the path an opened
 * descriptor names, once cosmic.sys carries one): another process
 * retargeting a link between the call and its resolution goes unseen. */
static bool log_resolution (enum observed_resolution how, size_t at,
                            size_t length) {
  if (how == RESOLVE_NONE) return true;
  if (!resolved_here(observing.bytes + at, length)) return log_put("n", 1);
  char room[PATH_MAX];
  size_t rest;
  size_t found = resolution(observing.bytes + at, length,
                            how == RESOLVE_LINK, room, &rest);
  if (found == 0) return log_string("", 0);
  size_t prefix;
  size_t whole = resolution_length(room, found, observing.bytes + at, rest,
                                   length, &prefix);
  if (whole > SIZE_MAX - 1 - sizeof whole) return false;
  /* Room first: the path it is read from is in the log, which growing
   * may move. */
  if (!log_room(1 + sizeof whole + whole)) return false;
  if (!log_put("s", 1) || !log_put(&whole, sizeof whole)) return false;
  resolution_write(observing.bytes + observing.length, room, prefix,
                   observing.bytes + at, rest, length);
  observing.length += whole;
  return true;
}

/* Logs a call's argument, and its resolution when it has one. */
static bool log_argument (const struct observed_call *call, const char *text,
                          size_t length) {
  if (call->argument == ARGUMENT_NONE) return true;
  if (text == NULL) {
    return log_put("n", 1) &&
           (call->resolution == RESOLVE_NONE || log_put("n", 1));
  }
  if (call->argument == ARGUMENT_TEXT) return log_string(text, length);
  size_t at;
  if (!log_path(text, length, &at)) return false;
  return log_resolution(call->resolution, at, observing.length - at);
}

/* Ends the record begun at `start`: dropped when it is the same as the
 * last one kept. */
static void log_settle (size_t start) {
  size_t size = observing.length - start;
  if (start - observing.last == size &&
      memcmp(observing.bytes + observing.last, observing.bytes + start, size) ==
          0) {
    observing.length = start;
  } else {
    observing.last = start;
  }
}

/* Keeps the record of `call` asked its first argument and answering the
 * `count` values at the top of the stack; false, having kept nothing,
 * when it cannot. */
static bool log_record (lua_State *L, enum cosmic_observed_call call,
                        int count) {
  size_t start = observing.length;
  unsigned char header[2] = {(unsigned char)call, (unsigned char)count};
  const char *text = NULL;
  size_t length = 0;
  if (lua_type(L, 1) == LUA_TSTRING) text = lua_tolstring(L, 1, &length);
  bool kept = log_put(header, sizeof header) &&
              log_argument(&observed_calls[call], text, length);
  for (int i = count; kept && i >= 1; i--) {
    kept = log_value(L, -i, false);
  }
  if (!kept) {
    observing.length = start;
    return false;
  }
  log_settle(start);
  return true;
}

int cosmic_observed_call (lua_State *L, enum cosmic_observed_call call,
                          lua_CFunction query) {
  int count = query(L);
  if (!log_record(L, call, count)) {
    lua_pop(L, count);
    return cosmic_fail(L, ENOMEM);
  }
  return count;
}

bool cosmic_observed_ask (lua_State *L, enum cosmic_observed_call call,
                          lua_CFunction query) {
  int top = lua_gettop(L);
  int count = query(L);
  bool kept = log_record(L, call, count);
  lua_settop(L, top);
  return kept;
}

bool cosmic_observed_note (enum cosmic_observed_call call, const char *text,
                           size_t length) {
  size_t start = observing.length;
  unsigned char header[2] = {(unsigned char)call, 0};
  if (!log_put(header, sizeof header) ||
      !log_argument(&observed_calls[call], text, length)) {
    observing.length = start;
    return false;
  }
  log_settle(start);
  return true;
}

/* Turns the log on or off; what it holds stays until drained. */
static int observe (lua_State *L) {
  luaL_checktype(L, 1, LUA_TBOOLEAN);
  cosmic_observing = lua_toboolean(L, 1);
  return 0;
}

/* Says which paths a record resolves from here on: nil none, and a
 * directory every absolute one outside it or climbing with "..", which
 * for "" (within which nothing lies) is every one. */
static int resolving_outside (lua_State *L) {
  size_t length = 0;
  const char *tree = luaL_optlstring(L, 1, NULL, &length);
  if (tree == NULL) {
    resolving.which = RESOLVING_NONE;
  } else if (length == 0 || length >= sizeof resolving.tree) {
    resolving.which = RESOLVING_ALL;
  } else {
    memcpy(resolving.tree, tree, length);
    resolving.length = length;
    resolving.which = RESOLVING_OUTSIDE;
  }
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
 * `{call = name, path = argument, resolved = resolution, n = count,
 * ...}`, its answers from 1 to `n`, and `partial = true` when one of
 * them held what no record can. The log is emptied once the list is
 * made: a failure making it keeps every record. */
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
    lua_createtable(L, count, 5);
    lua_pushstring(L, call->name);
    lua_setfield(L, -2, "call");
    if (call->argument != ARGUMENT_NONE) {
      at = push_logged(L, at, &whole);
      lua_setfield(L, -2, "path");
    }
    if (call->resolution != RESOLVE_NONE) {
      at = push_logged(L, at, &whole);
      lua_setfield(L, -2, "resolved");
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
  free(observing.bytes);
  observing.bytes = NULL;
  observing.length = 0;
  observing.room = 0;
  observing.last = 0;
  return 1;
}

/* What `path` resolves to now, as a record's resolution is told (see
 * `resolution`), through a link it ends in unless `link`: "" for a
 * relative path, or one that resolves to nothing. */
static int resolve (lua_State *L) {
  size_t length;
  const char *path = luaL_checklstring(L, 1, &length);
  bool link = lua_toboolean(L, 2);
  char room[PATH_MAX];
  size_t rest;
  size_t found = length > 0 && path[0] == '/'
                     ? resolution(path, length, link, room, &rest)
                     : 0;
  if (found == 0) {
    lua_pushliteral(L, "");
    return 1;
  }
  size_t prefix;
  size_t whole = resolution_length(room, found, path, rest, length, &prefix);
  luaL_Buffer buffer;
  char *out = luaL_buffinitsize(L, &buffer, whole);
  resolution_write(out, room, prefix, path, rest, length);
  luaL_pushresultsize(&buffer, whole);
  return 1;
}

int cosmic_open_observed (lua_State *L) {
  lua_createtable(L, 0, 14);
  lua_pushcfunction(L, observe);
  lua_setfield(L, -2, "observe");
  lua_pushcfunction(L, observed);
  lua_setfield(L, -2, "observed");
  lua_pushcfunction(L, resolving_outside);
  lua_setfield(L, -2, "resolving");
  lua_pushcfunction(L, resolve);
  lua_setfield(L, -2, "resolve");
  /* The calls themselves, past the log: the observer's own questions
   * are none of the test's. */
  static const luaL_Reg calls[] = {
    {"getcwd", cosmic_query_getcwd},
    {"executable", cosmic_query_executable},
    {"lstat", cosmic_query_lstat},
    {"readlink", cosmic_query_readlink},
    {"realpath", cosmic_query_realpath},
    {"stat", cosmic_query_stat},
    {"readdir", cosmic_query_readdir},
    {"getenv", cosmic_query_getenv},
    {"environ", cosmic_query_environ},
    {"spawn", cosmic_spawn_unobserved},
    {NULL, NULL},
  };
  luaL_setfuncs(L, calls, 0);
  return 1;
}
