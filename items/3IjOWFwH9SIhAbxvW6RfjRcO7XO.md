## Goal

Close one exactness gap surfaced by the `re`/`getopt`/`argon2` census
(item YloP_x1CX, sibling of #276/#277 under the cosmo-contracts
container): `re.Regex:match`'s failure path shares its slot-2 position
between two unrelated meanings — the capture-groups table on a match,
and the error string on a genuine engine failure — the same
architectural shape `unix.nanosleep` is the cited archetype for. Unlike
its sibling `re.Regex:search` (zero cosmic callers), this one has a
live cosmic-side caller paying the deviation's cost today.

## Evidence

**C source**: `re.Regex:match` is the SAME underlying C function as
`re.Regex:search` — `tool/net/lre.c:227`, `kLuaReRegexMeth[]` maps both
Lua-facing method names to `LuaReRegexSearch` (`lre.c:175-187`, via
`LuaReSearchImpl` at `lre.c:66-93`). The C pushes at most two values:
`(match, captures)` on a match, a bare `nil` on no-match, or
`(nil, err)` on a genuine `regexec()` engine failure — never three.
Reachability is data-dependent (a real engine failure), not an
argument-shape violation — NOT a raise candidate.

**`tool/net/definitions.lua:1443-1462`** (current, at
`cosmic-lua/cosmopolitan` master `fd0884d9` — re-confirm line numbers
before editing):

```
---@return string|nil match the whole matched substring; nil both when
--- nothing matched and when the search failed
---@return {string}|string|nil captures the parenthesized capture groups
--- (in order) on a match, or the error string when it failed. The C
--- pushes at most two values: `(match, captures)`, a bare `nil` for a
--- no-match, or `(nil, err)`. A third slot was annotated here and never
--- returned, so a generated binding declared a value that does not exist.
---@nodiscard
function re.Regex:match(str, flags) end
```

As with `re.Regex:search`, this annotation already unions the shared
slot honestly with explanatory prose — it is not the silently-wrong
plain-type shape `unix.openpty` had before its fix. The open question
is whether that documented union is the accepted final shape for this
family, or whether the family instead gets a C-level arity change that
removes the overlap outright — `0YFj_out2` is deciding this for the
whole family (see Change below).

**Probe** (from the cosmopolitan repo root, against
`o//tool/lua/lua` built via `make -j$(nproc) o//tool/lua/lua`):

```
$ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:match("xxabxx"))'
```

(from YloP_x1CX's own transcript; re-run and paste fresh output when
picking this up.)

**Cosmic-side spend** (the live cost this capture, if it changes the
contract, has downstream implications for — though fixing that
downstream code is out of scope here, see Non-goals):
`cosmic/re.tl:184-196` (function `match`) calls `regex:match(text)` and
must hand-decode the shared slot at runtime:

```
local m, caps = regex:match(text)
if not m then
  if caps then
    -- Engine failure: the binding reports nil, err.
    return nil, tostring(caps)
  end
  -- No match is not an error.
  return nil
end
```

This `if caps then ... else ...` branch — telling a captures table
apart from an error string by shape alone — is the deviation's live,
paid-for cost in cosmic today.

## Change

This capture is **blocked on `0YFj_out2`**
(`cosmo.unix: nanosleep's failure tuple shares slots with the EINTR
remaining-time success values`), the archetype item for this tuple-
deviation family, still in `building` state as of this writing. Do not
pick this item up before `0YFj_out2` lands.

Once `0YFj_out2` is done, read its final `## Change`/result for the
settled mechanism, then:

- If it settled on **arity separation**: change
  `LuaReRegexSearch`/`LuaReSearchImpl` in `tool/net/lre.c` (shared with
  `:search`, so land that C change once and it fixes both methods
  together — coordinate with whoever holds the `:search` capture so
  the C edit isn't duplicated) to return a genuinely separate error
  slot, and rewrite this binding's `definitions.lua` annotation
  (re-verify current line numbers first) to match. Run
  `make -j$(nproc) o//tool/lua/test`.
- If it settled on **documented union accepted as-is**: this binding's
  current annotation (quoted above) already carries that shape.
  Confirm it matches whatever canonical style `0YFj_out2` settled and
  align wording if it differs.

Either way, re-run the probe above and paste its output. If the
contract genuinely changes shape (the arity-separation branch), also
leave a note on this item naming `cosmic/re.tl:184-196` as the
cosmic-side site a follow-up item (filed separately, in the
`cosmic-lua/cosmic` repo) will need to simplify once the shared slot is
gone — do not make that edit here, since it is a different repo.

## Non-goals

- No change to `re.Regex:search`, `re.Regex:find`, or `re.search`
  (module-level) — each is its own sibling capture, also blocked on
  `0YFj_out2`. (`:search` shares the SAME C function as `:match` — see
  above — so the two C-side fixes are one edit; coordinate, don't
  duplicate.)
- No change to `re.compile` or `argon2.hash_encoded` — census-verified
  tuple-exact.
- No change to `getopt.parse` — a different fix family (raise
  candidate), its own sibling capture.
- No edit to `cosmic/re.tl` in this item — that is
  `cosmic-lua/cosmic`, a different repo; note the follow-up, don't make
  it here.

## Acceptance

- `re.Regex:match`'s failure path and its `definitions.lua` annotation
  agree with whatever mechanism `0YFj_out2` settled on for the family.
- The probe above, re-run against the rebuilt binary, is pasted with
  its actual output.
- `make -j$(nproc) o//tool/lua/test` passes.
