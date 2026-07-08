--- Recursive directory-tree operations.
--- Internal submodule used by cosmic.fs.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")
local errstr = require("cosmic.errno").str
local fs_ops = require("cosmic.fs.ops")

--- Handle for reading directory entries (internal).
local record TreeDirHandle
  read: function(self): string, number
  close: function(self)
end

local copytree_into: function(string, string): boolean, string

--- Copy one directory level: entries are dispatched by lstat kind so a
--- symlink is recreated (readlink + symlink), never followed — the same
--- cycle policy as walk. Regular files go through fs_ops.copy, which
--- preserves permission bits. Other kinds (fifos, sockets, devices) are
--- not portably copyable and are skipped.
local function copy_entries(src: string, dst: string): boolean, string
  local handle, oerr = unix.opendir(src)
  if not handle then
    return false, errstr(oerr, "copytree: opendir: " .. src)
  end
  local h = handle as TreeDirHandle
  while true do
    local entry = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local s = cosmo_path.join(src, entry)
      local d = cosmo_path.join(dst, entry)
      local st, serr = unix.stat(s, unix.AT_SYMLINK_NOFOLLOW)
      if not st then
        h:close()
        return false, errstr(serr, "copytree: stat: " .. s)
      end
      local mode = st:mode()
      if unix.S_ISLNK(mode) then
        local target, rerr = unix.readlink(s)
        if not target then
          h:close()
          return false, errstr(rerr, "copytree: readlink: " .. s)
        end
        local ok, lerr = unix.symlink(target, d)
        if not ok then
          h:close()
          return false, errstr(lerr, "copytree: symlink: " .. d)
        end
      elseif unix.S_ISDIR(mode) then
        local ok, cerr = copytree_into(s, d)
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

copytree_into = function(src: string, dst: string): boolean, string
  local st, serr = unix.stat(src, unix.AT_SYMLINK_NOFOLLOW)
  if not st then
    return false, errstr(serr, "copytree: stat: " .. src)
  end
  if not unix.S_ISDIR(st:mode()) then
    return false, "copytree: not a directory: " .. src
  end
  local ok, merr = unix.makedirs(dst, st:mode() & tonumber("777", 8))
  if not ok then
    return false, errstr(merr, "copytree: makedirs: " .. dst)
  end
  return copy_entries(src, dst)
end

--- Recursively copy a directory tree, preserving permission bits.
--- Symlinks are recreated verbatim (readlink + symlink) and never
--- followed — the same cycle policy as walk, so symlink loops cannot
--- cause infinite copies, and a symlinked directory arrives as a
--- symlink, not a second copy of its target. Fifos, sockets, and
--- device nodes are skipped. Destination directories are created as
--- needed; existing destination files are overwritten.
--- @param src string The directory to copy
--- @param dst string The destination directory (created if missing)
--- @return boolean True on success
--- @return string Error message on the first failure
local function copytree(src: string, dst: string): boolean, string
  return copytree_into(src, dst)
end

local record FsTreeModule
  copytree: function(src: string, dst: string): boolean, string
end

local M: FsTreeModule = {
  copytree = copytree,
}

return M
