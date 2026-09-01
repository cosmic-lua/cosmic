## Goal

G3, via the cosmo-contracts container: close the one tuple-deviation
surfaced by the filesystem-namespace census — `unix.mkstemp` is the
only nil-admitting binding in that slice whose success shape does not
fit `T|nil, err string, errno?`. Fix it the way `unix.nanosleep` was
already fixed: bundle the success-only extra value so slot 2 is always
the error string on failure and never doubles as a success value.

## Evidence

- `tool/net/definitions.lua:5161` — the first `@return` line for
  `unix.mkstemp` reads `---@return integer|nil fd, string path`: two
  values packed into slots 1/2 on success (`fd`, `path`). The next two
  lines (`:5162` `---@return string? error`, `:5163`
  `---@return unix.Errno? errno`) declare slot 2 as the error string on
  failure. So slot 2 is `path` on success and `error` on failure — the
  same shared-slot shape the census names `unix.nanosleep` as the
  archetype of.
- `third_party/lua/cosmo/lunix.c:1798-1817` (`LuaUnixMkstemp`): on
  success pushes exactly 2 values (`fd`, `path`) and returns 2; on
  failure calls `LuaUnixSysretErrno` (`lunix.c:219-236`), which pushes
  exactly `nil, err, errno` (3 values) and returns 3. Probe transcript
  against `o//tool/lua/lua` (built via `make -j$(nproc) o//tool/lua/lua`),
  run from the cosmopolitan repo root:
  ```
  $ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd,path=unix.mkstemp(d.."/t_XXXXXX") print("success:",fd,path) unix.close(fd) unix.unlink(path) local fd2,e,eno=unix.mkstemp("/tmp/fsns-nosuchdir-xyz/t_XXXXXX") print("failure:",fd2,e,eno) unix.rmdir(d)'
  success:	3	/tmp/fsns6wm9g0/t_z1w70h
  failure:	nil	mkstemp: ENOENT: No such file or directory	2
  ```
- cosmic-side spend (`grep -rn 'unix\.mkstemp' cosmic/` in a
  cosmic-lua/cosmic checkout) — every call site already carries an
  explicit comment documenting the deviation as a known landmine, not a
  hypothetical:
  - `cosmic/fs/ops.tl:380-381` — `-- The binding returns (fd, path) on
    success and (nil, Errno) on failure.` / `local fd, path =
    unix.mkstemp(template)`
  - `cosmic/fs/file.tl:92-94` — identical comment / `local fd, tmp =
    unix.mkstemp(path .. ".XXXXXX")`
  - `cosmic/embed/init.tl:375` — `local tmp_fd, tmp_path =
    unix.mkstemp(output .. ".XXXXXX")` (relies on the same shape,
    branching only on `not tmp_fd`)
- `unix.nanosleep` (`lunix.c:1686-1696`) already carries a comment
  describing the identical problem it used to have and the fix applied:
  bundling the success/remainder shape into one table so "every slot's
  meaning fixed: 1 is always the value-or-nil, 2/3 are always
  error/errno."

## Change

Apply the same bundling fix `unix.nanosleep` received: change
`unix.mkstemp`'s success return from two positional values `(fd, path)`
to a shape where slot 2 is never anything but the error string on
failure — e.g. `(fd, {path = path})`, or fold `path` into a record
alongside `fd` the same way `nanosleep`'s remaining-time table does.
Update `tool/net/definitions.lua`'s annotation for `unix.mkstemp` to
match in the same commit (this repo's AGENTS.md binding-contract rule:
"a deliberate contract change needs a matching `definitions.lua` update
here ... landed as its own change, never inside an optimization").

Downstream (cosmic-lua/cosmic, NOT part of this capture): the three
call sites above will need their destructuring updated once cosmic
bumps its cosmos pin to a release carrying this fix — flag it as a
consequence, do not fix it here.

## Non-goals

- No change to any other binding in the filesystem-namespace census
  slice — every other row there is already exact.
- No cosmic-side wrapper change — that is cosmic's own follow-up once
  it bumps its cosmos pin.
- No re-litigating the `unix.nanosleep` fix itself — cited only as
  settled precedent for the pattern to repeat.

## Acceptance

- `unix.mkstemp`'s success path returns exactly 2 values where slot 2
  is never a bare string sharing shape with the failure path's error
  slot; its failure path is unchanged: `nil, err string, errno`.
- `tool/net/definitions.lua`'s annotation for `unix.mkstemp` reflects
  the new shape.
- A probe transcript demonstrating both the success and failure shapes
  accompanies the PR, in the form shown in this capture's Evidence
  section.
- `make -j$(nproc) o//tool/lua/test` passes (binding tests + the
  annotation-coverage ratchet).
