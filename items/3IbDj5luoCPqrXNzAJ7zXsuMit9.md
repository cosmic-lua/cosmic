Evidence, 2026-08-29: after the alias-first render lands (3IbDFQzq /
PR #1514), the one human-facing surface still leading with bare id8s
is the verbs' refusal and success texts — e.g. `gitboard-take:
REFUSED: 3Ib4KH0q is claimed by ...`, `gitboard-done: 3Ib4KH0q
completed`. These are read by the session that just typed an alias,
so the answer should speak the same name. Refusal/verdict texts are
not parsed contracts the way commit subjects are, but tests do grep
several of them — the change is to lead with the alias and keep the
id8 present in the same line (both names, alias first), updating the
test greps in place, across gitverbs/gitgate/gitverdict/gitgraph/
gitcompare verdict-line call sites. Commit subjects and log grammars
stay raw-id-only (the settled wall). Refine by measuring the call
sites (`grep -c "id:sub(1, 8)" _work/*.tl` per file) before pulling.
