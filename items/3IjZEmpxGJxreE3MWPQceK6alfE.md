## Goal

`tool/net/demo/unix-dir.lua:77` destructures `unix.localtime()`'s
return positionally:

```lua
year,mon,mday,hour,min,sec,gmtoffsec = unix.localtime(unixsec)
```

PR #321 ("unix: bundle gmtime/localtime into one table, tighten
sigpending/clearenv nils") changed `unix.localtime` to return one
`unix.BrokenDownTime` table instead of 11 positional values on
success. This demo now silently misbehaves: `year` becomes the whole
table, and `mon`/`mday`/etc. are all `nil`, with no error raised
anywhere.

## Evidence

- `tool/net/demo/unix-dir.lua:77` (current master, post-#321): the
  positional destructuring line above.
- `tool/net/definitions.lua`'s `unix.localtime` now declares
  `---@return unix.BrokenDownTime|nil` — a single table, not 11
  positional values — confirmed by `git show <321-merge-sha> --
  tool/net/definitions.lua`.
- This demo is not built or run by `make -j$(nproc) o//tool/lua/test`
  or any other CI-invoked target (confirmed: neither
  `tool/net/BUILD.mk` nor `tool/lua/BUILD.mk` references
  `demo/unix-dir.lua`), so no gate caught the breakage.

## Change

Rewrite `tool/net/demo/unix-dir.lua:77`'s destructuring to read the
new `unix.BrokenDownTime` table's fields (`.year`, `.mon`, `.mday`,
`.hour`, `.min`, `.sec`, `.gmtoffsec`, ...) instead of positional
locals, and update whatever the demo does with those values
accordingly (read the surrounding function body first — the fix
should preserve the demo's existing behavior/output, not just make it
not crash).

## Non-goals

- No change to `unix.localtime`/`unix.gmtime` themselves — already
  fixed by #321.
- No change to `tool/net/help.txt`'s stale documentation of the old
  return shape — that is a separate, sibling finding (see the
  `help.txt` capture filed alongside this one).

## Acceptance

- `tool/net/demo/unix-dir.lua` runs without error against the current
  `unix.localtime` table-returning shape and produces output
  equivalent in substance to what it produced before #321 (same
  fields, read from the table instead of positional locals).
