--- Path manipulation utilities.
--- Wraps cosmo.path for path operations: dirname, basename, join, exists, isfile, isdir, islink.
local path = require("cosmo.path")

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

local record PathModule
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  exists: function(path: string): boolean
  isfile: function(path: string): boolean
  isdir: function(path: string): boolean
  islink: function(path: string): boolean
end

local M: PathModule = {
  dirname = dirname,
  basename = basename,
  join = join,
  exists = exists,
  isfile = isfile,
  isdir = isdir,
  islink = islink,
}

return M
