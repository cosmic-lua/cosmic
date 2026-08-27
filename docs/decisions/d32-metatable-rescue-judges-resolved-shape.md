# D32 — the metatable is-rescue judges the resolved shape, not the spelling

- **date:** 2026-08
- **status:** active
- **context:** the carried tl patch (D21) rescues `is` dispatch on a
  `metatable<T>`-typed value: `local mt = getmetatable(x); if mt is
  {string: any} then` narrows instead of being refused, because a
  runtime `type(x) == "table"` test is exactly what a `getmetatable()`
  result supports. The rescue landed judging the target by how it was
  SPELLED. Measured 2026-08-27 with `cosmic.teal.check_file`,
  byte-identically under the tree checker and the pinned release:

  | subject | result |
  |---|---|
  | `mt is {string: any}` (inline map) | `ok=true` |
  | `type Rec = {string: any}` then `mt is Rec` | `ok=false` |
  | `mt is {string}` (inline array) | `ok=true` |
  | `type Arr = {string}` then `mt is Arr` | `ok=false` |
  | `mt is Handler` (record nominal) | `ok=false` |

  The refused cases each report `cannot resolve a type for mt here`
  twice plus `mt (of type metatable<<any type>>) can never be a
  <Name>`. The cause is where tl builds the is-fact,
  `node.known = IsFact({ var = node.e1.tk, typ = ub, w = node })` in
  `o/3p/tl/tl.lua`: the fact carries `ub`, the UNRESOLVED target, so a
  named type reaches the rescue's `is_table_metatable` helper with
  `typename == "nominal"` and matches no structural kind. An alias and
  the literal it names therefore behave differently for no reason
  anybody chose. The constraint that stopped the rescue from admitting
  records was never written down as a decision — it lived only in the
  non-goals of the completed work item that landed the rescue — so the
  next reader had nothing to read before widening or narrowing it.
- **decision:** the rescue resolves a nominal target before judging it,
  and admits it by its RESOLVED structural kind, restricted to `map`
  and `array`.
  - a target resolving to `record` or `interface` keeps failing: a
    `metatable<T>` value carries metamethod keys, not a record's
    declared fields.
  - every scalar keeps failing, aliased or not — `type S = string` then
    `mt is S` is refused exactly as `mt is string` is.
  - naming is irrelevant on both sides. An inline `{K: V}` / `{T}` and
    a `type X = {K: V}` alias of one are the same case, and the SOURCE
    side is still recognized by identity against
    `cache_std_metatable_type`, never by name.
- **rejected:**
  - **resolve and admit every table-kinded resolved kind, records and
    interfaces included.** One line shorter — the restricting set goes
    away entirely — and it is what Teal's own `is` does for an
    `any`-typed value. It loses because a `metatable<T>` value carries
    metamethod keys: narrowing it to `Handler {name: string}` would
    type `mt.name` as `string` for a field that does not exist,
    manufacturing a use-site error out of a dispatch that was supposed
    to be honest. Measured 2026-08-27: with the unrestricted set,
    `mt is Handler` flips to `ok=true`.
  - **leave the rescue inline-only and document the limitation.** It
    loses because "the inline literal narrows, the byte-identical alias
    does not" is an accident of where the is-fact is built (from `ub`,
    not from the resolved type), not a property anybody chose. Writing
    it down as a rule teaches users to inline a shape they have already
    named, which is the opposite of what the type layer is for.
  - **match the target by NAME rather than by resolved kind.** Already
    rejected when the rescue landed, in favour of identity against
    `cache_std_metatable_type`; restated here so nobody re-opens it. A
    name test is defeated by any local alias and cannot tell two
    unrelated types apart.
- **consequences:** an alias is now a first-class way to spell a
  metatable shape, so a project can name `{string: any}` once and
  dispatch on the name. Records and interfaces stay refused, so the
  rescue still cannot manufacture a field.

  The accepted cost, measured: the rescue is already unsound for the
  VALUE type. `mt is {string: integer}` checks clean under the shipped
  checker (probed 2026-08-27 under the pinned release → `ok=true`),
  typing `mt.__index` as `integer`. This decision widens the ways to
  REACH that hole — now by name as well as inline — without creating
  it. Closing it is separate work with its own decision, and this
  record does not claim to.

  What would make us revisit: an upstream tl that builds the is-fact
  from the RESOLVED type rather than `ub`. That deletes the carried
  entry outright rather than amending this record, which is D21's
  maturity clause doing its job.
