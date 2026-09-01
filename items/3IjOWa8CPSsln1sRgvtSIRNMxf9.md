## Goal

Close one exactness gap surfaced by the `re`/`getopt`/`argon2` census
(item YloP_x1CX, sibling of #276/#277 under the cosmo-contracts
container): `re.Regex:find`'s failure path shares its slot-2 position
(the match's absolute stop offset) with the error string on a genuine
engine failure — the same architectural shape `unix.nanosleep` is the
cited archetype for.

## Evidence

**C source**: `tool/net/lre.c:189-210` (`LuaReRegexFind`), via
`LuaReFindImpl` (`lre.c:102-131`). Reachability of the failure path is
data-dependent (a genuine regex-engine failure), not an argument-shape
violation — NOT a raise candidate.

**`tool/net/definitions.lua:1465-1492`** (current, at
`cosmic-lua/cosmopolitan` master `fd0884d9` — re-confirm line numbers
before editing):

```
---@return integer|nil start absolute 1-based offset of the first matched character
---@return integer|string|nil stop absolute 1-based offset of the last matched character (an error string when start is nil)
---@return {string} captures the parenthesized capture groups, in order
---@nodiscard
function re.Regex:find(str, flags, init) end
```

Note the terser style here versus `:search`/`:match`/`re.search`: this
one already has an inline parenthetical (`an error string when start
is nil`) explaining the overload, but lacks their fuller "the C pushes
at most N values" prose block. Whether that terser form is sufficient
or should be brought up to the fuller style is worth folding into
whatever this deviation family settles on (see Change).

**Probe** (from the cosmopolitan repo root, against
`o//tool/lua/lua` built via `make -j$(nproc) o//tool/lua/lua`):

```
$ o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:find("xxabxx"))'
```

(from YloP_x1CX's own transcript; re-run and paste fresh output when
picking this up.)

**Cosmic-side spend**: `cosmic/re.tl:280` and `cosmic/re.tl:326` both
guard the shared slot. From `scan_matches` (line ~280):

```
local s, e, caps = regex:find(text, sflags, pos)
if s == nil then
  if e is string then
    return false, e
  end
  break
end
```

and from `find` (line ~326):

```
local s, e, caps = regex:find(text, 0, 1)
if s == nil then
  if e is string then
    return nil, e
  end
```

Both sites use a type-narrowing `is string` check on `e` (the `stop`
slot) purely to tell "no match" (`e` absent/nil) apart from "engine
failure" (`e` is the error string) — the deviation's live cost, paid
twice.

## Change

This capture is **blocked on `0YFj_out2`**
(`cosmo.unix: nanosleep's failure tuple shares slots with the EINTR
remaining-time success values`), the archetype item for this tuple-
deviation family, still in `building` state as of this writing. Do not
pick this item up before `0YFj_out2` lands.

Once `0YFj_out2` is done, read its final `## Change`/result for the
settled mechanism, then:

- If it settled on **arity separation**: change `LuaReRegexFind`/
  `LuaReFindImpl` in `tool/net/lre.c` to return a genuinely separate
  error slot rather than reusing `stop`, and rewrite this binding's
  `definitions.lua` annotation (re-verify current line numbers first)
  to declare the new, non-overlapping shape — bring it to whatever
  prose style the settled family convention uses (matching the fuller
  `:search`/`:match` block style, if that's what won). Run
  `make -j$(nproc) o//tool/lua/test`.
- If it settled on **documented union accepted as-is**: decide whether
  this binding's terser inline-parenthetical style needs to be brought
  up to the fuller prose block the other three siblings in this family
  use, for consistency, or whether the terser form is fine as its own
  documented exception. Either way, state the decision in this item's
  spec explicitly rather than leaving it implicit.

Either way, re-run the probe above and paste its output. If the
contract changes shape (arity-separation branch), also leave a note on
this item naming `cosmic/re.tl:280` and `:326` as the cosmic-side sites
a follow-up item (filed separately, in the `cosmic-lua/cosmic` repo)
will need to simplify — do not make that edit here, since it is a
different repo.

## Non-goals

- No change to `re.Regex:search`, `re.Regex:match`, or `re.search`
  (module-level) — each is its own sibling capture, also blocked on
  `0YFj_out2`.
- No change to `re.compile` or `argon2.hash_encoded` — census-verified
  tuple-exact.
- No change to `getopt.parse` — a different fix family (raise
  candidate), its own sibling capture.
- No edit to `cosmic/re.tl` in this item — that is
  `cosmic-lua/cosmic`, a different repo; note the follow-up, don't make
  it here.

## Acceptance

- `re.Regex:find`'s failure path and its `definitions.lua` annotation
  agree with whatever mechanism `0YFj_out2` settled on for the family,
  and its documentation style is reconciled (or deliberately kept
  distinct, with that decision stated) against its three siblings.
- The probe above, re-run against the rebuilt binary, is pasted with
  its actual output.
- `make -j$(nproc) o//tool/lua/test` passes.
