/* XML text to a stream of events: expat reads, this core hands each event
 * to Lua. */

#ifndef COSMIC_XML_H
#define COSMIC_XML_H

#include "lua.h"

/* Opens the table that backs the [`cosmic.xml`] wrapper, registered under
 * the raw [`cosmic.internal.xml`] name. */
int cosmic_open_xml (lua_State *L);

#endif
