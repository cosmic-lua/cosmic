/* JSON text to Lua values and back: yyjson reads, this core writes. */

#ifndef COSMIC_JSON_H
#define COSMIC_JSON_H

#include "lua.h"

/* Opens the table that backs the `cosmic.json` wrapper, registered under
 * the raw `cosmic.internal.json` name. */
int cosmic_open_json (lua_State *L);

#endif
