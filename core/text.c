#include "text.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "lauxlib.h"

/* `lines(text, bare)`: the lines of `text` as a new list, each without its
 * newline. A last line with no newline is one too; none follows a last
 * newline. Where `bare`, a `\r` at the end of a line goes too. */
static int text_lines (lua_State *L) {
  size_t len = 0;
  const char *text = luaL_checklstring(L, 1, &len);
  int bare = lua_toboolean(L, 2);
  /* A first pass counts the lines, so the list is made at its size. */
  size_t count = 0;
  for (const char *at = text, *end = text + len; at < end; count++) {
    const char *nl = memchr(at, '\n', (size_t)(end - at));
    if (nl == NULL) break;
    at = nl + 1;
  }
  if (len > 0 && text[len - 1] != '\n') count++;
  if (count > INT32_MAX) return luaL_error(L, "lines: %I lines are past the most a list holds", (lua_Integer)count);
  lua_createtable(L, (int)count, 0);
  const char *at = text, *end = text + len;
  lua_Integer i = 0;
  while (at < end) {
    const char *nl = memchr(at, '\n', (size_t)(end - at));
    const char *stop = nl != NULL ? nl : end;
    size_t n = (size_t)(stop - at);
    if (bare && n > 0 && at[n - 1] == '\r') n--;
    lua_pushlstring(L, at, n);
    lua_rawseti(L, -2, ++i);
    if (nl == NULL) break;
    at = nl + 1;
  }
  return 1;
}

/* `newlines(text, i, j)`: how many newlines bytes `i` through `j` of `text`
 * hold (from 1, as string.sub counts, clamped to the text), and where the
 * last of them is, or 0 where none is. */
static int text_newlines (lua_State *L) {
  size_t len = 0;
  const char *text = luaL_checklstring(L, 1, &len);
  lua_Integer i = luaL_checkinteger(L, 2), j = luaL_checkinteger(L, 3);
  if (i < 1) i = 1;
  if (j > (lua_Integer)len) j = (lua_Integer)len;
  lua_Integer count = 0, last = 0;
  if (i <= j) {
    const char *at = text + i - 1, *end = text + j;
    const char *nl;
    while (at < end && (nl = memchr(at, '\n', (size_t)(end - at))) != NULL) {
      count++;
      last = (lua_Integer)(nl - text) + 1;
      at = nl + 1;
    }
  }
  lua_pushinteger(L, count);
  lua_pushinteger(L, last);
  return 2;
}

/* One item of a list being sorted: its bytes, which the list keeps alive,
 * and its place in the list. */
struct item {
  const char *bytes;
  size_t len;
  lua_Integer at;
};

/* The first `n` bytes of `a` and `b` by their order as unsigned bytes, as
 * memcmp orders them, eight at a time: musl's memcmp takes a byte a step,
 * and lines that share a long prefix made that most of a sort's time. */
static int bytes_order (const unsigned char *a, const unsigned char *b, size_t n) {
  while (n >= 8) {
    uint64_t x, y;
    memcpy(&x, a, 8);
    memcpy(&y, b, 8);
    if (x != y) {
#if !defined(__BYTE_ORDER__)
#error "core/text.c compares words by the byte order __BYTE_ORDER__ names"
#elif __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
      x = __builtin_bswap64(x);
      y = __builtin_bswap64(y);
#endif
      return x < y ? -1 : 1;
    }
    a += 8;
    b += 8;
    n -= 8;
  }
  for (; n > 0; a++, b++, n--)
    if (*a != *b) return *a < *b ? -1 : 1;
  return 0;
}

/* By bytes, as `LC_ALL=C sort` orders them: a prefix first. */
static int item_order (const struct item *x, const struct item *y) {
  size_t n = x->len < y->len ? x->len : y->len;
  int c = bytes_order((const unsigned char *)x->bytes, (const unsigned char *)y->bytes, n);
  if (c != 0) return c;
  return (x->len > y->len) - (x->len < y->len);
}

/* Sorts `items` stably, with `spare` as room for as many: a merge of runs
 * that double, so equal strings keep their places and no host's qsort
 * decides the order. */
static void merge_sort (struct item *items, struct item *spare, size_t n) {
  struct item *from = items, *to = spare;
  for (size_t width = 1; width < n; width *= 2) {
    for (size_t lo = 0; lo < n; lo += 2 * width) {
      size_t mid = lo + width < n ? lo + width : n;
      size_t hi = lo + 2 * width < n ? lo + 2 * width : n;
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi) to[k++] = item_order(&from[j], &from[i]) < 0 ? from[j++] : from[i++];
      while (i < mid) to[k++] = from[i++];
      while (j < hi) to[k++] = from[j++];
    }
    struct item *t = from;
    from = to;
    to = t;
  }
  if (from != items) memcpy(items, from, n * sizeof *items);
}

/* luaL_error's format is lua_pushfstring's, which has no %zu or %llu: a
 * count goes as %I, a lua_Integer. */

/* `sort(list)`: a new list of the strings of `list`, sorted by their bytes.
 * Raises where an item is not a string. */
static int text_sort (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Unsigned n = lua_rawlen(L, 1);
  if (n > INT32_MAX || n > SIZE_MAX / (2 * sizeof(struct item)))
    return luaL_error(L, "sort: a list of %I items is past the most it sorts", (lua_Integer)n);
  /* Userdata, so the collector frees it however this call ends. */
  struct item *items = lua_newuserdatauv(L, 2 * (size_t)n * sizeof *items, 0);
  for (lua_Unsigned k = 0; k < n; k++) {
    if (lua_rawgeti(L, 1, (lua_Integer)k + 1) != LUA_TSTRING)
      return luaL_error(L, "sort: item %I is a %s, not a string", (lua_Integer)k + 1,
        luaL_typename(L, -1));
    items[k].bytes = lua_tolstring(L, -1, &items[k].len);
    items[k].at = (lua_Integer)k + 1;
    lua_pop(L, 1);
  }
  /* No Lua runs while it sorts, so the list still holds every string. */
  merge_sort(items, items + n, (size_t)n);
  lua_createtable(L, (int)n, 0);
  for (lua_Unsigned k = 0; k < n; k++) {
    lua_rawgeti(L, 1, items[k].at);
    lua_rawseti(L, -2, (lua_Integer)k + 1);
  }
  return 1;
}

static const luaL_Reg module[] = {
  {"lines", text_lines},
  {"newlines", text_newlines},
  {"sort", text_sort},
  {NULL, NULL},
};

int cosmic_open_text (lua_State *L) {
  luaL_newlib(L, module);
  return 1;
}
