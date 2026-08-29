Evidence, 2026-08-29: KSUIDs lead with the timestamp's high bits, so
every id filed the same week shares its first 3-4 display characters —
today's live board shows 3IVLEO8M / 3IVUGuv6 / 3IVRNCFB side by side,
distinguishable only in dense mixed-case base62 tail characters
(l/1/I, O/0 collisions included). The scheme must stay (time-sort and
filename identity are load-bearing); legibility is a display-layer
problem, three independently-landable layers, all DERIVED from the id
and never stored: (1) chunk the rendered prefix (3Ib4-KH0q) in every
board render; (2) a hash-derived adjective-noun petname from a small
shipped word list, printed beside the id in show/next/status and
accepted by prefix resolution as an alias; (3) stable per-id ANSI
color via cosmic.ansi in tty renders, gated on NO_COLOR. Commit
subjects and item files keep raw ids — the log's fixed grammars are a
parsing contract (flowstats ships against them).
