/* Strings that are safe to put in HTML, as opaque userdata: one type for
 * markup in element content (`SafeHtml`) and one for a value inside an
 * attribute (`SafeAttr`). A value is made only here, by escaping or by
 * `trust`, so having one is the proof the string was handled for its
 * context. */

#ifndef COSMIC_HTML_H
#define COSMIC_HTML_H

#include "lua.h"

/* Opens the table that backs the [`cosmic.html`] wrapper, registered
 * under the raw [`cosmic.internal.html`] name. */
int cosmic_open_html (lua_State *L);

#endif
