## Evidence

Pasting a brief into an agent prompt decoded every `\uXXXX` in the
albm_OBbo review brief (a spec about mapping backtick to ```) into
the literal character, so the reviewer read "map ` to `". The agent had
to be killed and respawned with doubled backslashes; a second brief
(zbl9_M8VS) needed `\t` and line-continuation backslashes doubled by
hand. `gitboard brief --help | grep -c -- --out` → 0; the verdict line
says "paste the body verbatim", and `_work/gitboard.tl:184` forbids
hand-writing one.

## Change

`_work/brief.tl`: `--out FILE` writes the filled brief body (without
the verdict line) to FILE and prints a verdict line naming the path and
the placeholders still to fill. `_work/doctrine.tl` (orchestrate, the
brief bullet): one sentence — a brief may be handed to an agent as the
path of that file with "read it whole, it is your brief verbatim"; the
file is exact where a pasted prompt may not be.

`_work/brief_test.tl`: `--out` round-trips byte-for-byte against stdout
output for a spec containing ```, `\t` and a trailing backslash.

## Non-goals

No placeholder filling by the tool (`<WORKTREE>`, `<HEAD_SHA>` stay the
orchestrator's).
