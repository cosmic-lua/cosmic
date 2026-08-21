## Evidence

`gitboard new --repo OWNER/NAME` is the only way an item's `repo` field
is ever set, and it refuses a parentless item — "claim/pr/verdict/repo
belong to worked items, not roots". So an item that is filed as a
capture and later attached, or filed without the flag, can never gain
the field: `attach`, `move` and `spec` all leave it alone, and no verb
sets it.

Hit on 2026-08-21 handing wave 2 (3I7LEsGv) over to review. Its PR
lands in whilp/cosmopolitan, but the item had no `repo`, so
`move 3I7LEsGv check --pr 268` read the number against the board's own
origin and refused:

```
gitboard-move: REFUSED: cannot read PR #268:
GET /repos/whilp/cosmic/pulls/268: HTTP 404: Not Found; --force to hand it over anyway
```

`--force` would have handed it over with the field still wrong, leaving
`land` to fail the same way at merge time. The workaround taken instead
was the skill's once-only one: edit `items/<id>.tl` and commit (board
commit "repo 3I7LEsGv whilp/cosmopolitan"). Wave 1's item carries the
field, so the cross-repo path itself works — only the way to correct or
add it after the fact is missing.

## Why it might matter

Every cross-repo item is filed the same way this one was, so the
workaround is not a one-off: it is the only path for any item whose
repo is decided after it is opened, which is the normal case when a
capture is triaged into a plan. Each use is a hand-edited commit that
bypasses the tool's validation, and the failure it prevents is silent
until `land` tries to merge the wrong repo's PR number.

Shape of a fix: either a `repo` verb, or a `--repo` option on the verbs
that already mutate a worked item (`attach`, or `move`), or accepting
`--repo` on `new` for a root and validating it only once the item
becomes workable.
