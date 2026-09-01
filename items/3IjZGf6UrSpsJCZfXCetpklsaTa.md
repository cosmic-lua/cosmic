## Goal

`tool/net/help.txt` (the hand-maintained redbean manual) documents
`unix.gmtime`/`unix.localtime`, `unix.clearenv`, and
`unix.sigpending` with their PRE-#321 return shapes: the two time
functions as 11 positional values with the failure path sharing
`mon`/`mday` with the error, and `clearenv`/`sigpending` as
`true|nil`/`Sigset|nil` with a reachable failure branch. PR #321
changed all four bindings' actual behavior and their
`tool/net/definitions.lua` annotations; `help.txt` was not part of
that PR's scope and is not generated from `definitions.lua`, so it is
now stale documentation with no gate that catches the drift.

## Evidence

- `tool/net/help.txt`: grep for `gmtime`, `localtime`, `clearenv`,
  `sigpending` to find the stale sections (re-locate line numbers at
  the time this is worked — this capture was filed from a PR
  description, not a direct line citation).
- `tool/net/definitions.lua`'s current annotations for these four
  bindings (post-#321): `unix.gmtime`/`unix.localtime` return
  `unix.BrokenDownTime|nil, string?, unix.Errno?`;
  `unix.clearenv` returns plain `true`; `unix.sigpending` returns
  plain `unix.Sigset`.
- Confirm no build target regenerates `help.txt` from
  `definitions.lua` (if one exists, this capture is moot — say so and
  close not-planned instead of hand-editing).

## Change

Update `tool/net/help.txt`'s documentation for `unix.gmtime`,
`unix.localtime`, `unix.clearenv`, and `unix.sigpending` to describe
their current (post-#321) return shapes and failure behavior,
matching `tool/net/definitions.lua`'s current annotations for each.

## Non-goals

- No change to any binding's actual behavior — documentation only.
- No change to `tool/net/demo/unix-dir.lua` (separate sibling
  finding, already filed).
- If `help.txt` turns out to be generated rather than hand-maintained,
  this capture is moot — close not-planned with the generator's name
  instead of hand-editing generated output.

## Acceptance

- `tool/net/help.txt`'s sections for these four bindings describe the
  current return shape and failure behavior, matching
  `tool/net/definitions.lua`.
