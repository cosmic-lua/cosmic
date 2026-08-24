Split out of 3IK8EOci during its 2026-08-24 refinement, which took only
the token-copy hypothesis so the diff stays one hypothesis.

**Rejected 2026-08-24 on measurement.** The pass this item proposed to
remove costs 2.4% of the scenario on a scenario whose spread is ±7-12%,
and the only output-preserving shape captures a fraction of that. The
evidence is below; nothing here is landable under the `optimize` skill's
own gate, so the item is ended not-planned rather than driven to the bar.

## Problem
`mark_type_params` (`cosmic/format/init.tl:36`, measured 2026-08-24 at
9bcb0f7d) walks a line's items looking for `function ... < ... > (` and
marks the span `_tight_before`. It is called per line from inside the
emit loop (line 271), so every line is scanned twice: once by this pass
and once by the emit walk that immediately follows it.

The claim was true and the conclusion did not follow: two walks over the
same items are not two equal costs. The mark walk does an `ipairs` step
and one `item.kind` lookup per item; the emit walk does that plus a
`needs_space` call, a `_tight_before` lookup, a `#line.items` length op
and an append. The cheap walk is a small fraction of the pair.

## What was measured
All numbers on the tree at 6e3af831 (main + PR #1355, whose emit-buffer
change is in the same loop), one host, `--only format`.

**Cost of the whole pass**, isolated by repeating the call — the marking
is idempotent, so N calls emit identical bytes and the delta is N-1
extra passes:

    # in format's emit loop, `mark_type_params(line.items)` repeated N times
    bin/cosmic --make build
    o/bin/cosmic --make run _perf/run.tl --only format --out o/perf/format-Nx.json

| calls | `format_module_source` samples | mean |
|---|---|---|
| 1x | 10.40, 10.68, 10.80, 11.01 ms | 10.72 ms |
| 10x | 12.96, 13.07, 12.99 ms | 13.01 ms |

`(13.01 - 10.72) / 9` = **0.254 ms per pass = 2.37%** of the scenario.
`alloc_kb` is 1433.1 in every run, at every N: the pass allocates
nothing, so no allocation win exists here at all.

**2.37% is the ceiling for deleting the pass outright**, and the
scenario's own measured spread on this host is ±7-12% (and reached 31%
during 3IM89fv4's refinement). Nothing this size is measurable here.

**The fold captures a fraction of that ceiling.** Prototyped: hoist the
body to `mark_type_params_at(items, i)` and call it from inside the emit
walk when the walk sees a `function` keyword — the marks land at indices
ahead of the walk, so they are set before the walk reads them, and the
per-line scope is preserved exactly.

    format_module_source   10.74 ms ± 5.8%   alloc 1433.11 KB   (folded)
    format_module_source   10.68 ms ± 11.7%  alloc 1433.16 KB   (baseline)

No result, and the reason is structural: the fold removes the `ipairs`
step but keeps the `item.kind`/`item.tk` tests, which is where most of
the 0.254 ms sits. Lua does not CSE the `item.kind` the emit walk
already reads, so folding trades an iterator step for nothing.

## Why the other shape is not a perf item
Hoisting the marking to run once over the flat item list (or into
`build_items`, which already walks the token stream) WOULD skip the
per-item test — but it drops the per-line scope. Today a
`function<T>(` whose type parameters sit on a different source line
than the `function` keyword is not marked, because the scan cannot see
past the line end; a flat-list scan would mark it and render it tightly.
That is a formatter behaviour change on a code shape the tree does not
contain, so the `fmt` gate would not catch it. It is a contract question
about what the formatter does to wrapped type-parameter lists, not a
transcription — if anyone wants it, it is a new item with that decision
in its `Change`, and its motivation is consistency, not the 2.4%.

## Non-goals
Nothing to build.

## Acceptance
Nothing to accept. The reproduction commands are in **What was measured**;
each writes only under `o/` and touches no committed file.

## Enablement
none needed — the question was answerable with the harness that already
exists, and it was answered.
