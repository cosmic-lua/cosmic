#ifndef COSMIC_HTTP_H
#define COSMIC_HTTP_H

#include "lauxlib.h"

/* Opens the raw `cosmic.internal.http` module: a single function,
 * `open`, returning a userdata `Handle` with `status`, `url`,
 * `headers`, `read`, `sent` and `close` methods -- the same "raw module
 * registered under cosmic.internal.*" shape core/sqlite.c uses, listed
 * in core/store.c's `raw_modules` the same way. See cosmic/http.tl for
 * the typed wrapper this backs. */
int cosmic_open_http (lua_State *L);

#ifdef COSMIC_CHECKED
/* The checked core's count of transfers holding curl state: made by
 * `open`, and not yet released by a close, a failure or the collector.
 * `testing.live_transfers` reads it. */
extern lua_Integer cosmic_http_live_transfers;
#endif

#endif /* COSMIC_HTTP_H */
