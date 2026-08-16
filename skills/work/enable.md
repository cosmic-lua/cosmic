# Enabling: making implementers succeed

the planner's leverage is not writing smarter issues — it is changing
the system so a less sophisticated model cannot help but get it right.
this repo already works this way for humans and agents alike: the
fallible-returns lint, the `-- cast:` justification, the find-needle
lint, verdict lines, the coverage ratchet — each one exists because
some mistake kept happening and a mechanism now catches it before
review does. enablement is doing that ON PURPOSE, ahead of the
failure, as part of refining work toward the ready bar.

## the enablement check

before any `move N ready`, simulate the implementer: walk the issue's
`Change` as a literal-minded model would, and list every point where
it could take a wrong turn — a decision the body leaves open, a
convention it could miss, an API that invites misuse, a failure it
would only discover at review. then, for each predicted wrong turn,
choose the strongest available countermeasure. in strict preference
order:

1. **core** — change code so the wrong turn is impossible or caught
   by a gate. a type that will not admit the mistake, a lint that
   names it, a test the acceptance can cite, an error message that
   says what to do instead, a helper that makes the right way the
   short way, scaffolding (a fixture, a template file) the issue can
   point at. gates transfer to every future issue; prose does not.
2. **docs** — when the knowledge is real but not mechanizable: a
   guide section (`docs/guides/**` ships in the binary), an AGENTS.md
   convention, a doc comment on the API the issue touches. docs are
   for judgment calls; anything a machine could check belongs in
   core.
3. **skills** — last resort, when the guidance is about workflow
   rather than the tree: a new chapter or rule in `skills/*`. skills
   reach only agents that load them; core and docs reach everyone.

the ordering is a budget, not a menu: reach for docs only when core
cannot encode it, and for skills only when it is not about the code
at all. record the outcome in the issue's `## Enablement` section —
`none needed` (and why), or `Blocked by: #N` lines naming the
enablement issues that must land first.

## enablement issues

an enablement countermeasure that is not trivial becomes its own
issue, labeled `work:enable`, held to the SAME ready bar and flowing
through the same board — implementers can and should build the lints
and fixtures that protect their own future work. the feature slice
carries `Blocked by: #N` so `next` sequences them correctly. never
fold enablement into the feature slice itself: a lint that lands
inside the PR it polices proves nothing.

enablement can also be a research slice: "run the failing path, write
down what an implementer sees, propose the countermeasure" — its
deliverable is a comment and follow-up issues, not code.

## evidence: where enablement work comes from

predictions are seed; evidence is gold. three feeds, in rising order
of cost:

1. **review bounces.** every time an implementer bounces an issue
   back (`SKILL.md`, implementer step on under-specification) or a
   review finds a wrong turn (`review.md`), the planner asks: which
   countermeasure would have prevented this — and files it. a bounce
   with no enablement issue filed is evidence dropped on the floor.
2. **repeated review comments.** the second time a review makes the
   same point, that point is a lint or a doc waiting to be written.
3. **agent evals.** the `agent-eval` skill's journals show where
   fresh agents stumble with no context at all — the same frictions,
   observed cleanly. mine them when planning enablement epics.

## what enablement is not

- not a euphemism for lowering the bar: `--make ci`, the contract
  freezes, and the conventions bind implementers fully. enablement
  makes the bar reachable, never lower.
- not speculative infrastructure: a countermeasure is filed against a
  predicted or observed wrong turn on real planned work, and its
  issue names that work. tooling with no failure to prevent is scope
  creep with a virtuous name.
- not planner-only work: enablement issues are ordinary ready issues;
  implementers build them.
