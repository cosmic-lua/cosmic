Found while handing 3IHHJcVr over to `check` on 2026-08-23.

`gitboard move ID check --pr N` refuses a draft PR:

```
gitboard-move: REFUSED: PR #270 is a draft — offer it for review before handing it over
```

A scheduled Claude Code session runs under a standing environment instruction to
open every pull request as a draft. So every such session hits this refusal on
the last step of every slice it implements, and its only ways past are to
un-draft the PR it was told to leave drafted, or to `--force` the move — which
the `work` skill's guardrails reserve for repair, not flow. This session
un-drafted #270 and recorded why; the next one will face the same choice with no
memory of this.

The refusal itself is defensible: a draft normally means "not finished". But the
board's `check` reviewer is another session, not a human waiting on the GitHub
review-request signal, and a draft PR is fully readable — diff, CI, and the
acceptance evidence in its body are all present regardless of draft state. The
gate is enforcing a human-workflow convention on a machine-workflow handover.

Possible shapes, for whoever refines this:

- accept a draft when the item carries acceptance evidence, keeping the refusal
  for a PR with no commits or an empty body;
- keep the refusal but have it name un-drafting as the sanctioned response, so
  the session is following the tool instead of working around it;
- decide the un-draft IS the handover and say so in the `work` skill's slice
  loop, which today says only "open the PR READY for review" and does not
  contemplate an environment that forbids that at creation time.

Related, already on the board: 3IFUskgH (a research slice has no PR at all, so
`check` needs `--force`). Both are the same gate meeting a shape it did not
anticipate.
