--- Path manipulation functions for the filesystem module.
--- Pure string operations for dirname, basename, join, normalize, etc.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")

--- Strip final component from path.
--- Examples: "/usr/lib" -> "/usr", "usr" -> ".", "/" -> "/"
--- @param str string The path to get the directory from
--- @return string The directory portion of the path
local function dirname(str: string): string
  return cosmo_path.dirname(str)
end

--- Return final component of path.
--- Examples: "/usr/lib" -> "lib", "/" -> "/", "." -> "."
--- @param str string The path to get the basename from
--- @return string The final component of the path
local function basename(str: string): string
  return cosmo_path.basename(str)
end

--- Concatenate path components.
--- Absolute paths in later arguments reset the result.
--- Nil arguments are skipped; exclusively nil returns nil.
--- @param ... string Path components to join
--- @return string The joined path
local function join(...: string): string
  return cosmo_path.join(...)
end

--- Check if path exists (regular file, directory, or special file).
--- Symbolic links are followed (uses stat): a symlink resolves to its target,
--- and returns true if the target exists. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path exists
local function exists(p: string): boolean
  return cosmo_path.exists(p)
end

--- Check if path is a regular file.
--- Symbolic links are followed (uses stat), matching POSIX `test -f`,
--- Python, and Node: a symlink to a regular file counts as a regular
--- file. Use islink() to detect the symlink itself. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a regular file
local function isfile(p: string): boolean
  local st = unix.stat(p)
  return st ~= nil and unix.S_ISREG((st as unix.Stat):mode())
end

--- Check if path is a directory.
--- Symbolic links are followed (uses stat), matching POSIX `test -d`,
--- Python, and Node: a symlink to a directory counts as a directory.
--- Use islink() to detect the symlink itself. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a directory
local function isdir(p: string): boolean
  local st = unix.stat(p)
  return st ~= nil and unix.S_ISDIR((st as unix.Stat):mode())
end

--- Check if path is a symbolic link.
--- Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a symbolic link
local function islink(p: string): boolean
  return cosmo_path.islink(p)
end

--- Normalize path by removing `.` and `..` components without filesystem access.
--- Also removes redundant slashes. Pure string manipulation.
--- Examples: "/usr/./lib" -> "/usr/lib", "/usr/lib/../bin" -> "/usr/bin"
--- @param p string The path to normalize
--- @return string The normalized path
local function normalize(p: string): string
  if p == "" then
    return "."
  end

  -- Fast path: a path that is already normal — no redundant "//" or
  -- trailing "/", and no "." or ".." components — normalizes to itself,
  -- so return it without allocating the parts table and result string.
  -- The predicate is a conservative subset of "output == input" built
  -- from C-implemented full-string checks (no per-component Lua loop);
  -- anything it doesn't match falls through to the authoritative loop
  -- below, which stays the source of truth for correctness. Note a
  -- component merely containing dots (e.g. "..." or "a.b") is normal and
  -- correctly passes, since only exact "." / ".." segments are excluded.
  if p:sub(-1) ~= "/"
  and not p:find("//", 1, true)
  and p ~= "." and p:sub(1, 2) ~= "./"
  and p:sub(-2) ~= "/." and not p:find("/./", 1, true)
  and p ~= ".." and p:sub(1, 3) ~= "../"
  and p:sub(-3) ~= "/.." and not p:find("/../", 1, true) then
    return p
  end

  local is_absolute = p:sub(1, 1) == "/"

  -- Split into components, filtering empty strings (from // or trailing /)
  local parts: {string} = {}
  local n = 0
  for part in p:gmatch("[^/]+") do
    if part == "." then
      -- skip current dir
    elseif part == ".." then
      if n > 0 and parts[n] ~= ".." then
        parts[n] = nil
        n = n - 1
      elseif not is_absolute then
        -- for relative paths, preserve leading ..
        n = n + 1
        parts[n] = ".."
      end
      -- for absolute paths starting with /.., just ignore the ..
    else
      n = n + 1
      parts[n] = part
    end
  end

  if is_absolute then
    if n == 0 then
      return "/"
    else
      return "/" .. table.concat(parts, "/")
    end
  else
    if n == 0 then
      return "."
    else
      return table.concat(parts, "/")
    end
  end
end

--- Convert relative path to absolute by prepending cwd.
--- Does NOT resolve symlinks or access filesystem (except to get cwd).
--- @param p string The path to make absolute
--- @return string The absolute path
local function abspath(p: string): string
  if p == "" then
    return unix.getcwd() or "."
  end
  if p:sub(1, 1) == "/" then
    return normalize(p)
  end
  local cwd = unix.getcwd()
  if not cwd then
    return normalize(p)
  end
  return normalize(cwd .. "/" .. p)
end

--- Make path relative to another path (defaults to cwd).
--- Pure string manipulation - does not access the filesystem.
--- @param p string The path to make relative
--- @param base string The base path (defaults to cwd)
--- @return string The relative path
local function relpath(p: string, base: string): string
  -- Get absolute versions of both paths. When both p and the implicit
  -- base need cwd (relative p, no explicit base), fetch it once instead
  -- of once per abspath() call.
  local abs_p: string
  local abs_base: string
  if base then
    abs_p = abspath(p)
    abs_base = abspath(base)
  elseif p:sub(1, 1) == "/" then
    abs_p = normalize(p)
    abs_base = unix.getcwd() or "."
  else
    local cwd = unix.getcwd() or "."
    abs_p = normalize(cwd .. "/" .. p)
    abs_base = cwd
  end

  -- Split into components
  local function split_path(s: string): {string}
    local path_parts: {string} = {}
    for part in s:gmatch("[^/]+") do
      table.insert(path_parts, part)
    end
    return path_parts
  end

  local p_parts = split_path(abs_p)
  local base_parts = split_path(abs_base)

  -- Find common prefix length
  local common_len = 0
  local max_common = math.min(#p_parts, #base_parts)
  for i = 1, max_common do
    if p_parts[i] == base_parts[i] then
      common_len = i
    else
      break
    end
  end

  -- Build relative path: go up from base, then down to target
  local rel_parts: {string} = {}

  -- Add ".." for each remaining component in base
  for _ = common_len + 1, #base_parts do
    table.insert(rel_parts, "..")
  end

  -- Add remaining components from target
  for i = common_len + 1, #p_parts do
    table.insert(rel_parts, p_parts[i])
  end

  if #rel_parts == 0 then
    return "."
  end

  return table.concat(rel_parts, "/")
end

--- Split path into root and extension.
--- Extension includes the dot. Handles multiple extensions by splitting at
--- the last dot in the basename. Hidden files (starting with .) have no extension.
--- Examples: "foo.txt" -> "foo", ".txt"; ".bashrc" -> ".bashrc", ""
--- @param p string The path to split
--- @return string The root portion (path without extension)
--- @return string The extension (including dot, or empty string)
local function splitext(p: string): string, string
  local base = cosmo_path.basename(p)
  local dir = cosmo_path.dirname(p)

  -- Handle hidden files: if basename starts with . and has no other dot, no extension
  if base:sub(1, 1) == "." then
    local rest = base:sub(2)
    local dot_pos = rest:find("%.")
    if not dot_pos then
      -- Hidden file with no extension
      return p, ""
    end
    -- Hidden file with extension: find last dot in the non-hidden part
    local last_dot: integer = 0
    for i = #base, 2, -1 do
      if base:sub(i, i) == "." then
        last_dot = i
        break
      end
    end
    if last_dot > 0 then
      local extension = base:sub(last_dot)
      local root_base = base:sub(1, last_dot - 1)
      if dir == "." then
        return root_base, extension
      else
        return dir .. "/" .. root_base, extension
      end
    end
    return p, ""
  end

  -- Find last dot in basename
  local last_dot: integer = 0
  for i = #base, 1, -1 do
    if base:sub(i, i) == "." then
      last_dot = i
      break
    end
  end

  if last_dot == 0 or last_dot == 1 then
    -- No dot, or dot at start (shouldn't happen since we handled hidden files)
    return p, ""
  end

  local extension = base:sub(last_dot)
  local root_base = base:sub(1, last_dot - 1)

  if dir == "." then
    return root_base, extension
  else
    return dir .. "/" .. root_base, extension
  end
end

--- Return the extension of a path.
--- Extension includes the dot. Convenience wrapper around splitext.
--- @param p string The path to get extension from
--- @return string The extension (including dot, or empty string)
local function ext(p: string): string
  local _, extension = splitext(p)
  return extension
end

--- Return the current user's home directory.
--- Uses $HOME, falling back to $USERPROFILE (Windows).
--- @return string | nil The home directory, or nil when unknown
--- @return string? Error message when no home directory is set
local function home(): string | nil, string
  local dir = os.getenv("HOME") or os.getenv("USERPROFILE")
  if not dir or dir == "" then
    return nil, "home: HOME is not set"
  end
  return dir
end

--- Expand a leading "~" in a path to the user's home directory.
--- Only bare "~" and "~/..." are expanded; "~user/..." forms and
--- paths without the prefix are returned unchanged, as is any path
--- when no home directory can be determined.
--- @param p string The path to expand
--- @return string The expanded path
local function expanduser(p: string): string
  if p ~= "~" and p:sub(1, 2) ~= "~/" then
    return p
  end
  local dir = home()
  if not dir then
    return p
  end
  if p == "~" then
    return dir
  end
  return cosmo_path.join(dir, p:sub(3))
end

local record FsPathModule
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  home: function(): string | nil, string
  expanduser: function(p: string): string
  exists: function(path: string): boolean
  isfile: function(path: string): boolean
  isdir: function(path: string): boolean
  islink: function(path: string): boolean
  normalize: function(p: string): string
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
  ext: function(p: string): string
end

local M: FsPathModule = {
  dirname = dirname,
  basename = basename,
  join = join,
  home = home,
  expanduser = expanduser,
  exists = exists,
  isfile = isfile,
  isdir = isdir,
  islink = islink,
  normalize = normalize,
  abspath = abspath,
  relpath = relpath,
  splitext = splitext,
  ext = ext,
}

return M
