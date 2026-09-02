## Problem

Item 3IkwiKoC ("G9 has no practice that turns the size report's numbers
into pruning work") asks for two different kinds of deliverable in one
`## Change`: a documentation edit landable as a normal product PR
(amending `skills/work/decompose.md`, possibly a decision record), AND
"demonstrate it once by actually reading the current `size.json` trend
and filing... at least one real pruning candidate from it" — i.e.
running `gitboard new` to file a board item under the G9 root.

The standing builder brief (`gitboard brief builder ID`) explicitly
forbids the agent from running any `gitboard` command ("board state is
the orchestrator's job"), and the research brief's role is the inverse:
its whole deliverable is board state with no product PR. Neither role
covers "land a product PR AND file exactly one board item as part of
the same acceptance."

## Question

Should this item be split into two — a builder item for the
documentation/decision-record change, and a research item (or an
orchestrator-side follow-up) whose recommendation is the one G9 item
to file, applied via `new` after review — or should the builder brief
gain a narrow, explicit exception letting a builder file a single
board item when the spec's own Acceptance requires it?

## Evidence

Observed during a `/work` orchestrator pass on 2026-09-02 sizing up
item 3IkwiKoC for a builder claim: its Acceptance section requires a
filed item under the G9 root as proof the documented practice works,
which the emitted builder brief's fixed "do not run gitboard" rule
makes impossible to satisfy from inside the build.
