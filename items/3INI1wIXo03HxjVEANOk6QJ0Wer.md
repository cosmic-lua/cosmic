`AGENTS.md`'s cosmo-to-cosmic mapping table sends a reader to a
function that does not exist.

```
$ grep -n "chmod" AGENTS.md
125:| `cosmo.unix.chmod(p, m)` | `require("cosmic.fs").chmod(p, m)` |
$ grep -n "set_mode" cosmic/fs/init.tl
149:  set_mode: function(path: string, mode: integer): boolean, string
283:  set_mode = fs_ops.set_mode,
```

There is no `fs.chmod`. The rename landed with a note in the module's
own doc comment ("Set permission bits (#988: was chmod)"), and the
table AGENTS.md leads with was not carried along. Hit today writing a
probe for `3IMcrrZg`: the mapping table is exactly what a session
reaches for when it needs the cosmic name for a `cosmo.*` call, so the
table being stale costs a round trip through
`cosmic --docs fs` — the checker's error is good ("invalid key
'chmod' in record 'fs'") but the file that sent the session there is
the one that lied.

`AGENTS.md` and `CLAUDE.md` carry the same line at the same number
(125), so both move together.

The rest of the table was spot-checked against the same binary and
holds: `fs.read`, `fs.write`, `fs.join`, `fs.is_file`, `fs.temp_dir`,
`fs.remove_all`, `fs.make_dirs`, `json.decode`, `json.encode`,
`fetch.fetch` all resolve. `chmod` is the only dead row found — but
one dead row is enough to make the reader check every other one, which
is the cost worth removing.

Worth deciding while fixing it, since the answer is what keeps the row
from dying again: a table of names in prose has no gate, and
`_build/snippets_test.tl` cannot see it because the cells are inline
code rather than a fence. Either the row set becomes something a test
resolves against the module records (the `_build/guides_test.tl`
pattern — require the module and assert each named key exists), or the
table shrinks to the two or three mappings that carry real teaching
weight and the rest defers to `cosmic --docs <module>`. Naming which
one is part of the slice.
