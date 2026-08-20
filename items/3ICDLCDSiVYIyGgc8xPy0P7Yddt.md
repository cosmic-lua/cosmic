## Evidence

2026-08-20 audit at main 0b2907b9, by reading `_build/dupes.tl` (the
gate is green today, so these are latent). Three normalizer defects:
(1) :69 strips comments with `raw:gsub("%-%-.*$", "")` with no
string-literal awareness, so bodies containing `"--make ci"`-style
literals — common in exactly the `_cli` trees the gate scans — are
truncated before hashing: two distinct bodies differing only after a
`--` inside a string collide, and a genuine difference there is
erased. (2) :47-57 `param_names` stops at the first `)` so function-
typed parameters truncate the list, and comma-splitting treats words
inside tuple/map types as parameter names — `(a: {string, integer})`
yields "params" `a` and `integer`, and :78 then renames every
standalone `integer` token in the body. (3) :98 body extraction
truncates at a line that is exactly `end` inside a long string.
Separate from the scan-scope gap already captured (3IBuI5jY: _fuzz/
not scanned).
