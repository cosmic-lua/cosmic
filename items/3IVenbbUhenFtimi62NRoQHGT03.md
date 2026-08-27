## Goal

G3 — an honest type layer, no escape hatches. Reverse-applying an entry
from `3p/tl/tl_patch/` and re-running the checker is how a slice proves
that a narrowing test guards the carried patch rather than stock tl. The
obvious way to do it — a modified `tl.lua` on `package.path` — silently
measures the checker the binary already carries and reports the opposite
answer. This slice makes the correct probe the short one and pins the
trap with a test.

Measured 2026-08-27, from the repo root on a built tree. The whole
reproduction, verbatim, writing only under `/tmp`:

    mkdir -p /tmp/tlprobe/cosmic
    sed 's/^return tl$/tl.SCRATCH_MARKER = "MODIFIED-COPY"\nreturn tl/' \
      o/3p/tl/tl.lua > /tmp/tlprobe/tl.lua
    printf 'return {SCRATCH_MARKER = "MODIFIED-COPY"}\n' \
      | tee /tmp/tlprobe/notembedded.lua /tmp/tlprobe/cosmic/string.lua \
            /tmp/tlprobe/cosmic/json.lua > /dev/null
    cat > /tmp/tlprobe/wrong.lua <<'EOF'
    package.path = "/tmp/tlprobe/?.lua;" .. package.path
    for _, n in ipairs({"tl", "cosmic.string", "cosmic.json", "notembedded"}) do
      print(n, tostring(require(n).SCRATCH_MARKER))
    end
    EOF
    cat > /tmp/tlprobe/right.lua <<'EOF'
    package.loaded["tl"] = dofile("/tmp/tlprobe/tl.lua")
    local tl = require("tl")
    print("chunk source   =", debug.getinfo(tl.check_string, "S").source)
    print("SCRATCH_MARKER =", tostring(tl.SCRATCH_MARKER))
    EOF
    o/bin/cosmic /tmp/tlprobe/wrong.lua
    o/bin/cosmic /tmp/tlprobe/right.lua

`wrong.lua` prints, with the modified copies first on `package.path`:

    tl	nil
    cosmic.string	nil
    cosmic.json	nil
    notembedded	MODIFIED-COPY

So the shadowing is not tl-specific: every module the binary embeds
ignores `package.path`, and only a name it does not embed resolves from
it. `right.lua` — the preload form — observes the edit:

    chunk source   =	@/tmp/tlprobe/tl.lua
    SCRATCH_MARKER =	MODIFIED-COPY

The cause is `cosmic/searcher.tl`: `zip_searcher` (line 163) resolves a
module by `loadfile("/zip/" .. name .. ".lua")`, and `install_zip` (line
214) seats it at `package.searchers[2]` — ahead of the stock Lua file
searcher, the only one that reads `package.path`. Dumping the chain
with `debug.getinfo` confirms seat 2 is
`/zip/cosmic/searcher.lua:163` and seats 3-5 are the C searchers.
`package.loaded` is read by `require` before any searcher runs, which
is why the preload form cannot be beaten.

This is distinct from the `require("tl").loader()` hazard AGENTS.md
already names: that one (tl.lua line 15484) inserts tl's own searcher
at index 2 and DEMOTES `zip_searcher`. Same chain, opposite direction,
different failure.

## Change

Two files. No new module.

### 1. `_make/patch.tl` — add `patch.reverse`, the inverse of `patch.apply`

Measured 2026-08-27: `wc -l _make/patch.tl` is 255 (245 lines under the
500-line cap); `grep -c 'package.loaded' _make/patch.tl` is 0.

Add one options record and one exported function, beside the existing
`apply`:

```teal
--- Which entries to reverse, in which unpacked file, loaded as what.
local record Options
  --- The pin's source path, e.g. "3p/tl/tl_pin.tl".
  pin: string
  --- The pin's unpack directory, e.g. "o/3p/tl".
  dir: string
  --- Entry names to reverse. Must be non-empty.
  entries: {string}
  --- The file under `dir` to load, e.g. "tl.lua". Every named entry
  --- must target it.
  file: string
  --- Module name to install the loaded copy as, e.g. "tl".
  module_name: string
end

--- @return any|nil The loaded module
--- @return string The error
reverse: function(opts: Options): any, string
```

Export both through `PatchModule` (`type Options = Options` and the
`reverse` field), as `Edit` and `apply` already are.

Behaviour, in this order. Every failure returns `nil` plus one string
prefixed `make: `, in the style of the existing messages:

1. `paths_of_pin(opts.pin)` then `read_all` — propagate their errors
   unchanged. A pin carrying no patch is an error here, not a nil-nil
   miss: `"make: " .. opts.pin .. ": carries no patch to reverse"`.
2. Refuse an empty `opts.entries`:
   `"make: reverse needs at least one entry name"`.
3. Refuse a name in `opts.entries` the set does not declare, naming it
   and the pin.
4. Refuse a named entry whose `file` field is not `opts.file`, naming
   the entry, its file, and `opts.file`.
5. Read `fs.join(opts.dir, opts.file)`. For each name in
   `opts.entries` order, count occurrences of that entry's `replace`
   with the existing local `count`; unless it is exactly 1, refuse with
   a message naming the entry, the count, and that the unpack directory
   is not patched — run `--make fetch`. Otherwise rewrite with
   `str.replace(text, e.replace, e.find, 1)`.
6. Write the rewritten text into a fresh `fs.temp_dir` (under
   `TEST_TMPDIR` when set, else `/tmp`), named after `opts.file`'s
   basename. Never write into `opts.dir`.
7. `package.loaded[opts.module_name] = dofile(<that path>)`, then
   return that value. Installing before returning is the point: a
   caller handed the module and left to install it can install it
   wrong.

Give `reverse` a doc comment stating that it installs into
`package.loaded` because `require` reads that table before any
searcher, and that a caller whose process outlives the probe saves and
restores `package.loaded[opts.module_name]` itself — `reverse` does not
restore.

Then add a `Probing an entry` paragraph to the module's header doc
comment, immediately after the bullet list that ends `unpack directory
under `o/``, before the `return { … }` example. It states, as fact
about the code as it is today:

- A modified copy of a pinned file placed on `package.path` is ignored.
  `require` resolves a module the binary embeds from its own `/zip`
  before `package.path` is consulted, so such a probe measures the
  shipped copy and reports a confident wrong answer with nothing
  logged.
- `patch.reverse` is the probe: it reverses named entries into a
  temporary copy and installs it in `package.loaded`, which `require`
  reads before any searcher.

Write it to the house docs standard: state the fact as it is today, no
history, no board or issue references, no narration of who got this
wrong.

### 2. `_make/patch_test.tl` — four tests

Measured 2026-08-27: `wc -l _make/patch_test.tl` is 155;
`bin/cosmic --make test _make/patch_test.tl` ends `6 tests: 6 passed`
and `test: PASS (1 file)`.

Re-measured at pull: the test runner discovers `test_*` functions by
name. `bin/cosmic --make test _make/patch_test.tl` reports `6 test
functions` and the file carries no call lines, so new tests add none
either.

- `test_package_path_does_not_override_an_embedded_module` — pins the
  trap. With `NAME = "cosmic.string"`: write
  `<tmp>/cosmic/string.lua` returning `{SCRATCH_MARKER = "shadow"}`;
  save `package.loaded[NAME]` and `package.path`; prepend
  `<tmp>/?.lua`; assert `package.searchpath(NAME, package.path)` is the
  shadow file, so the path genuinely names it first; set
  `package.loaded[NAME] = nil`; `require(NAME)`; restore
  `package.loaded[NAME]` and `package.path` BEFORE asserting; assert
  the result's `SCRATCH_MARKER` is nil.
- `test_reverse_loads_the_reversed_copy` — synthetic fixture, no real
  pin. In a temp dir write `x_pin.tl` (`return {}`), `x_patch.tl` with
  one entry whose `file` is `m.lua`, `find` is `return {v = "stock"}`
  and `replace` is `return {v = "patched"}`, and `m.lua` holding the
  `find` text. `patch.apply` it, then `patch.reverse` with
  `module_name = "_make_patch_probe_fixture"`. Assert the returned
  table's `v` is `"stock"`, that `package.loaded[...]` is that same
  table, and that `m.lua` in the temp dir still holds the patched text
  — reverse copies, it does not edit in place. Clear
  `package.loaded[...]` at the end.
- `test_reverse_refuses_unknown_and_mismatched_entries` — on the same
  fixture, assert `reverse` returns nil plus a message for: an empty
  `entries`, a name the patch does not declare, and a name whose entry
  targets a different `file` than `opts.file`.
- `test_reverse_flips_the_checker_on_the_real_pin` — the end-to-end
  proof, against `3p/tl/tl_pin.tl` and `o/3p/tl/tl.lua`, reversing the
  single entry `narrow-truthiness`. The snippet, as a long string:

  ```
  local record R
    x: integer
  end
  local function f(r: R | nil): integer
    if not r then
      return 0
    end
    return r.x
  end
  return f
  ```

  With `cosmic.teal` as loaded, `teal.check(src, {chunk_name =
  "snippet.tl"})` reports 0 errors. Then save `package.loaded["tl"]`,
  call `patch.reverse{pin = "3p/tl/tl_pin.tl", dir = "o/3p/tl",
  entries = {"narrow-truthiness"}, file = "tl.lua", module_name =
  "tl"}`, re-check the same snippet, restore `package.loaded["tl"]`
  immediately, and only then assert: the reversed run reported at least
  one error and one of the messages contains `cannot index key`.
  Restoring before asserting is what keeps a failure from leaving a
  de-patched checker installed for the rest of the process. Verified
  by hand 2026-08-27 with the same reversal driven by a scratch
  script: shipped `0` errors, reversed `1` error, `cannot index key
  'x' in variable 'r' of type R | nil`.

## Non-goals

- **Do not touch `3p/tl/tl_patch/**`.** No entry added, removed,
  renamed, or edited. Two open PRs are changing that directory; this
  slice reads it and nothing more.
- **Do not touch `cosmic/searcher.tl`.** Its precedence is deliberate —
  an artifact running as itself resolves its own embedded modules
  first — and `wc -l cosmic/searcher.tl` is 498 against the 500-line
  cap, so there is no room for a note there. In particular, do not add
  a warning when `package.path` shadows an embedded module: that is a
  runtime behaviour change to every artifact, not this slice.
- **Do not change the existing `_make.patch` surface.**
  `paths_of_pin`, `read`, `read_all`, `applied` and `apply` keep their
  signatures and their message text. `grep -n 'patch\.[a-z_]*(' _make/fetch.tl`
  returns 5 lines today — `paths_of_pin` twice, `read_all`, `apply`,
  `applied` — and `read` is reached through `read_all`.
- **Do not edit `AGENTS.md`.** Line 176 already names `_make/patch.tl`
  as the patch mechanism, which is the pointer; the sentence around it
  is about nil-union narrowing and a probing clause does not belong in
  it.
- No new `--make` verb, no CLI flag, and no `_cli/build/` change:
  `reverse` is a module function a probe script requires.
- `reverse` does not restore `package.loaded` and does not delete its
  temporary copy. It is a probe.
- No change to `cosmic/teal.tl` or `cosmic/_teal_engine.tl`.
- Do not weaken the coverage ratchet. `.cosmic-coverage` line 75 reads
  `["_make/patch.tl"] = {["covered"] = 81, ["total"] = 87}` today; if
  `--make coverage` refuses the new floor, run exactly
  `bin/cosmic --make coverage --baseline` and commit the rewritten
  `.cosmic-coverage`. Any other way of quieting it is out of scope.

## Acceptance

Run from the repo root on a built tree.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _make/patch_test.tl` ends `test: PASS (1
  file)` and reports `10 tests: 10 passed` (6 today plus the four
  above).
- `wc -l _make/patch.tl` is ≤ 400 (255 today).
- `wc -l _make/patch_test.tl` is ≤ 300 (155 today).
- `git diff origin/main...HEAD --name-only` lists exactly
  `_make/patch.tl` and `_make/patch_test.tl` — plus `.cosmic-coverage`
  when and only when the coverage gate demanded the baseline rewrite
  above. No other path.
- `grep -c 'Probing an entry' _make/patch.tl` is 1.

## Enablement

`none needed` — no blocker items; this item IS the enablement work,
and the check below is the record of choosing its rung.

The strongest core countermeasure — making the wrong form loud — is
out of reach, and the reason is where the failure happens. The bad
probe is written in a throwaway script outside the repo, so no lint
over the tree can see it, and `--check lint` never runs on it. The only
place that could catch it is the searcher itself, and that would mean a
runtime warning in every artifact against a precedence the design
states on purpose, in a file with 2 lines of headroom. So this slice
takes the reachable core rung: a helper that makes the right probe the
short one, plus tests that pin both halves of the fact so the prose
beside them cannot rot. Stated plainly, because the capture asked:
`patch.reverse` does not remove `package.path` from reach — it adds a
right form beside the wrong one — which is why the header paragraph
lands in the same commit, in the file a session changing an entry is
already reading.

Wrong turns a literal-minded builder could take, each closed above:

- Installing a de-patched `tl` for the rest of the test process. The
  real-pin test saves `package.loaded["tl"]` and restores it before it
  asserts.
- Writing the reversed copy into `o/3p/tl/`, corrupting the build tree.
  Step 6 requires a fresh temp dir and Non-goals repeats it.
- Reversing with `string.gsub`, whose pattern semantics would maul tl
  source. Step 5 names `str.replace(..., 1)` and the exact-once count.
- Returning three slots. `reverse` returns `any` in slot 1, so slot 2
  is the error and nothing follows it — the `fallible-returns` lint
  fails the file otherwise.
- Picking a module the binary does not embed for the shadowing test,
  which would pass for the wrong reason. The test names
  `cosmic.string`.
