#include "json.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fail.h"
#include "fault.h"
#include "guard.h"
#include "lauxlib.h"
#include "memory.h"
#include "yyjson.h"

/* The metatable that marks a table as a JSON array, so an empty one
 * encodes as `[]` rather than `{}`. Every array decode builds carries
 * it; objects carry none. */
#define ARRAY_TYPE "cosmic.json.array"

/* The stand-in a caller may ask decode to put where JSON says `null`,
 * and that encodes as `null`: a userdata, so indexing it by mistake
 * raises instead of answering nil. Held in the registry under this
 * name, its metatable under NULL_TYPE. */
#define NULL_KEY "cosmic.json.null.value"
#define NULL_TYPE "cosmic.json.null"

/* How many arrays and objects may nest when the caller names no limit,
 * and the most any caller may name: both walks below recurse once per
 * level, on the C stack. */
#define DEFAULT_DEPTH 64
#define MAX_DEPTH 1000

/* yyjson allocates and frees through these, on the heap the core's own
 * C uses (core/memory.h), so the checked core counts its blocks and can
 * refuse one. The fault point refuses yyjson's allocation alone. An
 * allocation walk cannot: it refuses every allocation after the refused
 * too, so the message that answers yyjson's refusal could never be
 * built. */
static void *json_malloc (void *ctx, size_t size) {
  (void)ctx;
  return COSMIC_FAULT("json_malloc") ? NULL : cosmic_malloc(size);
}

static void *json_realloc (void *ctx, void *block, size_t old_size,
                           size_t size) {
  (void)ctx;
  (void)old_size;
  return cosmic_realloc(block, size);
}

static void json_free (void *ctx, void *block) {
  (void)ctx;
  cosmic_free(block);
}

static const yyjson_alc allocator = {json_malloc, json_realloc, json_free,
  NULL};

static void release_doc (void *doc) { yyjson_doc_free(doc); }

/* The nesting limit at `arg`: DEFAULT_DEPTH when absent, and a raise
 * when outside 1 to MAX_DEPTH. The raise names the option, not the
 * argument: callers pass it in an options table, where a position
 * would point at nothing they wrote. */
static int checked_depth (lua_State *L, int arg) {
  if (lua_isnoneornil(L, arg)) return DEFAULT_DEPTH;
  int exact = 0;
  lua_Integer depth = lua_tointegerx(L, arg, &exact);
  if (!exact || depth < 1 || depth > MAX_DEPTH) {
    luaL_error(L, "json: max_depth must be an integer from 1 to %d", MAX_DEPTH);
  }
  return (int)depth;
}

/* ---- paths ------------------------------------------------------ */

/* Where in a value a failure is, as a path below `$`: `[3].name`. A
 * walk that fails puts its own segment in front at each level it
 * returns through, so the path is whole once the walk is out. `cut`
 * says the outermost segments did not fit. */
struct path {
  char text[200];
  size_t len;
  bool cut;
};

static void prepend_path (struct path *p, const char *segment, size_t n) {
  if (p->cut || n >= sizeof p->text - p->len) {
    p->cut = true;
    return;
  }
  memmove(p->text + n, p->text, p->len);
  memcpy(p->text, segment, n);
  p->len += n;
}

/* `[i]`: an array's index, as Lua counts it, from 1. */
static void prepend_index (struct path *p, lua_Integer i) {
  char segment[32];
  int n = snprintf(segment, sizeof segment, "[%lld]", (long long)i);
  prepend_path(p, segment, (size_t)n);
}

static bool is_word_byte (unsigned char c, bool first) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' ||
         (!first && c >= '0' && c <= '9');
}

/* `.name` for a key that is a word, and `["some key"]` for any other,
 * its unprintable bytes shown as `?` and a long one cut short. */
static void prepend_key (struct path *p, const char *s, size_t n) {
  char segment[48];
  size_t used = 0;
  bool word = n > 0 && n <= 40;
  for (size_t i = 0; word && i < n; i++) {
    word = is_word_byte((unsigned char)s[i], i == 0);
  }
  if (word) {
    segment[used++] = '.';
    memcpy(segment + used, s, n);
    used += n;
  } else {
    segment[used++] = '[';
    segment[used++] = '"';
    for (size_t i = 0; i < n; i++) {
      if (used > sizeof segment - 8) {
        memcpy(segment + used, "...", 3);
        used += 3;
        break;
      }
      unsigned char c = (unsigned char)s[i];
      if (c == '"' || c == '\\') segment[used++] = '\\';
      segment[used++] = c >= 0x20 && c < 0x7f ? (char)c : '?';
    }
    segment[used++] = '"';
    segment[used++] = ']';
  }
  prepend_path(p, segment, used);
}

/* Pushes `p` as `$` and its segments, `$...` in front when the
 * outermost were cut. */
static void push_path (lua_State *L, const struct path *p) {
  lua_pushfstring(L, "$%s", p->cut ? "..." : "");
  lua_pushlstring(L, p->text, p->len);
  lua_concat(L, 2);
}

/* ---- decoding ---------------------------------------------------- */

struct decoding {
  lua_State *L;
  /* The stack slot holding the caller's stand-in for `null`, or 0 when
   * `null` decodes to nil. */
  int null_index;
  int max_depth;
  /* Whether a number no Lua number holds exactly as an integer, or at
   * all, decodes as its text rather than the nearest float. */
  int big_as_string;
  /* Whether an object may hold a key twice, the last member standing. */
  bool duplicate_keys;
  /* Where the value decode refuses is, once it refuses one, and, for a
   * key twice, the second. */
  struct path path;
  yyjson_val *repeated;
};

/* What makes a document that read cleanly one decode refuses. */
enum problem { NO_PROBLEM, REPEATED_KEY, TOO_DEEP };

/* What a member read as `null` holds while its object is built, when
 * `null` decodes to nil and keys are checked: a nil would leave the key
 * out, and a key twice after it unseen. */
static const char null_member = 0;

/* The most members an object may have for its keys to be compared
 * pair by pair, and through a set of them on the C stack, twice as many
 * slots as members. A larger object's keys are looked up in the table
 * as they go in: Lua's string hash is seeded, where the set's is not, so
 * keys chosen to collide make only a small set's search slow. */
#define FEW_MEMBERS 8
#define SET_MEMBERS 64

/* FNV-1a over a key's bytes, for the set of an object's keys below. */
static uint32_t key_hash (const char *s, size_t n) {
  uint32_t h = 2166136261u;
  for (size_t i = 0; i < n; i++) {
    h = (h ^ (unsigned char)s[i]) * 16777619u;
  }
  return h;
}

/* The index of the first member of `obj`, of SET_MEMBERS at most, whose
 * key an earlier member has, or its size when none does, found through
 * a set of its keys. Never inlined: the set would sit in each frame of
 * the recursive walk that calls it, a kilobyte a level. */
__attribute__((noinline)) static size_t repeated_in_set (yyjson_val *obj) {
  size_t count = yyjson_obj_size(obj);
  size_t idx;
  size_t max;
  yyjson_val *key;
  yyjson_val *item;
  yyjson_val *set[2 * SET_MEMBERS];
  size_t slots = 4;
  while (slots < 2 * count) slots *= 2;
  memset(set, 0, slots * sizeof *set);
  yyjson_obj_foreach(obj, idx, max, key, item) {
    const char *s = yyjson_get_str(key);
    size_t n = yyjson_get_len(key);
    size_t at = key_hash(s, n) & (slots - 1);
    while (set[at] != NULL) {
      if (yyjson_get_len(set[at]) == n &&
          memcmp(yyjson_get_str(set[at]), s, n) == 0) {
        return idx;
      }
      at = (at + 1) & (slots - 1);
    }
    set[at] = key;
  }
  return count;
}

/* The index of the first member of `obj`, of SET_MEMBERS at most, whose
 * key an earlier member has, or its size when none does. */
static size_t repeated_member (yyjson_val *obj) {
  size_t count = yyjson_obj_size(obj);
  if (count > FEW_MEMBERS) return repeated_in_set(obj);
  const char *s[FEW_MEMBERS];
  size_t n[FEW_MEMBERS];
  size_t idx;
  size_t max;
  yyjson_val *key;
  yyjson_val *item;
  yyjson_obj_foreach(obj, idx, max, key, item) {
    s[idx] = yyjson_get_str(key);
    n[idx] = yyjson_get_len(key);
    for (size_t k = 0; k < idx; k++) {
      if (n[k] == n[idx] && memcmp(s[k], s[idx], n[idx]) == 0) return idx;
    }
  }
  return count;
}

/* Pushes `val` as a Lua value, or answers what decode refuses in it --
 * an array or object nested `max_depth` deep, a key twice unless
 * `duplicate_keys` -- having pushed nothing, with the path to it in
 * `d->path`. It finds the first such in the order the text holds them:
 * a member's key is checked before its value is read. `depth` counts the
 * arrays and objects open around `val`. A `null` without a stand-in is
 * nil, which leaves a hole in an array and, set into an object, leaves
 * the key out -- after an earlier member of the key too, which
 * `duplicate_keys` lets through: the last value of a key stands. */
static enum problem push_value (struct decoding *d, yyjson_val *val,
                                int depth) {
  lua_State *L = d->L;
  size_t idx;
  size_t max;
  yyjson_val *key;
  yyjson_val *item;
  switch (yyjson_get_type(val)) {
    case YYJSON_TYPE_BOOL:
    lua_pushboolean(L, yyjson_get_bool(val));
    return NO_PROBLEM;
    case YYJSON_TYPE_NUM:
    switch (yyjson_get_subtype(val)) {
      case YYJSON_SUBTYPE_SINT:
      lua_pushinteger(L, (lua_Integer)yyjson_get_sint(val));
      break;
      case YYJSON_SUBTYPE_UINT: {
        /* Past a Lua integer's range, a number is the nearest float,
         * as Lua reads an integer literal that does not fit -- or its
         * digits, when the caller asked to keep them. */
        uint64_t u = yyjson_get_uint(val);
        if (u <= (uint64_t)LUA_MAXINTEGER) {
          lua_pushinteger(L, (lua_Integer)u);
        } else if (d->big_as_string) {
          char digits[24];
          snprintf(digits, sizeof digits, "%llu", (unsigned long long)u);
          lua_pushstring(L, digits);
        } else {
          lua_pushnumber(L, (lua_Number)u);
        }
        break;
      }
      default:
      lua_pushnumber(L, (lua_Number)yyjson_get_real(val));
      break;
    }
    return NO_PROBLEM;
    /* TODO: a big number read this way encodes back as a JSON string.
     * A marker the encoder writes verbatim (Json.number(text), checked
     * to be a JSON number) would let it round-trip as a number. */
    case YYJSON_TYPE_RAW: /* only a big number, and only when asked */
    lua_pushlstring(L, yyjson_get_raw(val), yyjson_get_len(val));
    return NO_PROBLEM;
    case YYJSON_TYPE_STR:
    lua_pushlstring(L, yyjson_get_str(val), yyjson_get_len(val));
    return NO_PROBLEM;
    case YYJSON_TYPE_ARR: {
      if (depth >= d->max_depth) return TOO_DEEP;
      luaL_checkstack(L, 3, "JSON nests too deeply");
      size_t count = yyjson_arr_size(val);
      lua_createtable(L, count > INT32_MAX ? INT32_MAX : (int)count, 0);
      luaL_setmetatable(L, ARRAY_TYPE);
      yyjson_arr_foreach(val, idx, max, item) {
        enum problem found = push_value(d, item, depth + 1);
        if (found != NO_PROBLEM) {
          lua_pop(L, 1);
          prepend_index(&d->path, (lua_Integer)idx + 1);
          return found;
        }
        lua_rawseti(L, -2, (lua_Integer)idx + 1);
      }
      return NO_PROBLEM;
    }
    case YYJSON_TYPE_OBJ: {
      if (depth >= d->max_depth) return TOO_DEEP;
      luaL_checkstack(L, 4, "JSON nests too deeply");
      size_t count = yyjson_obj_size(val);
      /* A small object's keys are compared with each other before it
       * is built, which costs less than a lookup of each in the table;
       * a large one's are looked up as they go in. */
      size_t repeat = count;
      bool check = false;
      if (!d->duplicate_keys) {
        if (count <= SET_MEMBERS) {
          repeat = repeated_member(val);
        } else {
          check = true;
        }
      }
      lua_createtable(L, 0, count > INT32_MAX ? INT32_MAX : (int)count);
      bool held = false;
      yyjson_obj_foreach(val, idx, max, key, item) {
        if (idx == repeat) {
          lua_pop(L, 1);
          d->repeated = key;
          prepend_key(&d->path, yyjson_get_str(key), yyjson_get_len(key));
          return REPEATED_KEY;
        }
        lua_pushlstring(L, yyjson_get_str(key), yyjson_get_len(key));
        /* The key, pushed to be set, is looked up first in the table it
         * goes into: one lookup more for each member. */
        if (check) {
          lua_pushvalue(L, -1);
          if (lua_rawget(L, -3) != LUA_TNIL) {
            lua_pop(L, 3);
            d->repeated = key;
            prepend_key(&d->path, yyjson_get_str(key), yyjson_get_len(key));
            return REPEATED_KEY;
          }
          lua_pop(L, 1);
        }
        enum problem found = push_value(d, item, depth + 1);
        if (found != NO_PROBLEM) {
          lua_pop(L, 2);
          prepend_key(&d->path, yyjson_get_str(key), yyjson_get_len(key));
          return found;
        }
        if (check && lua_isnil(L, -1)) {
          lua_pop(L, 1);
          lua_pushlightuserdata(L, (void *)&null_member);
          held = true;
        }
        lua_rawset(L, -3);
      }
      if (held) {
        yyjson_obj_foreach(val, idx, max, key, item) {
          if (yyjson_is_null(item)) {
            lua_pushlstring(L, yyjson_get_str(key), yyjson_get_len(key));
            lua_pushnil(L);
            lua_rawset(L, -3);
          }
        }
      }
      return NO_PROBLEM;
    }
    default: /* YYJSON_TYPE_NULL: nothing else reads without a flag */
    if (d->null_index == 0) {
      lua_pushnil(L);
    } else {
      lua_pushvalue(L, d->null_index);
    }
    return NO_PROBLEM;
  }
}

/* The index of the first member of `obj` whose key an earlier member
 * has, or its size when none does. A large object's keys go through a
 * Lua table, pushed and popped here, whose string hash is seeded. */
static size_t repeated_key_index (lua_State *L, yyjson_val *obj) {
  size_t count = yyjson_obj_size(obj);
  if (count <= SET_MEMBERS) return repeated_member(obj);
  size_t idx;
  size_t max;
  yyjson_val *key;
  yyjson_val *item;
  luaL_checkstack(L, 3, "JSON nests too deeply");
  lua_createtable(L, 0, count > INT32_MAX ? INT32_MAX : (int)count);
  yyjson_obj_foreach(obj, idx, max, key, item) {
    lua_pushlstring(L, yyjson_get_str(key), yyjson_get_len(key));
    lua_pushvalue(L, -1);
    if (lua_rawget(L, -3) != LUA_TNIL) {
      lua_pop(L, 3);
      return idx;
    }
    lua_pop(L, 1);
    lua_pushboolean(L, 1);
    lua_rawset(L, -3);
  }
  lua_pop(L, 1);
  return count;
}

/* The first problem in `val` that `push_value` would find, in the same
 * order, without building anything: for `check` and `format`. */
static enum problem first_problem (lua_State *L, yyjson_val *val, int depth,
                                   int max_depth, bool duplicate_keys,
                                   struct path *path, yyjson_val **key) {
  size_t idx;
  size_t max;
  yyjson_val *name;
  yyjson_val *item;
  if (!yyjson_is_ctn(val)) return NO_PROBLEM;
  if (depth >= max_depth) return TOO_DEEP;
  if (yyjson_is_arr(val)) {
    yyjson_arr_foreach(val, idx, max, item) {
      enum problem found =
          first_problem(L, item, depth + 1, max_depth, duplicate_keys, path, key);
      if (found != NO_PROBLEM) {
        prepend_index(path, (lua_Integer)idx + 1);
        return found;
      }
    }
    return NO_PROBLEM;
  }
  size_t repeat =
      duplicate_keys ? yyjson_obj_size(val) : repeated_key_index(L, val);
  yyjson_obj_foreach(val, idx, max, name, item) {
    enum problem found = REPEATED_KEY;
    if (idx == repeat) {
      *key = name;
    } else {
      found = first_problem(L, item, depth + 1, max_depth, duplicate_keys, path, key);
    }
    if (found != NO_PROBLEM) {
      prepend_key(path, yyjson_get_str(name), yyjson_get_len(name));
      return found;
    }
  }
  return NO_PROBLEM;
}

/* How a decoded text is laid out in lines, for a failure to say where
 * it is. */
struct layout {
  /* Whether the text is JSON5, which ends a line at U+2028 and U+2029
   * too. */
  bool json5;
  /* 0 when the text is a whole, its own lines counted from 1; else the
   * text is this one line of a larger one, a JSON Lines record, which
   * nothing inside ends. */
  lua_Integer record;
};

/* The line and column of byte `pos` of `text`, both counted from 1,
 * the column in bytes. A line ends at \n, \r, or \r\n taken as one:
 * the line ends JSON's whitespace holds. In JSON5 it ends at U+2028 or
 * U+2029 (E2 80 A8, E2 80 A9) too, which JSON5 reads as line
 * terminators even raw inside a quoted string, as an editor breaks the
 * line there. In RFC 8259 either can appear only inside a string, where
 * it is a character like any other and adds its three bytes to the
 * column. A record is one line whatever it holds. */
static void position (const char *text, size_t pos,
                      const struct layout *layout, size_t *line,
                      size_t *column) {
  *line = 1;
  *column = 1;
  if (layout->record > 0) {
    *line = (size_t)layout->record;
    *column = pos + 1;
    return;
  }
  bool json5 = layout->json5;
  for (size_t i = 0; i < pos; i++) {
    unsigned char c = (unsigned char)text[i];
    if (c == '\r' && i + 1 < pos && text[i + 1] == '\n') i++;
    if (c == 0xe2 && json5 && i + 2 < pos &&
        (unsigned char)text[i + 1] == 0x80 &&
        ((unsigned char)text[i + 2] == 0xa8 ||
         (unsigned char)text[i + 2] == 0xa9)) {
      i += 2;
      c = '\n';
    }
    if (c == '\n' || c == '\r') {
      (*line)++;
      *column = 1;
    } else {
      (*column)++;
    }
  }
}

/* The offset of the first array or object in `text` that opens with
 * `max_depth` others already open around it: the one decode refuses.
 * yyjson keeps no offsets in its document, so this counts brackets in
 * the text, which read cleanly. It skips strings, single-quoted ones
 * too, and comments: `//` and block comments as JSON5 has them, and
 * `#` ones. Outside a string, text that read cleanly holds `//`, a
 * block comment's opening or `#` only as the start of a comment.
 * A line comment ends where yyjson ends it: at \n or \r, and in JSON5
 * (`json5`) at U+2028 or U+2029 too. */
static size_t deep_offset (const char *text, size_t len, int max_depth,
                           bool json5) {
  int open = 0;
  for (size_t i = 0; i < len; i++) {
    char c = text[i];
    if (c == '"' || c == '\'') {
      for (i++; i < len && text[i] != c; i++) {
        if (text[i] == '\\') i++;
      }
    } else if (c == '#' || (c == '/' && i + 1 < len && text[i + 1] == '/')) {
      /* U+2028 and U+2029 are E2 80 A8 and E2 80 A9. */
      while (i < len && text[i] != '\n' && text[i] != '\r' &&
             !(json5 && i + 2 < len && (unsigned char)text[i] == 0xe2 &&
               (unsigned char)text[i + 1] == 0x80 &&
               ((unsigned char)text[i + 2] == 0xa8 ||
                (unsigned char)text[i + 2] == 0xa9))) {
        i++;
      }
    } else if (c == '/' && i + 1 < len && text[i + 1] == '*') {
      for (i += 2; i + 1 < len && !(text[i] == '*' && text[i + 1] == '/'); i++) {
      }
      i++;
    } else if (c == '[' || c == '{') {
      if (open >= max_depth) return i;
      open++;
    } else if (c == ']' || c == '}') {
      open--;
    }
  }
  return len;
}

/* Pushes where `text` stopped being JSON, as a line and a column
 * of bytes, both counted from 1. A record that ran out of memory or holds
 * no value (where comments are read, only a comment) names its line
 * alone. */
static void read_failure (lua_State *L, const char *text, size_t len,
                          const struct layout *layout,
                          const yyjson_read_err *err) {
  if (err->code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) {
    if (layout->record > 0) {
      lua_pushfstring(L, "line %I: out of memory", layout->record);
    } else {
      lua_pushliteral(L, "out of memory");
    }
    return;
  }
  if (len == 0 || err->code == YYJSON_READ_ERROR_EMPTY_CONTENT) {
    if (layout->record > 0) {
      lua_pushfstring(L, "invalid JSON at line %I: the line holds no value",
                      layout->record);
    } else {
      lua_pushliteral(L, "invalid JSON: the text is empty");
    }
    return;
  }
  size_t line, column;
  position(text, err->pos < len ? err->pos : len, layout, &line, &column);
  lua_pushfstring(L, "invalid JSON at line %I, column %I: %s",
                  (lua_Integer)line, (lua_Integer)column, err->msg);
}

/* The value of the four hex digits at `s`, or -1 when they are not. */
static long hex4 (const char *s) {
  long v = 0;
  for (int k = 0; k < 4; k++) {
    char c = s[k];
    int digit = c >= '0' && c <= '9'   ? c - '0'
                : c >= 'a' && c <= 'f' ? c - 'a' + 10
                : c >= 'A' && c <= 'F' ? c - 'A' + 10
                                       : -1;
    if (digit < 0) return -1;
    v = v * 16 + digit;
  }
  return v;
}

/* Writes each lone surrogate escape in `s` -- a \uD800-\uDBFF with no
 * \uDC00-\uDFFF after it, or a \uDC00-\uDFFF alone -- over with
 * \ufffd, the same length, in place; a pair and every other escape
 * are left as they are. How many it wrote. */
static size_t repair_surrogates (char *s, size_t n) {
  size_t count = 0;
  size_t i = 0;
  while (i < n) {
    if (s[i] != '\\' || i + 1 >= n) {
      i++;
      continue;
    }
    if (s[i + 1] != 'u' || i + 6 > n) {
      i += 2;
      continue;
    }
    long unit = hex4(s + i + 2);
    if (unit < 0xd800 || unit > 0xdfff) {
      i += 2;
      continue;
    }
    if (unit <= 0xdbff && i + 12 <= n && s[i + 6] == '\\' && s[i + 7] == 'u') {
      long low = hex4(s + i + 8);
      if (low >= 0xdc00 && low <= 0xdfff) {
        i += 12;
        continue;
      }
    }
    memcpy(s + i + 2, "fffd", 4);
    count++;
    i += 6;
  }
  return count;
}

/* The flag under which yyjson reads `#` line comments:
 * patch/yyjson/01-hash-comments-flag.txt defines it in yyjson.c, on a
 * bit upstream leaves unused.
 * TODO: name YYJSON_READ_ALLOW_HASH_COMMENTS from yyjson.h once
 * `cosmic fix` compiles the core against the patched vendor trees
 * rather than vendor/ itself (build/c/init.tl's include_dirs). */
#define READ_ALLOW_HASH_COMMENTS ((yyjson_read_flag)1 << 14)

/* Pushes that `key`, a member's key in `doc`, read from
 * `text`, repeats a key of its object at `path`. A document read
 * without YYJSON_READ_INSITU holds every string in `str_pool`, a copy
 * of the text unescaped in place, so a key's offset there is its offset
 * in the text: the first byte after its opening quote, or its own first
 * when JSON5 leaves it unquoted. */
static void repeat_failure (lua_State *L, const char *text, size_t len,
                            const struct layout *layout, yyjson_doc *doc,
                            yyjson_val *key, const struct path *path) {
  size_t pos = (size_t)(yyjson_get_str(key) - doc->str_pool);
  if (pos > 0 && pos <= len && (text[pos - 1] == '"' || text[pos - 1] == '\'')) {
    pos--;
  }
  size_t line, column;
  position(text, pos < len ? pos : len, layout, &line, &column);
  lua_pushfstring(L, "duplicate key at line %I, column %I (",
                  (lua_Integer)line, (lua_Integer)column);
  push_path(L, path);
  lua_pushliteral(L, ")");
  lua_concat(L, 3);
}

/* Pushes that the array or object at `path` in `text` nests
 * deeper than `max_depth`. The position is the first bracket in the text
 * that opens that deep, which is that container: the walk that found it
 * visits the document in the order the text holds it. */
static void deep_failure (lua_State *L, const char *text, size_t len,
                          const struct layout *layout, int max_depth,
                          const struct path *path) {
  size_t line, column;
  position(text, deep_offset(text, len, max_depth, layout->json5), layout,
           &line, &column);
  lua_pushfstring(L, "JSON nests deeper than %d levels at line %I, column %I (",
                  max_depth, (lua_Integer)line, (lua_Integer)column);
  push_path(L, path);
  lua_pushliteral(L, ")");
  lua_concat(L, 3);
}

/* What a read of a text is told. */
struct reading {
  /* The text, which [`read_text`] replaces with a copy it repaired when it
   * reads lone surrogates. */
  const char *text;
  size_t len;
  struct layout layout;
  yyjson_read_flag flags;
  bool lone_surrogates;
  bool duplicate_keys;
  int max_depth;
};

/* Reads the options every read takes from the arguments at `at`:
 * `max_depth`, `json5`, `lone_surrogates`, `hash_comments` and
 * `duplicate_keys`, in that order. */
static void read_options (lua_State *L, int at, struct reading *r) {
  r->max_depth = checked_depth(L, at);
  r->layout.json5 = lua_toboolean(L, at + 1);
  r->layout.record = 0;
  r->flags = r->layout.json5 ? YYJSON_READ_JSON5 : YYJSON_READ_NOFLAG;
  r->lone_surrogates = lua_toboolean(L, at + 2);
  if (lua_toboolean(L, at + 3)) r->flags |= READ_ALLOW_HASH_COMMENTS;
  r->duplicate_keys = lua_toboolean(L, at + 4);
}

/* Reads `r->text` into a document, which it sets as `guard`'s resource,
 * and answers it; or NULL, having pushed why it is refused: it is not
 * one JSON value as `r` reads one, or, when `walk` is true, the walk
 * below finds a problem in it -- which a decode, building the value,
 * finds itself. A repaired copy of the text stays on the stack above
 * the guard. */
static yyjson_doc *read_text (lua_State *L, struct reading *r,
                              struct cosmic_guard *guard, bool walk) {
  yyjson_read_err err;
  yyjson_doc *doc =
      yyjson_read_opts((char *)r->text, r->len, r->flags, &allocator, &err);
  if (doc == NULL && r->lone_surrogates && err.msg != NULL &&
      strstr(err.msg, "surrogate") != NULL) {
    /* yyjson refuses a lone surrogate escape whatever it is told, so
     * read a copy with each one written over as \ufffd. The copy is a
     * userdata on the stack, above the guard, and outlives the read. */
    char *copy = lua_newuserdatauv(L, r->len, 0);
    memcpy(copy, r->text, r->len);
    if (repair_surrogates(copy, r->len) > 0) {
      r->text = copy;
      doc = yyjson_read_opts(copy, r->len, r->flags, &allocator, &err);
    }
  }
  if (doc == NULL) {
    read_failure(L, r->text, r->len, &r->layout, &err);
    return NULL;
  }
  guard->resource = doc;
  if (!walk) return doc;
  struct path path;
  memset(&path, 0, sizeof path);
  yyjson_val *key = NULL;
  switch (first_problem(L, yyjson_doc_get_root(doc), 0, r->max_depth,
                        r->duplicate_keys, &path, &key)) {
    case REPEATED_KEY:
    repeat_failure(L, r->text, r->len, &r->layout, doc, key, &path);
    return NULL;
    case TOO_DEEP:
    deep_failure(L, r->text, r->len, &r->layout, r->max_depth, &path);
    return NULL;
    default:
    return doc;
  }
}

/* Answers nil and the message on top of the stack. */
static int refused (lua_State *L) {
  lua_pushnil(L);
  lua_insert(L, -2);
  return 2;
}

/* decode(text, null?, max_depth?, json5?, big_as_string?,
 * lone_surrogates?, record?, hash_comments?, duplicate_keys?): the value
 * `text` holds, and "". nil and a message when it is not one JSON
 * value -- RFC 8259, or JSON5 when `json5` is true, either with `#`
 * line comments when `hash_comments` is -- holds an object with a key
 * twice unless `duplicate_keys`, or nests past
 * `max_depth` (64 by default). JSON `null` is `null` when given, and
 * nil when not. With `big_as_string`, an integer past 64 bits, or a
 * number past a double's range, is its own text. With `record`, the
 * text is that line of a JSON Lines text, and a failure names it. */
static int json_decode (lua_State *L) {
  struct reading r;
  r.text = luaL_checklstring(L, 1, &r.len);
  r.max_depth = checked_depth(L, 3);
  r.layout.json5 = lua_toboolean(L, 4);
  r.layout.record = luaL_optinteger(L, 7, 0);
  luaL_argcheck(L, r.layout.record >= 0, 7, "a record's line is not negative");
  r.flags = r.layout.json5 ? YYJSON_READ_JSON5 : YYJSON_READ_NOFLAG;
  struct decoding d;
  d.L = L;
  d.null_index = lua_isnoneornil(L, 2) ? 0 : 2;
  d.max_depth = r.max_depth;
  d.big_as_string = lua_toboolean(L, 5);
  if (d.big_as_string) r.flags |= YYJSON_READ_BIGNUM_AS_RAW;
  r.lone_surrogates = lua_toboolean(L, 6);
  if (lua_toboolean(L, 8)) r.flags |= READ_ALLOW_HASH_COMMENTS;
  r.duplicate_keys = lua_toboolean(L, 9);
  d.duplicate_keys = r.duplicate_keys;
  memset(&d.path, 0, sizeof d.path);
  d.repeated = NULL;
  lua_settop(L, 9);
  /* Building the value allocates, and an allocation can raise: the
   * guard frees the document then, and on every return. */
  struct cosmic_guard *guard = cosmic_guard_push(L, release_doc);
  yyjson_doc *doc = read_text(L, &r, guard, false);
  if (doc == NULL) return refused(L);
  switch (push_value(&d, yyjson_doc_get_root(doc), 0)) {
    case REPEATED_KEY:
    repeat_failure(L, r.text, r.len, &r.layout, doc, d.repeated, &d.path);
    return refused(L);
    case TOO_DEEP:
    deep_failure(L, r.text, r.len, &r.layout, r.max_depth, &d.path);
    return refused(L);
    default:
    return cosmic_succeeded(L);
  }
}

/* check(text, max_depth?, json5?, lone_surrogates?, hash_comments?,
 * duplicate_keys?, big_as_string?): true and "" when `decode` would read
 * `text` under the same options; else false and the message it would
 * fail with. It builds no value. */
static int json_check (lua_State *L) {
  struct reading r;
  r.text = luaL_checklstring(L, 1, &r.len);
  read_options(L, 2, &r);
  if (lua_toboolean(L, 7)) r.flags |= YYJSON_READ_BIGNUM_AS_RAW;
  lua_settop(L, 7);
  struct cosmic_guard *guard = cosmic_guard_push(L, release_doc);
  if (read_text(L, &r, guard, true) == NULL) {
    lua_pushboolean(L, 0);
    lua_insert(L, -2);
    return 2;
  }
  return cosmic_done(L);
}

/* ---- encoding ---------------------------------------------------- */

struct encoding {
  lua_State *L;
  /* Holds `p`, so a raise anywhere in the walk frees it. */
  struct cosmic_guard *guard;
  char *p;
  size_t len;
  size_t cap;
  /* The stack slot holding the `null` stand-in. */
  int null_index;
  /* Whether to lay the text out over lines, two spaces a level. */
  int pretty;
  int max_depth;
  /* Why the value cannot be encoded, once it cannot. */
  char failure[160];
  /* Where. `out_of_memory` says the failure was not the value's, so no
   * path is told. */
  struct path path;
  int out_of_memory;
};

/* Records why the value cannot be encoded, and answers -1 for the
 * caller to pass up. */
static int refuse (struct encoding *e, const char *why) {
  snprintf(e->failure, sizeof e->failure, "%s", why);
  return -1;
}

static int refuse_memory (struct encoding *e) {
  e->out_of_memory = 1;
  return refuse(e, "out of memory");
}

static int put (struct encoding *e, const char *s, size_t n) {
  /* Nothing to copy, and `e->p` is still NULL before the first byte:
   * memcpy takes no null pointer, even for no bytes. */
  if (n == 0) return 0;
  if (n > e->cap - e->len) {
    size_t room = e->cap == 0 ? 256 : e->cap;
    while (room - e->len < n) {
      if (room > SIZE_MAX / 2) return refuse_memory(e);
      room *= 2;
    }
    char *grown = cosmic_realloc(e->p, room);
    if (grown == NULL) return refuse_memory(e);
    e->p = grown;
    e->guard->resource = grown;
    e->cap = room;
  }
  memcpy(e->p + e->len, s, n);
  e->len += n;
  return 0;
}

#define PUT_LITERAL(e, s) put((e), (s), sizeof(s) - 1)

/* A newline and `depth` levels of indentation, when laying out. */
static int put_break (struct encoding *e, int depth) {
  if (!e->pretty) return 0;
  if (PUT_LITERAL(e, "\n") < 0) return -1;
  for (int i = 0; i < depth; i++) {
    if (PUT_LITERAL(e, "  ") < 0) return -1;
  }
  return 0;
}

/* Whether s[0..n) is UTF-8: no overlong form, no surrogate, nothing
 * past U+10FFFF. */
static int is_utf8 (const unsigned char *s, size_t n) {
  size_t i = 0;
  while (i < n) {
    unsigned char c = s[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    size_t need;
    unsigned char lo = 0x80;
    unsigned char hi = 0xbf;
    if (c >= 0xc2 && c <= 0xdf) {
      need = 1;
    } else if (c >= 0xe0 && c <= 0xef) {
      need = 2;
      if (c == 0xe0) lo = 0xa0;
      if (c == 0xed) hi = 0x9f;
    } else if (c >= 0xf0 && c <= 0xf4) {
      need = 3;
      if (c == 0xf0) lo = 0x90;
      if (c == 0xf4) hi = 0x8f;
    } else {
      return 0;
    }
    if (n - i <= need) return 0;
    if (s[i + 1] < lo || s[i + 1] > hi) return 0;
    for (size_t k = 2; k <= need; k++) {
      if (s[i + k] < 0x80 || s[i + k] > 0xbf) return 0;
    }
    i += need + 1;
  }
  return 1;
}

static const char hex[] = "0123456789abcdef";

static int put_string (struct encoding *e, const char *s, size_t n) {
  if (!is_utf8((const unsigned char *)s, n)) {
    return refuse(e, "cannot encode a string that is not UTF-8");
  }
  if (PUT_LITERAL(e, "\"") < 0) return -1;
  size_t start = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c >= 0x20 && c != '"' && c != '\\') continue;
    if (put(e, s + start, i - start) < 0) return -1;
    start = i + 1;
    char escape[6] = {'\\', 0, 0, 0, 0, 0};
    size_t length = 2;
    switch (c) {
      case '"': escape[1] = '"'; break;
      case '\\': escape[1] = '\\'; break;
      case '\b': escape[1] = 'b'; break;
      case '\f': escape[1] = 'f'; break;
      case '\n': escape[1] = 'n'; break;
      case '\r': escape[1] = 'r'; break;
      case '\t': escape[1] = 't'; break;
      default:
      escape[1] = 'u';
      escape[2] = '0';
      escape[3] = '0';
      escape[4] = hex[c >> 4];
      escape[5] = hex[c & 0xf];
      length = 6;
      break;
    }
    if (put(e, escape, length) < 0) return -1;
  }
  if (put(e, s + start, n - start) < 0) return -1;
  return PUT_LITERAL(e, "\"");
}

static int put_number (struct encoding *e, int idx) {
  lua_State *L = e->L;
  yyjson_val val;
  char text[48];
  if (lua_isinteger(L, idx)) {
    val.tag = YYJSON_TYPE_NUM | YYJSON_SUBTYPE_SINT;
    val.uni.i64 = (int64_t)lua_tointeger(L, idx);
  } else {
    double f = (double)lua_tonumber(L, idx);
    if (!isfinite(f)) {
      return refuse(e, isnan(f) ? "cannot encode NaN"
                                : "cannot encode an infinite number");
    }
    val.tag = YYJSON_TYPE_NUM | YYJSON_SUBTYPE_REAL;
    val.uni.f64 = f;
  }
  char *end = yyjson_write_number(&val, text);
  if (end == NULL) return refuse(e, "cannot encode a number");
  return put(e, text, (size_t)(end - text));
}

static int put_value (struct encoding *e, int idx, int depth);

/* The array at `idx`, `top` elements long, none of them missing. */
static int put_array (struct encoding *e, int idx, lua_Integer top,
                      int depth) {
  lua_State *L = e->L;
  if (PUT_LITERAL(e, "[") < 0) return -1;
  for (lua_Integer i = 1; i <= top; i++) {
    if (i > 1 && PUT_LITERAL(e, ",") < 0) return -1;
    if (put_break(e, depth + 1) < 0) return -1;
    lua_rawgeti(L, idx, i);
    int status = put_value(e, lua_gettop(L), depth + 1);
    lua_pop(L, 1);
    if (status < 0) {
      prepend_index(&e->path, i);
      return -1;
    }
  }
  if (put_break(e, depth) < 0) return -1;
  return PUT_LITERAL(e, "]");
}

/* One member: the key at `key`, the value at `value`. */
static int put_member (struct encoding *e, int key, int value, int first,
                       int depth) {
  lua_State *L = e->L;
  if (!first && PUT_LITERAL(e, ",") < 0) return -1;
  if (put_break(e, depth + 1) < 0) return -1;
  size_t n;
  const char *s = lua_tolstring(L, key, &n);
  if (put_string(e, s, n) < 0) {
    if (!e->out_of_memory) refuse(e, "cannot encode a key that is not UTF-8");
    return -1;
  }
  if (PUT_LITERAL(e, ":") < 0) return -1;
  if (e->pretty && PUT_LITERAL(e, " ") < 0) return -1;
  if (put_value(e, value, depth + 1) < 0) {
    prepend_key(&e->path, s, n);
    return -1;
  }
  return 0;
}

/* One key of an object being sorted: its bytes live in the object,
 * which is on the stack and unchanged for as long as they are read. */
struct sorted_key {
  const char *s;
  size_t n;
};

static int compare_sorted (const void *a, const void *b) {
  const struct sorted_key *x = a;
  const struct sorted_key *y = b;
  size_t n = x->n < y->n ? x->n : y->n;
  int c = memcmp(x->s, y->s, n);
  if (c != 0) return c;
  return (x->n > y->n) - (x->n < y->n);
}

/* The object at `idx`, which has `count` string keys and nothing else,
 * its members in byte order of their keys. */
static int put_object (struct encoding *e, int idx, lua_Integer count,
                       int depth) {
  lua_State *L = e->L;
  if (PUT_LITERAL(e, "{") < 0) return -1;
  struct sorted_key *keys =
      lua_newuserdatauv(L, (size_t)count * sizeof *keys, 0);
  lua_Integer n = 0;
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    lua_pop(L, 1);
    keys[n].s = lua_tolstring(L, -1, &keys[n].n);
    n++;
  }
  qsort(keys, (size_t)n, sizeof *keys, compare_sorted);
  for (lua_Integer i = 0; i < n; i++) {
    /* TODO: each member pushes its key again to find its value, which
     * interns a long key a second time. Collect the members into a
     * Lua table in the first pass and sort that; measure first. */
    lua_pushlstring(L, keys[i].s, keys[i].n);
    lua_pushvalue(L, -1);
    lua_rawget(L, idx);
    int top = lua_gettop(L);
    int status = put_member(e, top - 1, top, i == 0, depth);
    lua_pop(L, 2);
    if (status < 0) {
      lua_pop(L, 1);
      return -1;
    }
  }
  lua_pop(L, 1);
  if (count > 0 && put_break(e, depth) < 0) return -1;
  return PUT_LITERAL(e, "}");
}

/* The lowest index of 1..top the array at `idx` holds nothing at. */
static lua_Integer first_hole (lua_State *L, int idx, lua_Integer top) {
  lua_Integer i = 1;
  for (; i <= top; i++) {
    int absent = lua_rawgeti(L, idx, i) == LUA_TNIL;
    lua_pop(L, 1);
    if (absent) break;
  }
  return i;
}

/* A table is an object when every key is a string, and an array when
 * every key is an integer from 1 up or it carries the array mark; an
 * empty unmarked table is an object. Anything else is refused. */
static int put_table (struct encoding *e, int idx, int depth) {
  lua_State *L = e->L;
  if (depth >= e->max_depth) {
    snprintf(e->failure, sizeof e->failure,
             "cannot encode a value nested deeper than %d levels"
             " (does it contain itself?)",
             e->max_depth);
    return -1;
  }
  luaL_checkstack(L, 6, "JSON nests too deeply");
  int marked = 0;
  if (lua_getmetatable(L, idx)) {
    luaL_getmetatable(L, ARRAY_TYPE);
    marked = lua_rawequal(L, -1, -2);
    lua_pop(L, 2);
  }
  lua_Integer count = 0;
  lua_Integer strings = 0;
  lua_Integer top = 0;
  const char *other = NULL;
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    lua_pop(L, 1);
    count++;
    if (lua_type(L, -1) == LUA_TSTRING) {
      strings++;
    } else if (lua_isinteger(L, -1) && lua_tointeger(L, -1) >= 1) {
      lua_Integer i = lua_tointeger(L, -1);
      if (i > top) top = i;
    } else if (other == NULL) {
      other = lua_isinteger(L, -1)               ? "an integer key below 1"
              : lua_type(L, -1) == LUA_TNUMBER ? "a fractional number key"
                                                 : lua_typename(L, lua_type(L, -1));
    }
  }
  if (other != NULL) {
    snprintf(e->failure, sizeof e->failure, "cannot encode a table with %s%s",
             other[0] == 'a' ? "" : "a ", other);
    if (other[0] != 'a') {
      size_t used = strlen(e->failure);
      snprintf(e->failure + used, sizeof e->failure - used, " key");
    }
    return -1;
  }
  if (strings > 0) {
    if (marked) return refuse(e, "cannot encode an array with a string key");
    if (strings < count) {
      return refuse(e, "cannot encode a table with both string and "
                       "integer keys");
    }
    return put_object(e, idx, count, depth);
  }
  if (count == 0) return marked ? PUT_LITERAL(e, "[]") : PUT_LITERAL(e, "{}");
  if (top > count) {
    snprintf(e->failure, sizeof e->failure,
             "cannot encode an array with a hole (index %lld is nil)",
             (long long)first_hole(L, idx, top));
    return -1;
  }
  return put_array(e, idx, top, depth);
}

static int put_value (struct encoding *e, int idx, int depth) {
  lua_State *L = e->L;
  switch (lua_type(L, idx)) {
    case LUA_TNIL:
    return PUT_LITERAL(e, "null");
    case LUA_TBOOLEAN:
    return lua_toboolean(L, idx) ? PUT_LITERAL(e, "true")
                                 : PUT_LITERAL(e, "false");
    case LUA_TNUMBER:
    return put_number(e, idx);
    case LUA_TSTRING: {
      size_t n;
      const char *s = lua_tolstring(L, idx, &n);
      return put_string(e, s, n);
    }
    case LUA_TTABLE:
    return put_table(e, idx, depth);
    default:
    if (lua_rawequal(L, idx, e->null_index)) return PUT_LITERAL(e, "null");
    snprintf(e->failure, sizeof e->failure, "cannot encode a %s",
             luaL_typename(L, idx));
    return -1;
  }
}

/* encode(value, pretty?, max_depth?): `value` as JSON text, and "". nil and
 * a message when it holds something JSON cannot say. */
static int json_encode (lua_State *L) {
  luaL_checkany(L, 1);
  struct encoding e;
  memset(&e, 0, sizeof e);
  e.L = L;
  e.pretty = lua_toboolean(L, 2);
  e.max_depth = checked_depth(L, 3);
  lua_settop(L, 3);
  lua_getfield(L, LUA_REGISTRYINDEX, NULL_KEY);
  e.null_index = lua_gettop(L);
  e.guard = cosmic_guard_push(L, cosmic_free);
  if (put_value(&e, 1, 0) < 0) {
    lua_pushnil(L);
    if (e.path.len == 0 || e.out_of_memory) {
      lua_pushstring(L, e.failure);
    } else {
      lua_pushfstring(L, "%s at ", e.failure);
      push_path(L, &e.path);
      lua_concat(L, 2);
    }
    return 2;
  }
  lua_pushlstring(L, e.p, e.len);
  return cosmic_succeeded(L);
}

/* ---- text to text ------------------------------------------------ */

/* Whether s[0..n) is a number as RFC 8259 writes one. */
static bool is_json_number (const char *s, size_t n) {
  size_t i = 0;
  if (i < n && s[i] == '-') i++;
  if (i < n && s[i] == '0') {
    i++;
  } else if (i < n && s[i] >= '1' && s[i] <= '9') {
    while (i < n && s[i] >= '0' && s[i] <= '9') i++;
  } else {
    return false;
  }
  if (i < n && s[i] == '.') {
    size_t start = ++i;
    while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    if (i == start) return false;
  }
  if (i < n && (s[i] == 'e' || s[i] == 'E')) {
    i++;
    if (i < n && (s[i] == '+' || s[i] == '-')) i++;
    size_t start = i;
    while (i < n && s[i] >= '0' && s[i] <= '9') i++;
    if (i == start) return false;
  }
  return i == n;
}

/* A number read as its text, `s[0..n)`: as written when RFC 8259 writes
 * it so, and else -- JSON5's hexadecimal, `+1`, `.5` and `5.` -- the
 * shortest text that reads back to the number it names. NaN and the
 * infinities are refused: JSON has no text for them. */
static int put_raw_number (struct encoding *e, const char *s, size_t n) {
  if (is_json_number(s, n)) return put(e, s, n);
  yyjson_read_err err;
  yyjson_doc *doc =
      yyjson_read_opts((char *)s, n, YYJSON_READ_JSON5, &allocator, &err);
  if (doc == NULL) {
    /* The number read once already, as part of the text. */
    return err.code == YYJSON_READ_ERROR_MEMORY_ALLOCATION
               ? refuse_memory(e)
               : refuse(e, "cannot format a number");
  }
  yyjson_val *val = yyjson_doc_get_root(doc);
  double f = yyjson_get_num(val);
  char text[48];
  char *end = NULL;
  if (isfinite(f)) end = yyjson_write_number(val, text);
  yyjson_doc_free(doc);
  if (end == NULL) {
    return refuse(e, isnan(f) ? "cannot format NaN"
                              : "cannot format an infinite number");
  }
  return put(e, text, (size_t)(end - text));
}

/* `f` as ECMAScript's Number.prototype.toString writes it, which RFC
 * 8785 makes a canonical number: the shortest digits that read back to
 * `f`, laid out without an exponent from 1e-6 up to but not including
 * 1e21, and with one, signed, outside it. -0 is "0". `f` is finite. */
static int put_canonical_number (struct encoding *e, double f) {
  if (f == 0) return PUT_LITERAL(e, "0");
  yyjson_val val;
  val.tag = YYJSON_TYPE_NUM | YYJSON_SUBTYPE_REAL;
  val.uni.f64 = f;
  char shortest[48];
  char *end = yyjson_write_number(&val, shortest);
  if (end == NULL) return refuse(e, "cannot format a number");
  /* The digits of `shortest`, whatever its layout, and `point`: the
   * number is 0.<digits> times ten to the `point`. */
  char digits[24];
  int count = 0;
  int point = 0;
  bool seen_point = false;
  const char *c = shortest;
  if (*c == '-') c++;
  for (; c < end && *c != 'e' && *c != 'E'; c++) {
    if (*c == '.') {
      seen_point = true;
    } else if (count == 0 && *c == '0') {
      if (seen_point) point--;
    } else {
      if (count < (int)sizeof digits) digits[count++] = *c;
      if (!seen_point) point++;
    }
  }
  if (c < end) point += atoi(c + 1);
  /* A number other than zero has a digit other than zero. */
  if (count == 0) return refuse(e, "cannot format a number");
  while (count > 1 && digits[count - 1] == '0') count--;
  char out[48];
  int used = 0;
  if (f < 0) out[used++] = '-';
  if (point >= count && point <= 21) {
    memcpy(out + used, digits, (size_t)count);
    used += count;
    for (int i = count; i < point; i++) out[used++] = '0';
  } else if (point > 0 && point <= 21) {
    memcpy(out + used, digits, (size_t)point);
    used += point;
    out[used++] = '.';
    memcpy(out + used, digits + point, (size_t)(count - point));
    used += count - point;
  } else if (point > -6 && point <= 0) {
    out[used++] = '0';
    out[used++] = '.';
    for (int i = point; i < 0; i++) out[used++] = '0';
    memcpy(out + used, digits, (size_t)count);
    used += count;
  } else {
    out[used++] = digits[0];
    if (count > 1) {
      out[used++] = '.';
      memcpy(out + used, digits + 1, (size_t)(count - 1));
      used += count - 1;
    }
    used += snprintf(out + used, sizeof out - (size_t)used, "e%c%d",
                     point - 1 < 0 ? '-' : '+', abs(point - 1));
  }
  return put(e, out, (size_t)used);
}

/* The code point of the UTF-8 sequence at `s`, which is well formed. */
static uint32_t code_point (const unsigned char *s) {
  if (s[0] < 0x80) return s[0];
  if (s[0] < 0xe0) return (uint32_t)(s[0] & 0x1f) << 6 | (s[1] & 0x3f);
  if (s[0] < 0xf0) {
    return (uint32_t)(s[0] & 0x0f) << 12 | (uint32_t)(s[1] & 0x3f) << 6 |
           (s[2] & 0x3f);
  }
  return (uint32_t)(s[0] & 0x07) << 18 | (uint32_t)(s[1] & 0x3f) << 12 |
         (uint32_t)(s[2] & 0x3f) << 6 | (s[3] & 0x3f);
}

/* The order RFC 8785 sorts keys in: by their UTF-16 code units. It is
 * the order of their code points, which is UTF-8's byte order, but for
 * one case: a character past U+FFFF is a surrogate pair, whose first
 * unit (U+D800 to U+DBFF) sorts before U+E000 to U+FFFF. Both keys are
 * well-formed UTF-8. */
static int compare_utf16 (const char *a, size_t an, const char *b, size_t bn) {
  size_t n = an < bn ? an : bn;
  size_t i = 0;
  while (i < n && a[i] == b[i]) i++;
  if (i == n) return (an > bn) - (an < bn);
  /* The keys share every byte before `i`, so the character holding
   * byte `i` starts at the same place in both. */
  while (i > 0 && ((unsigned char)a[i] & 0xc0) == 0x80) i--;
  uint32_t x = code_point((const unsigned char *)a + i);
  uint32_t y = code_point((const unsigned char *)b + i);
  if ((x > 0xffff) != (y > 0xffff)) {
    uint32_t bmp = x > 0xffff ? y : x;
    int pair_first = bmp >= 0xe000 ? -1 : 1;
    return x > 0xffff ? pair_first : -pair_first;
  }
  return (x > y) - (x < y);
}

/* One member of an object being sorted. */
struct member {
  yyjson_val *key;
  yyjson_val *value;
};

static int compare_members (const void *a, const void *b) {
  const struct member *x = a;
  const struct member *y = b;
  return compare_utf16(yyjson_get_str(x->key), yyjson_get_len(x->key),
                       yyjson_get_str(y->key), yyjson_get_len(y->key));
}

static int put_text_value (struct encoding *e, yyjson_val *val, int depth,
                           bool canonical);

/* One member of an object, `key` and `value`. */
static int put_text_member (struct encoding *e, yyjson_val *key,
                            yyjson_val *value, bool first, int depth,
                            bool canonical) {
  if (!first && PUT_LITERAL(e, ",") < 0) return -1;
  if (put_break(e, depth + 1) < 0) return -1;
  if (put_string(e, yyjson_get_str(key), yyjson_get_len(key)) < 0) return -1;
  if (PUT_LITERAL(e, ":") < 0) return -1;
  if (e->pretty && PUT_LITERAL(e, " ") < 0) return -1;
  if (put_text_value(e, value, depth + 1, canonical) < 0) {
    prepend_key(&e->path, yyjson_get_str(key), yyjson_get_len(key));
    return -1;
  }
  return 0;
}

/* The object `obj`: its members as the text holds them, or, when
 * `canonical`, sorted as RFC 8785 sorts them, in a userdata pushed and
 * popped here. */
static int put_text_object (struct encoding *e, yyjson_val *obj, int depth,
                            bool canonical) {
  size_t count = yyjson_obj_size(obj);
  size_t idx;
  size_t max;
  yyjson_val *key;
  yyjson_val *item;
  if (count == 0) return PUT_LITERAL(e, "{}");
  if (PUT_LITERAL(e, "{") < 0) return -1;
  if (!canonical) {
    yyjson_obj_foreach(obj, idx, max, key, item) {
      if (put_text_member(e, key, item, idx == 0, depth, false) < 0) return -1;
    }
  } else {
    luaL_checkstack(e->L, 2, "JSON nests too deeply");
    struct member *members =
        lua_newuserdatauv(e->L, count * sizeof *members, 0);
    yyjson_obj_foreach(obj, idx, max, key, item) {
      members[idx].key = key;
      members[idx].value = item;
    }
    qsort(members, count, sizeof *members, compare_members);
    for (size_t i = 0; i < count; i++) {
      if (put_text_member(e, members[i].key, members[i].value, i == 0, depth,
                          true) < 0) {
        lua_pop(e->L, 1);
        return -1;
      }
    }
    lua_pop(e->L, 1);
  }
  if (put_break(e, depth) < 0) return -1;
  return PUT_LITERAL(e, "}");
}

/* `val`, a value of a document [`first_problem`] found nothing in, so no
 * deeper than the limit it was given. Without `canonical` its numbers
 * were read as their text (YYJSON_READ_NUMBER_AS_RAW); with it, as
 * numbers. */
static int put_text_value (struct encoding *e, yyjson_val *val, int depth,
                           bool canonical) {
  size_t idx;
  size_t max;
  yyjson_val *item;
  switch (yyjson_get_type(val)) {
    case YYJSON_TYPE_NULL:
    return PUT_LITERAL(e, "null");
    case YYJSON_TYPE_BOOL:
    return yyjson_get_bool(val) ? PUT_LITERAL(e, "true")
                                : PUT_LITERAL(e, "false");
    case YYJSON_TYPE_RAW:
    return put_raw_number(e, yyjson_get_raw(val), yyjson_get_len(val));
    case YYJSON_TYPE_NUM: {
      double f = yyjson_get_num(val);
      if (!isfinite(f)) {
        return refuse(e, isnan(f) ? "cannot format NaN"
                                  : "cannot format an infinite number");
      }
      return put_canonical_number(e, f);
    }
    case YYJSON_TYPE_STR:
    return put_string(e, yyjson_get_str(val), yyjson_get_len(val));
    case YYJSON_TYPE_ARR:
    if (yyjson_arr_size(val) == 0) return PUT_LITERAL(e, "[]");
    if (PUT_LITERAL(e, "[") < 0) return -1;
    yyjson_arr_foreach(val, idx, max, item) {
      if (idx > 0 && PUT_LITERAL(e, ",") < 0) return -1;
      if (put_break(e, depth + 1) < 0) return -1;
      if (put_text_value(e, item, depth + 1, canonical) < 0) {
        prepend_index(&e->path, (lua_Integer)idx + 1);
        return -1;
      }
    }
    if (put_break(e, depth) < 0) return -1;
    return PUT_LITERAL(e, "]");
    default: /* YYJSON_TYPE_OBJ */
    return put_text_object(e, val, depth, canonical);
  }
}

/* format(text, max_depth?, json5?, lone_surrogates?, hash_comments?,
 * duplicate_keys?, pretty?, canonical?): the value `text` holds, read as
 * `check` reads it, written again as RFC 8259 text, and "". Its members
 * keep the text's order, a key twice too, and its numbers their text,
 * unless JSON5 wrote one RFC 8259 cannot; with `pretty`, laid out as
 * `encode` lays a value out. With `canonical`, RFC 8785's form instead:
 * members sorted by their keys' UTF-16 code units, numbers as
 * ECMAScript writes the double each reads as, and no space. nil and a
 * message when the text does not read, or holds NaN or an infinity. */
static int json_format (lua_State *L) {
  struct reading r;
  r.text = luaL_checklstring(L, 1, &r.len);
  read_options(L, 2, &r);
  bool canonical = lua_toboolean(L, 8);
  if (!canonical) r.flags |= YYJSON_READ_NUMBER_AS_RAW;
  struct encoding e;
  memset(&e, 0, sizeof e);
  e.L = L;
  e.pretty = !canonical && lua_toboolean(L, 7);
  lua_settop(L, 8);
  struct cosmic_guard *doc_guard = cosmic_guard_push(L, release_doc);
  yyjson_doc *doc = read_text(L, &r, doc_guard, true);
  if (doc == NULL) return refused(L);
  e.guard = cosmic_guard_push(L, cosmic_free);
  if (put_text_value(&e, yyjson_doc_get_root(doc), 0, canonical) < 0) {
    lua_pushnil(L);
    if (e.path.len == 0 || e.out_of_memory) {
      lua_pushstring(L, e.failure);
    } else {
      lua_pushfstring(L, "%s at ", e.failure);
      push_path(L, &e.path);
      lua_concat(L, 2);
    }
    return 2;
  }
  lua_pushlstring(L, e.p, e.len);
  return cosmic_succeeded(L);
}

/* array(t?): marks `t` (a new table when absent) as a JSON array and
 * answers it. Raises when `t` already has another metatable. */
static int json_array (lua_State *L) {
  if (lua_isnoneornil(L, 1)) {
    lua_settop(L, 0);
    lua_newtable(L);
  } else {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_settop(L, 1);
  }
  if (lua_getmetatable(L, 1)) {
    luaL_getmetatable(L, ARRAY_TYPE);
    luaL_argcheck(L, lua_rawequal(L, -1, -2), 1,
                  "the table already has another metatable");
    lua_settop(L, 1);
    return 1;
  }
  luaL_setmetatable(L, ARRAY_TYPE);
  return 1;
}

/* is_array(v): whether `v` is a table carrying the array mark. */
static int json_is_array (lua_State *L) {
  int marked = 0;
  if (lua_type(L, 1) == LUA_TTABLE && lua_getmetatable(L, 1)) {
    luaL_getmetatable(L, ARRAY_TYPE);
    marked = lua_rawequal(L, -1, -2);
  }
  lua_pushboolean(L, marked);
  return 1;
}

static int null_tostring (lua_State *L) {
  lua_pushliteral(L, "null");
  return 1;
}

static const luaL_Reg module[] = {
  {"decode", json_decode},     {"encode", json_encode},
  {"check", json_check},       {"format", json_format},
  {"array", json_array},       {"is_array", json_is_array},
  {NULL, NULL},
};

int cosmic_open_json (lua_State *L) {
  luaL_newmetatable(L, ARRAY_TYPE);
  lua_pop(L, 1);

  lua_newuserdatauv(L, 0, 0);
  luaL_newmetatable(L, NULL_TYPE);
  lua_pushcfunction(L, null_tostring);
  lua_setfield(L, -2, "__tostring");
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable");
  lua_setmetatable(L, -2);
  lua_pushvalue(L, -1);
  lua_setfield(L, LUA_REGISTRYINDEX, NULL_KEY);

  luaL_newlib(L, module);
  lua_insert(L, -2);
  lua_setfield(L, -2, "null");
  lua_pushinteger(L, DEFAULT_DEPTH);
  lua_setfield(L, -2, "default_depth");
  lua_pushinteger(L, MAX_DEPTH);
  lua_setfield(L, -2, "depth_limit");
  return 1;
}
