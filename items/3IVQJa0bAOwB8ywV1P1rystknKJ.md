## Goal

G3 — an honest type layer, no escape hatches. A carried checker rule must be
described where it is declared and pinned by a test, so a diagnostic a reader
hits is distinguishable from a regression, and a later re-port of the patch
cannot drop half the rule while the other half stays green.

## Change

The `closure-global-widen` entry of the carried tl patch treats a name declared
in scope 1 as always-assigned, and its anchor sits inside `widen_all_unions`
itself rather than at the function-boundary call sites. Every caller of that
function therefore drops a global's narrow — including the four LOOP sites,
which pass their own node:

    $ grep -n "widen_all_unions" o/3p/tl/tl.lua
    10910:   function TypeChecker:widen_all_unions(node)
    13173:            self:widen_all_unions(node)      -- ["while"]
    13185:            self:widen_all_unions()          -- ["label"], stock widen-all
    13241:            self:widen_all_unions(node)      -- ["repeat"]
    13262:            self:widen_all_unions(node)      -- ["forin"]
    13317:            self:widen_all_unions(node)      -- ["fornum"]
    (the remaining seven pass self.chunk_body: the function boundaries)

Measured 2026-08-27 against the tree build (`o/bin/cosmic`) and the pinned
release (`o/bootstrap/cosmic`, which predates the entry), on a source whose
guard narrows the global `gv` to `string`:

    $ cat /tmp/f.tl
    global gv: string | integer = "x"
    if not (gv is string) then return end
    print(gv:upper())
    for _i = 1, 3 do print(gv:upper()) end

    $ o/bootstrap/cosmic --check types /tmp/f.tl
    Type check passed: /tmp/f.tl
    $ o/bin/cosmic --check types /tmp/f.tl
    /tmp/f.tl:4:27: error: cannot index key 'upper' in variable 'gv' of type string | integer

All four loop forms behave this way and nothing else does. Same guard, one form
per file, under `o/bin/cosmic --check types`:

| body                                                  | verdict |
|-------------------------------------------------------|---------|
| `while os.time() < 0 do print(gv:upper()) end`        | error   |
| `repeat print(gv:upper()) until os.time() > 0`        | error   |
| `for _k, _v in pairs({a = 1}) do print(gv:upper()) end` | error |
| `for _i = 1, 3 do print(gv:upper()) end`              | error   |
| `print(gv:upper())` (straight line, below the guard)   | passes  |
| `if os.time() > 0 then print(gv:upper()) end`          | passes  |
| the same four bodies over a narrowed LOCAL             | pass    |

The behaviour is correct and stays. Two files change; neither changes checker
behaviour.

### 1. `3p/tl/tl_patch/closure.tl` — the file header comment only

`grep -n "Loop and if sites" 3p/tl/tl_patch/closure.tl` is line 21 today.
Replace exactly these two lines:

    -- no assignment anywhere. Loop and if sites keep their own nodes —
    -- they widen for a different question (assigned in the loop body).

with exactly these eight:

    -- no assignment anywhere. The four loop sites — `while`, `repeat`,
    -- `forin` and `fornum` — pass their own node, so a LOCAL keeps its
    -- narrow unless the loop body assigns it. A GLOBAL does not: the
    -- always-assigned test sits inside `widen_all_unions` itself, which
    -- every one of those sites calls, so a global's narrow drops at loop
    -- entry as well as at a function boundary — the same soundness
    -- argument, since a loop body can run after another module assigns the
    -- global. Straight-line use below the guard keeps its narrow.

The `and if` clause goes because it is wrong: `if` and `if_block` widen through
`self:widen_all(node.if_widens, {})` (`o/3p/tl/tl.lua:13125`), a different
function this entry does not touch — which is why an `if` body keeps a global's
narrow in the table above.

This edit sits in the file header, ABOVE the `return {` table, so no `find` or
`replace` string moves, `o/3p/tl/tl.lua` is not re-derived, and the slice needs
no `bin/cosmic --make fetch`. Measured: `wc -l < 3p/tl/tl_patch/closure.tl` is
207 today and 213 after (cap 500); the file still parses to 10 entries under
`cosmic.literal`.

### 2. `cosmic/teal_closure_test.tl` — one new test function

Append it immediately before the file's final line,
`print("all closure carry tests passed")`, following the file's
call-after-define convention and reusing its existing `checks` helper. Verbatim:

    -- A global's narrow drops at a loop boundary too. Each of the four loop
    -- forms widens against its own node, and a global is always-assigned
    -- there, so the body -- which can run again after another module
    -- assigns the global -- sees the union. Straight-line use above the
    -- loop keeps its narrow, so exactly one diagnostic is expected per
    -- source.
    local function test_a_global_narrow_does_not_carry_into_a_loop_body()
      local diag = "cannot index key 'upper' in variable 'gv' of type string | integer"
      local forms: {{string}} = {
        {"while", "while os.time() < 0 do print(gv:upper()) end"},
        {"repeat", "repeat print(gv:upper()) until os.time() > 0"},
        {"forin", "for _k, _v in pairs({a = 1}) do print(gv:upper()) end"},
        {"fornum", "for _i = 1, 3 do print(gv:upper()) end"},
      }
      for _, form in ipairs(forms) do
        local ok, msgs = checks("closure_global_loop_" .. form[1] .. ".tl", [[
    global gv: string | integer = "x"
    if not (gv is string) then return end
    print(gv:upper())
    ]] .. form[2] .. "\n")
        assert(not ok, "a global narrow must not carry into a " .. form[1] .. " body")
        local n, at = 0, 1
        while true do
          local i, j = msgs:find(diag, at, true)
          if not i then break end
          n, at = n + 1, j + 1
        end
        assert(n == 1, form[1] .. ": expected one diagnostic, got: " .. msgs)
      end
    end
    test_a_global_narrow_does_not_carry_into_a_loop_body()

Two notes on that code, both load-bearing:

- The four long-string sources are written flush-left in the real file (the
  indentation above is this spec's block quote). The `[[ ]]` body carries the
  guard and a straight-line `print(gv:upper())`; `form[2]` supplies the loop.
- The count-to-one loop uses `msgs:find(diag, at, true)` rather than
  `msgs:gmatch(diag)`: `diag` is a variable needle, `gmatch` has no plain flag,
  and asserting exactly ONE diagnostic is what pins straight-line survival in
  the same assertion. `n == 0` is the unpatched outcome.

Measured 2026-08-27 on the branch carrying PR #1472:

    $ git show origin/main:cosmic/teal_closure_test.tl | wc -l
    175
    $ git show origin/main:cosmic/teal_closure_test.tl | grep -c '^local function test_'
    7

PR #1472 (item `3IVL5DSr`, in `check`) adds three test functions to the same
file, taking it to 256 lines / 10 test functions. This change adds 32 lines and
one test function on whichever base it lands on — 207/8 without #1472, 288/11
with it — both far under the 500-line cap. The two do NOT compose into a
conflict worth waiting on: both append independent test functions in the same
trailing region, immediately above the final `print`, and a rebase resolves by
keeping both blocks in either order. Do not block on #1472; branch off the
latest `origin/main` and take whichever base is there.

## Non-goals

- No checker behaviour change. The loop drop is correct; this slice describes
  and pins it. Do not add, remove, reorder or re-word any `find` or `replace`
  string in `3p/tl/tl_patch/**` — those are the frozen anchors, and the derived
  `o/3p/tl/tl.lua` must come out byte-identical. No `--make fetch` step, no
  `bin/cosmic.pin` bump.
- Do not touch `3p/tl/tl_patch/narrow.tl` or `3p/tl/tl_patch/ast_cache.tl`.
  Item `3IVL4phw` (PR #1468) is editing `narrow.tl` right now.
- Do not touch `_make/patch.tl`.
- Do not modify any of the existing test functions in
  `cosmic/teal_closure_test.tl`, and do not touch `cosmic/teal_narrowing_test.tl`
  or `cosmic/teal_test.tl`.
- Do not split the closure boundary's body/continuation scan, or otherwise act
  on `3IVZsiwL`.
- No new lint, no `docs/guides/**` section, no decision record. The comment and
  the test are the whole deliverable.
- Board state stays on the board: `3IVQKRm2` is an unpromoted capture of this
  same observation and is not this diff's to close.

## Acceptance

Run from the repo root. Nothing below writes into the committed tree.

1. The gate, with the verdict line read rather than a piped status:

       $ bin/cosmic --make ci
       ci: PASS (5 stages)

2. The test file itself, reporting one more test function than the base commit
   (8 without PR #1472, 11 with it):

       $ bin/cosmic --make test cosmic/teal_closure_test.tl
       ✓ cosmic/teal_closure_test.tl (11 test functions)  …ms
       1 checks: 1 passed
       test: PASS (1 file)

3. The cold-build rule's gate, run explicitly:

       $ bin/cosmic --make test _build/coldbuild_test.tl
       test: PASS (1 file)

4. The new test type-checks under the PINNED release, so no pin bump stages
   ahead of this slice:

       $ o/bootstrap/cosmic --check types cosmic/teal_closure_test.tl
       Type check passed: cosmic/teal_closure_test.tl

5. Bounds and shape. Both `grep -c` counts must be equal (call-after-define)
   and exactly one greater than the base commit's, and both `wc -l` under their
   stated ceilings:

       $ grep -c '^local function test_' cosmic/teal_closure_test.tl   # 11 (8 without #1472)
       $ grep -c '^test_' cosmic/teal_closure_test.tl                  # same number
       $ git show origin/main:cosmic/teal_closure_test.tl | grep -c '^local function test_'  # one fewer
       $ wc -l < cosmic/teal_closure_test.tl                           # ≤ 300
       $ wc -l < 3p/tl/tl_patch/closure.tl                             # 213, ≤ 500

6. The diff touches exactly two files. THREE dots — the two-dot form compares
   against a moving `origin/main` and is a known recurring defect:

       $ git diff origin/main...HEAD --name-only
       3p/tl/tl_patch/closure.tl
       cosmic/teal_closure_test.tl

7. **The guard proof — the evidence this slice exists to produce.** A test that
   passes whether or not the patch entry is present is worthless, so run the new
   test BOTH ways: reverse-apply only `closure-global-widen` (swap its `replace`
   text back to its `find` text) into a scratch copy of the derived
   `o/3p/tl/tl.lua`, then run the compiled test file against each checker with
   `package.loaded["tl"]` preloaded, with `assert` collecting rather than
   aborting so every shape reports. Rehearsed 2026-08-27; these commands and
   their output are verbatim.

       $ rm -rf /tmp/loopguard && mkdir -p /tmp/loopguard/t1 /tmp/loopguard/t2
       $ cat > /tmp/loopguard/neuter.lua <<'LUA'
       local literal = require("cosmic.literal")
       local fs = require("cosmic.fs")
       local entries = assert(literal.parse_file("3p/tl/tl_patch/closure.tl"))
       local e = assert(entries["closure-global-widen"])
       local src = assert(fs.read("o/3p/tl/tl.lua"))
       local i, j = src:find(e.replace, 1, true)
       assert(i, "patched text not found")
       assert(not src:find(e.replace, j + 1, true), "found more than once")
       assert(fs.write("/tmp/loopguard/tl_reversed.lua",
         src:sub(1, i - 1) .. e.find .. src:sub(j + 1)))
       print("reversed closure-global-widen")
       LUA
       $ cat > /tmp/loopguard/run.lua <<'LUA'
       package.loaded["tl"] = assert(loadfile(arg[1]))()
       local real = assert
       local fails = 0
       _G.assert = function(v, msg, ...)
         if not v then
           fails = fails + 1
           io.stdout:write("  FAIL: ", tostring(msg), "\n")
         end
         return v, msg, ...
       end
       local ok, err = pcall(real(loadfile(arg[2])))
       _G.assert = real
       if not ok then io.stdout:write("  RUNTIME ERROR: ", tostring(err), "\n") end
       io.stdout:write("failed assertions: ", tostring(fails), "\n")
       LUA
       $ o/bin/cosmic /tmp/loopguard/neuter.lua
       reversed closure-global-widen
       $ o/bin/cosmic --compile cosmic/teal_closure_test.tl > /tmp/loopguard/test.lua
       $ TEST_TMPDIR=/tmp/loopguard/t1 o/bin/cosmic /tmp/loopguard/run.lua \
           o/3p/tl/tl.lua /tmp/loopguard/test.lua
       all closure carry tests passed
       failed assertions: 0
       $ TEST_TMPDIR=/tmp/loopguard/t2 o/bin/cosmic /tmp/loopguard/run.lua \
           /tmp/loopguard/tl_reversed.lua /tmp/loopguard/test.lua
         FAIL: a global narrow must not carry into a closure
         FAIL: a global narrow must not carry into a named function
         FAIL: a global narrow must not carry into a while body
         FAIL: while: expected one diagnostic, got:
         FAIL: a global narrow must not carry into a repeat body
         FAIL: repeat: expected one diagnostic, got:
         FAIL: a global narrow must not carry into a forin body
         FAIL: forin: expected one diagnostic, got:
         FAIL: a global narrow must not carry into a fornum body
         FAIL: fornum: expected one diagnostic, got:
       all closure carry tests passed
       failed assertions: 10

   Required outcome: **0** failed assertions with the entry, **10** without —
   of which **8 are the new test** (four `must not carry into a <form> body`
   plus four `<form>: expected one diagnostic`, `msgs` empty because the source
   checks clean). The other two are the pre-existing closure and named-function
   global tests, which is the control: without the new test the same run gives 2
   (rehearsed on the tree file as it stands today), so the delta of 8 is
   attributable to this change alone. `neuter.lua` succeeding is also the proof
   that the entry's `replace` string was left untouched — if the diff had edited
   it, the `find` in the derived `o/3p/tl/tl.lua` would fail "patched text not
   found".

   Paste the both-ways output into the PR description; it is what the reviewer
   reads before the diff and cannot reconstruct from the branch.

## Enablement

`none needed` — no blocker items, nothing to land first.

The enablement check, walking the `Change` as a literal-minded session would:

- **Wrong turn: editing the entry's inline comment instead of the file header.**
  That would change patch DATA, requiring `bin/cosmic --make fetch` to
  re-derive `o/3p/tl/tl.lua` and leaving the tree inconsistent until it ran.
  Countermeasure in place: the `Change` names the exact two lines and their
  exact replacement, `Non-goals` freezes every `find`/`replace` string, and
  Acceptance 7's `neuter.lua` fails loudly if the `replace` text moved.
- **Wrong turn: a test that passes either way.** Countermeasure: Acceptance 7
  demands the both-ways run with the exact counts (0 / 10, delta 8), and the
  `n == 1` assertion fails at `n == 0` without the entry rather than merely
  reporting a different message.
- **Wrong turn: assuming a pin bump must stage first.** It must not, and this
  is measured, not reasoned: the cold build's generation 1 type-checks the tree
  with the PINNED checker, and the new test's SOURCE uses only ordinary Teal.
  Verified 2026-08-27 — `o/bootstrap/cosmic` is the artifact named by
  `bin/cosmic.pin` (`2026-08-27-555873e`), and

      $ o/bootstrap/cosmic --check types <the file with the new test>
      Type check passed

  The test's ASSERTIONS run under the tree-built binary during `--make test`,
  which carries the entry; the pinned checker never runs them. Acceptance 3 and
  4 hold this.
- **Wrong turn: waiting on PR #1472, or rebasing over it destructively.**
  Countermeasure: the `Change` states the compose rule explicitly (independent
  appends, keep both) and both possible base measurements.
- **Wrong turn: the two-dot diff.** Countermeasure: Acceptance 6 writes the
  three-dot form with its expected two lines.
