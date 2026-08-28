## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **proved-value narrowing** class, 12 sites.
Files: `_make/root_test.tl` 3; `cosmic/searcher.tl` 2;
`_cli/build/steps.tl` 1; `_make/imports.tl` 1; `_make/root.tl` 1;
`_make/runverb.tl` 1; `_perf/perf_test.tl` 1; `cosmic/re.tl` 1;
`cosmic/string_test.tl` 1. The shape is a `T | nil` re-typed to `T`
because the code above established the nil cannot occur — an early-exit
guard, an `or` fallback that cannot itself be nil, or a fact about the
environment a test runs in. The census verdict is **what closes it
here**, and the striking part is that the mechanisms all ship already:
`check.must` turns a fallible call into a plain value in tests and
examples, which is exactly what the three `fs.cwd() as string` sites in
`_make/root_test.tl` want; and the carried tl patch already narrows
`x or fallback` to the plain type when the fallback cannot be nil, and
already narrows below an early-exit guard whose branch cannot fall
through. So a first pass should DELETE each cast and re-run
`--make ci`: several are expected to check clean as dead weight left
behind by an older checker, and only the ones that fail need the local
copy or the `check.must` rewrite. Do not weaken a guard to make a cast
removable. Every deletion lowers the affected `_build/casts_baseline.tl`
rows; run exactly the regen command the ratchet's failure message
prints. The class description and its exemplar citation are the
`### proved-value narrowing` section of `docs/design/casts.md`; the
per-site list is `docs/design/cast-sites.tsv`.
