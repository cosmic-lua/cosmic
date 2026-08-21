`gitboard new --repo OWNER/NAME` is the only way an item's `repo` field
is ever set, so an item whose cross-repo destination becomes known after
it was opened has no verb that can record it. 3I7LDODd hit this on
2026-08-21: its spec said the PR lands in whilp/cosmopolitan and told the
session to "set it on this item when it lands", but `move ID check --pr N`
reads the PR against the board's origin and refused with
`cannot read PR #267: GET /repos/whilp/cosmic/pulls/267: HTTP 404`. The
session worked around it by hand-editing `items/<id>.tl` to add
`["repo"] = "whilp/cosmopolitan"` and committing, after which the move
succeeded — the file format held, but the workaround is exactly what the
hard rule says to file rather than repeat.

The gap is a setter. Either `move` grows a `--repo OWNER/NAME` option
(natural, since `--pr` is already set there and the two travel together),
or there is a small `gitboard repo ID OWNER/NAME`. Whichever shape, it
should validate against `item.tl`'s `^[%w%-%.]+/[%w%-%._]+$` the way
`new` does, and refuse on a root the way `claim`/`pr`/`verdict`/`repo`
already do (`item.tl:137`).
