--- Directory walking and file collection utilities.
--- Provides recursive directory traversal, pattern-based file collection,
--- and file iteration.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")

--- File or directory metadata for walk visitor.
local record WalkStat
  mode: function(self): number
  size: function(self): number
  mtim: function(self): number
end

--- Handle for reading directory entries (internal).
local record WalkDirHandle
  read: function(self): string
  close: function(self)
end

--- File information with Unix permissions.
local record FileInfo
  mode: number
end

--- Visitor function type for directory traversal.
--- Return false to skip recursion into subdirectories.
--- @param full_path string The complete path to the file or directory
--- @param entry string The basename of the file or directory
--- @param stat WalkStat File metadata
--- @param ctx any User-provided context passed through the walk
--- @return boolean Return false to skip recursing into this directory
local type Visitor = function(full_path: string, entry: string, stat: WalkStat, ctx: any): boolean

--- Walk a directory tree, calling visitor for each entry.
--- Recursively traverses subdirectories unless visitor returns false.
--- @param dir string The directory to walk
--- @param visitor Visitor Function called for each file and directory
--- @param ctx T Optional context passed to visitor function
--- @return T The context object, potentially modified by visitor
local function walk<T>(dir: string, visitor: Visitor, ctx?: T): T
  ctx = ctx or {} as T
  local handle = unix.opendir(dir) as WalkDirHandle
  if not handle then return ctx end

  while true do
    local entry = handle:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local full_path = cosmo_path.join(dir, entry)
      local st = unix.stat(full_path) as WalkStat
      if st then
        local continue = visitor(full_path, entry, st, ctx)
        if continue ~= false and unix.S_ISDIR(st:mode()) then
          walk(full_path, visitor, ctx)
        end
      end
    end
  end
  handle:close()
  return ctx
end

--- Convert a glob pattern to a Lua pattern.
--- Supports * (any chars), ? (single char), and character classes [abc].
--- @param glob string The glob pattern
--- @return string The equivalent Lua pattern
local function glob_to_pattern(glob: string): string
  local pattern = glob
  :gsub("([%.%^%$%(%)%%])", "%%%1") -- escape special chars (except * ? [ ])
  :gsub("%*", ".*") -- * -> .*
  :gsub("%?", ".") -- ? -> .
  return "^" .. pattern .. "$"
end

--- Collect file paths matching a pattern.
--- Recursively walks directory tree and returns matching file paths.
--- @param dir string The directory to search
--- @param pattern string Glob pattern (*.lua) or Lua pattern (%.lua$)
--- @return {string} List of full paths to matching files
local function collect(dir: string, pattern: string): {string}
  -- Detect if it's a glob or Lua pattern
  -- Globs use * and ?, Lua patterns use % for escaping
  local is_glob = pattern:find("*", 1, true) or pattern:find("?", 1, true)
  local lua_pattern: string
  if is_glob then
    lua_pattern = glob_to_pattern(pattern)
  else
    lua_pattern = pattern
  end

  local results: {string} = {}
  walk(dir, function(full_path: string, entry: string, st: WalkStat, ctx: {string}): boolean
      if not unix.S_ISDIR(st:mode()) and entry:match(lua_pattern) then
        table.insert(ctx, full_path)
      end
      return true
    end, results)
  return results
end

--- Recursively collect all files with their Unix permissions.
--- Returns a map of relative paths to file information.
--- @param dir string The directory to walk
--- @return {string:FileInfo} Map of relative paths to file information
local function collect_all(dir: string): {string: FileInfo}
  local files: {string: FileInfo} = {}

  local function do_walk(base_dir: string, rel_base: string)
    local handle = unix.opendir(base_dir) as WalkDirHandle
    if not handle then return end

    while true do
      local entry = handle:read()
      if not entry then break end
      if entry ~= "." and entry ~= ".." then
        local full_path = cosmo_path.join(base_dir, entry)
        local rel_path = rel_base == "" and entry or cosmo_path.join(rel_base, entry)
        local st = unix.stat(full_path) as WalkStat

        if st then
          if unix.S_ISDIR(st:mode()) then
            do_walk(full_path, rel_path)
          elseif unix.S_ISREG(st:mode()) or unix.S_ISLNK(st:mode()) then
            local mode = st:mode() & 0x1ff
            files[rel_path] = {mode = mode}
          end
        end
      end
    end
    handle:close()
  end

  do_walk(dir, "")
  return files
end

--- Iterate over files matching a pattern.
--- Returns an iterator that yields file paths.
--- @param dir string The directory to search
--- @param pattern string Glob pattern (*.lua) - defaults to all files (*)
--- @return function Iterator yielding file paths
local function files(dir: string, pattern?: string): function(): string
  pattern = pattern or "*"

  -- Detect if it's a glob or Lua pattern
  local is_glob = pattern:find("*", 1, true) or pattern:find("?", 1, true)
  local lua_pattern: string
  if is_glob then
    lua_pattern = glob_to_pattern(pattern)
  else
    lua_pattern = pattern
  end

  -- Stack of (dir, handle) for depth-first traversal
  local stack: {{string, WalkDirHandle}} = {}
  local handle = unix.opendir(dir) as WalkDirHandle
  if handle then
    table.insert(stack, {dir, handle})
  end

  return function(): string
    while #stack > 0 do
      local current = stack[#stack]
      local current_dir = current[1]
      local current_handle = current[2]

      local entry = current_handle:read()
      if not entry then
        current_handle:close()
        table.remove(stack)
      elseif entry ~= "." and entry ~= ".." then
        local full_path = cosmo_path.join(current_dir, entry)
        local st = unix.stat(full_path) as WalkStat
        if st then
          if unix.S_ISDIR(st:mode()) then
            -- Push subdirectory onto stack
            local subhandle = unix.opendir(full_path) as WalkDirHandle
            if subhandle then
              table.insert(stack, {full_path, subhandle})
            end
          elseif entry:match(lua_pattern) then
            return full_path
          end
        end
      end
    end
    return nil
  end
end

local record FsWalkModule
  walk: function<T>(dir: string, visitor: Visitor, ctx?: T): T
  collect: function(dir: string, pattern: string): {string}
  collect_all: function(dir: string): {string: FileInfo}
  files: function(dir: string, pattern?: string): function(): string
end

local M: FsWalkModule = {
  walk = walk,
  collect = collect,
  collect_all = collect_all,
  files = files,
}

return M
