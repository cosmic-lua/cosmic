## Goal

`unix.Dir:fd()`'s doc comment in `tool/net/definitions.lua` claims a
failure mode that no longer exists in the underlying C implementation
— pure documentation drift, filed while classifying the unix
stat/directory-stream/temp-fd census slice (parent container).

## Evidence

`tool/net/definitions.lua` (search for `function unix.Dir:fd`)
documents: "Returns `EOPNOTSUPP` if using a `/zip/...` path or if
using Windows NT."

`libc/stdio/dirstream.c`'s current `dirfd()`:
```c
int dirfd(DIR *dir) {
  return dir->fd;
}
```
Unconditional — no `EOPNOTSUPP` branch anywhere. `git log -L
'/^int dirfd/,+3:libc/stdio/dirstream.c'` shows commit `110559ce6`
("Make ZipOS and Qemu work better", 2023-08-15) deleted the
`if (dir->iszip) rc = eopnotsupp(); else if (IsWindows()) rc =
eopnotsupp();` branches that used to justify the doc comment,
collapsing it to the unconditional return above.

Probe (from the cosmopolitan repo root, against `o//tool/lua/lua`
built by `make -j$(nproc) o//tool/lua/lua`):
```
$ o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir("/zip/");print(d:fd())'
3
```
A valid fd, not `nil`/`EOPNOTSUPP`, contradicting the doc comment.

Cosmic-side spend: `cosmic/fs/dir.tl` (`wrap_dir`'s `fd` method)
already codes around the stale claim with a defensive `raw:fd() or -1`
fallback and a comment citing the same EOPNOTSUPP-on-zip/Windows
rationale — harmless belt-and-suspenders given the code is otherwise
correct, but worth revisiting once the doc comment here is fixed.

## Change

Update `tool/net/definitions.lua`'s `unix.Dir:fd()` doc comment to
drop the stale EOPNOTSUPP claim and describe the current, unconditional
behavior (always returns the directory stream's underlying file
descriptor as a plain integer). Separately, once this lands, consider
(implementer's judgment, not required by this capture) whether
`cosmic/fs/dir.tl`'s `raw:fd() or -1` defensive fallback can simplify
now that the underlying claim it defends against is confirmed false —
not required here.

## Non-goals

- No change to `unix.Dir:fd()`'s actual return shape or behavior —
  documentation only.
- No change to `unix.Dir:tell()` — a lesser, similar note (its `|nil`
  has never been reachable since the file's initial import, but no doc
  comment claims otherwise for it, so there's no drift to correct).
- No required change to `cosmic/fs/dir.tl` — the defensive fallback is
  harmless and simplifying it is left to implementer's judgment, not
  gated by this capture's acceptance bar.

## Acceptance

- `unix.Dir:fd()`'s doc comment in `tool/net/definitions.lua` matches
  its actual, current behavior.
