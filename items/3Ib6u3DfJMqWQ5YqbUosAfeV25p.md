Evidence, 2026-08-29: KSUIDs lead with the timestamp's high bits, so
every id filed the same week shares its first 3-4 display characters —
today's live board shows 3IVLEO8M / 3IVUGuv6 / 3IVRNCFB side by side,
distinguishable only in dense mixed-case base62 tail characters
(l/1/I, O/0 collisions included). The scheme must stay (time-sort and
filename identity are load-bearing); legibility is a display-layer
problem, and an "unambiguous rendering" is necessarily a DERIVED ALIAS
— the id8 is base62 text, so a different alphabet is a different
string. Direction (owner-set): one alias layer, derived by pure
function and never stored — Crockford base32 (0-9 A-Z minus I L O U;
input folds i->1, o->0, case-insensitive) over a HASH of the id (or
its trailing random bytes), NOT the timestamp bits, so the first
chunk is distinct across same-week items; 8 chars = 40 bits, rendered
chunked (Q4TX-9GMD), collision-checked against the live set at
render/resolve time. Rendered BESIDE the raw id in show/next/status
(alias for eyes and typing, id for grep); prefix resolution accepts
either form; commit subjects and item files keep raw ids only — the
log's fixed grammars are a parsing contract (flowstats ships against
them). Color rendering was considered and
rejected outright (owner-set): not needed. Petnames (adjective-noun word
list) were considered and set aside: same mechanics, worse density,
plus a shipped word list — revisit only if cross-conversation
memorability proves worth it.
