## Goal

Close one exactness gap surfaced by the `re`/`getopt`/`argon2` census
(item YloP_x1CX, sibling of #276/#277 under the cosmo-contracts
container): `re.Regex:search`'s failure path shares its slot-2
position between two unrelated meanings — the capture-groups table on
a match, and the error string on a genuine engine failure — the same
architectural shape `unix.nanosleep` is the cited archetype for.

## Evidence

**C source** — `tool/net/lre.c:175-187` (`LuaReRegexSearch`), calling
`LuaReSearchImpl` (`lre.c:66-93`). The C pushes at most two values:
`(match, captures)` on a match, a bare `nil` on no-match, or
`(nil, err)` on a genuine `regexec()` engine failure (`lre.c:64-65`) —
never three. Reachability is data-dependent (a real engine failure,
e.g. out of memory), not an argument-shape violation a correct caller
avoids by construction — so this is NOT a raise candidate; the fix
lives in the tuple shape, not in converting the return to a Lua error.

**`tool/net/definitions.lua:1420-1440`** (current, at
`cosmic-lua/cosmopolitan` master `fd0884d9` — re-confirm line numbers
haven't drifted before editing):

```
---@return string|nil match the whole matched substring; nil both when
--- nothing matched and when the search failed
---@return {string}|string|nil captures the parenthesized capture groups
--- (in order) on a match, or the error string when it failed. The C
--- pushes at most two values: `(match, captures)`, a bare `nil` for a
--- no-match, or `(nil, err)`. A third slot was annotated here and never
--- returned, so a generated binding declared a value that does not exist.
---@nodiscard
function re.Regex:search(str, flags) end
```

Note for whoever picks this up: the annotation here is **already** a
union (`{string}|string|nil`) with prose spelling out both branches —
it is not the "silently wrong plain type" shape `unix.openpty` had
before its fix (board handle `Kjua_j899`). What's still true is the
underlying architectural fact the census flagged: slot 2 does double
duty (captures table vs. error string) at the C level itself, which is
exactly `unix.nanosleep`'s shape, not `unix.openpty`'s (openpty's C was
already a clean, if under-annotated, 3-value contract; nanosleep's C
genuinely reuses a position across success and failure). Whether that
counts as "already fixed" or still needs a C-level arity change is the
open question `0YFj_out2` is deciding for the whole family — see
Change below.

**Probe** (from the cosmopolitan repo root, against
`o//tool/lua/lua` built via `make -j$(nproc) o//tool/lua/lua`):

```
$ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:search("xxabxx"))'
```

(from YloP_x1CX's own transcript; re-run and paste fresh output when
picking this up, since it wasn't re-pasted in that item's summary row)

**Cosmic-side spend**: `grep -rn ':search(' cosmic/` in a
`cosmic-lua/cosmic` checkout → zero hits. `cosmic/re.tl` never calls
`:search` — it uses `:match` (same underlying C function, see the
sibling capture for `re.Regex:match`) instead, per its own comment. No
cosmic wrapper is affected by whatever this item changes.

## Change

This capture is **blocked on `0YFj_out2`**
(`cosmo.unix: nanosleep's failure tuple shares slots with the EINTR
remaining-time success values`), the archetype item for this exact
tuple-deviation family, still in `building` state as of this writing.
Do not pick this item up before `0YFj_out2` lands — it is deciding the
fix mechanism (either a C-level return-arity change so no slot is
reused across success/failure, or a decision that documented-union is
an accepted exception) for the whole family, and this capture must
match whatever it settles rather than invent an independent shape.

Once `0YFj_out2` is done, read its final `## Change`/result for the
settled mechanism, then:

- If it settled on **arity separation** (a genuinely separate trailing
  slot for the error, never overlapping a real success value): change
  `LuaReRegexSearch`/`LuaReSearchImpl` in `tool/net/lre.c` to return a
  distinct extra slot for the error string rather than reusing the
  captures-table position, and rewrite the `definitions.lua` annotation
  above (re-verify its current line numbers first) to declare the new,
  non-overlapping shape. Run `make -j$(nproc) o//tool/lua/test`.
- If it settled on **documented union accepted as-is**: this binding's
  current annotation (quoted above) already carries that shape and
  prose. Verify it matches whatever canonical phrasing/style
  `0YFj_out2` established (e.g. does it want the prose to explicitly
  name the failure tuple the way the `unix.openpty` fix did?) and bring
  it into alignment if the wording differs; otherwise close this item
  noting no change was needed beyond confirming conformance.

Either way, re-run the probe above against the freshly built binary
and paste its output.

## Non-goals

- No change to `re.Regex:match`, `re.Regex:find`, or `re.search`
  (module-level) — each is its own sibling capture, filed alongside
  this one and also blocked on `0YFj_out2`.
- No change to `re.compile` or `argon2.hash_encoded` — the census
  verified both tuple-exact; not in scope anywhere in this family.
- No change to `getopt.parse` — a different fix family entirely (a
  raise-candidate, not a tuple deviation), its own sibling capture.
- No cosmic-side (`cosmic-lua/cosmic`) change — `cosmic/re.tl` has zero
  callers of `:search`, so nothing there needs to move regardless of
  which mechanism this settles on.

## Acceptance

- `re.Regex:search`'s failure path and its `definitions.lua` annotation
  agree with whatever mechanism `0YFj_out2` settled on for the family.
- The probe above, re-run against the rebuilt binary, is pasted with
  its actual output.
- `make -j$(nproc) o//tool/lua/test` passes.
