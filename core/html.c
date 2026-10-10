#include "html.h"

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "lauxlib.h"

#define SAFE_HTML_TYPE "cosmic.html.SafeHtml"
#define SAFE_ATTR_TYPE "cosmic.html.SafeAttr"
#define SAFE_URL_TYPE "cosmic.html.SafeUrl"
#define SAFE_URL_PART_TYPE "cosmic.html.SafeUrlPart"
#define SAFE_JSON_TYPE "cosmic.html.SafeJson"

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

static bool is_ascii_alpha (unsigned char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

static bool is_slash (unsigned char c) {
  return c == '/' || c == '\\';
}

/* Whether the `len` bytes at `s` are `word`, a lower-case string, in any
 * case. ASCII only: a byte of 0x80 or more never folds to a letter. */
static bool equals_ignoring_case (const char *s, size_t len,
                                  const char *word) {
  if (strlen(word) != len) {
    return false;
  }
  for (size_t i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c >= 'A' && c <= 'Z') {
      c = (unsigned char)(c - 'A' + 'a');
    }
    if (c != (unsigned char)word[i]) {
      return false;
    }
  }
  return true;
}

/* Whether `href` lets the `len` bytes at `s` through, with `schemes`
 * (lower case, ended by NULL) the schemes it allows. Browsers drop
 * leading and trailing C0 controls and spaces, and every tab, newline and
 * carriage return, before they read a scheme, so a text with a control
 * byte, a DEL, or a space at either end is refused rather than read as
 * the browser would. What is left is read as a browser reads it:
 *
 * - a colon before the first `/`, `?` or `#` makes what precedes it the
 *   scheme, which must be a letter and then letters, digits, `+`, `-` or
 *   `.`, and be one of `schemes` in any case. A colon there after
 *   anything else is refused, not read as a relative path as a browser
 *   would read `%6Aavascript:` or `1a:`: another reader of the URL may
 *   take it for a scheme;
 * - with no scheme, the text is a relative reference, refused only when
 *   it begins with two of `/` and `\`, which a browser reads as a host
 *   (`//h`, `\\h`, `/\h`, `\/h`). */
static bool url_allowed (const char *s, size_t len,
                         const char *const *schemes) {
  if (len > 0 && (s[0] == ' ' || s[len - 1] == ' ')) {
    return false;
  }
  for (size_t i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x20 || c == 0x7f) {
      return false;
    }
  }
  size_t colon = 0;
  while (colon < len && s[colon] != ':' && s[colon] != '/' &&
         s[colon] != '?' && s[colon] != '#') {
    colon++;
  }
  if (colon < len && s[colon] == ':') {
    if (!is_ascii_alpha((unsigned char)s[0])) {
      return false;
    }
    for (size_t i = 1; i < colon; i++) {
      unsigned char c = (unsigned char)s[i];
      if (!is_ascii_alphanumeric(c) && c != '+' && c != '-' && c != '.') {
        return false;
      }
    }
    for (; *schemes != NULL; schemes++) {
      if (equals_ignoring_case(s, colon, *schemes)) {
        return true;
      }
    }
    return false;
  }
  return !(len >= 2 && is_slash((unsigned char)s[0]) &&
           is_slash((unsigned char)s[1]));
}

/* Pushes the string at `index` when [`url_allowed`] with `schemes`, else
 * `about:invalid`, as a SafeUrl. The text is not attribute-escaped: a
 * SafeUrl is a URL, and the page escapes it where it puts it in an
 * attribute. */
static int wrap_allowed_url (lua_State *L, int index,
                             const char *const *schemes) {
  size_t len;
  const char *s = luaL_checklstring(L, index, &len);
  if (url_allowed(s, len, schemes)) {
    lua_pushvalue(L, index);
  } else {
    lua_pushliteral(L, "about:invalid");
  }
  wrap(L, SAFE_URL_TYPE);
  return 1;
}

/* `href`: a whole URL from data, http, https or mailto or relative. */
static int html_href (lua_State *L) {
  static const char *const schemes[] = { "http", "https", "mailto", NULL };
  return wrap_allowed_url(L, 1, schemes);
}

/* `local_href`: a relative reference only, so no scheme at all. */
static int html_local_href (lua_State *L) {
  static const char *const schemes[] = { NULL };
  return wrap_allowed_url(L, 1, schemes);
}

static int html_trust_url (lua_State *L) {
  luaL_checktype(L, 1, LUA_TSTRING);
  lua_settop(L, 1);
  wrap(L, SAFE_URL_TYPE);
  return 1;
}

static int html_raw_url (lua_State *L) {
  push_string_of(L, 1, SAFE_URL_TYPE);
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

/* The length of the sequence at `index`, which raises, naming `what`, for
 * a table that is no sequence. A sequence has the keys 1 to its length
 * and no others; `#` of a table with a hole may name either border, so
 * one is refused. */
static lua_Unsigned check_sequence (lua_State *L, int index,
                                    const char *what) {
  luaL_checktype(L, index, LUA_TTABLE);
  lua_Unsigned count = lua_rawlen(L, index);
  lua_Unsigned keys = 0;
  lua_pushnil(L);
  while (lua_next(L, index) != 0) {
    lua_pop(L, 1);
    if (!lua_isinteger(L, -1) || lua_tointeger(L, -1) < 1 ||
        (lua_Unsigned)lua_tointeger(L, -1) > count) {
      return (lua_Unsigned)luaL_error(L, "html: %s is not a sequence", what);
    }
    keys++;
  }
  if (keys != count) {
    return (lua_Unsigned)luaL_error(L, "html: %s is not a sequence", what);
  }
  return count;
}

/* `concat`: the strings of a sequence of SafeHtml, one after another, in
 * one buffer. A table that is no sequence raises, as does an element
 * that is not a SafeHtml (a SafeAttr is not one), naming its place.
 * Elements are read raw: a `__index` or
 * `__len` of the list is not consulted. */
static int html_concat (lua_State *L) {
  lua_Unsigned count = check_sequence(L, 1, "parts");
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

static bool is_url_unreserved (unsigned char c) {
  return is_ascii_alphanumeric(c) || c == '-' || c == '.' || c == '_' ||
         c == '~';
}

/* Pushes the string at the absolute `index` with every byte but the
 * unreserved ones (`A-Z a-z 0-9 - . _ ~`) written as `%` and two
 * uppercase hex digits, as [`Url.escape`] writes them. A string with none
 * is its own escape. With `dot_rule`, a string that is exactly `.` or
 * `..` is written `%252E` or `%252E%252E`: a browser takes a path
 * segment of `.`, `..` or their `%2e` spellings for a dot segment, so no
 * spelling of the dots can stand for the value, and the percent sign
 * itself is escaped to make a segment that names no one. */
static void push_url_escaped (lua_State *L, int index, bool dot_rule) {
  size_t len;
  const char *s = lua_tolstring(L, index, &len);
  if (dot_rule && len > 0 && len <= 2 && s[len - 1] == '.' &&
      (len == 1 || s[0] == '.')) {
    lua_pushstring(L, len == 1 ? "%252E" : "%252E%252E");
    return;
  }
  bool plain = true;
  for (size_t i = 0; plain && i < len; i++) {
    plain = is_url_unreserved((unsigned char)s[i]);
  }
  if (plain) {
    lua_pushvalue(L, index);
    return;
  }
  static const char hex[] = "0123456789ABCDEF";
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  size_t kept = 0;
  for (size_t i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if (is_url_unreserved(c)) {
      continue;
    }
    luaL_addlstring(&b, s + kept, i - kept);
    luaL_addchar(&b, '%');
    luaL_addchar(&b, hex[c >> 4]);
    luaL_addchar(&b, hex[c & 15]);
    kept = i + 1;
  }
  luaL_addlstring(&b, s + kept, len - kept);
  luaL_pushresult(&b);
}

/* Leaves argument 1, a string or a number, as a string in slot 1. */
static void check_text (lua_State *L) {
  int kind = lua_type(L, 1);
  if (kind != LUA_TSTRING && kind != LUA_TNUMBER) {
    luaL_typeerror(L, 1, "string or number");
  }
  lua_settop(L, 1);
  lua_tolstring(L, 1, NULL);
}

/* `url_part`: one piece of a URL (a path segment, a query name or value,
 * a fragment) from data; see [`push_url_escaped`]. */
static int html_url_part (lua_State *L) {
  check_text(L);
  push_url_escaped(L, 1, true);
  wrap(L, SAFE_URL_PART_TYPE);
  return 1;
}

/* `url_query`: `name=value` pairs joined by `&`, in order, each name and
 * value escaped as a part but for the dot rule, which is about path
 * segments. A pair that is not two strings answers `nil` and why. */
static int html_url_query (lua_State *L) {
  lua_Unsigned count = check_sequence(L, 1, "pairs");
  for (lua_Unsigned i = 1; i <= count; i++) {
    lua_rawgeti(L, 1, (lua_Integer)i);
    bool pair = lua_type(L, -1) == LUA_TTABLE && lua_rawlen(L, -1) == 2;
    if (pair) {
      lua_rawgeti(L, -1, 1);
      lua_rawgeti(L, -2, 2);
      pair = lua_type(L, -2) == LUA_TSTRING && lua_type(L, -1) == LUA_TSTRING;
      lua_pop(L, 2);
    }
    if (!pair) {
      lua_pushnil(L);
      lua_pushfstring(L, "html: pair %I is not two strings", (lua_Integer)i);
      return 2;
    }
    lua_pop(L, 1);
  }
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (lua_Unsigned i = 1; i <= count; i++) {
    for (int half = 1; half <= 2; half++) {
      if (half == 2) {
        luaL_addchar(&b, '=');
      } else if (i > 1) {
        luaL_addchar(&b, '&');
      }
      lua_rawgeti(L, 1, (lua_Integer)i);
      lua_rawgeti(L, -1, half);
      push_url_escaped(L, lua_gettop(L), false);
      lua_remove(L, -3);
      lua_remove(L, -2);
      luaL_addvalue(&b);
    }
  }
  luaL_pushresult(&b);
  wrap(L, SAFE_URL_PART_TYPE);
  return 1;
}

static int html_raw_url_part (lua_State *L) {
  push_string_of(L, 1, SAFE_URL_PART_TYPE);
  return 1;
}

static bool is_ascii_digit (unsigned char c) {
  return c >= '0' && c <= '9';
}

/* Adds `\` and the code of `c` in lowercase hex and a space, as CSS reads
 * a character it must escape, with the backslash and the space written
 * as character references for an attribute. */
static void add_css_escape (luaL_Buffer *b, unsigned char c) {
  static const char hex[] = "0123456789abcdef";
  luaL_addstring(b, "&#92;");
  if (c >= 16) {
    luaL_addchar(b, hex[c >> 4]);
  }
  luaL_addchar(b, hex[c & 15]);
  luaL_addstring(b, "&#32;");
}

/* `escape_css_attr`: `CSS.escape` of the string, then `escape_attr` of
 * that, in one pass, so the result goes in a quoted attribute as it is.
 * Letters, digits and bytes of 0x80 or more pass; `-` and `_` pass as CSS
 * and are character references as attribute text. A digit first, or
 * after a leading `-`, a lone `-`, and every other ASCII byte is a hex
 * escape; NUL is U+FFFD. The escape ends in a space, so a literal space
 * after the slot is a second space and stays a combinator. The slot may
 * be mid-identifier, where escaping a leading digit does no harm. */
static int html_escape_css_attr (lua_State *L) {
  check_text(L);
  size_t len;
  const char *s = lua_tolstring(L, 1, &len);
  bool plain = true;
  for (size_t i = 0; plain && i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    plain = c >= 0x80 || is_ascii_alphanumeric(c);
  }
  if (plain && len > 0 && is_ascii_digit((unsigned char)s[0])) {
    plain = false;
  }
  if (plain) {
    lua_pushvalue(L, 1);
  } else {
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    for (size_t i = 0; i < len; i++) {
      unsigned char c = (unsigned char)s[i];
      bool leads_identifier = i == 0 || (i == 1 && s[0] == '-');
      if (c == 0) {
        luaL_addstring(&b, "\xef\xbf\xbd");
      } else if (c == '_') {
        luaL_addstring(&b, "&#95;");
      } else if (c == '-' && len > 1) {
        luaL_addstring(&b, "&#45;");
      } else if (c >= 0x80 || (is_ascii_alphanumeric(c) &&
                               !(is_ascii_digit(c) && leads_identifier))) {
        luaL_addchar(&b, (char)c);
      } else {
        add_css_escape(&b, c);
      }
    }
    luaL_pushresult(&b);
  }
  wrap(L, SAFE_ATTR_TYPE);
  return 1;
}

/* `trust_json` is the one door that takes text as JSON unchecked. The
 * module's wrapper checks the text before it calls it and does not offer
 * it. */
static int html_trust_json (lua_State *L) {
  luaL_checktype(L, 1, LUA_TSTRING);
  lua_settop(L, 1);
  wrap(L, SAFE_JSON_TYPE);
  return 1;
}

static int html_raw_json (lua_State *L) {
  push_string_of(L, 1, SAFE_JSON_TYPE);
  return 1;
}

static const luaL_Reg module[] = {
  {"escape", html_escape},
  {"escape_attr", html_escape_attr},
  {"trust", html_trust},
  {"trust_attr", html_trust_attr},
  {"raw", html_raw},
  {"raw_attr", html_raw_attr},
  {"href", html_href},
  {"trust_url", html_trust_url},
  {"raw_url", html_raw_url},
  {"concat", html_concat},
  {"url_part", html_url_part},
  {"url_query", html_url_query},
  {"raw_url_part", html_raw_url_part},
  {"local_href", html_local_href},
  {"escape_css_attr", html_escape_css_attr},
  {"trust_json", html_trust_json},
  {"raw_json", html_raw_json},
  {NULL, NULL},
};

int cosmic_open_html (lua_State *L) {
  /* `__metatable` is false so no program can read the metatable to add
   * an operator or a `__tostring` to every safe value. */
  const char *types[] = { SAFE_HTML_TYPE, SAFE_ATTR_TYPE,
    SAFE_URL_TYPE, SAFE_URL_PART_TYPE, SAFE_JSON_TYPE };
  for (size_t i = 0; i < sizeof types / sizeof *types; i++) {
    luaL_newmetatable(L, types[i]);
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "__metatable");
    lua_pop(L, 1);
  }
  luaL_newlib(L, module);
  return 1;
}
