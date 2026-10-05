#include "html.h"

#include <stdbool.h>
#include <stddef.h>

#include "lauxlib.h"

#define SAFE_HTML_TYPE "cosmic.html.SafeHtml"
#define SAFE_ATTR_TYPE "cosmic.html.SafeAttr"

/* A safe value is a userdata with no memory of its own whose one user
 * value is the string: the string is Lua's, so `raw` hands it back
 * without a copy, `concat` appends it as it is, and the collector owns
 * it with nothing for a finalizer to release. The metatable has a name
 * and nothing else, so no operator reaches the string: a leak is a call
 * to `raw`. */

/* Pops the string on top of the stack into a new safe value of
 * `type_name` and leaves that on top. */
static void wrap (lua_State *L, const char *type_name) {
  lua_newuserdatauv(L, 0, 1);
  lua_insert(L, -2);
  lua_setiuservalue(L, -2, 1);
  luaL_setmetatable(L, type_name);
}

/* Pushes the string of the safe value at `index`, which must be one of
 * `type_name`. */
static void push_string_of (lua_State *L, int index, const char *type_name) {
  luaL_checkudata(L, index, type_name);
  lua_getiuservalue(L, index, 1);
}

static const char *text_entity (unsigned char c) {
  switch (c) {
    case '&': return "&amp;";
    case '<': return "&lt;";
    case '>': return "&gt;";
    case '"': return "&quot;";
    case '\'': return "&#39;";
    default: return NULL;
  }
}

/* `escape`: the five characters that can end or open markup in text or
 * in a quoted attribute value. Nothing else changes, so any byte of
 * UTF-8 passes through as it came. A string with none of them is its own
 * escape and is wrapped as it is. */
static int html_escape (lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  bool plain = true;
  for (size_t i = 0; plain && i < len; i++) {
    plain = text_entity((unsigned char)s[i]) == NULL;
  }
  if (plain) {
    lua_pushvalue(L, 1);
  } else {
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    size_t kept = 0;
    for (size_t i = 0; i < len; i++) {
      const char *entity = text_entity((unsigned char)s[i]);
      if (entity != NULL) {
        luaL_addlstring(&b, s + kept, i - kept);
        luaL_addstring(&b, entity);
        kept = i + 1;
      }
    }
    luaL_addlstring(&b, s + kept, len - kept);
    luaL_pushresult(&b);
  }
  wrap(L, SAFE_HTML_TYPE);
  return 1;
}

static bool is_ascii_alphanumeric (unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
         (c >= 'a' && c <= 'z');
}

/* `escape_attr`: an allowlist. Every ASCII byte but a letter or a digit
 * becomes a decimal character reference, so the value holds no quote,
 * `<`, `>`, `&` or other delimiter that could end a quoted value or
 * open markup. It is for quoted values only: an empty result in an
 * unquoted position leaves no value, and the next attribute is read as
 * its value.
 *
 * A byte of 0x80 or more passes through. A reference per byte would be
 * wrong: the bytes of one UTF-8 character are not code points, and
 * `&#195;&#169;` reads as two Latin-1 characters, not the "e acute" the
 * two bytes make. And no UTF-8 byte of 0x80 or more is a delimiter in
 * any attribute syntax. The cost is the page's encoding: the markup is
 * UTF-8, as a template's is. Bytes that are not UTF-8 pass as they are,
 * and a browser reads each as U+FFFD. */
static int html_escape_attr (lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  bool plain = true;
  for (size_t i = 0; plain && i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    plain = c >= 0x80 || is_ascii_alphanumeric(c);
  }
  if (plain) {
    lua_pushvalue(L, 1);
  } else {
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    size_t kept = 0;
    for (size_t i = 0; i < len; i++) {
      unsigned char c = (unsigned char)s[i];
      if (c >= 0x80 || is_ascii_alphanumeric(c)) {
        continue;
      }
      luaL_addlstring(&b, s + kept, i - kept);
      /* "&#" and up to three digits and ";": the longest, "&#127;",
       * is six bytes. */
      char *at = luaL_prepbuffsize(&b, 8);
      char digits[3];
      int count = 0;
      for (unsigned v = c; v > 0; v /= 10) {
        digits[count++] = (char)('0' + v % 10);
      }
      size_t n = 0;
      at[n++] = '&';
      at[n++] = '#';
      if (count == 0) {
        at[n++] = '0';
      }
      while (count > 0) {
        at[n++] = digits[--count];
      }
      at[n++] = ';';
      luaL_addsize(&b, n);
      kept = i + 1;
    }
    luaL_addlstring(&b, s + kept, len - kept);
    luaL_pushresult(&b);
  }
  wrap(L, SAFE_ATTR_TYPE);
  return 1;
}

/* `trust` and `trust_attr`: the string is taken as already safe. The
 * only door that does not escape, kept apart in name so a review can
 * find every use. */
static int html_trust (lua_State *L) {
  luaL_checktype(L, 1, LUA_TSTRING);
  lua_settop(L, 1);
  wrap(L, SAFE_HTML_TYPE);
  return 1;
}

static int html_trust_attr (lua_State *L) {
  luaL_checktype(L, 1, LUA_TSTRING);
  lua_settop(L, 1);
  wrap(L, SAFE_ATTR_TYPE);
  return 1;
}

/* `raw` and `raw_attr`: the string of a SafeHtml, or of a SafeAttr,
 * the only way back to one. Each refuses the other's type. */
static int html_raw (lua_State *L) {
  push_string_of(L, 1, SAFE_HTML_TYPE);
  return 1;
}

static int html_raw_attr (lua_State *L) {
  push_string_of(L, 1, SAFE_ATTR_TYPE);
  return 1;
}

/* `concat`: the strings of a sequence of SafeHtml, one after another, in
 * one buffer. A table that is no sequence raises, as does an element
 * that is not a SafeHtml (a SafeAttr is not one), naming its place.
 * Elements are read raw: a `__index` or
 * `__len` of the list is not consulted. */
static int html_concat (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Unsigned count = lua_rawlen(L, 1);
  /* A sequence has the keys 1 to its length and no others; `#` of a table
   * with a hole may name either border, so one is refused. */
  lua_Unsigned keys = 0;
  lua_pushnil(L);
  while (lua_next(L, 1) != 0) {
    lua_pop(L, 1);
    if (!lua_isinteger(L, -1) || lua_tointeger(L, -1) < 1 ||
        (lua_Unsigned)lua_tointeger(L, -1) > count) {
      return luaL_error(L, "html: parts is not a sequence");
    }
    keys++;
  }
  if (keys != count) {
    return luaL_error(L, "html: parts is not a sequence");
  }
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (lua_Unsigned i = 1; i <= count; i++) {
    lua_rawgeti(L, 1, (lua_Integer)i);
    if (luaL_testudata(L, -1, SAFE_HTML_TYPE) == NULL) {
      return luaL_error(L, "html: element %I is not a SafeHtml",
                        (lua_Integer)i);
    }
    lua_getiuservalue(L, -1, 1);
    lua_remove(L, -2);
    luaL_addvalue(&b);
  }
  luaL_pushresult(&b);
  wrap(L, SAFE_HTML_TYPE);
  return 1;
}

static const luaL_Reg module[] = {
  {"escape", html_escape},
  {"escape_attr", html_escape_attr},
  {"trust", html_trust},
  {"trust_attr", html_trust_attr},
  {"raw", html_raw},
  {"raw_attr", html_raw_attr},
  {"concat", html_concat},
  {NULL, NULL},
};

int cosmic_open_html (lua_State *L) {
  /* `__metatable` is false so no program can read the metatable to add
   * an operator or a `__tostring` to every safe value. */
  const char *types[] = { SAFE_HTML_TYPE, SAFE_ATTR_TYPE };
  for (size_t i = 0; i < sizeof types / sizeof *types; i++) {
    luaL_newmetatable(L, types[i]);
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "__metatable");
    lua_pop(L, 1);
  }
  luaL_newlib(L, module);
  return 1;
}
