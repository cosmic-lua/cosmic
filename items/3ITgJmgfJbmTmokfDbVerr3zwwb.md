`gitboard` can set an item's landing repo only at `new --repo
OWNER/NAME`, and nothing can change it afterwards. An item filed
without it — which is every item a session captures before it knows
where the fix will land, and every item adopted from the triage queue —
is stuck pointing at the board's origin, `whilp/cosmic`. The failure
lands at the worst moment: the builder has already done the work,
opened the PR in the other repo, and then `move ID check --pr N`
refuses, because the PR-existence check reads the wrong repo. Observed
2026-08-27 on `3ITerUZf`, whose fix landed in whilp/cosmopolitan as PR
#281: `gitboard move 3ITerUZf check --pr 281` printed `REFUSED: cannot
read PR #281: GET /repos/whilp/cosmic/pulls/281: HTTP 404: Not Found;
--force to hand it over anyway`.

Neither escape is good. `--force` hands the item over with the wrong
repo recorded, so `land` will later try to merge `whilp/cosmic#281`,
which is a different PR or none. Editing `items/<ksuid>.tl` by hand and
committing is what the `work` skill's hard rules prescribe for a
missing verb, and is what was done here — one commit adding
`["repo"] = "whilp/cosmopolitan"` between `phase` and `title` — but it
bypasses the validation and the WIP re-check that every mutation
otherwise goes through, and it is the second such workaround the rule
allows exactly once each.

The verb: `gitboard repo ID OWNER/NAME`, one commit, validated by
`_work/item.tl:149`'s existing `^[%w%-%.]+/[%w%-%._]+$` check and
refused on a root or container the same way `claim`/`pr`/`verdict` are
(`_work/item.tl:146`). An empty argument would clear it back to the
default. `move ID check --pr N` could also accept `--repo` and set it
in the same mutation, which is the shape that removes the failure from
the moment it actually bites; whether that is instead of the standalone
verb or as well as it is a refinement question.
