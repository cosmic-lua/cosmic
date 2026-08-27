# Problem

G8's measured-by is UNBUILT, and goals.md says so in those words: flow
health per release (ready→merged lead time, WIP-limit adherence, no
column starved or saturated for a whole release) and the cost ratchet
(tokens × model tier per merged slice, trending down). The board
branch's git log holds every transition — `gitboard stats` already
reads dwell and transition counts from it (n=1295 transitions today)
— but nothing renders the per-release health verdict, and nothing
records cost at all: no field on an item carries tokens or model
tier, so the ratchet has no data source, not just no reader.

Today's board is a live example of what the report would catch:
ready=1, do=1, check=0 against a 158-item backlog — refinement
starved for at least one visible window, and nothing surfaced it.

# Change

Two halves, sized in plan:

- the READER: extend the stats machinery to a per-release flow-health
  report — lead time distribution, WIP adherence, starvation windows
  per column — keyed by release tags, published with the release
  assets like perf and size history.
- the COST source: decide where tokens × model tier per slice comes
  from (recorded at claim/verdict by the session, a field the runner
  stamps, or declared out of reach and the goal's measured-by amended
  via a goals.md PR + decision). Building a reader for data nobody
  writes is the failure mode to avoid; deciding the source is in
  scope, building heavy telemetry is not.

# Non-goals

- Retuning WIP limits (review.md's flow review does that, fed by this
  report).
- Any change to verbs' transition behavior.

# Acceptance

- the report runs over the real board log and prints a per-release
  verdict for the flow-health clauses goals.md names.
- the cost half lands as either a recorded field with a reader, or an
  amended goals.md measured-by with its decision record — not
  silence.
