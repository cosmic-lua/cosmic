## Evidence

`gitboard spec` overwrote another session's spec on an item that
session had already claimed and moved to `do`, with no refusal and no
warning. Observed 2026-08-27 14:36 UTC on `3IUBNQZZ`.

Two sessions were handed the same refine of `3IUBNQZZ` out of the same
bounce. Session A (`e532d9f6…`) refined it (commits `caab816d`,
`e32eed78`, `f50b1394`), moved it `plan -> ready -> do` (`ac2c93c7`,
`fd6c73cd`), claimed it, and began building. Session B (`0b13d2b4`)
had run `gitboard sync` at the start of its pass ("state is current"),
read the spec as it stood then, spent the pass refining it, and
committed `7a8d52aa spec 3IUBNQZZ` — which replaced session A's spec
wholesale with a competing design while A was mid-build against it.
The verb printed `gitboard-spec: 3IUBNQZZ's spec replaced` and pushed.

Nothing refused it, at either of the two points that could have:

- **No baseline check on the spec.** The board's compare-and-swap is
  git's: B's commit rebased cleanly onto A's, because the conflict is
  semantic (same file, sequential writes) rather than a failed push.
  `SKILL.md` says "two sessions editing the SAME item cannot rebase
  past each other", and that holds only when both writes are in
  flight — a session that syncs, reads, thinks, and writes minutes
  later is a lost update with a clean rebase, which is the ordinary
  case for a refine.
- **No claim check on `spec`.** `3IUBNQZZ` was in `do` carrying
  `claim: e532d9f6-4b7d-5145-9534-7c6759ebc0d8`, and `spec` neither
  consulted the claim nor mentioned it. `move` and `verdict` derive a
  session identity precisely so work is not taken from under its
  claimant; `spec` does not.

B noticed only by accident: an unrelated `cp` of a sibling item's
sidecar returned content its own earlier `gitboard show` had not, which
is what exposed the intervening commits. B then restored A's spec
verbatim (`git show f50b1394:items/3IUBNQZZ….md` -> `gitboard spec`,
diff-verified identical, `gitboard-check: meets the ready bar`), so the
board is intact — but the recovery depended on the clobbering session
happening to look.

Two candidate countermeasures, neither chosen here:

- `spec` refuses when the item's spec has changed since the session
  read it — a `--base <sha>` or content-hash argument, the same
  compare-and-swap the push half already has, moved up to the item.
- `spec` refuses (or warns loudly) on an item whose phase is `do` or
  `check` and whose `claim` is not this session's, on the same
  reasoning that keeps `next` from handing a session its own PR.

Related: `3IVDEyar` and `3IVDirCO` are the same split-off item filed
four minutes apart by these two sessions out of the same refine;
`3IVDEyar` was ended not-planned as the duplicate. Duplicate captures
are the cheap half of this collision. The clobbered spec is the
expensive half.
