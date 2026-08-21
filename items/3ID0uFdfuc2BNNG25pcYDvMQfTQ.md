`gitboard new --repo OWNER/NAME` is the only way an item's `repo` field
is ever set, and it refuses a parentless item — "claim/pr/verdict/repo
belong to worked items, not roots". So an item whose cross-repo
destination becomes known after it was opened has no verb that can
record it: `attach`, `move` and `spec` all leave the field alone.

## Two occurrences, both cross-repo handovers

`3I7LDODd` on 2026-08-21: its spec said the PR lands in
whilp/cosmopolitan and told the session to "set it on this item when it
lands", but `move ID check --pr N` reads the PR against the board's
origin and refused with
`cannot read PR #267: GET /repos/whilp/cosmic/pulls/267: HTTP 404`.

`3I7LEsGv` the same day, handing wave 2 over:

```
gitboard-move: REFUSED: cannot read PR #268:
GET /repos/whilp/cosmic/pulls/268: HTTP 404: Not Found; --force to hand it over anyway
```

Both were worked around the skill's once-only way — hand-edit
`items/<id>.tl` to add `["repo"] = "whilp/cosmopolitan"` and commit
(board commit "repo 3I7LEsGv whilp/cosmopolitan") — after which the
move succeeded. The file format held; the workaround is exactly what
the hard rule says to file rather than repeat.

## Why it matters

Every cross-repo item is filed this way, so the workaround is not a
one-off: it is the only path for any item whose repo is decided after
it is opened, which is the normal case when a capture is triaged into a
plan. Each use is a hand-edited commit bypassing the tool's validation.
The `--force` the refusal offers is worse than the workaround — it
hands the item over with the field still wrong, leaving `land` to fail
the same way at merge time, silently until then.

## Shape of a fix

A setter, in one of these shapes:

- `move` grows a `--repo OWNER/NAME` option (natural, since `--pr` is
  already set there and the two travel together);
- a small `gitboard repo ID OWNER/NAME`;
- `--repo` accepted on `new` for a root, validated only once the item
  becomes workable.

Whichever shape, it should validate against `item.tl`'s
`^[%w%-%.]+/[%w%-%._]+$` the way `new` does, and refuse on a root the
way `claim`/`pr`/`verdict`/`repo` already do (`item.tl:137`).

Also captured as 3IDj9tRO, ended as a duplicate at triage; its evidence
is folded in above.
