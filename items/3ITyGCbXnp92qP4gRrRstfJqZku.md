## Change

Export the glob-to-Lua-pattern conversion once from `cosmic.fs`, drop the copy in
`_make/project.tl`, and add `cosmic` to the dupes gate's scope.

`_build/dupes.tl` is zero-tolerance and its `TREES` comment names this as one of
two standing exclusions: "`cosmic` (whose `glob_to_pattern` `_make/project.tl`
copies) join once their standing duplicates are exported and required — the gate is
zero-tolerance, so a tree enters only clean."

Running the gate's own scanner with `cosmic` added to `TREES` reports it:

```
identical body at _make/project.tl:98 and cosmic/fs/find.tl:25
  — export one and require it
```

Both are seven-line bodies, identical after the gate's normalization, differing
only in their doc comments:

```teal
local pattern = glob
  :gsub("([%.%^%$%(%)%[%]%+%-%%])", "%%%1")
  :gsub("%*", ".*")
  :gsub("%?", ".")
return "^" .. pattern .. "$"
```

### The helper has to be public, and that is forced

`cosmic/fs/find.tl` holds it as a `local`, unexported (`M` is `find`, `find_iter`,
`find_info`, `glob`). `_make` cannot reach it there, and cannot reach it anywhere
internal:

- `cosmic/doc/visibility.tl`'s `is_public` matches `^cosmic%.([%w_]+)$` — a single
  segment — so `cosmic.fs.find` is internal and unrequirable from outside
  `cosmic/`.
- Moving the helper to `_tool/` fails the other way: `cosmic.fs` must boot inside a
  STRIPPED artifact, whose floor is `cosmic/**`, so it may not depend on `_tool`.

So the only home reachable by both is the public `cosmic.fs` surface. That is an
addition to a permanent API, which is a real cost and should be stated — but it
introduces no new concept: `cosmic.fs`'s `FindOptions` already exposes Lua patterns
publicly (`pattern: string`, "Lua pattern matched against each basename"), so a
documented glob-to-pattern converter sits inside a vocabulary the module already
publishes.

### Files

- `cosmic/fs/find.tl` — export `glob_to_pattern` on the module table; keep the
  fuller of the two doc comments (find.tl's, which explains why `[`, `]`, `+`, `-`
  and `%` are escaped).
- `cosmic/fs/init.tl` — re-export it on the `cosmic.fs` entry point, since that is
  the only name outside `cosmic/` can require.
- `_make/project.tl` — delete the local copy; call `fs.glob_to_pattern`.
  `.cosmicignore` behaviour must not change.
- `_build/dupes.tl` — add `"cosmic"` to `TREES`.
- `_build/dupes_test.tl` — add `cosmic` to the `--- reads:` line, which the gate's
  comment says mirrors `TREES` so a diff invalidates the cached verdict.
- A test that `fs.glob_to_pattern` is reachable from the public entry point and
  that its escaping still holds for the `*[a-z]*` case find.tl's comment calls out.

The public-surface baseline records module names, not function names (50 entries,
all `["cosmic.<name>"] = true`), so this does not move `_build/public_surface_baseline.tl`.

### Landing order

The sibling item adding `_perf` to the gate edits the same two lines in
`_build/dupes.tl` and `_build/dupes_test.tl`. Whichever lands second rebases; it is
a one-entry list edit, not a conflict worth sequencing with a blocker.

## Non-goals

- No behaviour change to `.cosmicignore` matching or to `fs.find`'s globbing.
- No new lint or ratchet. This widens an existing gate's scope; it does not change
  what the gate does.
