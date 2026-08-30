## Problem

Every batch item under the tree-migration container (3IOCdooE) carries
this acceptance check, meant to prove no self-call survives in scope
while also catching a selection that matched nothing:

```
grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' <scope> | xargs grep -c '^test_[A-Za-z0-9_]*()$' | grep -v ':0$'
```

The parenthetical beside it says "prints nothing (and the `ls`/`grep`
selection still names the files, so an empty selection is a bug, not a
pass)". The command does the opposite of that. Once the edit lands the
leading `grep -rln` matches no files, so `xargs` runs `grep -c` with no
file arguments — it reads STDIN and prints a bare `0`, which has no
`path:` prefix for `grep -v ':0$'` to filter. So the check prints `0`
on success, and prints nothing in the empty-selection case it was
written to catch: inverted from the stated intent.

Evidence: observed running the check verbatim during batch 3/7
(2026-08-30, origin/main 259400ce). The form that behaves as described
separates selection from counting, so the file list is named
independently of whether any match remains:

```
find <scope> -name '*_test.tl' | xargs grep -c '^test_[A-Za-z0-9_]*()$' | grep -v ':0$'
```

which named 29 files and printed nothing.

This matters beyond one batch: the container has seven batch items and
the same text is in each, so every remaining batch inherits a check
that cannot fail the way its own prose promises. The fix is to correct
the acceptance text in the container spec and the unstarted batch
items. Which items still carry it is unmeasured — that survey is what
this item needs before it reaches the spec bar.
