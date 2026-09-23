#include "json.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
 * refuse one. */
static void *json_malloc (void *ctx, size_t size) {
  (void)ctx;
  return cosmic_malloc(size);
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
         * as Lua reads an integer literal that does not fit. */
        uint64_t u = yyjson_get_uint(val);
        if (u <= (uint64_t)LUA_MAXINTEGER) {
          lua_pushinteger(L, (lua_Integer)u);
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

/* nil and where `text` stopped being JSON, as a line and a column of
 * bytes, both counted from 1. */
static int read_failure (lua_State *L, const char *text, size_t len,
                         const yyjson_read_err *err) {
  lua_pushnil(L);
  if (err->code == YYJSON_READ_ERROR_MEMORY_ALLOCATION) {
    lua_pushliteral(L, "out of memory");
    return 2;
  }
  if (len == 0 || err->code == YYJSON_READ_ERROR_EMPTY_CONTENT) {
    lua_pushliteral(L, "invalid JSON: the text is empty");
    return 2;
  }
  size_t pos = err->pos < len ? err->pos : len;
  size_t line = 1;
  size_t column = 1;
  for (size_t i = 0; i < pos; i++) {
    if (text[i] == '\n') {
      line++;
      column = 1;
    } else {
      column++;
    }
  }
  lua_pushfstring(L, "invalid JSON at line %I, column %I: %s",
                  (lua_Integer)line, (lua_Integer)column, err->msg);
  return 2;
}

/* decode(text, null?, max_depth?, json5?): the value `text` holds, and
 * "". nil and a message when it is not one JSON value -- RFC 8259, or
 * JSON5 when `json5` is true -- or nests past `max_depth` (64 by
 * default). JSON `null` is `null` when given, and nil when not. */
static int json_decode (lua_State *L) {
  size_t len;
  const char *text = luaL_checklstring(L, 1, &len);
  struct decoding d;
  d.L = L;
  d.null_index = lua_isnoneornil(L, 2) ? 0 : 2;
  d.max_depth = checked_depth(L, 3);
  yyjson_read_flag flags = lua_toboolean(L, 4) ? YYJSON_READ_JSON5
                                               : YYJSON_READ_NOFLAG;
  lua_settop(L, 4);
  /* Building the value allocates, and an allocation can raise: the
   * guard frees the document then, and on every return. */
  struct cosmic_guard *guard = cosmic_guard_push(L, release_doc);
  yyjson_read_err err;
  yyjson_doc *doc =
      yyjson_read_opts((char *)text, len, flags, &allocator, &err);
  if (doc == NULL) return read_failure(L, text, len, &err);
  guard->resource = doc;
  if (!push_value(&d, yyjson_doc_get_root(doc), 0)) {
    lua_pushnil(L);
    lua_pushfstring(L, "JSON nests deeper than %d levels", d.max_depth);
    return 2;
  }
  lua_pushliteral(L, "");
  return 2;
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
  int max_depth;
  /* Why the value cannot be encoded, once it cannot. */
  char failure[160];
};

/* Records why the value cannot be encoded, and answers -1 for the
 * caller to pass up. */
static int refuse (struct encoding *e, const char *why) {
  snprintf(e->failure, sizeof e->failure, "%s", why);
  return -1;
}

static int put (struct encoding *e, const char *s, size_t n) {
  if (n > e->cap - e->len) {
    size_t room = e->cap == 0 ? 256 : e->cap;
    while (room - e->len < n) {
      if (room > SIZE_MAX / 2) return refuse(e, "out of memory");
      room *= 2;
    }
    char *grown = cosmic_realloc(e->p, room);
    if (grown == NULL) return refuse(e, "out of memory");
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

static int put_string (struct encoding *e, const char *s, size_t n) {
  if (!is_utf8((const unsigned char *)s, n)) {
    return refuse(e, "cannot encode a string that is not UTF-8");
  }
  static const char hex[] = "0123456789abcdef";
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
    if (status < 0) return -1;
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
  if (put_string(e, s, n) < 0) return -1;
  if (PUT_LITERAL(e, ":") < 0) return -1;
  if (e->pretty && PUT_LITERAL(e, " ") < 0) return -1;
  return put_value(e, value, depth + 1);
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
               "cannot encode an array with a hole at index %lld",
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
 * sparse_as_null?): `value` as JSON text, and "". nil and a message
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
  lua_settop(L, 7);
  lua_getfield(L, LUA_REGISTRYINDEX, NULL_KEY);
  e.null_index = lua_gettop(L);
  e.guard = cosmic_guard_push(L, cosmic_free);
  if (put_value(&e, 1, 0) < 0) {
    lua_pushnil(L);
    lua_pushstring(L, e.failure);
    return 2;
  }
  lua_pushlstring(L, e.p, e.len);
  lua_pushliteral(L, "");
  return 2;
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
  return 1;
}
