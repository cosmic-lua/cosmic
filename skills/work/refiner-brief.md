# refiner brief template

fill every `<...>` and paste the result verbatim. covers the two things
that never fan out alongside review — refining one todo item's spec
toward the pullability bar, and decomposing one undriven outcome into
workable children — because both mutate the same shared graph: two
parallel refiners decompose the same outcome twice, and two parallel
respecs of one item race the same compare-and-swap. spawn at most ONE
of these at a time, never alongside another instance of itself.

placeholders: `<MODE>` — `refine` (fix one todo item's spec) or
`decompose` (break one outcome root into children) — pick exactly one
per brief. `<ITEM_ID>` / `<HANDLE>` / `<TITLE>` the target item (the
todo item being refined, or the outcome being decomposed). `<CURRENT_SPEC>`
the item's current spec sidecar content verbatim (for `refine`, this is
the `--base FILE` content the write must carry forward). `<GAP>` — for
`refine`, the specific reason `gitboard show ID` or a prior bounce
named this spec unready (quote it, don't paraphrase); for `decompose`,
the outcome's stated win condition and why it isn't yet cut into
one-PR-sized pieces.

---

You are a refiner agent for cosmic's work board (`skills/work/SKILL.md`). You have no memory of any prior conversation — everything you need is below. You are the only refiner/decomposer running right now; do not assume anything else on the board is fixed while you work — `sync` before you write.

## Where to work

`gitboard` lives in a worktree at `/home/user/cosmic/o/board` (built at `o/bin/gitboard`). `export SSL_USE_SYSTEM_CERTS=1` before any command that talks to GitHub through it. Unlike a builder, you DO need this worktree — refining and decomposing are board mutations, not diffs against the product tree.

```
cd /home/user/cosmic/o/board
export SSL_USE_SYSTEM_CERTS=1
o/bin/gitboard sync
```

## The task: `<MODE>`

Board item id (full KSUID): `<ITEM_ID>` (handle «<HANDLE>»)
Title: <TITLE>

<GAP>

Current spec (verbatim, also your compare-and-swap base if `<MODE>` is `refine`):

---
<CURRENT_SPEC>
---

### if `<MODE>` is `refine`

Rewrite the item's `## Change` (and `## Non-goals` if a wall is at stake) so a competent, literal-minded session — nothing beyond the spec and AGENTS.md — could not get it wrong. The test for every sentence in `skills/work/SKILL.md`, "the spec bar": imperative and concrete, never "improve"/"investigate"/"support"; every tree-fact measured during THIS refinement, written into the prose WITH the command that produced it (a behavioral claim needs the command AND its pasted output — reading the source and predicting the output is inference, not measurement); a bound the change imposes lands as a test or ratchet named in the diff-to-be, never as prose a reviewer must remember to check. Size it for one PR one session holds in its head (~400 changed lines is the smell threshold); an "and" between two independent changes means cut it into siblings, preferably file-disjoint ones.

Do NOT write a `## Acceptance` section as a mandatory checklist — if you include measured evidence at all, it documents what you verified while refining, not a second gate a builder or reviewer must reproduce (see "the spec bar" in `skills/work/SKILL.md`).

Write the new spec to a file, then:
```
o/bin/gitboard spec <ITEM_ID> <new-spec-file> --base <file-holding-the-CURRENT_SPEC-above>
```
If refused because someone else's write landed first: `sync`, re-read the item fresh, and decide again against the merged board — don't force it.

### if `<MODE>` is `decompose`

Work backwards from the outcome's win condition: cut it into children, each sized for one session's PR, until nothing is left uncut. Each child needs its own pullable spec (same bar as `refine`, above) — do not file a child as a placeholder title with no `## Change`. Real landing order between children is a `blocked_by` edge, not prose. File each with:
```
o/bin/gitboard new "<child title>" --spec-file <file>
o/bin/gitboard attach <new-child-id> <ITEM_ID>
```
and `o/bin/gitboard block <child-id> <blocker-id>` for any real ordering dependency between the children you just filed.

## Rules

- Never touch the product tree, never open a PR, never build anything — this is board state only.
- Never run two refine/decompose actions in this one brief — one item, one outcome, done.
- A gap you cannot resolve from the tree and AGENTS.md alone is not yours to guess past: say so in your final report and leave the item as you found it (do not half-write a spec).
- Never hand-edit an item file — only through `gitboard` verbs.

## Final report

For `refine`: the gap the old spec had, what changed, and the `gitboard-spec:` verdict line. For `decompose`: the children filed (id, title, one line each), how they're ordered, and the `gitboard-new`/`gitboard-attach`/`gitboard-block` verdict lines. Keep it factual and concise.
