#ifndef COSMIC_HTTP_H
#define COSMIC_HTTP_H

#include "lauxlib.h"

/* Opens the raw `cosmic.internal.http` module: a single function,
 * `open`, returning a userdata `Handle` with `status`, `url`,
 * `headers`, `read` and `close` methods -- the same "raw module
 * registered under cosmic.internal.*" shape core/sqlite.c uses, wired
 * into core/store.c and core/main.c the same way. See cosmic/http.tl
 * for the typed wrapper this backs. */
int cosmic_open_http(lua_State *L);

#endif /* COSMIC_HTTP_H */
