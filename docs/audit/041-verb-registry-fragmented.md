# 041 — adding a verb touches five structures plus two if-chains

severity: medium (maintainability; seven more verbs are planned)
type: design
area: `_make/init.tl`

## issue

the design's stated economics for units is "a new unit kind costs a
table row." verbs — the surface users actually touch — cost more, spread
across `_make/init.tl`:

- `IMPLEMENTED` (list, line 33) and `PLANNED` (list, line 40) — a new
  verb edits one and maybe removes from the other.
- `TARGETS` (map, line 52) — only if it is a graph verb.
- `SELECTS` (map, line 79) — only if it takes path selection.
- `usage()` (line 102) derives from the two lists — free, which is the
  right shape and the model for the rest.
- `run()` hand-dispatches non-graph verbs in an if-chain:
  `verb == "check"` (315), `"clean"` (318), `"fetch"` (323); the
  graph path handles the rest, with a further special case inside
  `run_graph` (`verb == "build" and code == 0 and #paths == 0`,
  line 223).

so an implemented verb lives in one of two disjoint mechanisms (graph
verb vs if-chain), and which one is discoverable only by reading
`run()`. today that is 6 verbs and 3 branches — manageable. the plan
adds seven more (`run`, `regen`, `ci`, `coverage`, `enforce`,
`reproducible`, `offline`), and most are *policy* verbs — orchestration,
not graph targets — so on the current shape each becomes another
if-branch. at 13 verbs the if-chain is the module.

## why it matters beyond tidiness

`ci` is specified as "fixed order, each stage gated by whether the
project has material for it." expressing that over if-chain verbs means
`ci` reimplements each stage's invocation; expressing it over a verb
registry means `ci` is a list of verb names. the registry is not
refactoring for taste — it is the data structure phase 4 needs anyway.

## suggested fix

one table, one row per verb:

```
{name: string, planned: boolean, target: string|nil,
 select: Selection|nil, run: function|nil}
```

`usage`, the unknown-verb message, dispatch, and the planned-verb stub
all derive from it. `check`/`clean`/`fetch` become rows with a `run`;
graph verbs become rows with a `target`. the `build` post-step stays
special (it is genuinely build's), but as build's `run`, not a
condition inside the shared path. land it before phase 4 starts adding
policy verbs, while the migration is 6 rows instead of 13.
