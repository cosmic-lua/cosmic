## Goal

`_work/item.tl`'s `Item` record has no field recording which session
filed it. `claim`, `builders`, `speccers`, and `reviewer` all exist for
LATER lifecycle events (take, spec, verdict) — `new` writes none of
their kind. A spec that needs to know "which session filed item X" has
no field to read; it can only guess from commit-message text, which
`_work/gitfriction.tl`'s own doc comment names outright: "There is no
session field on a `new` commit, so a past `friction:` filing cannot
be attributed to an orchestrator by reading the log alone."

## Evidence

Two independent sessions, one pass (`3IrjZESx.../GDeh_uJY2`'s friction
log), hit this from opposite directions on the same item
(`zvR2_ujhh`):

- **Builder**: the item's spec described a fact as knowable from the
  board log — "the previous `friction:` item THIS orchestrator filed"
  — that the wire format cannot actually support. ~15 minutes and
  several greps/reads across `_work/brief.tl`, `_work/session.tl`,
  `_work/identity.tl`, and item files before confirming `new` commits
  carry no session field at all (unlike `take`/`spec`/`verdict`,
  which do), then inferred and documented a fallback interpretation
  ("most recent friction item by ANYONE") rather than stopping.
- **Reviewer**: round 1 confirmed the builder's inferred fallback was
  a real bug, not just a documentation gap — the boundary-detection
  code scans backward for "the previous friction item this
  orchestrator filed" but cannot distinguish orchestrators, so a
  concurrent orchestrator's own unrelated filing could silently
  satisfy this one's roll-call requirement.

The rework that landed in response (round 2, accepted, merged) did
NOT add the field — it redesigned around the gap instead
(`_work/gitfriction.tl`'s `claim_agent`/roll-call logic): a claim now
counts as "accounted for" once it appears as a heading in SOME
already-filed `friction:` item, whoever filed it, rather than trying
to attribute filings to orchestrators at all. That redesign is sound
and already passed adversarial review (mutation-tested against the
original bug at the attribution layer, not just the boundary-scan
layer round 1 broke) — this item does not touch it. But the underlying
absence — `new` carries no session field, full stop — is a real,
general gap for any future spec or tool that needs the same fact
`gitfriction.tl` worked around rather than had answered directly.

## Change

1. `_work/item.tl`'s `Item` record: add `opener: string` — "the
   session that filed this item via `new`; `''` for an item that
   predates this field." Plain string, not a list (`builders`)/set —
   `new` runs exactly once per item, so there is exactly one filer,
   unlike `claim`'s lease (which moves) or `builders`'s audit trail
   (which accumulates across takeovers).
2. `SPEC`/`Raw` shapes (`item.tl`'s `shape.record({...})` and the
   `Raw` record beside it): add `opener = shape.optional(shape.string)`
   /`opener: string | nil`, matching `reviewer`'s existing treatment
   exactly (a plain optional string, no list-splitting).
3. `decode`: `opener = raw.opener or ""`, same line shape as
   `reviewer = raw.reviewer or ""`.
4. `encode`: `if (it.opener or "") ~= "" then t.opener = it.opener end`,
   same shape as the existing `repo`/`base`/`reviewer` lines — zero
   value omitted, so an item with no recorded opener (created before
   this field, or via a path that legitimately sets none) writes no
   `opener` key at all, and the file diff for every future `new` shows
   exactly the one new line.
5. `_work/gitgraph.tl`'s `cmd_new`: takes the filing session (resolved
   the same way `cmd_take`/`cmd_attach`'s callers already resolve it —
   `_work.session.resolve`, the same identity `gitboard show`'s
   "session: ... (from CLAUDE_CODE_SESSION_ID)" line already prints)
   and sets `it.opener` on the record built at line ~77, alongside
   `id`/`title`/`parent`/`repo`. No new refusal: an item files
   successfully with an empty `opener` exactly as today if the calling
   process has no resolvable session identity — `opener` follows
   `claim`'s existing "empty is a valid, meaningful value" precedent,
   not `repo`'s new required-ness (a separate item, `HlNE_YWL2`, not
   this one).
6. `_work/gitboard.tl`'s CLI dispatcher: no new flag — `opener` is
   derived from the caller's own resolved session exactly like `take`'s
   default session, never supplied explicitly, so `new` cannot be used
   to claim authorship on another session's behalf.
7. Tests (`_work/item_test.tl`, `_work/gitgraph_test.tl`): `new`
   sets `opener` to the calling session's resolved identity; an item
   decoded from a file with no `opener` key gets `""`, not a decode
   failure (backward compatibility with every existing item file);
   `encode` round-trips a set `opener` and omits an empty one, matching
   `reviewer`'s existing round-trip test shape.

## Non-goals

Not touching `_work/gitfriction.tl`'s claim-attribution redesign —
it already works, already passed adversarial review, and does not
need `opener` to keep working; this item only makes the fact
available for whoever next needs it (a future spec, a future gate),
not a mandate to rewire the friction gate onto it. Not backfilling
`opener` on any existing item — every item filed before this change
keeps `opener = ""` forever, same as `verdict_spec`'s own documented
precedent ("'' on an item verdicted before the field existed —
unknown, which is not the same as unchanged, and nothing may be
concluded from it"). Not a `--session` override flag on `new` (unlike
`take`, which explicitly supports claiming under an named session for
recovery scenarios) — filing-authorship has no equivalent recovery
need identified, and adding one un-asked-for would let one session
misattribute a filing to another. Not touching `claim`/`builders`/
`speccers`/`reviewer`'s own shapes or semantics.
