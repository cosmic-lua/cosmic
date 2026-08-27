## Evidence

Found while reviewing `3ISlY5Xl` (PR #1419) and `3ISWHyP7` on
2026-08-26. Three items about the release perf gate cite a goal that
does not exist and hang off an outcome they do not serve.

All three specs open `## Goal` with **"G9 — every release publishes,
measured."** No such outcome is in `docs/goals.md`: `sed -n '94,270p'
docs/goals.md` lists G3, G6, G5, G9, G2, G4, G1, G8, G7, and **G9
there is "the least tree that keeps its promises"** — the
least-thing promise, measured by the public module surface ratchet.
`gitboard tree | grep -E '^\['` agrees: `[>5] 3HyRcrR3 G9 — the least
tree that keeps its promises`.

The outcome these items actually serve is **G6 — the defining paths,
ratcheted** (`docs/goals.md:127-140`), whose measured half is named in
its own prose as "the existing `perf-compare` gate". Yet all three are
parented under **G3 — an honest type layer, no escape hatches**
(`gitboard show 3ISlY5Xl` / `3ISWHyP7` / `3ISlWFiS` → `parent:
3HyRcW05wBip6Wqcz145bUQBTyj`), which is about `as` casts and Teal
narrowing and has nothing to do with benchmark noise.

The three:

- `3ISlY5Xl` — release perf gate reads noise from one control pair
- `3ISWHyP7` — release gate red: the A/B that root-caused the two flags
- `3ISlWFiS` — codec_base64_roundtrip_64k +7.8% [whilp/cosmopolitan]

Why it matters rather than being a cosmetic label: review step 5
(`skills/work/review.md`) walks the parent chain to its root and judges
the diff against that outcome. A reviewer doing that on `3ISlY5Xl`
reads G3 — an honest type layer — and finds a change about benchmark
variance that moves none of G3's win condition (zero casts, the
scaffolding deleted). The judgement only works once the parent is the
outcome the work serves. The same mis-parenting also means these items
carry G3's band-8 placement rather than G6's band-7, so the order the
board derives is asserting something nobody compared.

Two questions to settle, and the second is the goal owner's:

1. Where did "G9 — every release publishes, measured" come from — a
   renumbering `docs/goals.md` absorbed, or an invented goal that
   propagated by copy from one spec to the next? Whichever it is, the
   fix includes correcting the `## Goal` line in all three sidecars.
2. Re-parenting these three from G3 to G6 moves them from band 8 to
   band 7. That is a placement change against existing work, so it is
   not a reviewer's call to make alone — it is reported here for the
   goal owner rather than performed.

## Result (2026-08-27, this slice)

Question 1 answered from the board branch's own history
(`git log --all -S "every release publishes, measured" -- items/`):
the phrase was INVENTED in 3ISWHyP7's spec (commit 4e788163,
2026-08-26T17:19:36Z) and propagated by copy to 3ISlY5Xl (cd99c9fc,
19:50). It never appeared in docs/goals.md — the real G9 is "the
least tree that keeps its promises". The third item, 3ISlWFiS, had
already been corrected to cite G6 (commit 31390593, 21:49), which cut
the propagation vector; no OPEN item carries the phrase
(`grep -rln "every release publishes" items/` → only the two ended
sidecars and this capture).

Question 2 performed rather than escalated: all three items are now
ENDED (accepted with verdicts), so re-parenting them moves no live
band and displaces nothing — it is a record correction, the direction
(band 8 → band 7) is downward, and the skill reserves the goal
owner's judgment for comparisons that RAISE work. Done:
`attach 3ISlY5Xl|3ISWHyP7|3ISlWFiS 3HyRcd9F` (G6). The two stale
`## Goal` lines were corrected in place, each carrying a note naming
this item so the correction is visible in the record.

Follow-up seeded: none needed — review step 5's guard (walk the
parent chain) now reads the right outcome for all three, and the
copy-source is corrected.
