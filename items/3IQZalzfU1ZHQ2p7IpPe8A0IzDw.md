## Goal

G3 — an honest type layer. D23 closed the throw exemption list: "**No
other `cosmic.*` module may throw or exit.** The only other sanctioned
throws are D22's." `cosmic.time` needs a seat on that list, and taking
one without amending the record would make the record false.

## Change

Amend `docs/decisions/d23-check-throws.md` (the `decide` skill has the
form and the amend-versus-supersede rule) so the closed list either
admits a third entry or states the rule the third entry satisfies. The
rule is the interesting half: `cosmic.time.now()` reads
`unix.clock_gettime(unix.CLOCK_REALTIME)`, whose `integer | nil` first
slot is honest for an arbitrary caller-supplied clock id (EINVAL on an
unsupported one) and UNREACHABLE for the two constants cosmic passes.
That is a different shape from D22's CSPRNG throws and from check's: it
is not "the caller is the runner" and not "a contract violation", it is
"the binding's union has no reachable nil at this call".

So the amendment decides whether the exemption is

- **enumerated** — a third named module, and the next one needs another
  amendment; or
- **ruled** — a library may `assert` a value the binding's declaration
  admits but the call cannot produce, with the unreachability argued at
  the site. That admits `cosmic.time` and every future site of the same
  shape, and it draws a line an author can apply without asking.

Say which, say why, and record what was rejected.

## Non-goals

- **Do not edit `cosmic/time.tl`.** That is 3IPXQcgW, which this item
  unblocks; a doctrine change that lands inside the diff it licenses
  proves nothing.
- **Do not reopen D22 or D23's substance.** `check`'s exemption and the
  CSPRNG's stand; this is about whether the list is closed.
- **Do not widen this to "when may library code throw" in general.**
  The question is one shape, evidenced by one site.

## Acceptance

- `docs/decisions/d23-check-throws.md` carries the amendment in the
  form the `decide` skill fixes, with its `status` unchanged unless the
  record is superseded instead.
- AGENTS.md's throw rule ("never throw from library code — `cosmic.check`
  alone is exempt; the CSPRNG's throw-on-failure is the only other
  exception") reads as whatever the amendment decided.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed. The `decide` skill (`skills/decide/SKILL.md`) is the form,
and D23 plus D22 are the records in scope.
