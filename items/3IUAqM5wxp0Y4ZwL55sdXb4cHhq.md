`gitboard review` decides ownership from local git state, so after a
publish that did not converge it reports a claim the remote never
received. Observed 2026-08-27 ~05:2x UTC from session
`05f7c552-0c90-51cb-99b3-e018759c6ed5`, board worktree at `o/board`,
under heavy concurrent contention: `o/bin/gitboard review 3IU5Vhvy`
ended `gitboard-review: publish did not converge after 3 attempts`. It
had made its commit `ba96c610` ("review 3IU5Vhvy claimed by
05f7c552-…") **locally** and never pushed it — `git merge-base
--is-ancestor ba96c610 origin/board` was false. A retry of the same
verb then answered `gitboard-review: 3IU5Vhvy's review is already
yours`, because it read that stranded LOCAL commit rather than the
remote; meanwhile `572184f4` on `origin/board` already recorded the
review claimed by a different session, `0b13d2b4-bb26-5bc1-8635-
407acd85452c`, which had won the race by roughly 80 seconds. The
consequence is the exact cost the review claim exists to prevent: a
session that believes the second answer proceeds through a full
independent verification — checkout, fetch, build, `--make ci`,
acceptance greps, minutes of work — and is stopped only when the
compare-and-swap refuses at `verdict`, i.e. after the whole
verification, which `review.md` states is the difference between
losing the race for seconds and losing it for the entire review. That
is what happened here: the verification ran to completion and the
verdict was the first refusal. Suggested direction, for whoever
refines this rather than a decided design: an ownership report should
consult the REMOTE before claiming the review is yours, and a claim
whose publish did not converge should read as "claim unpublished" (or
be dropped) rather than "already yours" — the two states are not the
same fact. Related but distinct: `3IOCwdGD` records the half-landed
mutation and `sync` reporting `state is current` while the checkout
was ahead, which is the same publish path; `sync` reported `state is
current` twice in this session as well. This item is about what the
ownership report READS, not about the unpushed commit itself.
