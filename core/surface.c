#include "surface.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>

#include "lauxlib.h"
#include "lualib.h"
#include "store.h"
#include "syscalls.h"

/* A name that was removed says what took its place, at the site that
 * reached for it, rather than in a document somewhere else. */
struct replacement {
  const char *name;
  const char *hint;
};

static const struct replacement replacements[] = {
    {"io", "io is not available: files are cosmic.fs, and the standard "
           "streams are cosmic.fs.stdout, .stderr and .stdin"},
    {"os", "os is not available: time is cosmic.time, the environment is "
           "cosmic.env, and processes are cosmic.proc"},
    {"debug", "debug is not available: a traceback is cosmic.errors.trace"},
    {"dofile", "dofile is not available: a module comes from require, and "
               "a file's bytes come from cosmic.fs.read"},
    {"loadfile", "loadfile is not available: a module comes from require, "
                 "and a file's bytes come from cosmic.fs.read"},
    {"require", NULL},
    {NULL, NULL},
};

/* `print` over the syscall table, so every byte the process writes goes
 * through one door. */
static int surface_print(lua_State *L) {
  int count = lua_gettop(L);
  luaL_Buffer line;
  luaL_buffinit(L, &line);
  for (int i = 1; i <= count; i++) {
    size_t len;
    const char *text = luaL_tolstring(L, i, &len);
    if (i > 1) {
      luaL_addchar(&line, '\t');
    }
    luaL_addlstring(&line, text, len);
    lua_pop(L, 1);
  }
  luaL_addchar(&line, '\n');
  luaL_pushresult(&line);

  size_t len;
  const char *text = lua_tolstring(L, -1, &len);
  size_t at = 0;
  while (at < len) {
    ssize_t put = write(STDOUT_FILENO, text + at, len - at);
    if (put < 0) {
      if (errno == EINTR) {
        continue;
      }
      return luaL_error(L, "print: %s", strerror(errno));
    }
    at += (size_t)put;
  }
  lua_pop(L, 1);
  return 0;
}

/* A traceback, which is the one thing `debug` is kept for above the
 * private binding: a program reporting a failure needs to say where it
 * happened. */
static int surface_trace(lua_State *L) {
  const char *message = luaL_optstring(L, 1, NULL);
  int level = (int)luaL_optinteger(L, 2, 1);
  luaL_traceback(L, L, message, level);
  return 1;
}

static int open_errors(lua_State *L) {
  lua_createtable(L, 0, 1);
  lua_pushcfunction(L, surface_trace);
  lua_setfield(L, -2, "trace");
  return 1;
}

/* Raised when a program reaches for a name this surface removed. */
static int surface_missing(lua_State *L) {
  const char *name = lua_tostring(L, 2);
  lua_getfield(L, lua_upvalueindex(1), name == NULL ? "" : name);
  if (lua_isstring(L, -1)) {
    return lua_error(L);
  }
  lua_pop(L, 1);
  lua_pushnil(L);
  return 1;
}

static void open_library(lua_State *L, const char *name, lua_CFunction opener,
                         int global) {
  luaL_requiref(L, name, opener, global);
  lua_pop(L, 1);
}

/* Moves a library out of `package.loaded` and into the private table, so
 * neither a global nor `require` can reach it. */
static void make_private(lua_State *L, const char *name) {
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_getfield(L, -1, name);
  lua_getfield(L, LUA_REGISTRYINDEX, COSMIC_PRIVATE);
  lua_pushvalue(L, -2);
  lua_setfield(L, -2, name);
  lua_pop(L, 2);
  lua_pushnil(L);
  lua_setfield(L, -2, name);
  lua_pop(L, 1);
}

static void clear_field(lua_State *L, const char *table, const char *field) {
  lua_getglobal(L, table);
  lua_pushnil(L);
  lua_setfield(L, -2, field);
  lua_pop(L, 1);
}

lua_State *cosmic_surface_open(void) {
  lua_State *L = luaL_newstate();
  if (L == NULL) {
    return NULL;
  }

  lua_newtable(L);
  lua_setfield(L, LUA_REGISTRYINDEX, COSMIC_PRIVATE);

  open_library(L, LUA_GNAME, luaopen_base, 1);
  open_library(L, LUA_LOADLIBNAME, luaopen_package, 1);
  open_library(L, LUA_COLIBNAME, luaopen_coroutine, 1);
  open_library(L, LUA_TABLIBNAME, luaopen_table, 1);
  open_library(L, LUA_STRLIBNAME, luaopen_string, 1);
  open_library(L, LUA_MATHLIBNAME, luaopen_math, 1);
  open_library(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);

  /* Opened, then taken out of reach: boot mode and the private binding
   * are the only callers, and they hold them directly. */
  open_library(L, LUA_IOLIBNAME, luaopen_io, 0);
  open_library(L, LUA_OSLIBNAME, luaopen_os, 0);
  open_library(L, LUA_DBLIBNAME, luaopen_debug, 0);
  make_private(L, LUA_IOLIBNAME);
  make_private(L, LUA_OSLIBNAME);
  make_private(L, LUA_DBLIBNAME);

  /* `debug` was just taken out of reach above; the coverage collector
   * still needs the real table, so it is fetched back out of the
   * private binding and registered as the raw value behind
   * `cosmic.internal.debug` -- the same handoff `cosmic.store` and
   * `cosmic.sqlite` already get through the store searcher's trust
   * check (core/store.c's store_searcher). This runs on every open,
   * boot and normal alike, since cosmic_surface_open runs before
   * either path branches. */
  lua_getfield(L, LUA_REGISTRYINDEX, COSMIC_PRIVATE);
  lua_getfield(L, -1, LUA_DBLIBNAME);
  lua_remove(L, -2);
  cosmic_store_set_raw(L, "cosmic.internal.debug");

  lua_pushnil(L);
  lua_setglobal(L, "dofile");
  lua_pushnil(L);
  lua_setglobal(L, "loadfile");

  /* A file path never resolves to a module: the database is the only
   * module source, and the searcher that reads it is installed later. */
  clear_field(L, LUA_LOADLIBNAME, "path");
  clear_field(L, LUA_LOADLIBNAME, "cpath");
  clear_field(L, LUA_LOADLIBNAME, "loadlib");
  clear_field(L, LUA_LOADLIBNAME, "searchpath");

  lua_pushcfunction(L, surface_print);
  lua_setglobal(L, "print");

  lua_getfield(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, cosmic_open_syscalls);
  lua_setfield(L, -2, "cosmic.sys");
  lua_pushcfunction(L, open_errors);
  lua_setfield(L, -2, "cosmic.internal.errors");
  lua_pop(L, 1);

  lua_newtable(L);
  for (const struct replacement *r = replacements; r->name != NULL; r++) {
    if (r->hint == NULL) {
      continue;
    }
    lua_pushstring(L, r->hint);
    lua_setfield(L, -2, r->name);
  }
  lua_pushglobaltable(L);
  lua_newtable(L);
  lua_pushvalue(L, -3);
  lua_pushcclosure(L, surface_missing, 1);
  lua_setfield(L, -2, "__index");
  lua_setmetatable(L, -2);
  lua_pop(L, 2);

  return L;
}
