/* Text cut into lines and lists of strings sorted by their bytes, for the
 * calls of [`cosmic.shell`] that a file of a megabyte made slow in Lua. */

#ifndef COSMIC_TEXT_H
#define COSMIC_TEXT_H

#include "lua.h"

/* Opens the table that backs [`cosmic.shell`]'s line and sort calls,
 * registered under the raw [`cosmic.internal.text`] name. */
int cosmic_open_text (lua_State *L);

#endif
