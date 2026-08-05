--- Recursive directory-tree operations.
--- Internal submodule used by cosmic.fs.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")
local errno = require("cosmic.errno")
local errstr = errno.wrap
local fs_ops = require("cosmic.fs.ops")
local fs_types = require("cosmic.fs.types")
local type TreeDirHandle = fs_types.DirHandle

local copy_tree_into: function(string, string): boolean, string

--- Copy one directory level: entries are dispatched by lstat kind so a
--- symlink is recreated (readlink + symlink), never followed — the same
--- cycle policy as walk. Regular files go through fs_ops.copy, which
--- preserves permission bits. Other kinds (fifos, sockets, devices) are
--- not portably copyable and are skipped.
local function copy_entries(src: string, dst: string): boolean, string
  local handle, oerr = unix.opendir(src)
  if not handle then
    return false, errstr(oerr, "copy_tree: opendir: " .. src)
  end
  local h = handle as TreeDirHandle -- cast: userdata boundary
  while true do
    local entry = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local s = cosmo_path.join(src, entry)
      local d = cosmo_path.join(dst, entry)
      local st, serr = unix.stat(s, unix.AT_SYMLINK_NOFOLLOW)
      if not st then
        h:close()
        return false, errstr(serr, "copy_tree: stat: " .. s)
      end
      local mode = (st as unix.Stat):mode() -- cast: record union after guard
      if unix.S_ISLNK(mode) then
        local target, rerr = unix.readlink(s)
        if not target then
          h:close()
          return false, errstr(rerr, "copy_tree: readlink: " .. s)
        end
        -- symlink() fails EEXIST over an existing destination; unlink it
        -- first (ENOENT means there was nothing to remove) so re-copying
        -- a tree overwrites, matching copy()'s behavior on regular files.
        local unlinked, uerr, ueno = unix.unlink(d)
        if not unlinked and not errno.is(ueno, "ENOENT") then
          h:close()
          return false, errstr(uerr, "copy_tree: unlink: " .. d)
        end
        local ok, lerr = unix.symlink(target, d)
        if not ok then
          h:close()
          return false, errstr(lerr, "copy_tree: symlink: " .. d)
        end
      elseif unix.S_ISDIR(mode) then
        local ok, cerr = copy_tree_into(s, d)
        if not ok then
          h:close()
          return false, cerr
        end
      elseif unix.S_ISREG(mode) then
        local ok, cerr = fs_ops.copy(s, d)
        if not ok then
          h:close()
          return false, cerr
        end
      end
    end
  end
  h:close()
  return true
end

copy_tree_into = function(src: string, dst: string): boolean, string
  local st, serr = unix.stat(src, unix.AT_SYMLINK_NOFOLLOW)
  if not st then
    return false, errstr(serr, "copy_tree: stat: " .. src)
  end
  if not unix.S_ISDIR((st as unix.Stat):mode()) then -- cast: record union after guard
    return false, "copy_tree: not a directory: " .. src
  end
  local mode = (st as unix.Stat):mode() & tonumber("777", 8) -- cast: record union after guard
  local ok, merr = unix.makedirs(dst, mode)
  if not ok then
    return false, errstr(merr, "copy_tree: make_dirs: " .. dst)
  end
  -- make_dirs()'s mode is umask-filtered on creation and a no-op when dst
  -- already exists; chmod applies the exact bits either way, matching
  -- fs_ops.copy()'s treatment of file permissions.
  local chmodded, cerr = unix.chmod(dst, mode)
  if not chmodded then
    return false, errstr(cerr, "copy_tree: chmod: " .. dst)
  end
  return copy_entries(src, dst)
end

--- Recursively copy a directory tree, preserving permission bits.
--- Symlinks are recreated verbatim (readlink + symlink) and never
--- followed — the same cycle policy as walk, so symlink loops cannot
--- cause infinite copies, and a symlinked directory arrives as a
--- symlink, not a second copy of its target. Fifos, sockets, and
--- device nodes are skipped. Destination directories are created as
--- needed (with the source's permission bits, even if the destination
--- already existed); existing destination files and symlinks are
--- overwritten.
--- @param src string The directory to copy
--- @param dst string The destination directory (created if missing)
--- @return boolean True on success
--- @return string Error message on the first failure
local function copy_tree(src: string, dst: string): boolean, string
  return copy_tree_into(src, dst)
end

local record FsTreeModule
  copy_tree: function(src: string, dst: string): boolean, string
end

local M: FsTreeModule = {
  copy_tree = copy_tree,
}

return M
