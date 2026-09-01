## Goal

`tool/net/demo/unix-info.lua:38` destructures `unix.getrlimit()`'s
return positionally:

```lua
soft, hard = unix.getrlimit(id)
```

PR #324 ("unix: raise argument-shape errors for raise/sigprocmask,
bundle getrlimit's success pair") changed `unix.getrlimit` to return
one `unix.Rlimit` table (fields `soft`/`hard`) instead of two
positional integers on success. This demo now silently misbehaves:
`soft` becomes the whole table, and `hard` becomes `nil`, with no
error raised anywhere.

## Evidence

- `tool/net/demo/unix-info.lua:38` (current master, post-#324): the
  positional destructuring line above.
- `tool/net/definitions.lua`'s `unix.getrlimit` now declares
  `---@return unix.Rlimit|nil` — a single table, not two positional
  values.
- This demo is not built or run by `make -j$(nproc) o//tool/lua/test`
  or any other CI-invoked target (neither `tool/net/BUILD.mk` nor
  `tool/lua/BUILD.mk` references `demo/unix-info.lua`), so no gate
  caught the breakage — the same class of gap as the sibling
  `unix-dir.lua`/`unix.localtime` finding from PR #321.

## Change

Rewrite `tool/net/demo/unix-info.lua:38`'s destructuring to read the
new `unix.Rlimit` table's fields (`.soft`, `.hard`) instead of
positional locals, and update whatever the demo does with those
values accordingly (read the surrounding function body first — the
fix should preserve the demo's existing behavior/output, not just
make it not crash).

## Non-goals

- No change to `unix.getrlimit` itself — already fixed by #324.
- No change to `tool/net/demo/unix-dir.lua` (separate sibling finding,
  already filed for the #321 localtime change).

## Acceptance

- `tool/net/demo/unix-info.lua` runs without error against the current
  `unix.getrlimit` table-returning shape and produces output
  equivalent in substance to what it produced before #324 (same
  fields, read from the table instead of positional locals).
