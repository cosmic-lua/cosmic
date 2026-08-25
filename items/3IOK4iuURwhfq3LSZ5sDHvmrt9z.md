## Goal

G3 — close the **binding boundary** class of `from any` casts. The class was
filed as "13 sites, closed by annotating `tool/net/definitions.lua` in
whilp/cosmopolitan, then bumping the pin here". **That premise does not hold.**
Re-measured 2026-08-25 against `77f185b0` (the census in
`docs/design/casts.md` is dated `d3e59de7`), the 13 sites split five ways, and
only five of them are closable at all — all five inside this repository, with
no cosmopolitan change and no pin bump:

| sites | where | what actually closes it |
| --- | --- | --- |
| 3 | `cosmic/signal.tl:259,260,261` | nothing — the casts are already dead |
| 2 | `cosmic/url.tl:64,204` | `_types/gentype_render.tl` (this repo) |
| 1 | `cosmic/zip.tl:222` | irreducible: Teal forbids the union |
| 1 | `cosmic/fd.tl:187` | nothing: `fcntl`'s return really is cmd-dependent |
| 1 | `cosmic/teal.tl:166` | not a `cosmo.*` binding — `tl.d.tl`, via `_types/gentl.tl` |
| 2 | `cosmic/errno.tl:52`, `cosmic/quicksand/proc.tl:262` | not a return type — a dynamic name lookup off the `unix` table |
| 3 | `cosmic/coverage/init.tl` | not this class — stdlib monkey-patching |

The measurements behind each row are in `Non-goals`, which is where the eight
sites this slice does **not** touch are walled off with the evidence that they
do not belong here. This slice takes the five that close.

## Change

**1. `_types/gentype_inline.tl` (new file).** `cosmo.ParseParams` is annotated
`---@return { [1]: string, [2]: string? }[] params` — the exact shape
`cosmic/url.tl` casts to — but `convert_type` in `_types/gentype_render.tl`
renders it `any`, because its inline-struct guard (`if t:match("^{.*:") then
return "any" end`, line 68 today) fires before the `[]`-suffix branch below it
and nothing maps a positional struct. Put the two missing conversions in a new
shard rather than in `convert_type` itself: `wc -l < _types/gentype_render.tl`
is 486, so the 500-line cap leaves 14 lines and the branches do not fit.

Export one function:

```teal
--- @param t string The LuaLS type
--- @param convert function(string): string convert_type, for member types
--- @return string | nil The Teal type, or nil when t is not one of these forms
inline_array: function(t: string, convert: function(string): string): string | nil
```

It recognises exactly two forms and returns `nil` for everything else:

- **a bracketed struct array** — `t` matching `^({.*})%[%]$`: return
  `"{" .. convert(inner) .. "}"`.
- **a positional struct** — `t` matching `^{%s*%[1%]%s*:%s*(.+)}$`: split the
  body on commas, strip each member's `[n]:` label and its trailing `?`,
  `convert` each, and return `"{" .. elem .. "}"` when every member converts
  to the SAME Teal type. Return `nil` when they differ — Teal has no tuple
  type, so a mixed positional struct has no honest rendering and must keep
  falling through to `any`.

**2. `_types/gentype_render.tl`.** `require` the shard and call it from
`convert_type` immediately BEFORE the `if t:match("^{.*:")` guard, passing
`convert_type` itself as the callback; return its result when non-nil. Order
matters: after the guard the form is already `any`. Three lines; the file ends
at 489 or below, which is an Acceptance command.

**3. `_types/gentype_inline_test.tl` (new file).** Cover both recognised forms,
the mixed-member case that must stay `nil`, and a plain inline struct
(`{ name: string }`) that must stay `nil`. House test form — one `test_*`
function called on the line after its `end`. A new file, not an addition to
`_types/gentype_test.tl`: that file is 494 lines, 6 under the cap.

**4. `cosmic/url.tl`.** With the declaration concrete, both casts are
redundant: drop `as {{string}}` and the trailing `-- cast: from any` on lines
64 and 204. The file's third cast (line 54, `-- cast: %x%x is a hex pair`)
stays.

**5. `cosmic/signal.tl`.** Lines 259–261 cast `sigaction`'s second, third and
fourth returns "from any", but the generated declaration has been concrete for
some time — `o/_types/types_gen/cosmo/unix.d.tl` declares `sigaction:
function(...): function | integer | nil, integer, Sigset, string, Errno`. The
three casts narrow nothing. Verified 2026-08-25: replacing the block

```teal
  local phandler = prev as (function | integer) -- cast: from any
  local pflags = prev_flags as integer -- cast: from any
  local pmask = prev_mask as Sigset -- cast: from any
  return {handler = phandler, flags = pflags, mask = pmask}
```

with `return {handler = prev, flags = prev_flags, mask = prev_mask}` and
running `bin/cosmic --check types cosmic/signal.tl` prints
`Type check passed: cosmic/signal.tl`. Make that replacement. The file's other
two casts (line 250 `-- cast: handler union`, line 291 `-- cast: record built
incrementally`) stay.

**6. `_build/casts_baseline.tl`.** Run exactly the regen command the gate's
failure message prints (`bin/cosmic --make run _build/casts.tl --baseline`) and
commit the result; same for `.cosmic-coverage` if `--make ci` asks for it. Read
the regenerated diff before committing: only the rows this change touches may
move — a lowered row anywhere else means the regen ran against a partial tree,
so re-run it, never commit it.

**Blast radius, measured.** Prototyped 2026-08-25 and diffed
`o/_types/types_gen` before and after a build with the change: exactly one
declaration line moves,
`ParseParams: function(paramstring: string): any` →
`ParseParams: function(paramstring: string): {{string}}`. No other generated
declaration changes.

## Non-goals

- **No change to `whilp/cosmopolitan`, and no pin bump.** Nothing in this slice
  needs one. Do not open a PR there, do not touch `3p/cosmos/cosmos_pin.tl`.
- **`cosmic/zip.tl:222` stays.** `zip.open` IS annotated upstream
  (`---@return zip.Reader|zip.Writer|zip.Appender? archive`), and
  `convert_type` degrades it deliberately: Teal cannot discriminate a union of
  several table types. Verified 2026-08-25 — a file declaring `function():
  A | B | C | nil` over three records fails with `error: cannot discriminate a
  union between multiple table types`. Closing this site needs a different
  upstream return SHAPE, which AGENTS.md freezes. Do not touch the
  `table_count > 1` branch in `convert_type`.
- **`cosmic/fd.tl:187` stays.** `unix.fcntl` is declared `function(fd: integer,
  cmd: FcntlCmd, ...: any): any | nil, string, Errno` and the `any` is honest —
  what `fcntl` returns depends on `cmd`. Verified 2026-08-25: dropping the cast
  fails `--check types` with `got <any type> ... expected integer | nil`.
- **`cosmic/teal.tl:166` stays.** `tl.search_module`'s second return comes from
  `tl.d.tl`, generated by `_types/gentl.tl` from the pinned tl source — a
  different generator with a different upstream. Verified 2026-08-25: dropping
  the cast fails with `cannot index key 'close' in variable 'fd' of type <any
  type>`. Do not touch `_types/gentl.tl`.
- **`cosmic/errno.tl:52` and `cosmic/quicksand/proc.tl:262` stay.** Both index
  the `unix` table by a runtime string to reach an `E*` or `SIG*` constant. No
  return annotation reaches them; closing them would need a generated
  name-to-value map, which is separate work.
- **`cosmic/coverage/init.tl` stays.** Its `from any` casts are stdlib
  monkey-patching (`coroutine as {string: any}`, `co["create"]`, `os_mod
  ["exit"]`) — the dynamic-value class, item `3IOuSKFx`, not this one.
- **Do not rewrite `docs/design/casts.md`.** It is a dated census against
  `d3e59de7` and is meant to read as one; re-measuring it is separate work,
  and the correction this refinement made lives in this spec.
- No cast may be added anywhere in the diff, and no gate is weakened or
  exempted to make the numbers move.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _types/gentype_inline_test.tl` passes.
- `grep -n "ParseParams" o/_types/types_gen/cosmo.d.tl` shows
  `ParseParams: function(paramstring: string): {{string}}`. Today it shows
  `: any`.
- `grep -c -- "-- cast: " cosmic/url.tl` reports `1` (today `3`) and
  `grep -c -- "-- cast: " cosmic/signal.tl` reports `2` (today `5`).
- `grep -c -- "-- cast: " _types/gentype_inline.tl _types/gentype_inline_test.tl`
  reports `0` for both files.
- `grep -n '"cosmic/url.tl"\|"cosmic/signal.tl"' _build/casts_baseline.tl`
  shows `["cosmic/signal.tl"] = 2` and `["cosmic/url.tl"] = 1`. Today they are
  `5` and `3`.
- `grep -c -- "-- cast: .*from any" cosmic/zip.tl cosmic/fd.tl cosmic/teal.tl`
  reports `1` for each — the three walled-off sites are untouched.
- `wc -l _types/gentype_render.tl _types/gentype_inline.tl
  _types/gentype_inline_test.tl` reports `_types/gentype_render.tl` at 489 or
  below (today 486) and every file at 500 or below.
- `git diff --stat origin/main -- 3p/cosmos/cosmos_pin.tl` prints nothing —
  no pin moved.

## Enablement

none needed. Every fact this spec rests on was measured during the refinement
that wrote it, with the command that produced it stated beside it, and every
wrong turn it predicts is caught by a gate that already exists: the cast
justification lint and `_build/casts.tl`'s ratchet catch a cast smuggled into
the new shard, `--check types` catches a narrowing that does not hold, `--check
lint` catches the 500-line cap, and the coverage ratchet catches an untested
branch. The countermeasures are therefore the walls in `Non-goals` rather than
new machinery.

One enablement finding this refinement produced, recorded here rather than
acted on: `docs/design/casts.md`'s "Binding boundary" section is wrong about 11
of its 13 sites, and this item inherited that error verbatim at intake. A
census that is copied into specs is load-bearing, and this one has no gate. Its
correction is separate work.
