## Goal

G3 — an honest type layer: D23's "no other `cosmic.*` module may throw
or exit" becomes true in the tree. Refinement halved the item: of the
two throws it filed, one is not a library throw at all, so this slice
fixes the ONE real violation and records why the other needs nothing.

## Evidence

Re-measured 2026-08-26 against main `d61b2cc9` with the item's census
(`git ls-files 'cosmic/*.tl' 'cosmic/**/*.tl' | grep -v
'_test\.tl$\|_example\.tl$\|_benchmark\.tl$' | xargs grep -n 'assert('`,
doc-comment and `-- assert:`-licensed lines excluded):

- **`cosmic/embed/init.tl:186` is a string constant, not executable
  library code.** The `assert(loadfile("/zip/main.user.lua"))` sits
  inside `WRAP_MAIN` (lines 179–189), the long-bracket SOURCE of the
  generated artifact entry wrapper. It executes as the built
  artifact's own `/zip/main.lua` — a top-level script whose caller is
  the OS, where a throw with a message is the correct failure for a
  corrupt artifact. D23 governs `cosmic.*` library modules; no change,
  and this spec is the record of why.
- **`cosmic/quicksand/proxy/serve.tl:374` is the one real violation**:
  `if not listen_fd then assert(listen()) end` at the top of
  `serve_forever()`, whose declared type is `function()` (the `Server`
  record, line 35). `listen()` is honestly fallible
  (`integer | nil, string`, socket/bind/listen failures at lines 342,
  348, 353) and its failure is a REAL runtime condition — not the
  unreachable-nil shape D23's amendment licenses.
- The blast radius is two callers: the production caller
  (`cosmic/quicksand/proxy.tl:145`, the forked child) calls
  `listen_fn()` explicitly and exits 1 on failure BEFORE
  `serve_fn()` — so the lazy-listen path is production-unreachable and
  the new return changes no live behavior — and
  `cosmic/quicksand/proxy/serve_test.tl` (its `serve_forever`
  references; re-check at pull). File sizes: `serve.tl` 423 lines,
  `proxy.tl` 189 — headroom for +6 and +4.
- The six `-- assert:`-licensed dance sites (`cosmic/time.tl`,
  `cosmic/fs/path.tl`) are D23-sanctioned and retire independently via
  PR #1395; they are not this slice's.

## Change

1. **`cosmic/quicksand/proxy/serve.tl`** — `serve_forever` becomes the
   doctrine's fallible effect:
   - `Server` record field: `serve_forever: function(): boolean, string`.
   - Body: replace `if not listen_fd then assert(listen()) end` with

     ```teal
     if not listen_fd then
       local lok, lerr = listen()
       if not lok then return false, lerr end
     end
     ```

   - The loop's normal terminations (the EBADF/EINVAL
     listener-closed return at line ~390, and any fallthrough) become
     `return true` — the "supervisor decides what next" contract is
     unchanged, it just reads as a success now.
   - The doc comment on `serve_forever` (line 5 header and the
     function's own) states the new shape: `false, err` only when the
     lazy listen fails; `true` when the accept loop ends.
2. **`cosmic/quicksand/proxy.tl:145`** — the child's cast updates to
   the new shape (`server.serve_forever as function(): (boolean,
   string)` with its existing `-- cast: function shape` reason), and
   the call checks it:

   ```teal
   local sok, serr = serve_fn()
   if not sok then
     io.stderr:write("proxy.serve: " .. tostring(serr) .. "\n")
     unix.exit(1)
   end
   unix.exit(0)
   ```

3. **`cosmic/quicksand/proxy/serve_test.tl`** — update any
   `serve_forever` use to the two-slot shape (`check.must` or an
   explicit check); re-measure the exact sites at pull.
4. No D23 edit: the record's closed list becomes TRUE by this fix
   rather than amended around; `docs/decisions/**` untouched.

## Non-goals

- **`cosmic/embed/init.tl` untouched** — the Evidence paragraph is the
  record; the generated wrapper's script-level assert is correct where
  it runs. (A lexer-aware assert lint that skips string constants is
  board item 3IRTkNx1, split from this one.)
- **No behavior change on the production path**: the forked child
  already listens before serving, so the lazy-listen failure return is
  exercised only by direct `serve_forever()` callers.
- **The `-- assert:` lint is not this slice's** — 3IRTkNx1.
- **No signature change to `listen`/`accept`/`handle`** — they are
  already honest.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -n "assert(" cosmic/quicksand/proxy/serve.tl | grep -v -- "---"`
  prints nothing (today: line 374).
- `grep -n "serve_forever: function(): boolean, string" cosmic/quicksand/proxy/serve.tl`
  prints one line (today: none — the field reads `function()`).
- `bin/cosmic --make test cosmic/quicksand/proxy/serve_test.tl cosmic/quicksand/init_test.tl`
  ends `test: PASS (2 files)`.
- `git diff origin/main -- docs/ cosmic/embed/` is empty.

## Enablement

none needed. The fallible-effect shape (`boolean, string`) is
AGENTS.md doctrine; both callers are enumerated above with the exact
replacement shapes; the checker demands nothing new (a two-slot return
needs no narrowing at these call sites beyond the checks written).
