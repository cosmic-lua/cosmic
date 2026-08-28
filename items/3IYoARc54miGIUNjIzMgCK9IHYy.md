## Goal

G8 — the flow system. When a spec RELOCATES a rule from one mechanism to
another, the ready bar must make it enumerate every place the old
mechanism is asserted. Today it asks for the primary edit site and gets
a diff that leaves the manual contradicting itself.

## Problem

Caught on `3IYiZ9Md` (PR #1492), which moves review distance from an
identity gate in the machinery to a context gate in the procedure. Its
`## Change` named four files and, for `loop.md`, one location: "rewrite
step 3 (`:32-33`)". The implementation did exactly that and is green.

But `loop.md` asserts the OLD mechanism a second time, forty lines
below the edited step, in a section the spec never named:

```
skills/work/loop.md:65-73   ## minted identities and the verdict wall
  **work built by an agent this session spawned is this session's own
  work.** … never `review` or `verdict` an item whose claim or
  `builders` carry this session's identity or any name it minted. those
  items wait in `check` for a session that did not drive them — another
  loop, another run, a human. a loop that reviews its own wave is one
  session merging its own work with extra steps.
```

while the same PR rewrites the hard rule to read:

```
skills/work/SKILL.md:433
  no session accepts its own work. the review procedure carries this
  one: the verdict comes from a subagent whose context window holds the
  spec and the diff and nothing else, so it cannot be biased by a build
  it never saw (`review.md`).
```

A subagent spawned by the building session never saw the build, so
`SKILL.md` licenses exactly the verdict `loop.md` calls "own work with
extra steps". The manual gives opposite answers to the question a loop
session hits every pass: **may I review my own wave through a fresh
subagent?**

Two more assertions of the old mechanism survive the same PR, in a file
it edits:

```
skills/work/SKILL.md:34    `next --session NAME` never hands a session a
                           verdict on work that session built
skills/work/SKILL.md:198   | `check` | … awaiting a verdict from a
                           session that did not build it |
skills/work/SKILL.md:378   never accept your own: the item now carries
                           your claim, so `next` will route it elsewhere
```

Those three are not yet false — the machinery gate still exists until
`3IYYwdp7` removes it — but they describe the mechanism the item is
retiring, and nothing made the spec account for them.

**Nothing catches this.** `--make ci` is green: prose consistency across
files is not a gate, and cannot straightforwardly be one. The ready bar
is the only place it can be caught, and it is where this belongs.

## Change

Add to `decompose.md`'s ready bar: when an item's `Change` REPLACES a
mechanism — a gate moving from machinery to procedure, a rule changing
what enforces it, an API's callers moving to a successor — the spec must
carry an inventory of every site asserting the old mechanism, produced
by a command, with each site marked as one of:

- **rewritten** — the diff changes it, and the spec says to what;
- **still true** — the old mechanism survives this slice (a staged
  removal), so the assertion stands, and the spec says which later item
  retires it;
- **out of scope** — with the reason.

The inventory is a command and its output, so a reviewer re-runs it and
a later session sees what was deliberately left. State that the site
list comes from a grep for the mechanism's own words, not from memory
of where it is written.

Keep it proportionate: this applies to a `Change` that RELOCATES or
RETIRES a mechanism, not to every edit. A slice that adds a rule
without moving one owes no inventory.

## Non-goals

- No new gate, lint, or test. Prose-to-prose consistency across files is
  not mechanically checkable in general, and pretending otherwise buys a
  gate that is wrong in both directions.
- Do not change the three review verdicts, the six checks, or the
  verdict grammar.
- Do not change what `3IYiZ9Md` decides. The contradiction it left is
  that item's rework, not this one's; this item stops the next one.
- No change to `docs/goals.md`, `AGENTS.md`, or `_work/**`.

## Acceptance

- `decompose.md` gains the rule, in the shape its neighbouring bar
  clauses use, with the three dispositions named literally.
- `wc -l skills/work/decompose.md` stays under 500.
- Applied to `3IYiZ9Md` as the worked check: the grep the new clause
  demands (for the retiring mechanism's words) returns the four sites
  above, and each is classifiable under one of the three dispositions.
  Quote that run in the PR.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Evidence commands

```
grep -rn "own work\|your own\|own PR\|did not build\|builders" skills/work/
sed -n '58,75p' skills/work/loop.md
sed -n '430,436p' skills/work/SKILL.md
```

Measured 2026-08-28 against PR #1492 head `0248d62d`.
