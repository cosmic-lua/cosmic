Found while reviewing 3IWMDe1R (PR #1482), which puts the probe pointer
into the three `3p/tl/tl_patch/*.tl` entry files. That paragraph and
`_make/patch.tl` between them name exactly two probe forms: the wrong one
(`package.path`) and the right one (`patch.reverse`, which installs the
de-patched copy in `package.loaded`). A THIRD form is neither named nor
prevented, and it is the one a session reaches for when it wants a verdict
rather than a value: hand the snippet to `cosmic --check types`.

`--check types` never RUNS the file it checks, so a preload written inside
that file is inert, and the answer that comes back is the shipped, patched
checker's. Measured 2026-08-28 with `o/bin/cosmic` (built 2026-08-27
13:55) against a file whose first line is a `dofile` of a path that does
not exist:

    $ cat cli_probe.tl
    package.loaded["tl"] = dofile("/tmp/nonexistent-stock/tl.lua")

    local record R
      x: integer
    end
    local function make(): R | nil
      return nil
    end
    local r = make()
    if not r then
      return
    end
    print(r.x)

    $ o/bin/cosmic --check types cli_probe.tl
    Type check passed: .../cli_probe.tl
    exit=0

The `dofile` would have thrown had the line ever run. It did not, and the
guarded index checked clean because the shipped checker carries
`narrow-truthiness`. The in-process contrast, measured the same night on
the same snippet: shipped checker 0 errors, chunk `@/zip/tl.lua`; after
`patch.reverse{entries = {"narrow-truthiness"}, file = "tl.lua",
module_name = "tl"}` 1 error (`cannot index key 'x' in variable 'r' of
type R | nil`), chunk `@/tmp/patch-reverse-*/tl.lua`. Same snippet, three
forms, two of which report the opposite of the truth with nothing logged.

A second facet of the same "which bytes am I measuring" question, measured
in the same session: a bare script's `require("_make.patch")` resolves the
binary's EMBEDDED `_make/patch.tl`, not the tree's. Following the new
pointer in a scratch script against a binary predating the `reverse`
helper fails with

    invalid key 'reverse' in record 'patch' of type record PatchModule

which is at least loud, unlike the two silent forms. It is why a probe has
to run under `--make run` (or load the tree's copy explicitly) to see the
tree's `reverse` at all, and the entry-file paragraph does not say so.

Fix direction, unsettled — refinement picks one, core before docs:

- a fingerprint a probe can assert, so "which checker answered" is
  observable rather than inferred: `patch.reverse` already returns the
  loaded module, and `debug.getinfo(tl.check, "S").source` is the fact
  (`@/zip/tl.lua` vs `@/tmp/patch-reverse-*/tl.lua`) — a helper or a
  documented one-liner turns a silent wrong answer into an assertion that
  fails.
- naming the `--check types` form in the entry-file paragraph, as the
  `package.path` form is named today.
- neither, if a cheaper mechanism makes the wrong form impossible.

Done when a session probing an entry cannot get a confident wrong answer
without something failing or saying which checker it used, and the
countermeasure is demonstrated against the reproduction above.
