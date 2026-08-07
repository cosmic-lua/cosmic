--- posix_spawn-backed fast path for `cosmic.child.start`.
---
--- `unix.spawn` (posix_spawn) creates the child without forking the Lua
--- interpreter: no page-table copy, no Lua running in the child, and an
--- exec failure (ENOENT, EACCES, ...) comes back as the call's own error
--- return, so no exec-status pipe is needed. The binding exposes no file
--- actions, so the child's stdio is wired by temporarily dup2'ing the
--- child-side descriptors onto this process's fds 0/1/2 (the child
--- inherits copies of them) and restoring the originals right after the
--- spawn call returns. No Lua runs between the dup2s and the restore, so
--- the window is not observable from library callers.
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")

-- Sentinel in `saves`: the std fd was not open, so restoring it means
-- closing it again rather than dup2'ing a saved copy back.
local CLOSED = -1

-- Move std fd `n` out of the way. The copy is CLOEXEC (it must never
-- leak into the child) and placed at 10+ so it cannot collide with the
-- 0-2 range being wired.
-- @param n integer the std fd (0, 1, or 2)
-- @return integer | nil saved fd, CLOSED if `n` was not open, or nil when
--   the caller should abandon the fast path
local function save_fd(n: integer): integer | nil
  local saved, _, eno = unix.dup(n, nil, unix.O_CLOEXEC, 10)
  if saved then
    return saved
  end
  if errno.is(eno, "EBADF") then
    return CLOSED
  end
  return nil
end

--- Spawn `prog` via posix_spawn with fd0/fd1/fd2 as the child's stdio.
--- Callers must ensure none of the fds is a CLOEXEC descriptor that
--- already sits at its own std number (it would be skipped, and the
--- child would then lose it at exec).
--- @param prog string resolved executable path
--- @param argv {string} argument vector (argv[1] is the program name)
--- @param envp {string} | nil environment, or nil to inherit
--- @param fd0 integer child's stdin
--- @param fd1 integer child's stdout
--- @param fd2 integer child's stderr
--- @return integer | nil child pid; nil means failure or fallback
--- @return string | nil error: set only for a real spawn failure that
---   should be reported; `nil, nil` means "fall back to the fork path"
local function spawn(prog: string, argv: {string}, envp: {string} | nil,
    fd0: integer, fd1: integer, fd2: integer): integer | nil, string
  local targets: {integer} = {fd0, fd1, fd2}
  local saves: {integer} = {}

  -- Save the std fds that are about to be replaced.
  for i = 1, 3 do
    local std = i - 1
    if targets[i] ~= std then
      local saved = save_fd(std)
      if saved == nil then
        for j = 1, 3 do
          local s = saves[j]
          if s and s ~= CLOSED then unix.close(s) end
        end
        return nil
      end
      saves[i] = saved
    end
  end

  -- Resolve each target to a source fd immune to the wiring below. A
  -- target that names another std fd (0/1/2) about to be overwritten by
  -- a DIFFERENT wiring step -- a full stdout<->stderr swap, say -- would
  -- otherwise be read AFTER that step already clobbered it: the wiring
  -- loop dup2's in fixed 0->1->2 order, and an earlier iteration may
  -- already have overwritten the very std fd a later one names as its
  -- source. The save loop above already captured every about-to-be-
  -- overwritten std fd's PRISTINE value before any dup2 ran, so read
  -- from that saved copy instead of the live (possibly already
  -- clobbered) std fd.
  local sources: {integer} = {}
  for i = 1, 3 do
    local t = targets[i]
    if t >= 0 and t <= 2 and saves[t + 1] and saves[t + 1] ~= CLOSED then
      sources[i] = saves[t + 1]
    else
      sources[i] = t
    end
  end

  -- Wire the child-side fds onto 0/1/2. dup2 copies are not CLOEXEC, so
  -- the child inherits exactly these three.
  local wired = true
  for i = 1, 3 do
    local std = i - 1
    if targets[i] ~= std then
      if not unix.dup(sources[i], std) then
        wired = false
        break
      end
    end
  end

  local pid: integer
  local serr: string
  if wired then
    local p, e = unix.spawn(prog, argv, envp)
    pid = p
    serr = e
  end

  -- Restore the parent's own stdio, whether or not the spawn happened.
  for i = 1, 3 do
    local std = i - 1
    local s = saves[i]
    if s then
      if s == CLOSED then
        unix.close(std)
      else
        unix.dup(s, std)
        unix.close(s)
      end
    end
  end

  if not wired then
    return nil
  end
  if pid == nil then
    return nil, errno.wrap(serr, "exec failed")
  end
  return pid
end

local record FastModule
  spawn: function(prog: string, argv: {string}, envp: {string} | nil,
  fd0: integer, fd1: integer, fd2: integer): integer | nil, string
end

local M: FastModule = {
  spawn = spawn,
}

return M
