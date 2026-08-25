G3, under `3IOK4SZH` — the first of the dynamic-value boundary's three
closures: the repeated `cosmic._version` lookup.

Five files run the identical four lines — a non-literal module name, a
`pcall(require, ...)`, and a cast of the result to read `.cosmic` (and
sometimes `.cosmos`) off it. Measured 2026-08-25 against `dbca9e77` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`; six cast
lines in all:

| site | cast |
| --- | --- |
| `_cli/main_handlers.tl:64` | `ver as VersionInfo` |
| `_eval/stage.tl:239` | `version as {string: string}` |
| `_perf/run.tl:151` | `version as {string: string}` |
| `cosmic/_script_cache.tl:93` | `(ver as {string: string}).cosmic` |
| `cosmic/init.tl:51` | `(info as VersionInfo).cosmic` |
| `cosmic/init.tl:52` | `(info as VersionInfo).cosmic` |

The module name is non-literal on purpose: `cosmic._version` is generated
at build time and does not exist in the tree, so the checker cannot
resolve it and every caller pays for the dynamism. One typed lookup
returning a declared record or nil closes all six.

**The constraint refinement must settle first.** Three of the five
callers (`_cli/`, `_eval/`, `_perf/`) live outside `cosmic/`, and a
module under `cosmic/` may not be required from outside it unless it is
public (AGENTS.md; `cosmic/doc/visibility.tl`). So the helper is either a
public `cosmic.<name>` surface — with the `--docs` entry and the API
commitment that implies — or the trees outside `cosmic/` keep their own
copy and this closes only three of the six. Pick one and say which in the
`Change`; do not leave it to the builder.

Two facts the pick turns on: `cosmic/init.tl` already exposes a
`version()` function built on exactly this lookup, and `cosmic/init.tl`
is inside the strip floor, so whatever the helper is must live under
`cosmic/**` to survive a STRIPPED artifact.
