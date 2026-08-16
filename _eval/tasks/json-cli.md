Build a command-line tool that reports on a JSON inventory file. First create the fixture `testdata/items.json` with exactly this content (13 lines):

```json
[
  {"name": "alpha", "kind": "fruit", "count": 3},
  {"name": "beta", "kind": "veg", "count": 5},
  {"name": "gamma", "kind": "fruit", "count": 2},
  {"name": "delta", "kind": "veg", "count": 0}
]
```

The tool is a compiled binary `o/bin/jstat` (source at `cmd/jstat/main.tl`, built with the tool's build command) with three subcommands. `jstat list <path>` prints each record's `name`, one per line, in file order. `jstat filter <path> <kind>` prints the names of records whose `kind` field equals the argument, one per line, in file order. `jstat summary <path>` prints exactly one line of the form `items=<n> total=<sum of counts> kinds=<distinct kind count>`. Any failure — missing file, unreadable JSON, unknown subcommand, missing argument — must print a one-line error message to stderr, print nothing to stdout, and exit non-zero. Ship tests for the tool's logic and take the project to a green `ci` gate.

## Acceptance facts

- `./cosmic --make build` succeeds and produces an executable `o/bin/jstat`.
- `./o/bin/jstat list testdata/items.json` exits 0 with stdout exactly `alpha`, `beta`, `gamma`, `delta` (four lines, that order).
- `./o/bin/jstat filter testdata/items.json fruit` exits 0 with stdout exactly `alpha`, `gamma` (two lines).
- `./o/bin/jstat filter testdata/items.json veg` exits 0 with stdout exactly `beta`, `delta` (two lines) — `delta` has `count` 0 and must still appear (S-trap: zero is not absence).
- `./o/bin/jstat summary testdata/items.json` exits 0 with stdout exactly `items=4 total=10 kinds=2` — the total includes delta's 0, and the line is exactly one line with no trailing extra values (S-trap: printing a multi-return appends a trailing `nil`).
- `./o/bin/jstat summary testdata/missing.json` exits non-zero, stdout is empty, and stderr contains `testdata/missing.json`.
- Given a file `bad.json` containing exactly `{nope`, `./o/bin/jstat list bad.json` exits non-zero with empty stdout and a non-empty stderr line.
- The workspace contains at least one `*_test.tl`, and `./cosmic --make ci` ends with `ci: PASS`.
