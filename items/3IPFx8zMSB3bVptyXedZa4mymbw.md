Nothing catches a `-- cast: <reason>` comment left behind by a refactor
that removed the cast it justified. `_cli/lint.tl`'s
`check_cast_justification` only asks the question in one direction — for
each `as` token, is there a reason? — so a reason with no `as` under it
is invisible to the gate, and until the census counts `as` tokens
(board `3IOK5DUv`) it is counted as debt by `_build/casts.tl`.

Measured 2026-08-25 against `1dc5aa14`: `cosmic/compress.tl:48` and
`cosmic/compress.tl:68` both read
`-- cast: same word set; the binding names its enum independently`, each
directly above a `local result, err = cosmo.Deflate/Inflate(...)` line
that holds no cast. `grep -n " as " cosmic/compress.tl` prints only prose
matches. A walk of `_build/casts.tl`'s `TREES` counting `tl.lex` `as`
tokens per file, run beside `casts.count(".")`, reported
`lex total=356 files=116 ; grep total=363 files=119`, and
`cosmic/compress.tl` was the only file whose whole row (2) was orphaned
comments rather than quoted syntax.

The shape of a fix: a second direction in `check_cast_justification` (or
its own check beside it) that flags a line matching
`^%s*%-%- cast: %S` when the line below it carries no `as` token, and a
trailing `-- cast:` on a line that carries no `as` token. The lexer scan
it needs is already there — `cast_lines` gives the set of lines holding a
cast, so the check is a set difference against the lines holding a
reason. The false-positive risk to settle first is prose: a `---` doc
comment quoting the syntax (`_build/casts.tl:6`, `_cli/lint.tl:65`) would
trip a naive version, so the check has to distinguish a reason comment
from a sentence that mentions one.

`3IOK5DUv` deletes the two `cosmic/compress.tl` comments and stops the
census counting them, so this item is about preventing the next
occurrence, not cleaning up the current one.
