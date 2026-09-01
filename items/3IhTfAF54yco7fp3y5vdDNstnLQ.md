## Finding

`cosmic.sandbox.merge()` (`cosmic/sandbox/init.tl`) silently drops the
`net` section entirely from its result — it was never wired in when net
landed (PR #1596) — and, as of item `3I7LKuM2` (handle «X8Ro_I6Dl»,
"sandbox: the facade reaches ABI 9"), now also drops the new `scope`
section the same way. No test covers merging either section.

## Symptom

`sandbox.merge({net = {...}}, {other = {...}})` silently loses the `net`
policy from the result with no error — the caller gets a merged Options
table that looks complete but is missing a section they explicitly
passed. Same for `scope` after `3I7LKuM2` lands. Any caller relying on
`merge()` to compose a `net` or `scope` policy across two Options values
(e.g. a base project policy merged with a per-call override) silently
loses that half of the policy.

## Provenance

Surfaced 2026-08-31 while building item `3I7LKuM2` (handle «X8Ro_I6Dl»)
— the builder noticed `merge()` had no `net` handling already (a
pre-existing gap from PR #1596) and confirmed the new `scope` section
they were adding had the identical gap, but fixing `merge()` was outside
that item's `## Change`. Left alone there; filed here as its own gap.

## Change

Confirmed against current `main`
(`cosmic/sandbox/init.tl`, `merge()` at lines 377-405, `merged_list` at
lines 354-367) by running a real `merge()` call through the tree's own
source via `bin/cosmic --make run`:

```
$ cat scratch/check_merge.tl
local sandbox = require("cosmic.sandbox")
local merged = sandbox.merge(
  {net = {connect_tcp = {80, 443}}},
  {net = {connect_tcp = {8080}}})
print("merged.net =", merged.net)

$ bin/cosmic --make run scratch/check_merge.tl
...
merged.net =	nil
```

This confirms the `net` section is dropped exactly as described. Fix it
in `cosmic/sandbox/init.tl`:

1. Add a new local helper `merged_int_list`, right after `merged_list`
   (after line 367), identical in structure to `merged_list` (lines
   354-367) but typed for `{integer}` instead of `{string}` — `plan.Net`'s
   two fields, `connect_tcp` and `bind_tcp` (`cosmic/sandbox/plan.tl`
   lines 37-40: `record Net  connect_tcp: {integer}  bind_tcp: {integer}
   end`), are integer port lists, not string paths, so `merged_list`'s
   signature does not apply directly:

   ```teal
   local function merged_int_list(a: {integer}, b: {integer}): {integer}
     if a == nil and b == nil then return nil end
     local out: {integer} = {}
     local seen: {integer: boolean} = {}
     for _, list in ipairs({a or {}, b or {}}) do
       for _, p in ipairs(list) do
         if not seen[p] then
           seen[p] = true
           out[#out + 1] = p
         end
       end
     end
     return out
   end
   ```

2. In `merge()` (lines 377-405), add a `net` branch alongside the
   existing `fs` and `sys` branches — insert it right after the `sys`
   block (currently lines 391-397) and before the `best_effort` scalar
   assignment (currently line 398), following the same shape the `fs`
   branch uses (concat-and-dedupe each list field against what `out`
   already carries):

   ```teal
   if o.net then
     local nbase: Net = out.net or {}
     out.net = {
       connect_tcp = merged_int_list(nbase.connect_tcp, o.net.connect_tcp),
       bind_tcp = merged_int_list(nbase.bind_tcp, o.net.bind_tcp),
     }
   end
   ```

   `Net` is already in scope as `local type Net = plan.Net` (line 47).

3. In `cosmic/sandbox/init_test.tl`, extend `test_merge_composes_policies`
   (lines 367-394) with `net` coverage mirroring the existing `fs`
   assertions in the same test: merge two Options where both carry
   `net.connect_tcp` with one overlapping port and one policy-only port,
   assert the merged list's length and first-seen order the same way
   lines 372-374 do for `merged.fs.ro` (`check.equal(#merged.net.connect_tcp,
   ...)`, `check.equal(merged.net.connect_tcp[1], ...)`), and assert a
   `net.bind_tcp` present in only one policy survives unmerged, the same
   way line 375 does for `merged.fs.exec`. Use the existing `check`
   import already at the top of the file (line 10) — no new imports
   needed.

No other file changes: `apply()`, `validate()`, and the `Report`/`Section`
records are untouched — this is scoped to `merge()`'s composition logic
and its test.

## Non-goals

`scope` is explicitly NOT fixed here. Checked against the current `main`
tree:

```
$ grep -n 'type Options' -A 10 cosmic/sandbox/init.tl
local record Options
  fs: Fs
  sys: Sys
  net: Net
  best_effort: boolean
  allow_unenforced: boolean
  strict: boolean
  no_new_privs: boolean
end

$ grep -rn 'scope' cosmic/sandbox/
(no output)
```

`Options` has no `scope` field at all yet, and no `scope` reference
exists anywhere under `cosmic/sandbox/` — PR #1600 (item `3I7LKuM2`,
handle «X8Ro_I6Dl»), which introduces it, has not landed on `main`. Do
not add `scope` handling to `merge()` speculatively against a shape that
might still change in review. Once #1600 merges, re-verify (with the
same kind of `merge()` probe used above, against the landed `scope`
field) whether the identical drop applies and, if so, fix it as its own
follow-up — do not assume this Change already covers it.
