## Correction to this item's opening capture

The capture asserted that the overwrite came through the "edit the item file
directly when the tool lacks a verb" escape hatch, on the evidence that `set`
is absent from `gitboard help`. **That was wrong.** `set` is a tool-emitted
commit message, not a hand edit — `_work/gitgate.tl:296` writes it for an
in-place `move` that changes only `claim`/`pr` without crossing a phase:

```
$ grep -rn 'set %s in' _work/*.tl
_work/gitgate.tl:296:    ("set %s in %s%s"):format(it.id:sub(1, 8), where, forced_suffix(force, why))
```

The defect is real and the evidence below stands. Only the mechanism was
misidentified, and the true one is worse.

## The guard already exists, and it did not fire

`_work/gitgate.tl:279-284` refuses exactly this, and its comment describes
this incident class in the same words:

```teal
-- The same takeover rule the phase-crossing move applies: a claim
-- is a lock, and an in-place write was the one door that moved it
-- silently — a live session lost its item to a "set" nine seconds
-- after pulling it. Overwriting a live foreign claim says so with
-- --force --why, exactly like every other takeover.
if (claim or "") ~= "" and (it.claim or "") ~= "" and claim ~= it.claim
and not force then
  return verdict_line("move", false,
    ("REFUSED: %s is claimed by %s — take over a live claim with "
      .. "--force --why"):format(it.id:sub(1, 8), it.claim))
end
```

It landed **two days before this incident**:

```
$ git log --format='%h %ad %s' -S'is claimed by' -- _work/gitgate.tl | tail -1
246e3a8c Wed Aug 26 23:01:22 2026 -0700  gitboard next: candidate lists, seeded fan-out, and the fused claim (#1454)
```

And the overwrite was **not** a declared takeover — a forced write appends
`(forced: <why>)` via `forced_suffix` (`:70-75`), and the commit carries no
such suffix:

```
$ git log -1 --format='%s%n%b' 95858214
set 3IUBNQZZ in check
                       # empty body, no "(forced: …)"
```

Every branch of the guard's condition held: `it.claim` was non-empty
(`0b13d2b4-…/3IUBNQZZ`), the incoming claim was non-empty (it replaced it),
and the two differed. The write should have been refused. It was not.

## The finding, restated

**Board invariants are enforced by the client binary, so a session running a
stale `o/bin/gitboard` bypasses them silently.** The `board` branch ships its
own machinery and its own built binary; a worktree that has not rebuilt since
`246e3a8c` (2026-08-26) runs a gate that has no takeover rule in it, and the
board accepts the resulting commit because the commit itself is well-formed.

The split is visible in this same incident. Two protections were tested
minutes apart, with opposite outcomes:

- `gitboard spec --base` **correctly refused** a second session's write
  ("3IVLAF3Z's spec changed since you read it"). That is compare-and-swap over
  content the writer had to have read — it cannot be bypassed by an old
  client, because the base it compares against comes off the remote.
- The claim/pr takeover check **did not fire**. That is pure client-side
  logic over a field, and an old client simply does not run it.

So the rule of thumb: an invariant expressed as "compare against what the
remote holds" survives a stale client; an invariant expressed as "refuse this
combination of flags" does not.

## Cost

One duplicated implementation of `3IUBNQZZ` (two agents, two green CI runs,
~110k tokens on this side alone) and an orphaned PR #1484, closed by hand in
favour of #1485. The latent cost is the review wall: `flow.built_by` reads
`claim` and `builders`, so an item whose `claim` was silently replaced can be
routed for review to the session that built it. `builders` retained both
sessions here, which is what kept the wall standing.

## Not asserted here

The stale-client hypothesis explains every observation and no other
explanation fits the evidence, but it was not confirmed against the other
session's binary — that session is not this one's to inspect. Confirming it is
the first step of any fix.

Nor does this name the fix. Candidates: a version or machinery-digest stamp
carried in each commit so the board can reject a write from a client older
than the invariant it must honour; expressing the claim check as a
compare-and-swap over the claim field the way `spec --base` does; or a
rebuild-before-mutate step in the loop. They trade differently and the choice
belongs in `plan`.

## Result

Closed 2026-08-29, overtaken + consolidated: the mechanism this item captured (the phase-era in-place `set ... in <phase>` write at gitgate.tl:296) was deleted with the two-state rewrite; today a foreign LIVE claim can only move via `take --force --why` (audited) and a shared PR is refused by pr_collision_refusal (PR 1512). The residual concern — that authorship history survives an overwrite so no-self-review can still be derived — is exactly the involvement record item 3IVCd39E now specifies (builders append on every claim take, including forced takeovers).
