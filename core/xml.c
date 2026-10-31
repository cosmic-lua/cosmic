#include "xml.h"

#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

/* Before expat.h, which reads XML_GE: the core sees expat through the
 * configuration it was built with. */
#include "expat_config.h"
#include "expat.h"
#include "fail.h"
#include "lauxlib.h"
#include "memory.h"

#define PARSER_TYPE "cosmic.xml.parser"

/* The stack slot of the table a call to `feed` or `finish` fills: the
 * parser is 1 and the chunk 2. */
#define EVENTS 3

/* What an event is, in the order `kind_names` names them. */
enum kind { START, END, TEXT, COMMENT, INSTRUCTION };

static const char *const kind_names[] = {
  "start", "end", "text", "comment", "instruction",
};

/* One event as expat hands it over: pointers into expat's own memory,
 * good only until the handler that made it returns. */
struct event {
  enum kind kind;
  const XML_Char *name;
  const XML_Char **attributes;
  const char *text;
  size_t len;
};

/* A parser and what one call to it has collected. `parser` is NULL once
 * the parser is finished: by `finish`, a failure, a raise inside a
 * call, `__close` or `__gc`.
 *
 * No Lua code runs while expat holds the C stack, and nothing raises
 * across it: each event is appended under `lua_pcall`, and a raise there
 * stops expat and is raised again once `XML_Parse` has returned. */
struct parser {
  XML_Parser parser;
  lua_State *L;
  /* How many events the call's table holds. */
  lua_Integer count;
  /* What `lua_pcall` answered for the last append; past LUA_OK, the
   * error it left is on the stack's top. */
  int status;
  /* Character data not yet appended: expat hands it over in pieces,
   * which become one `text` event when anything else comes, or the
   * input ends, so where a chunk ends never splits one. */
  char *text;
  size_t len, cap;
  bool out_of_memory;
};

static void *xml_malloc (size_t size) { return cosmic_malloc(size); }

static void *xml_realloc (void *block, size_t size) {
  return cosmic_realloc(block, size);
}

static void xml_free (void *block) { cosmic_free(block); }

static const XML_Memory_Handling_Suite memory = {xml_malloc, xml_realloc,
  xml_free};

static void release (struct parser *p) {
  if (p->parser != NULL) {
    XML_ParserFree(p->parser);
    p->parser = NULL;
  }
  cosmic_free(p->text);
  p->text = NULL;
  p->len = 0;
  p->cap = 0;
}

/* A name as Lua sees it. A parser asked for namespaces is given names
 * as expat writes them, `uri}local`, and answers them in Clark's
 * notation, `{uri}local`; an unqualified name has no `}`. */
static void push_name (lua_State *L, const XML_Char *name) {
  if (strchr(name, '}') != NULL) {
    lua_pushfstring(L, "{%s", name);
  } else {
    lua_pushstring(L, name);
  }
}

/* Appends the event at 2 to the table at 1, as the event `count` at 3;
 * run under `lua_pcall`, so a raise stops at `deliver`. */
static int append_event (lua_State *L) {
  const struct event *ev = lua_touserdata(L, 2);
  lua_Integer index = lua_tointeger(L, 3);
  lua_createtable(L, 0, 3);
  lua_pushstring(L, kind_names[ev->kind]);
  lua_setfield(L, -2, "kind");
  if (ev->name != NULL) {
    push_name(L, ev->name);
    lua_setfield(L, -2, "name");
  }
  if (ev->attributes != NULL) {
    lua_newtable(L);
    for (const XML_Char **a = ev->attributes; a[0] != NULL; a += 2) {
      push_name(L, a[0]);
      lua_pushstring(L, a[1]);
      lua_rawset(L, -3);
    }
    lua_setfield(L, -2, "attributes");
  }
  if (ev->text != NULL) {
    lua_pushlstring(L, ev->text, ev->len);
    lua_setfield(L, -2, "text");
  }
  lua_rawseti(L, 1, index);
  return 0;
}

/* Appends `ev` to the call's table. After a failure nothing more is
 * appended, and expat is told to stop. */
static void deliver (struct parser *p, const struct event *ev) {
  if (p->status != LUA_OK || p->out_of_memory) return;
  lua_State *L = p->L;
  /* None of these pushes allocates. */
  lua_pushcfunction(L, append_event);
  lua_pushvalue(L, EVENTS);
  lua_pushlightuserdata(L, (void *)ev);
  lua_pushinteger(L, p->count + 1);
  p->status = lua_pcall(L, 3, 0, 0);
  if (p->status == LUA_OK) {
    p->count++;
  } else {
    XML_StopParser(p->parser, XML_FALSE);
  }
}

/* Appends the character data held back, if any, as one `text` event. */
static void flush_text (struct parser *p) {
  if (p->len == 0) return;
  struct event ev = {TEXT, NULL, NULL, p->text, p->len};
  deliver(p, &ev);
  p->len = 0;
}

static void on_start (void *data, const XML_Char *name,
                      const XML_Char **attributes) {
  struct parser *p = data;
  flush_text(p);
  struct event ev = {START, name, attributes, NULL, 0};
  deliver(p, &ev);
}

static void on_end (void *data, const XML_Char *name) {
  struct parser *p = data;
  flush_text(p);
  struct event ev = {END, name, NULL, NULL, 0};
  deliver(p, &ev);
}

static void on_text (void *data, const XML_Char *s, int len) {
  struct parser *p = data;
  if (p->out_of_memory || len <= 0) return;
  size_t n = (size_t)len;
  if (n > p->cap - p->len) {
    size_t cap = p->cap < 256 ? 256 : p->cap;
    while (cap - p->len < n) {
      if (cap > SIZE_MAX / 2) cap = SIZE_MAX;
      else cap *= 2;
    }
    char *grown = cosmic_realloc(p->text, cap);
    if (grown == NULL) {
      p->out_of_memory = true;
      XML_StopParser(p->parser, XML_FALSE);
      return;
    }
    p->text = grown;
    p->cap = cap;
  }
  memcpy(p->text + p->len, s, n);
  p->len += n;
}

static void on_comment (void *data, const XML_Char *text) {
  struct parser *p = data;
  flush_text(p);
  struct event ev = {COMMENT, NULL, NULL, text, strlen(text)};
  deliver(p, &ev);
}

static void on_instruction (void *data, const XML_Char *target,
                            const XML_Char *text) {
  struct parser *p = data;
  flush_text(p);
  struct event ev = {INSTRUCTION, target, NULL, text, strlen(text)};
  deliver(p, &ev);
}

/* `parser(namespaces)`: a parser, or nil and why. */
static int xml_parser (lua_State *L) {
  bool namespaces = lua_toboolean(L, 1);
  struct parser *p = lua_newuserdatauv(L, sizeof *p, 0);
  memset(p, 0, sizeof *p);
  luaL_setmetatable(L, PARSER_TYPE);
  static const XML_Char separator[] = {'}', '\0'};
  p->parser = XML_ParserCreate_MM(NULL, &memory,
                                  namespaces ? separator : NULL);
  if (p->parser == NULL) {
    lua_pushnil(L);
    lua_pushliteral(L, "xml: out of memory");
    return 2;
  }
  XML_SetUserData(p->parser, p);
  XML_SetElementHandler(p->parser, on_start, on_end);
  XML_SetCharacterDataHandler(p->parser, on_text);
  XML_SetCommentHandler(p->parser, on_comment);
  XML_SetProcessingInstructionHandler(p->parser, on_instruction);
  return cosmic_succeeded(L);
}

static struct parser *check_open (lua_State *L) {
  struct parser *p = luaL_checkudata(L, 1, PARSER_TYPE);
  if (p->parser == NULL) luaL_error(L, "xml: the parser is finished");
  return p;
}

/* Hands `len` bytes at `s` to expat, the last of the input when `final`,
 * in pieces `XML_Parse` can count. False when it refused them, a raise
 * was caught, or memory ran out. */
static bool parse (struct parser *p, const char *s, size_t len, bool final) {
  do {
    size_t n = len < (size_t)INT_MAX ? len : (size_t)INT_MAX;
    len -= n;
    if (XML_Parse(p->parser, s, (int)n, final && len == 0) !=
        XML_STATUS_OK) {
      return false;
    }
    s += n;
  } while (len > 0);
  return p->status == LUA_OK && !p->out_of_memory;
}

/* The answer to a call that collected events into the table at EVENTS:
 * the table and "", or nil and why. Any failure finishes the parser; a
 * raise caught inside the call is raised again. */
static int answer (lua_State *L, struct parser *p, bool parsed) {
  p->L = NULL;
  if (p->status != LUA_OK) {
    release(p);
    return lua_error(L);
  }
  if (p->out_of_memory) {
    release(p);
    lua_pushnil(L);
    lua_pushliteral(L, "xml: out of memory");
    return 2;
  }
  if (!parsed) {
    enum XML_Error code = XML_GetErrorCode(p->parser);
    uint64_t line = XML_GetCurrentLineNumber64(p->parser);
    uint64_t column = XML_GetCurrentColumnNumber64(p->parser);
    /* The message is copied before the parser it describes is freed;
     * expat's error strings are its own constants. */
    lua_pushnil(L);
    lua_pushfstring(L, "xml: line %I, column %I: %s", (lua_Integer)line,
                    (lua_Integer)column + 1, XML_ErrorString(code));
    release(p);
    return 2;
  }
  lua_pushvalue(L, EVENTS);
  return cosmic_succeeded(L);
}

/* Starts a call that collects events: the table at EVENTS, empty. */
static void begin (lua_State *L, struct parser *p) {
  lua_settop(L, EVENTS - 1);
  lua_newtable(L);
  p->L = L;
  p->count = 0;
  p->status = LUA_OK;
}

/* `feed(parser, chunk)`: the events `chunk` completes. */
static int parser_feed (lua_State *L) {
  struct parser *p = check_open(L);
  size_t len;
  const char *s = luaL_checklstring(L, 2, &len);
  begin(L, p);
  bool parsed = parse(p, s, len, false);
  return answer(L, p, parsed);
}

/* `finish(parser)`: the input has ended; the events it completes, and
 * the parser is finished. */
static int parser_finish (lua_State *L) {
  struct parser *p = check_open(L);
  begin(L, p);
  bool parsed = parse(p, "", 0, true);
  if (parsed) {
    flush_text(p);
    parsed = p->status == LUA_OK;
  }
  int results = answer(L, p, parsed);
  release(p);
  return results;
}

/* `__close` and `__gc`: the parser is finished and its memory freed. */
static int parser_close (lua_State *L) {
  release(luaL_checkudata(L, 1, PARSER_TYPE));
  return 0;
}

static const luaL_Reg parser_methods[] = {
  {"feed", parser_feed},
  {"finish", parser_finish},
  {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"parser", xml_parser},
  {NULL, NULL},
};

int cosmic_open_xml (lua_State *L) {
  luaL_newmetatable(L, PARSER_TYPE);
  lua_pushcfunction(L, parser_close);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, parser_close);
  lua_setfield(L, -2, "__close");
  luaL_newlib(L, parser_methods);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, module);
  return 1;
}
