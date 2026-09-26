#include "json.h"

#include <math.h>
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

/* An array with holes whose highest index is past this and past twice
 * its count of values is refused even with `sparse_as_null`: a table
 * like {[1e9] = 1} is not a billion-element array anyone meant. */
#define SPARSE_SAFE 10
#define SPARSE_RATIO 2

/* yyjson allocates and frees through these, on the heap the core's own
 * C uses (core/memory.h), so the checked core counts its blocks and can
 * refuse one. The fault point refuses yyjson's allocation alone, as an
 * allocation walk cannot: that refuses every one after too, so the
 * message yyjson's refusal answers could never be built. */
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
    luaL_error(L, "max_depth must be an integer from 1 to %d", MAX_DEPTH);
  }
  return (int)depth;
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
};

/* Pushes `val` as a Lua value and answers 1, or answers 0 having pushed
 * nothing when it nests deeper than the limit. `depth` counts the
 * arrays and objects open around it. A `null` without a stand-in pushes
 * nil, which leaves a hole in an array and, set into an object, leaves
 * the key out -- after an earlier duplicate, too, since the last value
 * of a key is the one that stands. */
static int push_value (struct decoding *d, yyjson_val *val, int depth) {
  lua_State *L = d->L;
  size_t idx;
  size_t max;
  yyjson_val *key;
  yyjson_val *item;
  switch (yyjson_get_type(val)) {
    case YYJSON_TYPE_BOOL:
    lua_pushboolean(L, yyjson_get_bool(val));
    return 1;
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
    return 1;
    /* TODO: a big number read this way encodes back as a JSON string.
     * A marker the encoder writes verbatim (Json.number(text), checked
     * to be a JSON number) would let it round-trip as a number. */
    case YYJSON_TYPE_RAW: /* only a big number, and only when asked */
    lua_pushlstring(L, yyjson_get_raw(val), yyjson_get_len(val));
    return 1;
    case YYJSON_TYPE_STR:
    lua_pushlstring(L, yyjson_get_str(val), yyjson_get_len(val));
    return 1;
    case YYJSON_TYPE_ARR: {
      if (depth >= d->max_depth) return 0;
      luaL_checkstack(L, 3, "JSON nests too deeply");
      size_t count = yyjson_arr_size(val);
      lua_createtable(L, count > INT32_MAX ? INT32_MAX : (int)count, 0);
      luaL_setmetatable(L, ARRAY_TYPE);
      yyjson_arr_foreach(val, idx, max, item) {
        if (!push_value(d, item, depth + 1)) {
          lua_pop(L, 1);
          return 0;
        }
        lua_rawseti(L, -2, (lua_Integer)idx + 1);
      }
      return 1;
    }
    case YYJSON_TYPE_OBJ: {
      if (depth >= d->max_depth) return 0;
      luaL_checkstack(L, 4, "JSON nests too deeply");
      size_t count = yyjson_obj_size(val);
      lua_createtable(L, 0, count > INT32_MAX ? INT32_MAX : (int)count);
      yyjson_obj_foreach(val, idx, max, key, item) {
        lua_pushlstring(L, yyjson_get_str(key), yyjson_get_len(key));
        if (!push_value(d, item, depth + 1)) {
          lua_pop(L, 2);
          return 0;
        }
        lua_rawset(L, -3);
      }
      return 1;
    }
    default: /* YYJSON_TYPE_NULL: nothing else reads without a flag */
    if (d->null_index == 0) {
      lua_pushnil(L);
    } else {
      lua_pushvalue(L, d->null_index);
    }
    return 1;
  }
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
 * the line ends JSON's whitespace holds. In JSON5, it ends at U+2028
 * or U+2029 (E2 80 A8, E2 80 A9) too, as JSON5 reads each as a line
 * terminator -- inside a quoted string as well, where JSON5 takes one
 * raw, as an editor breaks the line there; RFC 8259 has either only
 * inside a string, where it is a character like any other and adds
 * its three bytes to the column. A record is one line whatever it
 * holds. */
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
 * the text, which read cleanly, skipping strings -- single-quoted ones
 * too, and comments, as JSON5 has them, and `#` ones. Outside a string
 * a text that read cleanly holds `//`, a block comment's opening or `#`
 * only as a comment.
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

/* nil and where `text` stopped being JSON, as a line and a column of
 * bytes, both counted from 1; a record's line alone when it ran out
 * of memory or holds no value (where comments are read, only a
 * comment). */
static int read_failure (lua_State *L, const char *text, size_t len,
                         const struct layout *layout,
                         const yyjson_read_err *err) {
  lua_pushnil(L);
  if (err->code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) {
    if (layout->record > 0) {
      lua_pushfstring(L, "line %I: out of memory", layout->record);
    } else {
      lua_pushliteral(L, "out of memory");
    }
    return 2;
  }
  if (len == 0 || err->code == YYJSON_READ_ERROR_EMPTY_CONTENT) {
    if (layout->record > 0) {
      lua_pushfstring(L, "invalid JSON at line %I: the line holds no value",
                      layout->record);
    } else {
      lua_pushliteral(L, "invalid JSON: the text is empty");
    }
    return 2;
  }
  size_t line, column;
  position(text, err->pos < len ? err->pos : len, layout, &line, &column);
  lua_pushfstring(L, "invalid JSON at line %I, column %I: %s",
                  (lua_Integer)line, (lua_Integer)column, err->msg);
  return 2;
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

/* decode(text, null?, max_depth?, json5?, big_as_string?,
 * lone_surrogates?, record?, hash_comments?): the value
 * `text` holds, and "". nil and a message when it is not one JSON
 * value -- RFC 8259, or JSON5 when `json5` is true, either with `#`
 * line comments when `hash_comments` is -- or nests past
 * `max_depth` (64 by default). JSON `null` is `null` when given, and
 * nil when not. With `big_as_string`, an integer past 64 bits, or a
 * number past a double's range, is its own text. With `record`, the
 * text is that line of a JSON Lines text, and a failure names it. */
static int json_decode (lua_State *L) {
  size_t len;
  const char *text = luaL_checklstring(L, 1, &len);
  struct decoding d;
  d.L = L;
  d.null_index = lua_isnoneornil(L, 2) ? 0 : 2;
  d.max_depth = checked_depth(L, 3);
  struct layout layout;
  layout.json5 = lua_toboolean(L, 4);
  layout.record = luaL_optinteger(L, 7, 0);
  luaL_argcheck(L, layout.record >= 0, 7, "a record's line is not negative");
  yyjson_read_flag flags =
      layout.json5 ? YYJSON_READ_JSON5 : YYJSON_READ_NOFLAG;
  d.big_as_string = lua_toboolean(L, 5);
  if (d.big_as_string) flags |= YYJSON_READ_BIGNUM_AS_RAW;
  int lone_surrogates = lua_toboolean(L, 6);
  if (lua_toboolean(L, 8)) flags |= READ_ALLOW_HASH_COMMENTS;
  lua_settop(L, 8);
  /* Building the value allocates, and an allocation can raise: the
   * guard frees the document then, and on every return. */
  struct cosmic_guard *guard = cosmic_guard_push(L, release_doc);
  yyjson_read_err err;
  yyjson_doc *doc =
      yyjson_read_opts((char *)text, len, flags, &allocator, &err);
  if (doc == NULL && lone_surrogates && err.msg != NULL &&
      strstr(err.msg, "surrogate") != NULL) {
    /* yyjson refuses a lone surrogate escape whatever it is told, so
     * read a copy with each one written over as \ufffd. The copy is a
     * userdata on the stack, above the guard, and outlives the read. */
    char *copy = lua_newuserdatauv(L, len, 0);
    memcpy(copy, text, len);
    if (repair_surrogates(copy, len) > 0) {
      text = copy;
      doc = yyjson_read_opts(copy, len, flags, &allocator, &err);
    }
  }
  if (doc == NULL) return read_failure(L, text, len, &layout, &err);
  guard->resource = doc;
  if (!push_value(&d, yyjson_doc_get_root(doc), 0)) {
    lua_pushnil(L);
    size_t line, column;
    position(text, deep_offset(text, len, d.max_depth, layout.json5), &layout, &line,
             &column);
    lua_pushfstring(L, "JSON nests deeper than %d levels at line %I, column %I",
                    d.max_depth, (lua_Integer)line, (lua_Integer)column);
    return 2;
  }
  return cosmic_succeeded(L);
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
  /* One level's indentation, and whether to lay the text out at all. */
  const char *indent;
  size_t indent_len;
  int pretty;
  int sorted;
  int nan_as_null;
  int sparse_as_null;
  /* Write every character past ASCII as a \u escape. */
  int ascii;
  int max_depth;
  /* Why the value cannot be encoded, once it cannot. */
  char failure[160];
  /* Where, as a path below `$`: `[3].name`. Each level the failure
   * returns through puts its own segment in front, so the path is
   * whole once the walk is out. `path_cut` says the outermost segments
   * did not fit; `out_of_memory` that the failure was not the value's,
   * so no path is told. */
  char path[200];
  size_t path_len;
  int path_cut;
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

static void prepend_path (struct encoding *e, const char *segment, size_t n) {
  if (e->path_cut || n >= sizeof e->path - e->path_len) {
    e->path_cut = 1;
    return;
  }
  memmove(e->path + n, e->path, e->path_len);
  memcpy(e->path, segment, n);
  e->path_len += n;
}

/* `[i]`: an array's index, as Lua counts it, from 1. */
static void prepend_index (struct encoding *e, lua_Integer i) {
  char segment[32];
  int n = snprintf(segment, sizeof segment, "[%lld]", (long long)i);
  prepend_path(e, segment, (size_t)n);
}

static int is_word_byte (unsigned char c, int first) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' ||
         (!first && c >= '0' && c <= '9');
}

/* `.name` for a key that is a word, and `["some key"]` for any other,
 * its unprintable bytes shown as `?` and a long one cut short. */
static void prepend_key (struct encoding *e, const char *s, size_t n) {
  char segment[48];
  size_t used = 0;
  int word = n > 0 && n <= 40;
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
  prepend_path(e, segment, used);
}

static int put (struct encoding *e, const char *s, size_t n) {
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
    if (put(e, e->indent, e->indent_len) < 0) return -1;
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

/* `cp` as \uXXXX, or as a surrogate pair of them past U+FFFF. */
static int put_unicode_escape (struct encoding *e, uint32_t cp) {
  char out[12];
  size_t length = 0;
  uint32_t units[2];
  size_t count = 1;
  units[0] = cp;
  if (cp > 0xffff) {
    cp -= 0x10000;
    units[0] = 0xd800 | (cp >> 10);
    units[1] = 0xdc00 | (cp & 0x3ff);
    count = 2;
  }
  for (size_t u = 0; u < count; u++) {
    out[length++] = '\\';
    out[length++] = 'u';
    out[length++] = hex[(units[u] >> 12) & 0xf];
    out[length++] = hex[(units[u] >> 8) & 0xf];
    out[length++] = hex[(units[u] >> 4) & 0xf];
    out[length++] = hex[units[u] & 0xf];
  }
  return put(e, out, length);
}

static int put_string (struct encoding *e, const char *s, size_t n) {
  if (!is_utf8((const unsigned char *)s, n)) {
    return refuse(e, "cannot encode a string that is not UTF-8");
  }
  if (PUT_LITERAL(e, "\"") < 0) return -1;
  size_t start = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c >= 0x80 && e->ascii) {
      if (put(e, s + start, i - start) < 0) return -1;
      /* The string is valid UTF-8, so the lead byte says how many
       * continuation bytes follow, and they are there. */
      size_t extra = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : 1;
      uint32_t cp = c & (0x3f >> extra);
      for (size_t k = 1; k <= extra; k++) {
        cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3f);
      }
      if (put_unicode_escape(e, cp) < 0) return -1;
      i += extra;
      start = i + 1;
      continue;
    }
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
      if (e->nan_as_null) return PUT_LITERAL(e, "null");
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

/* The array at `idx`, `top` elements long, holes written as `null`. */
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
      prepend_index(e, i);
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
    prepend_key(e, s, n);
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
 * its members in byte order of their keys when sorting. */
static int put_object (struct encoding *e, int idx, lua_Integer count,
                       int depth) {
  lua_State *L = e->L;
  if (PUT_LITERAL(e, "{") < 0) return -1;
  if (!e->sorted) {
    int first = 1;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0) {
      int top = lua_gettop(L);
      if (put_member(e, top - 1, top, first, depth) < 0) {
        lua_pop(L, 2);
        return -1;
      }
      first = 0;
      lua_pop(L, 1);
    }
  } else {
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
  }
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
    if (!e->sparse_as_null) {
      snprintf(e->failure, sizeof e->failure,
               "cannot encode an array with a hole (index %lld is nil)",
               (long long)first_hole(L, idx, top));
      return -1;
    }
    if (top > SPARSE_SAFE && top / SPARSE_RATIO > count) {
      snprintf(e->failure, sizeof e->failure,
               "cannot encode an array this sparse: its highest index is"
               " %lld, and only %lld of its slots hold a value",
               (long long)top, (long long)count);
      return -1;
    }
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

/* Whether `s` is only JSON's own whitespace, as an indent must be. */
static int is_blank (const char *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (s[i] != ' ' && s[i] != '\t') return 0;
  }
  return 1;
}

/* encode(value, pretty?, indent?, sorted?, max_depth?, nan_as_null?,
 * sparse_as_null?, ascii?): `value` as JSON text, and "". nil and a message
 * when it holds something JSON cannot say. */
static int json_encode (lua_State *L) {
  luaL_checkany(L, 1);
  struct encoding e;
  memset(&e, 0, sizeof e);
  e.L = L;
  e.pretty = lua_toboolean(L, 2);
  e.indent = luaL_optlstring(L, 3, "  ", &e.indent_len);
  if (!is_blank(e.indent, e.indent_len)) {
    return luaL_error(L, "indent must be spaces and tabs");
  }
  e.sorted = lua_isnoneornil(L, 4) ? 1 : lua_toboolean(L, 4);
  e.max_depth = checked_depth(L, 5);
  e.nan_as_null = lua_toboolean(L, 6);
  e.sparse_as_null = lua_toboolean(L, 7);
  e.ascii = lua_toboolean(L, 8);
  lua_settop(L, 8);
  lua_getfield(L, LUA_REGISTRYINDEX, NULL_KEY);
  e.null_index = lua_gettop(L);
  e.guard = cosmic_guard_push(L, cosmic_free);
  if (put_value(&e, 1, 0) < 0) {
    lua_pushnil(L);
    if (e.path_len == 0 || e.out_of_memory) {
      lua_pushstring(L, e.failure);
    } else {
      e.path[e.path_len] = '\0';
      lua_pushfstring(L, "%s at $%s%s", e.failure, e.path_cut ? "..." : "",
                      e.path);
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
