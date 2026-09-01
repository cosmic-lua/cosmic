## Goal

Close one exactness gap surfaced by the `re`/`getopt`/`argon2` census
(item YloP_x1CX, sibling of #276/#277 under the cosmo-contracts
container): the module-level `re.search` (compile-then-search-once
convenience function, distinct from the `re.Regex:search` method) has
the identical tuple-deviation shape as its method-form siblings — slot
2 shares the capture-groups table (match) with the error string
(compile or engine failure) — the same architectural shape
`unix.nanosleep` is the cited archetype for.

## Evidence

**C source**: `tool/net/lre.c:136-153` (`LuaReSearch`) — compiles the
pattern and searches once, rather than reusing a precompiled `re.Regex`
the way the method form does. Failure is reachable two ways: a bad
pattern at compile time, or a genuine `regexec()` engine failure at
search time — both data-dependent (a malformed, normally
caller/user-supplied pattern string, or an engine failure), not an
argument-shape violation a correct caller avoids by construction — NOT
a raise candidate.

**`tool/net/definitions.lua:1510-1527`** (current, at
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
function re.search(regex, text, flags) end
```

Byte-identical prose block to `re.Regex:search`'s and
`re.Regex:match`'s current annotations — already a documented union,
not a silently-wrong plain type. As with its siblings, the open
question is whether that counts as the accepted final shape for the
family, or whether the family instead gets a C-level arity change —
`0YFj_out2` is deciding this (see Change below).

**Probe** (from the cosmopolitan repo root, against
`o//tool/lua/lua` built via `make -j$(nproc) o//tool/lua/lua`):

```
$ o//tool/lua/lua -e 'local re=require("cosmo.re"); print(re.search("[invalid", "xxabxx"))'
```

(from YloP_x1CX's own transcript, demonstrating the compile-failure
branch; re-run and paste fresh output when picking this up. Also worth
probing the search-time engine-failure branch and the plain-match
branch for completeness, since the census only exercised one of the
two failure paths.)

**Cosmic-side spend**: `grep -rn '\bre\.search(' cosmic/` in a
`cosmic-lua/cosmic` checkout → zero hits. Nothing in cosmic's own
wrapper calls this module-level convenience function; `cosmic/re.tl`
builds its own `compile`/`match`/`find` API on top of `re.compile` and
the `Regex` methods instead. No cosmic wrapper is affected by whatever
this item changes.

## Change

This capture is **blocked on `0YFj_out2`**
(`cosmo.unix: nanosleep's failure tuple shares slots with the EINTR
remaining-time success values`), the archetype item for this tuple-
deviation family, still in `building` state as of this writing. Do not
pick this item up before `0YFj_out2` lands — it is deciding the fix
mechanism for the whole family, and this capture must match whatever
it settles rather than invent an independent shape.

Once `0YFj_out2` is done, read its final `## Change`/result for the
settled mechanism, then:

- If it settled on **arity separation**: change `LuaReSearch` in
  `tool/net/lre.c` to return a genuinely separate error slot instead of
  reusing the captures-table position (for BOTH of its failure
  branches — compile failure and engine failure), and rewrite this
  binding's `definitions.lua` annotation (re-verify current line
  numbers first) to match. Run `make -j$(nproc) o//tool/lua/test`.
- If it settled on **documented union accepted as-is**: this binding's
  current annotation (quoted above) already carries that shape and
  prose, byte-identical to `re.Regex:search`'s. Confirm it still
  matches whatever canonical style `0YFj_out2` settled and align
  wording if it differs; otherwise close this item noting no change
  was needed beyond confirming conformance.

Either way, re-run the probe above (both failure branches, if you
extend it) against the freshly built binary and paste the output.

## Non-goals

- No change to `re.Regex:search`, `re.Regex:match`, or `re.Regex:find`
  — each is its own sibling capture, also blocked on `0YFj_out2`. (Note:
  despite the near-identical prose, `re.search` is a genuinely
  different C function — `LuaReSearch`, not `LuaReRegexSearch` — so its
  C-side fix, if the arity-separation branch is chosen, is a separate
  edit from the method forms', not shared code.)
- No change to `re.compile` or `argon2.hash_encoded` — census-verified
  tuple-exact.
- No change to `getopt.parse` — a different fix family (raise
  candidate), its own sibling capture.
- No cosmic-side (`cosmic-lua/cosmic`) change — zero callers found;
  nothing there needs to move regardless of which mechanism this
  settles on.

## Acceptance

- `re.search`'s failure path (both branches) and its `definitions.lua`
  annotation agree with whatever mechanism `0YFj_out2` settled on for
  the family.
- The probe above, re-run against the rebuilt binary, is pasted with
  its actual output.
- `make -j$(nproc) o//tool/lua/test` passes.
