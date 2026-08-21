## Evidence

`gitboard move ID do --claim SESSION` overwrites the claim on an item
that is already in `do`, with no refusal. The claim is the only thing
that makes `next --session NAME` withhold a verdict on work that session
built, so an overwrite silently transfers authorship and the guarantee
fails open — `next` then hands a session its own PR to review and says
nothing is wrong.

Observed on 2026-08-21 on item 3I7LGcLa (cosmos pin bump, wave 1).
Two sessions pulled it 65 seconds apart:

```
12:46:57  move 3I7LGcLa ready -> do     claude-i66dkr claims it
12:47:35  spec 3I7LGcLa                 claude-3gubgy rewrites the spec
12:47:40  move 3I7LGcLa do -> ready     claude-3gubgy returns it
12:48:02  move 3I7LGcLa ready -> do     claude-3gubgy claims it
13:03:38  move 3I7LGcLa do -> check --pr 1301   claude-i66dkr hands over ITS work
```

`claude-i66dkr` built and pushed whilp/cosmic#1301. The item's `claim`
field reads `claude-3gubgy`. `gitboard next --session claude-i66dkr`
then answered:

```
gitboard-next: review 3I7LGcLa cosmos pin bump: first release carrying the ABI-4
bindings — check is the rightmost phase awaiting a decision — verdicts before new work
```

That is the session being offered a verdict on its own PR. It was
declined by hand, not by the tool.

Note what did NOT fire. The push-as-compare-and-swap is described as
refusing two sessions editing the same item — "that refusal names the
items and hands back a clean checkout". Here both sessions mutated
3I7LGcLa repeatedly and every push landed: the moves were sequential in
time, so each rebased cleanly onto the last. Serialisation is not
mutual exclusion, and `do` is where the difference bites, because the
phase is meant to be a lease over one item held by one session.

The second casualty is spec work. `gitboard spec ID FILE` replaces the
sidecar wholesale from a file the session prepared earlier, so a session
that read the spec before a concurrent rewrite reverts that rewrite on
write-back, with no conflict and no warning. That happened here at
13:02:41 — the better of the two specs (it carried a
wave-1-vs-wave-2 discriminator and a "capture the perf baseline before
the pin moves" step) was reverted by a session working from a copy 16
minutes stale, and had to be restored by hand from
`git show ce3441de:items/…md`.

## Why it might matter

The review gate is the system's final gate, and `--session` is the
whole mechanism behind "never your own". A guarantee that depends on a
mutable single-valued field, which any later mover may overwrite
without refusal, is not enforced — it holds only while nobody collides.
An unattended session that trusts `next` will accept its own work and
report the board as healthy while doing it.

Directions worth weighing, not a decision:

- refuse `move ID do --claim B` while the item is in `do` claimed by A
  and the lease is live, the way a full phase refuses a pull — a claim
  is a lease, and taking over a live one should be `--force` with a
  reason, which is also what makes the takeover legible in the log.
- keep a claim HISTORY rather than one field, so `next` can withhold a
  verdict from every session that has held the item, not just the last.
  This is the version that survives a legitimate takeover: whoever
  actually built the diff stays disqualified as its reviewer.
- have `spec` detect that the sidecar changed since the session last
  read it and refuse, so a wholesale replace cannot silently revert a
  concurrent refinement.

## Where the evidence is

- board branch, `git log -- items/3I7LGcLaE6xqOwmNxcdBvRtT6Ft.tl` for
  the move sequence; `git diff ce3441de 2432ca0a --
  items/3I7LGcLaE6xqOwmNxcdBvRtT6Ft.md` for the reverted refinement.
- whilp/cosmic#1301, whose description carries the same timeline for
  whoever reviews it.
