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

/* The mark of an array that may have holes, which encode writes as
 * `null`; it is set only by `with_holes`, never by decode. */
#define HOLES_TYPE "cosmic.json.array_with_holes"

/* The stand-in a caller may ask decode to put where JSON says `null`,
 * and that encodes as `null`: a userdata, so indexing it by mistake
 * raises instead of returning nil. Held in the registry under this
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
 * too, so the message that reports yyjson's refusal could never be
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

/* Where in a value a failure is, as a JSON Pointer (RFC 6901): `/3/name`,
 * an array's index counted from 0. A walk that fails puts its own
 * segment in front at each level it returns through, so the pointer is
 * whole once the walk is out. `cut` says the outermost segments did not
 * fit. */
struct path {
  char text[200];
  size_t len;
  bool cut;
};

/* Makes room for `n` bytes in front of `p`, and returns where they go;
 * NULL, the path cut, when they do not fit. */
static char *path_room (struct path *p, size_t n) {
  if (p->cut || n >= sizeof p->text - p->len) {
    p->cut = true;
    return NULL;
  }
  memmove(p->text + n, p->text, p->len);
  p->len += n;
  return p->text;
}

/* `/i`: an array's index, counted from 0. */
static void prepend_index (struct path *p, size_t i) {
  char segment[32];
  int n = snprintf(segment, sizeof segment, "/%zu", i);
  char *at = path_room(p, (size_t)n);
  if (at != NULL) memcpy(at, segment, (size_t)n);
}

/* The most bytes of a key a path keeps when the key alone does not fit:
 * its start, then `...`, the path cut. */
#define KEPT_KEY 40

/* `/key`, with `~` written `~0` and `/` written `~1`. A key too long
 * for the path even alone, the innermost, keeps its first KEPT_KEY
 * bytes or fewer, ending on a whole escape and a whole UTF-8 character,
 * and `...`. */
static void prepend_key (struct path *p, const char *s, size_t n) {
  size_t escapes = 0;
  for (size_t i = 0; i < n; i++) escapes += s[i] == '~' || s[i] == '/';
  if (p->len == 0 && !p->cut && 1 + n + escapes >= sizeof p->text) {
    size_t used = 0;
    p->text[used++] = '/';
    for (size_t i = 0; i < n && used < 1 + KEPT_KEY; i++) {
      unsigned char c = (unsigned char)s[i];
      if (c == '~' || c == '/') {
        if (used + 2 > 1 + KEPT_KEY) break;
        p->text[used++] = '~';
        p->text[used++] = c == '~' ? '0' : '1';
      } else if (c >= 0x80 && (c & 0xc0) == 0xc0) {
        /* A lead byte: the character fits whole, or not at all. */
        size_t width = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : 2;
        if (i + width > n || used + width > 1 + KEPT_KEY) break;
        memcpy(p->text + used, s + i, width);
        used += width;
        i += width - 1;
      } else {
        p->text[used++] = (char)c;
      }
    }
    memcpy(p->text + used, "...", 3);
    p->len = used + 3;
    p->cut = true;
    return;
  }
  char *at = path_room(p, 1 + n + escapes);
  if (at == NULL) return;
  *at++ = '/';
  for (size_t i = 0; i < n; i++) {
    if (s[i] == '~' || s[i] == '/') {
      *at++ = '~';
      *at++ = s[i] == '~' ? '0' : '1';
    } else {
      *at++ = s[i];
    }
  }
}

/* Pushes `p` for a message, a JSON string as RFC 6901 writes a pointer
 * in JSON: `pointer "/users/2/name"`, or `pointer ending "..."` when the
 * outermost segments were cut. */
static void push_path (lua_State *L, const struct path *p) {
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_addstring(&b, p->cut ? "pointer ending \"" : "pointer \"");
  for (size_t i = 0; i < p->len; i++) {
    unsigned char c = (unsigned char)p->text[i];
    if (c == '"' || c == '\\') {
      luaL_addchar(&b, '\\');
      luaL_addchar(&b, (char)c);
    } else if (c < 0x20 || c == 0x7f) {
      char escape[8];
      snprintf(escape, sizeof escape, "\\u%04x", c);
      luaL_addstring(&b, escape);
    } else {
      luaL_addchar(&b, (char)c);
    }
  }
  luaL_addchar(&b, '"');
  luaL_pushresult(&b);
}

/* ---- decoding ---------------------------------------------------- */

struct decoding {
  lua_State *L;
  /* The stack slot holding the caller's stand-in for `null`, or 0 when
   * `null` decodes to nil. */
  int null_index;
  /* The stack slot holding the array metatable, which every array the
   * value holds is given. */
  int array_index;
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
  /* No caller passes NULL, but yyjson's iteration reads a NULL object as
   * empty only by arithmetic on a null pointer. */
  if (obj == NULL) return 0;
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

/* Pushes `val` as a Lua value, or returns what decode refuses in it --
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
      lua_pushvalue(L, d->array_index);
      lua_setmetatable(L, -2);
      yyjson_arr_foreach(val, idx, max, item) {
        enum problem found = push_value(d, item, depth + 1);
        if (found != NO_PROBLEM) {
          lua_pop(L, 1);
          prepend_index(&d->path, idx);
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

/* The member of `obj` whose key is s[0..n), the last of them when the
 * key is there twice (which only `duplicate_keys` lets through, the last
 * standing as decode builds it), or NULL. */
static yyjson_val *member_named (yyjson_val *obj, const char *s, size_t n) {
  size_t idx;
  size_t max;
  yyjson_val *key;
  yyjson_val *item;
  yyjson_val *found = NULL;
  yyjson_obj_foreach(obj, idx, max, key, item) {
    if (yyjson_get_len(key) == n && memcmp(yyjson_get_str(key), s, n) == 0) {
      found = item;
    }
  }
  return found;
}

/* Pushes the part of the container `val` that the selection at stack
 * slot `node` names (Selection in cosmic/internal/json.d.tl): in an
 * object, the members its `names` holds; in an array, the elements at
 * its `positions`, from 1. Each is the whole value when its own
 * selection is `whole`, else the part of it that selection names. A
 * step `val` does not hold, or one into a value that is no container,
 * is left out. An array keeps each element at its position, so it is
 * marked as one that may have holes. The whole text was checked for
 * depth and repeated keys before, so this refuses nothing. */
static void push_only (struct decoding *d, yyjson_val *val, int node) {
  lua_State *L = d->L;
  luaL_checkstack(L, 6, "JSON nests too deeply");
  bool object = yyjson_is_obj(val);
  lua_newtable(L);
  if (!object) luaL_setmetatable(L, HOLES_TYPE);
  int out = lua_gettop(L);
  lua_getfield(L, node, object ? "names" : "positions");
  int steps = lua_gettop(L);
  if (!lua_istable(L, steps)) luaL_error(L, "json: a selection without its steps");
  lua_pushnil(L);
  while (lua_next(L, steps) != 0) {
    yyjson_val *item = NULL;
    if (object && lua_type(L, -2) == LUA_TSTRING) {
      size_t n;
      const char *s = lua_tolstring(L, -2, &n);
      item = member_named(val, s, n);
    } else if (!object && lua_isinteger(L, -2)) {
      lua_Integer position = lua_tointeger(L, -2);
      if (position >= 1 && (lua_Unsigned)position <= yyjson_arr_size(val)) {
        item = yyjson_arr_get(val, (size_t)(position - 1));
      }
    }
    if (item != NULL && lua_istable(L, -1)) {
      int child = lua_gettop(L);
      lua_getfield(L, child, "whole");
      bool whole = lua_toboolean(L, -1);
      lua_pop(L, 1);
      if (whole) {
        lua_pushvalue(L, child - 1);
        /* read_text already walked the whole document under the same
         * max_depth and duplicate-key rule, so push_value finds no
         * problem, and its depth can start again at 0. */
        (void)push_value(d, item, 0);
        lua_rawset(L, out);
      } else if (yyjson_is_ctn(item)) {
        lua_pushvalue(L, child - 1);
        push_only(d, item, child);
        lua_rawset(L, out);
      }
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
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

/* The first problem in `val` that [`push_value`] would find, in the same
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
        prepend_index(path, idx);
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
  /* Where the text's first byte is in a larger one, for a text that is
   * a part of it: 1 and 1 for a whole. */
  lua_Integer line;
  lua_Integer column;
  /* The JSON Pointer of the value the text is in the larger one, NULL
   * for a whole: a pointer in a message is put under it. */
  const char *prefix;
};

/* Pushes the JSON Pointer s[0..n), whose segments are written as a
 * pointer writes them, for a message as [`push_path`] pushes a path: whole
 * when it fits a path, else its innermost segments that fit, and the
 * innermost alone shortened when even it does not, as [`prepend_key`]
 * shortens a key -- the rule a pointer cosmic.json writes in Teal is
 * shortened by too. */
static void push_pointer_text (lua_State *L, const char *s, size_t n) {
  struct path p;
  memset(&p, 0, sizeof p);
  size_t end = n;
  while (end > 0 && !p.cut) {
    size_t start = end;
    while (start > 0 && s[start - 1] != '/') start--;
    size_t slash = start > 0 ? start - 1 : 0;
    size_t width = end - slash;
    if (p.len == 0 && width >= sizeof p.text) {
      size_t used = 0;
      p.text[used++] = '/';
      for (size_t i = slash + 1; i < end && used < 1 + KEPT_KEY;) {
        unsigned char c = (unsigned char)s[i];
        size_t step = c == '~' ? 2 : c < 0x80 ? 1 : c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : 2;
        if (i + step > end || used + step > 1 + KEPT_KEY) break;
        memcpy(p.text + used, s + i, step);
        used += step;
        i += step;
      }
      memcpy(p.text + used, "...", 3);
      p.len = used + 3;
      p.cut = true;
      break;
    }
    char *at = path_room(&p, width);
    if (at == NULL) break;
    memcpy(at, s + slash, width);
    end = slash;
  }
  push_path(L, &p);
}

/* Pushes `p` as [`push_path`] does, under the layout's prefix, a JSON
 * Pointer, when it has one: the two shortened as one pointer, when the
 * path itself is whole. */
static void push_placed_path (lua_State *L, const struct layout *layout,
                              const struct path *p) {
  if (layout->prefix == NULL || p->cut) {
    push_path(L, p);
    return;
  }
  lua_pushstring(L, layout->prefix);
  lua_pushlstring(L, p->text, p->len);
  lua_concat(L, 2);
  size_t n;
  const char *whole = lua_tolstring(L, -1, &n);
  push_pointer_text(L, whole, n);
  lua_remove(L, -2);
}

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
  if (layout->record > 0) {
    *line = (size_t)layout->record;
    *column = pos + 1;
    return;
  }
  *line = (size_t)layout->line;
  *column = (size_t)layout->column;
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
  push_placed_path(L, layout, path);
  lua_pushliteral(L, ")");
  lua_concat(L, 3);
}

/* Pushes that the array or object at `path` in `text`, with `opened`
 * open around the text, nests deeper than `max_depth`. The position is
 * the first bracket in the text that opens that deep, which is that
 * container: the walk that found it visits the document in the order
 * the text holds it. */
static void deep_failure (lua_State *L, const char *text, size_t len,
                          const struct layout *layout, int max_depth,
                          int opened, const struct path *path) {
  size_t line, column;
  position(text, deep_offset(text, len, max_depth - opened, layout->json5),
           layout, &line, &column);
  lua_pushfstring(L, "JSON nests deeper than %d level%s at line %I, column %I (",
                  max_depth, max_depth == 1 ? "" : "s", (lua_Integer)line,
                  (lua_Integer)column);
  push_placed_path(L, layout, path);
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
  /* How many arrays and objects are open around the text's value in a
   * larger text: 0 for a whole. */
  int opened;
};

/* Reads the options every read takes from the arguments at `at`:
 * `max_depth`, `json5`, `lone_surrogates`, `hash_comments` and
 * `duplicate_keys`, in that order. */
static void read_options (lua_State *L, int at, struct reading *r) {
  r->max_depth = checked_depth(L, at);
  r->layout.json5 = lua_toboolean(L, at + 1);
  r->layout.record = 0;
  r->layout.line = 1;
  r->layout.column = 1;
  r->layout.prefix = NULL;
  r->flags = r->layout.json5 ? YYJSON_READ_JSON5 : YYJSON_READ_NOFLAG;
  r->lone_surrogates = lua_toboolean(L, at + 2);
  if (lua_toboolean(L, at + 3)) r->flags |= READ_ALLOW_HASH_COMMENTS;
  r->duplicate_keys = lua_toboolean(L, at + 4);
  r->opened = 0;
}

/* Reads `r->text` into a document, which it sets as `guard`'s resource,
 * and returns it; or NULL, having pushed why it is refused: it is not
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
  switch (first_problem(L, yyjson_doc_get_root(doc), r->opened, r->max_depth,
                        r->duplicate_keys, &path, &key)) {
    case REPEATED_KEY:
    repeat_failure(L, r->text, r->len, &r->layout, doc, key, &path);
    return NULL;
    case TOO_DEEP:
    deep_failure(L, r->text, r->len, &r->layout, r->max_depth, r->opened, &path);
    return NULL;
    default:
    return doc;
  }
}

/* Returns nil and the message on top of the stack. */
static int refused (lua_State *L) {
  lua_pushnil(L);
  lua_insert(L, -2);
  return 2;
}

/* decode(text, null?, max_depth?, json5?, big_as_string?,
 * lone_surrogates?, record?, hash_comments?, duplicate_keys?, line?,
 * column?, prefix?, opened?, only?): the value
 * `text` holds, and "". nil and a message when it is not one JSON
 * value -- RFC 8259, or JSON5 when `json5` is true, either with `#`
 * line comments when `hash_comments` is -- holds an object with a key
 * twice unless `duplicate_keys`, or nests past
 * `max_depth` (64 by default). JSON `null` is `null` when given, and
 * nil when not. With `big_as_string`, an integer past 64 bits, or a
 * number past a double's range, is its own text. With `record`, the
 * text is that line of a JSON Lines text, and a failure names it. With
 * `line` and `column`, the text starts there in a larger one, and a
 * failure counts from there; with `prefix`, the JSON Pointer of the
 * value the text is, a pointer a failure names is put under it; with
 * `opened`, that
 * many arrays and objects are open around it there, and count toward
 * `max_depth`. With `only`, a selection (Selection in
 * cosmic/internal/json.d.tl), the text is checked whole first, then only
 * what it selects is built ([`push_only`]). */
static int json_decode (lua_State *L) {
  struct reading r;
  r.text = luaL_checklstring(L, 1, &r.len);
  r.max_depth = checked_depth(L, 3);
  r.layout.json5 = lua_toboolean(L, 4);
  r.layout.record = luaL_optinteger(L, 7, 0);
  luaL_argcheck(L, r.layout.record >= 0, 7, "a record's line is not negative");
  r.layout.line = luaL_optinteger(L, 10, 1);
  luaL_argcheck(L, r.layout.line >= 1, 10, "a line is counted from 1");
  r.layout.column = luaL_optinteger(L, 11, 1);
  luaL_argcheck(L, r.layout.column >= 1, 11, "a column is counted from 1");
  r.layout.prefix = luaL_optstring(L, 12, NULL);
  lua_Integer opened = luaL_optinteger(L, 13, 0);
  luaL_argcheck(L, opened >= 0 && opened < r.max_depth, 13,
                "fewer levels open than max_depth");
  r.opened = (int)opened;
  bool only = !lua_isnoneornil(L, 14);
  if (only) luaL_checktype(L, 14, LUA_TTABLE);
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
  lua_settop(L, 14);
  luaL_getmetatable(L, ARRAY_TYPE);
  d.array_index = lua_gettop(L);
  /* Building the value allocates, and an allocation can raise: the
   * guard frees the document then, and on every return. */
  struct cosmic_guard *guard = cosmic_guard_push(L, release_doc);
  /* With a selection, the whole text is checked as `check` checks it
   * first, so a text decode refuses is refused whatever it selects; then
   * only the selected values are built. */
  yyjson_doc *doc = read_text(L, &r, guard, only);
  if (doc == NULL) return refused(L);
  yyjson_val *root = yyjson_doc_get_root(doc);
  if (only && yyjson_is_ctn(root)) {
    d.duplicate_keys = true;
    push_only(&d, root, 14);
    return cosmic_succeeded(L);
  }
  if (only) d.duplicate_keys = true;
  switch (push_value(&d, root, r.opened)) {
    case REPEATED_KEY:
    repeat_failure(L, r.text, r.len, &r.layout, doc, d.repeated, &d.path);
    return refused(L);
    case TOO_DEEP:
    deep_failure(L, r.text, r.len, &r.layout, r.max_depth, r.opened, &d.path);
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
  /* Whether to write every non-ASCII character as \uXXXX escapes, a
   * surrogate pair above U+FFFF, so the text is ASCII throughout. */
  int ascii;
  /* Why the value cannot be encoded, once it cannot. */
  char failure[160];
  /* Where. `out_of_memory` says the failure was not the value's, so no
   * path is told. */
  struct path path;
  int out_of_memory;
};

/* Records why the value cannot be encoded, and returns -1 for the
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
    if (e->ascii && c >= 0x80) {
      /* [`is_utf8`] accepted the string, so the sequence is whole. */
      if (put(e, s + start, i - start) < 0) return -1;
      uint32_t code;
      size_t extra = c >= 0xf0 ? 3 : c >= 0xe0 ? 2 : 1;
      code = c & (0x3f >> extra);
      for (size_t k = 1; k <= extra; k++) {
        code = code << 6 | ((unsigned char)s[i + k] & 0x3f);
      }
      i += extra;
      start = i + 1;
      char escape[12];
      enum { escape_length = 6 };
      if (code >= 0x10000) {
        uint32_t high = 0xd800 + ((code - 0x10000) >> 10);
        code = 0xdc00 + ((code - 0x10000) & 0x3ff);
        snprintf(escape, sizeof escape, "\\u%04x", (unsigned)high);
        if (put(e, escape, escape_length) < 0) return -1;
      }
      snprintf(escape, sizeof escape, "\\u%04x", (unsigned)code);
      if (put(e, escape, escape_length) < 0) return -1;
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
      prepend_index(&e->path, (size_t)(i - 1));
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

/* The most members an object is written of from the stack: each one's
 * key and value are left there as the table is walked, and sorted in
 * place, with no second lookup of a value by its key. */
#define STACKED_MEMBERS 32

/* One member of a small object being sorted: its key's bytes, which
 * live in the key on the stack, and the slot of that key; the value is
 * the slot above it. */
struct stacked_member {
  const char *s;
  size_t n;
  int slot;
};

/* The object at `idx`, which has `count` string keys and nothing else and
 * no more than STACKED_MEMBERS of them, its members in byte order of
 * their keys. */
static int put_small_object (struct encoding *e, int idx, lua_Integer count,
                             int depth) {
  lua_State *L = e->L;
  struct stacked_member members[STACKED_MEMBERS];
  /* `count` is at most STACKED_MEMBERS, which put_object sees to. */
  luaL_checkstack(L, 2 * STACKED_MEMBERS + 2, "JSON nests too deeply");
  int base = lua_gettop(L);
  int n = 0;
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    if (n == count) {
      lua_settop(L, base);
      return refuse(e, "cannot encode a table changed while it is read");
    }
    /* The key, the value, and a copy of the key that the next step takes. */
    lua_pushvalue(L, -2);
    struct stacked_member m;
    m.slot = lua_gettop(L) - 2;
    m.s = lua_tolstring(L, m.slot, &m.n);
    /* Insertion sort: a record has a few members. */
    int at = n;
    while (at > 0) {
      const struct stacked_member *before = &members[at - 1];
      size_t least = before->n < m.n ? before->n : m.n;
      int c = memcmp(before->s, m.s, least);
      if (c < 0 || (c == 0 && before->n < m.n)) break;
      members[at] = *before;
      at--;
    }
    members[at] = m;
    n++;
  }
  for (int i = 0; i < n; i++) {
    if (put_member(e, members[i].slot, members[i].slot + 1, i == 0, depth) < 0) {
      lua_settop(L, base);
      return -1;
    }
  }
  lua_settop(L, base);
  if (count > 0 && put_break(e, depth) < 0) return -1;
  return PUT_LITERAL(e, "}");
}

/* The object at `idx`, which has `count` string keys and nothing else,
 * its members in byte order of their keys. */
static int put_object (struct encoding *e, int idx, lua_Integer count,
                       int depth) {
  lua_State *L = e->L;
  if (PUT_LITERAL(e, "{") < 0) return -1;
  if (count <= STACKED_MEMBERS) return put_small_object(e, idx, count, depth);
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

/* The most holes an array that may have them writes as `null`: its
 * highest key is no cost to make, so the bytes of a text could be many
 * times the memory of the array it came from. */
#define MAX_HOLES 1048576

/* The array mark the table at `idx` carries: 1 for the array mark, 2 for
 * that of an array that may have holes, 0 for neither. */
static int array_mark (lua_State *L, int idx) {
  int mark = 0;
  if (lua_getmetatable(L, idx)) {
    luaL_getmetatable(L, ARRAY_TYPE);
    if (lua_rawequal(L, -1, -2)) {
      mark = 1;
    } else {
      luaL_getmetatable(L, HOLES_TYPE);
      if (lua_rawequal(L, -1, -3)) mark = 2;
      lua_pop(L, 1);
    }
    lua_pop(L, 2);
  }
  return mark;
}

/* A table is an object when every key is a string, and an array when
 * every key is an integer from 1 up or it carries the array mark; an
 * empty unmarked table is an object. Anything else is refused. An array
 * that may have holes is as long as its highest key and writes `null`
 * at each position it holds nothing at. */
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
  int mark = array_mark(L, idx);
  int marked = mark != 0;
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
  if (mark == 2 && top > 0) {
    if (top - count > MAX_HOLES) {
      snprintf(e->failure, sizeof e->failure,
               "cannot encode an array with more than %d holes (its highest"
               " key is %lld and it holds %lld items); use an object, or"
               " fill the holes",
               MAX_HOLES, (long long)top, (long long)count);
      return -1;
    }
    return put_array(e, idx, top, depth);
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

/* ---- the fractured layout ---------------------------------------- */

/* FracturedJson's layout (https://github.com/j-brooke/FracturedJson),
 * written again here from its rules: compact text, as this file's
 * writers write it, laid out for people to read. cosmic/json.tl's
 * [`Json.TextLayout`] says what each rule does; the limits below are
 * FracturedJson's defaults, but for the indent, two spaces as
 * `expanded` writes it. Its input is this file's own compact text, so a
 * byte out of place is a fault of this file, refused all the same. */

/* The most complex value written on one line, the most complex array
 * written several elements to a line, the fewest elements that is done
 * for, the most complex row of a table, and the most an object's keys
 * are padded to line its values up. */
enum {
  FJ_INLINE_COMPLEXITY = 2,
  FJ_COMPACT_COMPLEXITY = 2,
  FJ_COMPACT_ITEMS = 3,
  FJ_ROW_COMPLEXITY = 2,
  FJ_NAME_PADDING = 16,
  FJ_INDENT = 2,
};

enum fj_kind { FJ_ARRAY, FJ_OBJECT, FJ_NUMBER, FJ_STRING, FJ_LITERAL };

/* What a column of a table holds, over its rows: nothing yet but null,
 * numbers, strings or booleans, arrays, objects, or more than one of
 * those. */
enum fj_column {
  FJ_UNKNOWN, FJ_NUMBERS, FJ_SIMPLE, FJ_ARRAYS, FJ_OBJECTS, FJ_MIXED
};

#define FJ_NONE SIZE_MAX

/* One value of the text. Its children follow it, the first at the next
 * index, each linked to the next by `next`. */
struct fj_node {
  /* A scalar's text, or a member's key, quoted, in the input. */
  size_t at;
  size_t len;
  size_t key_at;
  size_t key_len;
  size_t key_width;
  /* How many characters it takes on one line. */
  size_t width;
  size_t count;
  size_t next;
  int complexity;
  enum fj_kind kind;
  bool null;
};

/* How the values in one column of a table are written. Its columns are
 * linked from `first` by `next`. */
struct fj_template {
  enum fj_column kind;
  size_t rows;
  size_t longest;
  /* A number column's widest part before its `.`, `e` or `E`, and from
   * there on. */
  size_t before;
  size_t after;
  size_t width;
  size_t first;
  size_t last;
  size_t count;
  size_t next;
  /* The column's key, in an object row: a node holding it. */
  size_t key_node;
  /* Whether a row nests, so its brackets are padded; whether one is an
   * array or an object; whether its columns are written aligned. */
  /* The width of a split row's brackets and cells, which `width`
   * may exceed for a narrower or a null row; the last object row that
   * filled this column, to find a key twice in one row. */
  size_t inner;
  size_t stamp;
  bool padded;
  bool nests;
  bool split;
};

struct fractured {
  struct encoding *out;
  const char *text;
  size_t len;
  struct fj_node *nodes;
  size_t n;
  size_t cap;
  struct cosmic_guard *node_guard;
  struct fj_template *t;
  size_t tn;
  size_t tcap;
  struct cosmic_guard *t_guard;
  long long width;
  size_t line_start;
  /* Counts object rows measured, to stamp the columns each fills. */
  size_t rows;
};

/* Characters, not bytes: UTF-8 code points. */
static size_t fj_chars (const char *s, size_t n) {
  size_t count = 0;
  for (size_t i = 0; i < n; i++) {
    if (((unsigned char)s[i] & 0xc0) != 0x80) count++;
  }
  return count;
}

/* Refuses text that is not compact JSON: never this file's own. */
#define fj_malformed(f) \
  refuse((f)->out, "cannot lay out text that is not compact JSON")

static size_t fj_new_node (struct fractured *f) {
  if (f->n == f->cap) {
    size_t cap = f->cap == 0 ? 256 : f->cap;
    if (cap > SIZE_MAX / 2 / sizeof *f->nodes) {
      refuse_memory(f->out);
      return FJ_NONE;
    }
    cap *= 2;
    struct fj_node *grown = cosmic_realloc(f->nodes, cap * sizeof *grown);
    if (grown == NULL) {
      refuse_memory(f->out);
      return FJ_NONE;
    }
    f->nodes = grown;
    f->node_guard->resource = grown;
    f->cap = cap;
  }
  memset(&f->nodes[f->n], 0, sizeof *f->nodes);
  return f->n++;
}

/* The end of the string opening at `at`: the index past its closing
 * quote, or 0 when it has none. */
static size_t fj_string_end (struct fractured *f, size_t at) {
  for (size_t i = at + 1; i < f->len; i++) {
    if (f->text[i] == '\\') {
      i++;
    } else if (f->text[i] == '"') {
      return i + 1;
    }
  }
  return 0;
}

/* Reads the value at `*at` into a node, its index in `*index`, and
 * moves `*at` past it. */
static int fj_read (struct fractured *f, size_t *at, int depth,
                    size_t *index) {
  if (*at >= f->len || depth > MAX_DEPTH) return fj_malformed(f);
  size_t self = fj_new_node(f);
  if (self == FJ_NONE) return -1;
  *index = self;
  char c = f->text[*at];
  if (c == '[' || c == '{') {
    bool object = c == '{';
    char close = object ? '}' : ']';
    f->nodes[self].kind = object ? FJ_OBJECT : FJ_ARRAY;
    (*at)++;
    if (*at < f->len && f->text[*at] == close) {
      (*at)++;
      f->nodes[self].width = 2;
      return 0;
    }
    size_t previous = FJ_NONE;
    size_t count = 0;
    size_t width = 0;
    int most = 0;
    for (;;) {
      size_t key_at = 0;
      size_t key_len = 0;
      if (object) {
        size_t end = *at < f->len && f->text[*at] == '"'
                       ? fj_string_end(f, *at) : 0;
        if (end == 0 || end >= f->len || f->text[end] != ':') {
          return fj_malformed(f);
        }
        key_at = *at;
        key_len = end - *at;
        *at = end + 1;
      }
      size_t child;
      if (fj_read(f, at, depth + 1, &child) < 0) return -1;
      struct fj_node *node = &f->nodes[child];
      if (object) {
        node->key_at = key_at;
        node->key_len = key_len;
        node->key_width = fj_chars(f->text + key_at, key_len);
        width += node->key_width + 2;
      }
      width += node->width;
      if (node->complexity > most) most = node->complexity;
      if (previous != FJ_NONE) f->nodes[previous].next = child;
      previous = child;
      count++;
      if (*at >= f->len) return fj_malformed(f);
      if (f->text[*at] == ',') {
        (*at)++;
        continue;
      }
      if (f->text[*at] != close) return fj_malformed(f);
      (*at)++;
      break;
    }
    struct fj_node *node = &f->nodes[self];
    node->count = count;
    node->complexity = most + 1;
    node->width = width + 2 + 2 * (count - 1) + (most + 1 >= 2 ? 2 : 0);
    return 0;
  }
  struct fj_node *node = &f->nodes[self];
  node->at = *at;
  if (c == '"') {
    size_t end = fj_string_end(f, *at);
    if (end == 0) return fj_malformed(f);
    node->kind = FJ_STRING;
    *at = end;
  } else {
    size_t end = *at;
    while (end < f->len && strchr(",:]}", f->text[end]) == NULL) end++;
    if (end == *at) return fj_malformed(f);
    node->kind = c == '-' || (c >= '0' && c <= '9') ? FJ_NUMBER : FJ_LITERAL;
    node->null = end - *at == 4 && memcmp(f->text + *at, "null", 4) == 0;
    *at = end;
  }
  node->len = *at - node->at;
  node->width = fj_chars(f->text + node->at, node->len);
  return 0;
}

/* ---- writing */

static int fj_spaces (struct fractured *f, long long n) {
  static const char blank[] = "                                ";
  while (n > 0) {
    size_t chunk = n > (long long)(sizeof blank - 1) ? sizeof blank - 1
                                                     : (size_t)n;
    if (put(f->out, blank, chunk) < 0) return -1;
    n -= (long long)chunk;
  }
  return 0;
}

/* Drops the spaces that end the line being written. */
static void fj_trim (struct fractured *f) {
  struct encoding *e = f->out;
  while (e->len > f->line_start && e->p[e->len - 1] == ' ') e->len--;
}

/* Ends the line being written, if any, and begins one `depth` levels
 * in. */
static int fj_line (struct fractured *f, int depth) {
  if (f->out->len > 0) {
    fj_trim(f);
    if (PUT_LITERAL(f->out, "\n") < 0) return -1;
  }
  f->line_start = f->out->len;
  return fj_spaces(f, (long long)depth * FJ_INDENT);
}

static long long fj_room (struct fractured *f, int depth) {
  return f->width - (long long)depth * FJ_INDENT;
}

static int fj_text (struct fractured *f, size_t at, size_t len) {
  return put(f->out, f->text + at, len);
}

static int fj_key (struct fractured *f, size_t node, long long pad) {
  struct fj_node *n = &f->nodes[node];
  if (fj_text(f, n->key_at, n->key_len) < 0) return -1;
  if (fj_spaces(f, pad) < 0) return -1;
  return PUT_LITERAL(f->out, ": ");
}

static int fj_open (struct fractured *f, bool object, bool pad) {
  if (object) return pad ? PUT_LITERAL(f->out, "{ ") : PUT_LITERAL(f->out, "{");
  return pad ? PUT_LITERAL(f->out, "[ ") : PUT_LITERAL(f->out, "[");
}

static int fj_close (struct fractured *f, bool object, bool pad) {
  if (object) return pad ? PUT_LITERAL(f->out, " }") : PUT_LITERAL(f->out, "}");
  return pad ? PUT_LITERAL(f->out, " ]") : PUT_LITERAL(f->out, "]");
}

/* `node` on one line. */
static int fj_inline (struct fractured *f, size_t node) {
  struct fj_node *n = &f->nodes[node];
  if (n->kind != FJ_ARRAY && n->kind != FJ_OBJECT) {
    return fj_text(f, n->at, n->len);
  }
  bool object = n->kind == FJ_OBJECT;
  if (n->count == 0) {
    return object ? PUT_LITERAL(f->out, "{}") : PUT_LITERAL(f->out, "[]");
  }
  bool pad = n->complexity >= 2;
  if (fj_open(f, object, pad) < 0) return -1;
  size_t child = node + 1;
  for (size_t i = 0; i < f->nodes[node].count; i++) {
    if (i > 0 && PUT_LITERAL(f->out, ", ") < 0) return -1;
    if (object && fj_key(f, child, 0) < 0) return -1;
    if (fj_inline(f, child) < 0) return -1;
    child = f->nodes[child].next;
  }
  return fj_close(f, object, pad);
}

/* ---- tables */

static size_t fj_new_template (struct fractured *f) {
  if (f->tn == f->tcap) {
    size_t cap = f->tcap == 0 ? 32 : f->tcap;
    if (cap > SIZE_MAX / 2 / sizeof *f->t) {
      refuse_memory(f->out);
      return FJ_NONE;
    }
    cap *= 2;
    struct fj_template *grown = cosmic_realloc(f->t, cap * sizeof *grown);
    if (grown == NULL) {
      refuse_memory(f->out);
      return FJ_NONE;
    }
    f->t = grown;
    f->t_guard->resource = grown;
    f->tcap = cap;
  }
  struct fj_template *t = &f->t[f->tn];
  memset(t, 0, sizeof *t);
  t->kind = FJ_UNKNOWN;
  t->first = FJ_NONE;
  t->last = FJ_NONE;
  t->next = FJ_NONE;
  t->key_node = FJ_NONE;
  return f->tn++;
}

/* Appends a new column to `t`, keyed by `key_node`'s key, or FJ_NONE
 * when memory refuses. */
static size_t fj_add_column (struct fractured *f, size_t t, size_t key_node) {
  size_t column = fj_new_template(f);
  if (column == FJ_NONE) return FJ_NONE;
  f->t[column].key_node = key_node;
  if (f->t[t].last == FJ_NONE) {
    f->t[t].first = column;
  } else {
    f->t[f->t[t].last].next = column;
  }
  f->t[t].last = column;
  f->t[t].count++;
  return column;
}

static bool fj_same_key (struct fractured *f, size_t a, size_t b) {
  struct fj_node *x = &f->nodes[a];
  struct fj_node *y = &f->nodes[b];
  return x->key_len == y->key_len &&
         memcmp(f->text + x->key_at, f->text + y->key_at, x->key_len) == 0;
}

/* The column of `t` keyed as `key_node` is, trying `hint` first, or
 * FJ_NONE. */
static size_t fj_find (struct fractured *f, size_t t, size_t key_node,
                       size_t hint) {
  if (hint != FJ_NONE && fj_same_key(f, f->t[hint].key_node, key_node)) {
    return hint;
  }
  for (size_t c = f->t[t].first; c != FJ_NONE; c = f->t[c].next) {
    if (fj_same_key(f, f->t[c].key_node, key_node)) return c;
  }
  return FJ_NONE;
}

/* The child of `node`, an object, keyed as the column `column` is,
 * trying `hint` first, or FJ_NONE. */
static size_t fj_member (struct fractured *f, size_t node, size_t column,
                         size_t hint) {
  if (f->nodes[node].count == 0) return FJ_NONE;
  size_t key = f->t[column].key_node;
  if (hint != 0 && hint != FJ_NONE && fj_same_key(f, hint, key)) return hint;
  size_t child = node + 1;
  for (size_t i = 0; i < f->nodes[node].count; i++) {
    if (fj_same_key(f, child, key)) return child;
    child = f->nodes[child].next;
  }
  return FJ_NONE;
}

static enum fj_column fj_column_of (struct fj_node *n) {
  if (n->null) return FJ_UNKNOWN;
  switch (n->kind) {
    case FJ_ARRAY:
    return FJ_ARRAYS;
    case FJ_OBJECT:
    return FJ_OBJECTS;
    case FJ_NUMBER:
    return FJ_NUMBERS;
    default:
    return FJ_SIMPLE;
  }
}

/* The length of a number's integer part: up to its `.`, `e` or `E`. */
static size_t fj_integer_length (const char *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (s[i] == '.' || s[i] == 'e' || s[i] == 'E') return i;
  }
  return n;
}

/* Adds `node`, one row's value in the column `t`, to what `t`
 * measures. */
static int fj_add_row (struct fractured *f, size_t t, size_t node) {
  struct fj_node *n = &f->nodes[node];
  struct fj_template *m = &f->t[t];
  enum fj_column kind = fj_column_of(n);
  m->rows++;
  if (n->width > m->longest) m->longest = n->width;
  if (kind != FJ_UNKNOWN) {
    if (m->kind == FJ_UNKNOWN) {
      m->kind = kind;
    } else if (m->kind != kind) {
      m->kind = FJ_MIXED;
    }
  }
  if (n->complexity >= 2) m->padded = true;
  if (kind == FJ_ARRAYS || kind == FJ_OBJECTS) m->nests = true;
  if (kind == FJ_NUMBERS) {
    size_t before = fj_integer_length(f->text + n->at, n->len);
    if (before > m->before) m->before = before;
    if (n->len - before > m->after) m->after = n->len - before;
    return 0;
  }
  if (kind != FJ_ARRAYS && kind != FJ_OBJECTS) return 0;
  if (f->t[t].kind == FJ_MIXED) return 0;
  size_t count = n->count;
  size_t stamp = ++f->rows;
  size_t child = node + 1;
  size_t column = f->t[t].first;
  for (size_t i = 0; i < count; i++) {
    if (kind == FJ_OBJECTS) {
      column = fj_find(f, t, child, column);
    }
    if (column == FJ_NONE) {
      /* Rows with more columns than a line has characters are no
       * table, and measuring them on would cost the square of their
       * count. */
      if ((long long)f->t[t].count >= f->width) {
        f->t[t].kind = FJ_MIXED;
        return 0;
      }
      column = fj_add_column(f, t, child);
      if (column == FJ_NONE) return -1;
    }
    if (kind == FJ_OBJECTS) {
      /* A key twice in one row has one column for two values: written
       * inline, the row keeps both. */
      if (f->t[column].stamp == stamp) {
        f->t[t].kind = FJ_MIXED;
        return 0;
      }
      f->t[column].stamp = stamp;
    }
    if (fj_add_row(f, column, child) < 0) return -1;
    column = f->t[column].next;
    child = f->nodes[child].next;
  }
  return 0;
}

/* How deep the columns of `t` nest: 0 for a leaf. */
static int fj_depth (struct fractured *f, size_t t) {
  int most = 0;
  if (f->t[t].kind != FJ_ARRAYS && f->t[t].kind != FJ_OBJECTS) return 0;
  for (size_t c = f->t[t].first; c != FJ_NONE; c = f->t[c].next) {
    int d = fj_depth(f, c) + 1;
    if (d > most) most = d;
  }
  return most;
}

/* Sets the widths of `t` and its columns, splitting rows into columns no
 * more than `levels` deep. */
static void fj_lay (struct fractured *f, size_t t, int levels) {
  struct fj_template *m = &f->t[t];
  m->split = false;
  if (m->kind == FJ_NUMBERS) {
    size_t width = m->before + m->after;
    m->width = width > m->longest ? width : m->longest;
    return;
  }
  if ((m->kind != FJ_ARRAYS && m->kind != FJ_OBJECTS) || levels <= 0 ||
      m->rows < 2 || m->count == 0) {
    m->width = m->longest;
    return;
  }
  m->split = true;
  size_t width = 2 + 2 * (m->count - 1) + (m->padded ? 2 : 0);
  bool object = m->kind == FJ_OBJECTS;
  for (size_t c = f->t[t].first; c != FJ_NONE; c = f->t[c].next) {
    fj_lay(f, c, levels - 1);
    width += f->t[c].width;
    if (object) width += f->nodes[f->t[c].key_node].key_width + 2;
  }
  f->t[t].inner = width;
  f->t[t].width = width > f->t[t].longest ? width : f->t[t].longest;
}

/* What follows a cell: nothing, a comma, or a space where a comma would
 * be. */
enum fj_sep { FJ_END, FJ_COMMA, FJ_BLANK };

static int fj_put_sep (struct fractured *f, enum fj_sep sep) {
  if (sep == FJ_COMMA) return PUT_LITERAL(f->out, ",");
  if (sep == FJ_BLANK) return PUT_LITERAL(f->out, " ");
  return 0;
}

/* `node`, or nothing when it is FJ_NONE, in the column `t`: `t`'s width
 * of characters, and `sep` where the column puts it. */
static int fj_cell (struct fractured *f, size_t node, size_t t,
                    enum fj_sep sep) {
  long long width = (long long)f->t[t].width;
  if (node == FJ_NONE) {
    return fj_spaces(f, width + (sep == FJ_END ? 0 : 1));
  }
  struct fj_node *n = &f->nodes[node];
  struct fj_template *m = &f->t[t];
  if (m->kind == FJ_NUMBERS && (n->kind == FJ_NUMBER || n->null)) {
    long long lead = n->kind == FJ_NUMBER
      ? (long long)m->before -
        (long long)fj_integer_length(f->text + n->at, n->len)
      : 0;
    if (fj_spaces(f, lead) < 0) return -1;
    if (fj_text(f, n->at, n->len) < 0) return -1;
    if (fj_spaces(f, width - lead - (long long)n->width) < 0) return -1;
    return fj_put_sep(f, sep);
  }
  if (!m->split || fj_column_of(n) != m->kind) {
    long long rest = width - (long long)n->width;
    if (fj_inline(f, node) < 0) return -1;
    if (fj_put_sep(f, sep) < 0) return -1;
    return fj_spaces(f, rest);
  }
  bool object = m->kind == FJ_OBJECTS;
  bool padded = m->padded;
  /* The last column this row holds a value in: a comma follows only a
   * value with another after it. */
  size_t last = 0;
  size_t position = 0;
  size_t hint = node + 1;
  for (size_t c = f->t[t].first; c != FJ_NONE; c = f->t[c].next) {
    position++;
    size_t child = object ? fj_member(f, node, c, hint)
                          : (position <= f->nodes[node].count ? 1 : FJ_NONE);
    if (child != FJ_NONE) {
      last = position;
      if (object) hint = f->nodes[child].next;
    }
  }
  if (fj_open(f, object, padded) < 0) return -1;
  size_t count = f->t[t].count;
  position = 0;
  hint = node + 1;
  size_t element = node + 1;
  for (size_t c = f->t[t].first; c != FJ_NONE; c = f->t[c].next) {
    position++;
    size_t child;
    if (object) {
      child = fj_member(f, node, c, hint);
      if (child != FJ_NONE) hint = f->nodes[child].next;
    } else {
      child = position <= f->nodes[node].count ? element : FJ_NONE;
      if (child != FJ_NONE) element = f->nodes[child].next;
    }
    enum fj_sep after = position == count ? FJ_END
                        : child != FJ_NONE && position < last ? FJ_COMMA
                                                              : FJ_BLANK;
    if (child == FJ_NONE) {
      long long blank = (long long)f->t[c].width + (after == FJ_END ? 0 : 1);
      if (object) {
        blank += (long long)f->nodes[f->t[c].key_node].key_width + 2;
      }
      if (fj_spaces(f, blank) < 0) return -1;
    } else {
      if (object && fj_key(f, child, 0) < 0) return -1;
      if (fj_cell(f, child, c, after) < 0) return -1;
    }
    if (position < count && PUT_LITERAL(f->out, " ") < 0) return -1;
  }
  if (fj_close(f, object, padded) < 0) return -1;
  if (fj_put_sep(f, sep) < 0) return -1;
  return fj_spaces(f, width - (long long)f->t[t].inner);
}

/* ---- layout */

/* What a line opens with before its value: a member's key, padded, and
 * `: `; or nothing. */
struct fj_prefix {
  size_t node;
  long long pad;
};

static const struct fj_prefix fj_no_prefix = {FJ_NONE, 0};

static long long fj_prefix_width (struct fractured *f, struct fj_prefix p) {
  if (p.node == FJ_NONE) return 0;
  return (long long)f->nodes[p.node].key_width + p.pad + 2;
}

static int fj_put_prefix (struct fractured *f, struct fj_prefix p) {
  if (p.node == FJ_NONE) return 0;
  return fj_key(f, p.node, p.pad);
}

/* The longest and shortest key of `node`, an object. */
static void fj_key_widths (struct fractured *f, size_t node, size_t *longest,
                           size_t *shortest) {
  *longest = 0;
  *shortest = SIZE_MAX;
  size_t child = node + 1;
  for (size_t i = 0; i < f->nodes[node].count; i++) {
    size_t w = f->nodes[child].key_width;
    if (w > *longest) *longest = w;
    if (w < *shortest) *shortest = w;
    child = f->nodes[child].next;
  }
}

static int fj_write (struct fractured *f, size_t node, int depth,
                     struct fj_prefix prefix, bool comma);

/* The template of `node`'s children as rows, in `*t`. */
static int fj_rows (struct fractured *f, size_t node, size_t *t) {
  f->tn = 0;
  *t = fj_new_template(f);
  if (*t == FJ_NONE) return -1;
  size_t child = node + 1;
  for (size_t i = 0; i < f->nodes[node].count; i++) {
    if (fj_add_row(f, *t, child) < 0) return -1;
    child = f->nodes[child].next;
  }
  return 0;
}

/* Writes `node`, an array, several elements to a line when that is how it
 * is written: 1 when written, 0 when not, -1 when it failed. */
static int fj_compact (struct fractured *f, size_t node, int depth,
                       struct fj_prefix prefix, bool comma) {
  struct fj_node *n = &f->nodes[node];
  size_t count = n->count;
  if (n->kind != FJ_ARRAY || count < FJ_COMPACT_ITEMS ||
      n->complexity > FJ_COMPACT_COMPLEXITY) {
    return 0;
  }
  long long space = fj_room(f, depth + 1);
  /* An element longer than a line is not lined up with the rest. */
  bool aligned = true;
  size_t total = 0;
  size_t child = node + 1;
  for (size_t i = 0; i < count; i++) {
    total += f->nodes[child].width;
    if ((long long)f->nodes[child].width > space) aligned = false;
    child = f->nodes[child].next;
  }
  size_t t = FJ_NONE;
  if (aligned) {
    if (fj_rows(f, node, &t) < 0) return -1;
    enum fj_column kind = f->t[t].kind;
    aligned = kind != FJ_UNKNOWN && kind != FJ_MIXED;
  }
  double average;
  if (aligned) {
    fj_lay(f, t, FJ_COMPACT_COMPLEXITY);
    average = (double)f->t[t].width;
  } else {
    average = (double)total / (double)count;
  }
  if (aligned && (average + 1) * (double)FJ_COMPACT_ITEMS > (double)space) {
    /* Too wide lined up: packed as they are instead. */
    aligned = false;
    average = (double)total / (double)count;
  }
  if ((average + 1) * (double)FJ_COMPACT_ITEMS > (double)space) return 0;
  if (fj_line(f, depth) < 0) return -1;
  if (fj_put_prefix(f, prefix) < 0) return -1;
  if (PUT_LITERAL(f->out, "[") < 0) return -1;
  long long used = 0;
  child = node + 1;
  for (size_t i = 0; i < count; i++) {
    bool last = i + 1 == count;
    long long size =
      (long long)(aligned ? f->t[t].width : f->nodes[child].width) +
      (last ? 0 : 1);
    if (used == 0 || used + 1 + size > space) {
      if (fj_line(f, depth + 1) < 0) return -1;
      used = 0;
    } else {
      if (PUT_LITERAL(f->out, " ") < 0) return -1;
      used++;
    }
    if (aligned) {
      if (fj_cell(f, child, t, last ? FJ_END : FJ_COMMA) < 0) return -1;
    } else {
      if (fj_inline(f, child) < 0) return -1;
      if (!last && PUT_LITERAL(f->out, ",") < 0) return -1;
    }
    used += size;
    child = f->nodes[child].next;
  }
  if (fj_line(f, depth) < 0) return -1;
  if (PUT_LITERAL(f->out, "]") < 0) return -1;
  if (comma && PUT_LITERAL(f->out, ",") < 0) return -1;
  return 1;
}

/* Writes `node` as a table, one member to a line in columns, when that
 * is how it is written: 1 when written, 0 when not, -1 when it
 * failed. */
static int fj_table (struct fractured *f, size_t node, int depth,
                     struct fj_prefix prefix, bool comma) {
  struct fj_node *n = &f->nodes[node];
  size_t count = n->count;
  bool object = n->kind == FJ_OBJECT;
  if (count < 2 || n->complexity > FJ_ROW_COMPLEXITY + 1) return 0;
  size_t longest = 0;
  size_t shortest = 0;
  if (object) fj_key_widths(f, node, &longest, &shortest);
  long long space = fj_room(f, depth + 1) - (object ? (long long)longest + 2 : 0) - 1;
  /* A row is no narrower in the table than on its own. */
  size_t child = node + 1;
  for (size_t i = 0; i < count; i++) {
    if ((long long)f->nodes[child].width > space) return 0;
    child = f->nodes[child].next;
  }
  size_t t;
  if (fj_rows(f, node, &t) < 0) return -1;
  if (f->t[t].kind != FJ_ARRAYS && f->t[t].kind != FJ_OBJECTS) return 0;
  for (size_t c = f->t[t].first; c != FJ_NONE; c = f->t[c].next) {
    /* Rows that hold an array or an object in a field where another
     * holds a scalar are not alike enough to line up. */
    if (f->t[c].kind == FJ_MIXED && f->t[c].nests) return 0;
  }
  int levels = fj_depth(f, t);
  for (;;) {
    if (levels <= 0) return 0;
    fj_lay(f, t, levels);
    if ((long long)f->t[t].width <= space && f->t[t].split) break;
    levels--;
  }
  if (fj_line(f, depth) < 0) return -1;
  if (fj_put_prefix(f, prefix) < 0) return -1;
  if (fj_open(f, object, false) < 0) return -1;
  child = node + 1;
  for (size_t i = 0; i < count; i++) {
    if (fj_line(f, depth + 1) < 0) return -1;
    if (object) {
      long long pad = (long long)(longest - f->nodes[child].key_width);
      if (fj_key(f, child, pad) < 0) return -1;
    }
    if (fj_cell(f, child, t, i + 1 < count ? FJ_COMMA : FJ_END) < 0) {
      return -1;
    }
    child = f->nodes[child].next;
  }
  if (fj_line(f, depth) < 0) return -1;
  if (fj_close(f, object, false) < 0) return -1;
  if (comma && PUT_LITERAL(f->out, ",") < 0) return -1;
  return 1;
}

static int fj_write (struct fractured *f, size_t node, int depth,
                     struct fj_prefix prefix, bool comma) {
  struct fj_node *n = &f->nodes[node];
  if (n->count == 0 ||
      (n->complexity <= FJ_INLINE_COMPLEXITY &&
       fj_prefix_width(f, prefix) + (long long)n->width + (comma ? 1 : 0) <=
         fj_room(f, depth))) {
    if (fj_line(f, depth) < 0) return -1;
    if (fj_put_prefix(f, prefix) < 0) return -1;
    if (fj_inline(f, node) < 0) return -1;
    return comma ? PUT_LITERAL(f->out, ",") : 0;
  }
  int done = fj_compact(f, node, depth, prefix, comma);
  if (done == 0) done = fj_table(f, node, depth, prefix, comma);
  if (done != 0) return done < 0 ? -1 : 0;
  bool object = f->nodes[node].kind == FJ_OBJECT;
  size_t longest = 0;
  size_t shortest = 0;
  if (object) fj_key_widths(f, node, &longest, &shortest);
  bool align = object && longest - shortest <= FJ_NAME_PADDING;
  if (fj_line(f, depth) < 0) return -1;
  if (fj_put_prefix(f, prefix) < 0) return -1;
  if (fj_open(f, object, false) < 0) return -1;
  size_t count = f->nodes[node].count;
  size_t child = node + 1;
  for (size_t i = 0; i < count; i++) {
    struct fj_prefix p = fj_no_prefix;
    if (object) {
      p.node = child;
      p.pad = align ? (long long)(longest - f->nodes[child].key_width) : 0;
    }
    if (fj_write(f, child, depth + 1, p, i + 1 < count) < 0) return -1;
    child = f->nodes[child].next;
  }
  if (fj_line(f, depth) < 0) return -1;
  if (fj_close(f, object, false) < 0) return -1;
  return comma ? PUT_LITERAL(f->out, ",") : 0;
}

/* Lays out `e`'s text, compact JSON, as FracturedJson does, in lines of
 * `width` characters where its values allow, and puts the laid-out text
 * in `e` in its place. Pushes three guards. */
static int lay_fractured (struct encoding *e, long long width) {
  lua_State *L = e->L;
  struct encoding out;
  memset(&out, 0, sizeof out);
  out.L = L;
  out.guard = cosmic_guard_push(L, cosmic_free);
  struct fractured f;
  memset(&f, 0, sizeof f);
  f.out = &out;
  f.text = e->p;
  f.len = e->len;
  f.width = width;
  f.node_guard = cosmic_guard_push(L, cosmic_free);
  f.t_guard = cosmic_guard_push(L, cosmic_free);
  size_t at = 0;
  size_t root;
  int status = fj_read(&f, &at, 0, &root);
  if (status == 0 && at != f.len) status = fj_malformed(&f);
  if (status == 0) status = fj_write(&f, root, 0, fj_no_prefix, false);
  if (status == 0) fj_trim(&f);
  if (status < 0) {
    memcpy(e->failure, out.failure, sizeof e->failure);
    e->out_of_memory = out.out_of_memory;
    return -1;
  }
  /* The input is let go and the output kept, under `e`'s guard. */
  cosmic_guard_release(e->guard);
  e->p = out.p;
  e->len = out.len;
  e->cap = out.cap;
  e->guard->resource = out.p;
  out.guard->resource = NULL;
  return 0;
}

/* How a text is laid out: what `layout` names. */
static const char *const layouts[] = {"compact", "expanded", "fractured",
  NULL};

enum { LAYOUT_COMPACT, LAYOUT_EXPANDED, LAYOUT_FRACTURED };

/* The line width argument at `arg`: 120 when absent; raises when it is
 * less than 1. */
static long long checked_width (lua_State *L, int arg) {
  lua_Integer width = luaL_optinteger(L, arg, 120);
  luaL_argcheck(L, width >= 1, arg, "the width must be at least 1");
  return (long long)width;
}

/* encode(value, layout?, max_depth?, ascii?, width?): `value` as JSON
 * text, and "", laid out as `layout` names, `fractured` in lines of
 * `width`. nil and a message when it holds something JSON cannot say. */
static int json_encode (lua_State *L) {
  luaL_checkany(L, 1);
  struct encoding e;
  memset(&e, 0, sizeof e);
  e.L = L;
  int layout = luaL_checkoption(L, 2, "compact", layouts);
  e.pretty = layout == LAYOUT_EXPANDED;
  e.max_depth = checked_depth(L, 3);
  e.ascii = lua_toboolean(L, 4);
  long long width = checked_width(L, 5);
  lua_settop(L, 5);
  lua_getfield(L, LUA_REGISTRYINDEX, NULL_KEY);
  e.null_index = lua_gettop(L);
  e.guard = cosmic_guard_push(L, cosmic_free);
  if (put_value(&e, 1, 0) < 0 ||
      (layout == LAYOUT_FRACTURED && lay_fractured(&e, width) < 0)) {
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
 * it so. JSON5's decimal forms differ from RFC 8259's only in a leading
 * `+`, a point with no digit before it (`.5`) or none after it (`5.`),
 * so they are written with the same digits, whatever the number's size:
 * `5.0`, `0.5`, a float still. Hexadecimal is written as the shortest text for the
 * integer it names. NaN and the infinities are refused: JSON has no
 * text for them. */
static int put_raw_number (struct encoding *e, const char *s, size_t n) {
  if (is_json_number(s, n)) return put(e, s, n);
  size_t start = e->len;
  size_t i = 0;
  int status = 0;
  if (i < n && s[i] == '+') {
    i++;
  } else if (i < n && s[i] == '-') {
    status = PUT_LITERAL(e, "-");
    i++;
  }
  if (status == 0 && i < n && s[i] == '.') status = PUT_LITERAL(e, "0");
  size_t point = i;
  while (point < n && s[point] != '.') point++;
  if (status == 0 && point < n &&
      (point + 1 == n || s[point + 1] == 'e' || s[point + 1] == 'E')) {
    status = put(e, s + i, point - i);
    if (status == 0) status = PUT_LITERAL(e, ".0");
    if (status == 0) status = put(e, s + point + 1, n - point - 1);
  } else if (status == 0) {
    status = put(e, s + i, n - i);
  }
  if (status < 0) return -1;
  if (is_json_number(e->p + start, e->len - start)) return 0;
  e->len = start;
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
        prepend_index(&e->path, idx);
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
 * duplicate_keys?, layout?, canonical?, width?): the value `text` holds,
 * read as `check` reads it, written again as RFC 8259 text, and "". Its
 * members keep the text's order, a key twice too, and its numbers their
 * text, in RFC 8259's form where JSON5 wrote another; laid out as
 * `encode` lays a value out by `layout` and `width`. With `canonical`, RFC 8785's form instead:
 * members sorted by their keys' UTF-16 code units, numbers as
 * ECMAScript writes the double each reads as, and no space. nil and a
 * message when the text does not read, or holds NaN or an infinity. */
static int json_format (lua_State *L) {
  struct reading r;
  r.text = luaL_checklstring(L, 1, &r.len);
  read_options(L, 2, &r);
  bool canonical = lua_toboolean(L, 8);
  int layout = canonical ? LAYOUT_COMPACT
                         : luaL_checkoption(L, 7, "compact", layouts);
  long long width = checked_width(L, 9);
  struct encoding e;
  memset(&e, 0, sizeof e);
  e.L = L;
  e.pretty = layout == LAYOUT_EXPANDED;
  lua_settop(L, 9);
  struct cosmic_guard *doc_guard = cosmic_guard_push(L, release_doc);
  yyjson_doc *doc = read_text(L, &r, doc_guard, true);
  if (doc == NULL) return refused(L);
  if (!canonical) {
    /* What decode refuses is refused with its message: yyjson reads a
     * number as its text with checks of its own, which word a failure
     * and place it otherwise and pass a hexadecimal number too large
     * for any integer. So the text is read as decode reads it first,
     * then again keeping each number's text: the same values, which
     * the first read's walk found nothing in. */
    yyjson_doc_free(doc);
    doc_guard->resource = NULL;
    r.flags |= YYJSON_READ_NUMBER_AS_RAW;
    doc = read_text(L, &r, doc_guard, false);
    if (doc == NULL) return refused(L);
  }
  e.guard = cosmic_guard_push(L, cosmic_free);
  if (put_text_value(&e, yyjson_doc_get_root(doc), 0, canonical) < 0 ||
      (layout == LAYOUT_FRACTURED && lay_fractured(&e, width) < 0)) {
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
 * returns it. Raises when `t` already has another metatable. */
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

/* with_holes(t, holey): marks `t`, which has no metatable, as an array
 * that may have holes when `holey` is true and as an array otherwise,
 * and returns it. */
static int json_with_holes (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int holey = lua_toboolean(L, 2);
  lua_settop(L, 1);
  luaL_setmetatable(L, holey ? HOLES_TYPE : ARRAY_TYPE);
  return 1;
}

/* is_array(v): whether `v` is a table carrying either array mark. */
static int json_is_array (lua_State *L) {
  lua_pushboolean(L, lua_type(L, 1) == LUA_TTABLE && array_mark(L, 1) != 0);
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
  {"with_holes", json_with_holes},
  {NULL, NULL},
};

int cosmic_open_json (lua_State *L) {
  luaL_newmetatable(L, ARRAY_TYPE);
  lua_pop(L, 1);

  luaL_newmetatable(L, HOLES_TYPE);
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
