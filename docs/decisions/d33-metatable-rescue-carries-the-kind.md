# D33 — the metatable is-rescue narrows to the target's kind, not the target

- **date:** 2026-08
- **status:** active
- **context:** the carried tl patch (D21) rescues `is` dispatch on a
  `metatable<T>`-typed value, and D32 settled which targets it admits:
  resolve a nominal, then admit it by its resolved structural kind,
  restricted to `map` and `array`. What the rescue did with an admitted
  target was to hand the fact through unchanged —
  `return { [f.var] = f }` — so the narrowed variable got the target's
  FULL type, value type included. A `metatable<T>`'s values are
  metamethods, not the target's values, so that narrowing manufactured
  a type the runtime never has. Measured 2026-08-27 with
  `cosmic.teal.check_file` against the derived checker
  (`package.loaded["tl"] = dofile("o/3p/tl/tl.lua")` — a `package.path`
  probe silently measures the copy the binary embeds instead):

  | subject | result |
  |---|---|
  | `mt is {string: integer}` then `mt.__index + 1` | `ok=true` |
  | `type Ints = {string: integer}`; `mt is Ints`; `mt.__index + 1` | `ok=true` |
  | `mt is {integer}` then `mt[1] + 1` | `ok=true` |
  | `mt is {string: integer}` then `local m: {string: integer} = mt` | `ok=true` |

  `mt.__index` typed as `integer`; at runtime it is a function, so
  `mt.__index + 1` throws — the checker passed a program that cannot
  run. The last row is why it mattered beyond the guard: the invented
  type assigns out into ordinary variables and arguments.

  D32 stated this as its accepted cost and said closing it was separate
  work with its own decision. This is that decision.

  What the checker can already spell needs no invention. `metatable<T>`
  is a record in tl's stdlib whose `__index`/`__newindex` are declared
  `any`, and on an unnarrowed `local mt = getmetatable(x)` the tree
  checker already types `mt.__index` as `any`, refuses `mt.nope`
  (`invalid key 'nope' in record 'mt'`), and refuses `#mt` and `mt[1]`.
- **decision:** the rescue admits a target by its KIND, so only the
  kind reaches the narrowed variable. The is-fact is rebuilt over the
  resolved target's kind with `any` values — a `map` target narrows
  `mt` to `{K: any}` with the target's key type kept, an `array` target
  to `{any}` — and the target's own value type is discarded.
  - `mt is {string: integer}` narrows `mt` to `{string: any}`, so
    `mt.__index` stays `any` and `mt.__index + 1` is refused
    (`cannot use operator '+' for types <any type> and integer`).
  - the same holds through a name: the rescue resolves the nominal
    before rebuilding, so an alias and the literal it names open
    identically, which is D32's rule applied to the value axis.
  - what the rescue admits is unchanged. Every target D32 admits still
    narrows and every target it refuses still fails; only the type the
    narrowed variable receives is weaker.
- **rejected:** three options that also close the hole, each measured
  2026-08-28 by loading a candidate checker with
  `package.loaded["tl"] = dofile(<edited copy of o/3p/tl/tl.lua>)` and
  re-running the subjects above plus the seven `test_metatable_*` cases
  in `cosmic/teal_metatable_test.tl`.
  - **narrow to nothing — leave `mt` at `metatable<T>`.** The most
    honest option available: `mt.nope` becomes an invalid-key error
    rather than passing. It loses because it flips the two array cases
    (inline `{string}` and an alias of one, both of which use `#mt`) to
    `ok=false` with `cannot use operator '#' on type
    metatable<<any type>>`. The array half of D32 would stop admitting
    anything, one day after it was decided.
  - **drop the positive rescue entry entirely, keeping the kind helper
    and the negated-branch entry.** The intuitive revert of the unsound
    half. It loses because it flips three of the seven cases to
    `ok=false` (`mt (of type metatable<<any type>>) can never be a
    Meta`), including the `{string: any}` ALIAS — which is D32's whole
    contribution. The inline `{string: any}` survives a deletion
    because tl's own subtyping admits it a branch earlier, so the
    rescue's positive half exists only for targets a metatable is not.
  - **refuse a target whose value type is not `any`.** Turns the
    unsound narrowing into a hard error rather than a weaker type. It
    loses because it re-introduces on the value axis exactly the
    asymmetry D32 removed on the naming axis: `{string: any}` narrows
    and the byte-equivalent `{string: integer}` is refused, with an
    error that names no fix.
- **consequences:** the rescue can no longer manufacture a value type,
  so a narrowed metatable's metamethods type as `any` and nothing the
  guard produces escapes into a concrete map or array. Four subjects
  that checked clean now fail, and none of them could run.

  The accepted cost: `any` is not the honest type either. A narrowed
  `mt` still accepts `#mt` and `mt[1]` because it is an array or map,
  where the record `metatable<T>` would refuse both — the kind test is
  what the runtime supports, and carrying only the kind is as close to
  the truth as the rescue can get without taking D32's array half away.
  A guard that wants real metamethod typing does not narrow at all: the
  unnarrowed `metatable<T>` already types `__index` as `any` and
  refuses an undeclared key.

  What would make us revisit: an upstream tl that builds the is-fact
  from the resolved type rather than the unresolved target. That
  deletes the carried entry outright rather than amending this record —
  D21's maturity clause, restated so nobody reads this record as a
  reason to keep the patch.
