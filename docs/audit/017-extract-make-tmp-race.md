# 017 — `extract_make` tmp-file race between concurrent builds

severity: low
type: bug (concurrency)
area: `_make/graph.tl`

## issue

`extract_make` writes the embedded engine to a fixed temp name
(`to .. ".tmp"`) then renames into place. two concurrent `--make`
invocations in one tree both use the same temp path: one can rename while
the other is mid-truncate/write, briefly installing a partial engine — the
exact torn-file failure the temp+rename idiom exists to prevent, defeated by
the fixed name.

## where

- `_make/graph.tl:214-227` — fixed `.tmp` suffix, write, chmod, rename.

## failure scenario

two shells (or a user plus an editor task) run `cosmic --make build`
simultaneously in a fresh tree. both see `o/make` missing, both extract;
interleaving installs a truncated `o/make`, and every subsequent build fails
with an unexecutable engine until someone deletes it — a heisenbug with no
pointer back to the race.

## suggested fix

unique temp name per process (`to .. ".tmp." .. proc.pid()`), rename over,
and tolerate `rename` losing to a concurrent winner (the destination bytes
are identical either way — same embedded engine). clean up the temp on the
losing path.

## test to add

hard to race deterministically; a cheap proxy is asserting the temp name
embeds the pid (unit-level), which pins the fix.
