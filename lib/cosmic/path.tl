--- Path manipulation utilities.
--- Wraps cosmo.path for path operations: dirname, basename, join, exists, isfile, isdir, islink.
--- Also provides pure string manipulation: abspath, normalize, relpath, splitext, ext.
local path = require("cosmo.path")
local unix = require("cosmo.unix")

--- Strip final component from path.
--- Examples: "/usr/lib" -> "/usr", "usr" -> ".", "/" -> "/"
--- @param str string The path to get the directory from
--- @return string The directory portion of the path
local function dirname(str: string): string
  return path.dirname(str)
end

--- Return final component of path.
--- Examples: "/usr/lib" -> "lib", "/" -> "/", "." -> "."
--- @param str string The path to get the basename from
--- @return string The final component of the path
local function basename(str: string): string
  return path.basename(str)
end

--- Concatenate path components.
--- Absolute paths in later arguments reset the result.
--- Nil arguments are skipped; exclusively nil returns nil.
--- @param ... string Path components to join
--- @return string The joined path
local function join(...: string): string
  return path.join(...)
end

--- Check if path exists (regular file, directory, or special file).
--- Symbolic links are followed. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path exists
local function exists(p: string): boolean
  return path.exists(p)
end

--- Check if path is a regular file.
--- Symbolic links are not followed. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a regular file
local function isfile(p: string): boolean
  return path.isfile(p)
end

--- Check if path is a directory.
--- Symbolic links are not followed. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a directory
local function isdir(p: string): boolean
  return path.isdir(p)
end

--- Check if path is a symbolic link.
--- Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a symbolic link
local function islink(p: string): boolean
  return path.islink(p)
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

  local is_absolute = p:sub(1, 1) == "/"

  -- Split into components, filtering empty strings (from // or trailing /)
  local parts: {string} = {}
  for part in p:gmatch("[^/]+") do
    if part == "." then
      -- skip current dir
    elseif part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        -- pop last component if it's not also a ..
        if is_absolute or parts[#parts] ~= ".." then
          table.remove(parts)
        else
          table.insert(parts, "..")
        end
      elseif not is_absolute then
        -- for relative paths, preserve leading ..
        table.insert(parts, "..")
      end
      -- for absolute paths starting with /.., just ignore the ..
    else
      table.insert(parts, part)
    end
  end

  if is_absolute then
    if #parts == 0 then
      return "/"
    else
      return "/" .. table.concat(parts, "/")
    end
  else
    if #parts == 0 then
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
  -- Get absolute versions of both paths
  local abs_p = abspath(p)
  local abs_base: string
  if base then
    abs_base = abspath(base)
  else
    abs_base = unix.getcwd() or "."
  end

  -- Split into components
  local function split_path(s: string): {string}
    local parts: {string} = {}
    for part in s:gmatch("[^/]+") do
      table.insert(parts, part)
    end
    return parts
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
  local base = path.basename(p)
  local dir = path.dirname(p)

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

--- Example_normalize demonstrates path normalization
local function Example_normalize()
  local p = require("cosmic.path")
  print(p.normalize("/usr/./lib"))
  print(p.normalize("/usr/lib/../bin"))
  print(p.normalize("a/b/../c"))
  print(p.normalize("//usr///lib//"))
  -- Output:
  -- /usr/lib
  -- /usr/bin
  -- a/c
  -- /usr/lib
end

--- Example_splitext demonstrates extension splitting
local function Example_splitext()
  local p = require("cosmic.path")
  local root: string
  local extension: string
  root, extension = p.splitext("archive.tar.gz")
  print(root, extension)
  root, extension = p.splitext(".bashrc")
  print(root, extension)
  root, extension = p.splitext("/path/to/file.txt")
  print(root, extension)
  -- Output:
  -- archive.tar	.gz
  -- .bashrc
  -- /path/to/file	.txt
end

--- Example_relpath demonstrates computing relative paths
local function Example_relpath()
  local p = require("cosmic.path")
  print(p.relpath("/usr/lib", "/usr"))
  print(p.relpath("/usr/lib", "/usr/bin"))
  print(p.relpath("/foo", "/bar"))
  -- Output:
  -- lib
  -- ../lib
  -- ../foo
end

-- Suppress unused warnings for examples
local _ = {Example_normalize, Example_splitext, Example_relpath}

local record PathModule
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
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

local M: PathModule = {
  dirname = dirname,
  basename = basename,
  join = join,
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
