## Evidence

Found by the builder of item `3IfBBCiSB6QBLluI6ziSo6ce5pY` («So6c_e5pY»,
"cosmic.doc.search: move --docs off substring matching onto FTS5 and
bm25") while attempting to pull it: that item's premise — "With FTS5
compiled into the library" — does not hold against the cosmos release
this repo currently pins.

`3p/cosmos/cosmos_pin.tl` on `main` pins `version =
"2026.08.31-6dfa6728a"`. Built against it,
`SELECT name FROM pragma_module_list WHERE name = 'fts5'` returns no
row — FTS5 is absent. FTS5 was added to cosmopolitan's *library*
build (not just the shell) by upstream commit `d88e994f`
("sqlite3: name the vendored ext/misc extensions in a registry...",
`third_party/sqlite3/BUILD.mk`'s `-DSQLITE_ENABLE_FTS5` under the
library defines) — landed 2026-09-02, after the currently pinned
2026-08-31 release.

The earliest published cosmos release carrying FTS5 is
`2026.09.02-d88e994fc`. Bumping the pin to it and running
`bin/cosmic --make build` fails type-checking in a file this item has
nothing to do with:

```
_cli/main_handlers.tl:98:28: error: argument 1: got MkstempPath, expected string
_cli/main_handlers.tl:100:33: error: argument 1: got MkstempPath, expected string
_cli/main_handlers.tl:103:29: error: argument 1: got MkstempPath, expected string
_cli/main_handlers.tl:105:33: error: argument 1: got MkstempPath, expected string
```

This is caused by an intervening, unrelated cosmopolitan change
(`b2a49c60`, 2026-09-01, "unix.mkstemp: bundle path into a table")
that lands before FTS5 in upstream history, so it is unavoidable
collateral of any pin bump that reaches FTS5. `_cli/main_handlers.tl:93`
does `local tmp_fd, tmp_path = unix.mkstemp(...)` and then passes
`tmp_path` as a plain string to `fs.write`/`fs.move`/`os.remove` at
the four flagged lines; it now needs `tmp_path.path`.

## Change

`3p/cosmos/cosmos_pin.tl`: bump `version`/`sha256` to a cosmos release
at or after `2026.09.02-d88e994fc` (the release notes/SHA256SUMS name
the exact artifact). `_cli/main_handlers.tl`: fix the four flagged
`unix.mkstemp` callers to use the `MkstempPath` record's `.path` field
per the new binding contract, matching whatever narrower type
`cosmo.d.tl` now generates for `unix.mkstemp`'s second return.

Gate: `bin/cosmic --make ci` ends `ci: PASS` against the bumped pin,
and `pragma_module_list` reports an `fts5` row from a fresh build.

## Non-goals

- No change to `cosmic/doc/**` or doc search itself — that is
  «So6c_e5pY»'s own change, blocked on this item and re-pullable once
  it lands.
- No chase of any OTHER binding-contract drift the pin bump might
  surface beyond the four `main_handlers.tl` call sites named above;
  if the bumped pin surfaces more than that, file it separately rather
  than widening this item — re-measure at pull time, since the exact
  set may have moved.
