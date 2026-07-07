--- Directory walking and file collection utilities.
--- Provides recursive directory traversal, pattern-based file collection,
--- and file iteration.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")
local types = require("cosmic.fs.types")
local errstr = require("cosmic.errno").str
local type WalkStat = types.WalkStat
local FileInfo = types.FileInfo

--- Handle for reading directory entries (internal).
--- `read`'s second return is the dirent d_type (unix.DT_DIR / DT_REG /
--- DT_LNK / ... / DT_UNKNOWN) where the filesystem supports it, letting
--- callers that only need "is this a directory" skip a stat(2) call.
local record WalkDirHandle
  read: function(self): string, number
  close: function(self)
end

--- Recursive walk helper. Records the first subtree error (opendir or
--- stat failure below the root) in errbox[1] rather than swallowing it.
local function walk_tree < T > (dir: string,
    visitor: function(string, string, WalkStat, T), ctx: T,
    errbox: {string})
  local handle, oerr = unix.opendir(dir)
  if not handle then
    if not errbox[1] then
      errbox[1] = errstr(oerr, "opendir: " .. dir)
    end
    return
  end
  local h = handle as WalkDirHandle

  while true do
    local entry = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local full_path = cosmo_path.join(dir, entry)
      -- Use AT_SYMLINK_NOFOLLOW so symlinked dirs are seen as S_ISLNK, not S_ISDIR.
      -- This prevents infinite recursion through symlink cycles.
      local st, serr = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
      if st then
        visitor(full_path, entry, types.wrap(st), ctx)
        if unix.S_ISDIR(st:mode()) then
          walk_tree(full_path, visitor, ctx, errbox)
        end
      elseif not errbox[1] then
        errbox[1] = errstr(serr, "stat: " .. full_path)
      end
    end
  end
  h:close()
end

--- Walk a directory tree, calling visitor for each entry.
--- Recursively traverses all subdirectories.
--- Does NOT recurse into symlinked directories to prevent symlink cycles.
---
--- The visitor receives four arguments:
---   path  (string)  — the full path to the entry (e.g. "dir/sub/file.txt").
---   name  (string)  — the basename of the entry (e.g. "file.txt").
---   st    (WalkStat) — stat result for the entry.
---   ctx   (T)       — the context value passed to walk().
---
--- IMPORTANT: do NOT join path and name — path is already the full path.
--- Joining them produces doubled paths like "dir/sub/file.txt/file.txt".
---
--- WalkStat is defined in cosmic.fs.types. Import it as:
---   local types = require("cosmic.fs.types")
---   local type WalkStat = types.WalkStat
---
--- If the root directory cannot be opened, returns nil plus the error.
--- Failures below the root (unreadable subdirectory, vanished entry) do
--- not stop the walk; the first such error is returned alongside the
--- context so callers never mistake a partial walk for a complete one.
--- @param dir string The directory to walk
--- @param visitor function Called for each entry: function(path, name, st, ctx)
--- @param ctx T Optional context passed to every visitor call
--- @return T | nil The context object, or nil if the root could not be opened
--- @return string First error encountered, if any
local function walk < T > (dir: string, visitor: function(string, string, WalkStat, T), ctx?: T): T | nil, string
  ctx = ctx or {} as T
  local handle, oerr = unix.opendir(dir)
  if not handle then
    return nil, errstr(oerr, "opendir: " .. dir)
  end
  local h = handle as WalkDirHandle
  local errbox: {string} = {}

  while true do
    local entry = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local full_path = cosmo_path.join(dir, entry)
      local st, serr = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
      if st then
        visitor(full_path, entry, types.wrap(st), ctx)
        if unix.S_ISDIR(st:mode()) then
          walk_tree(full_path, visitor, ctx, errbox)
        end
      elseif not errbox[1] then
        errbox[1] = errstr(serr, "stat: " .. full_path)
      end
    end
  end
  h:close()
  return ctx, errbox[1]
end

--- Convert a glob pattern to a Lua pattern.
--- Supports * (any chars), ? (single char), and character classes [abc].
--- @param glob string The glob pattern
--- @return string The equivalent Lua pattern
local function glob_to_pattern(glob: string): string
  -- Escape every Lua pattern magic character, including [ ] and + - which are
  -- meaningful inside Lua character classes. Otherwise a glob like "*[a-z]*"
  -- would smuggle a Lua character class through and match the wrong files.
  local pattern = glob
  :gsub("([%.%^%$%(%)%[%]%+%-%%])", "%%%1") -- escape special chars (except * ?)
  :gsub("%*", ".*") -- * -> .*
  :gsub("%?", ".") -- ? -> .
  return "^" .. pattern .. "$"
end

--- Collect file paths matching a pattern.
--- Recursively walks directory tree and returns matching file paths.
--- If the root directory cannot be opened, returns nil plus the error.
--- Failures below the root do not stop the collection; the first such
--- error is returned alongside the results.
--- @param dir string The directory to search
--- @param pattern string Glob pattern (*.lua) or Lua pattern (%.lua$)
--- @return {string} | nil List of matching paths, or nil if the root failed
--- @return string First error encountered, if any
local function collect(dir: string, pattern: string): {string} | nil, string
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
  local ctx, err = walk(dir, function(full_path: string, entry: string, st: WalkStat, acc: {string})
      if not st:is_dir() and entry:match(lua_pattern) then
        table.insert(acc, full_path)
      end
    end, results)
  if not ctx then
    return nil, err
  end
  return results, err
end

--- Recursively collect all files with their Unix permissions.
--- Returns a map of relative paths to file information.
--- If the root directory cannot be opened, returns nil plus the error.
--- Failures below the root do not stop the collection; the first such
--- error is returned alongside the results.
--- @param dir string The directory to walk
--- @return {string:FileInfo} | nil Map of relative paths to file information
--- @return string First error encountered, if any
local function collect_all(dir: string): {string: FileInfo} | nil, string
  local files: {string: FileInfo} = {}
  local errbox: {string} = {}

  local function do_walk(base_dir: string, rel_base: string): boolean
    local handle, oerr = unix.opendir(base_dir)
    if not handle then
      if not errbox[1] then
        errbox[1] = errstr(oerr, "opendir: " .. base_dir)
      end
      return false
    end
    local h = handle as WalkDirHandle

    while true do
      local entry, kind = h:read()
      if not entry then break end
      if entry ~= "." and entry ~= ".." then
        local full_path = cosmo_path.join(base_dir, entry)
        local rel_path = rel_base == "" and entry or cosmo_path.join(rel_base, entry)

        if kind == unix.DT_DIR then
          -- d_type never follows symlinks, so a real directory (as opposed
          -- to a symlink to one) is enough to recurse without a stat(2)
          -- call. This is what prevents infinite recursion through
          -- symlink cycles below too: a symlinked dir reports DT_LNK.
          do_walk(full_path, rel_path)
        elseif kind ~= unix.DT_REG and kind ~= unix.DT_UNKNOWN then
          -- Definitely neither a directory nor a regular file (symlink,
          -- fifo, socket, ...): matches neither branch below, so skip
          -- without paying for a stat(2) call.
        else
          -- kind is DT_REG (need the mode bits) or DT_UNKNOWN (filesystem
          -- doesn't expose d_type; fall back to a real stat). Use
          -- AT_SYMLINK_NOFOLLOW so a symlinked dir reports S_ISLNK, not
          -- S_ISDIR, preserving the same cycle prevention as above.
          local st, serr = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
          if st then
            if unix.S_ISDIR(st:mode()) then
              do_walk(full_path, rel_path)
            elseif unix.S_ISREG(st:mode()) then
              local mode = st:mode() & 0x1ff
              files[rel_path] = {mode = mode}
            end
          elseif not errbox[1] then
            errbox[1] = errstr(serr, "stat: " .. full_path)
          end
        end
      end
    end
    h:close()
    return true
  end

  if not do_walk(dir, "") then
    return nil, errbox[1]
  end
  return files, errbox[1]
end

--- Iterator over file paths, as returned by files().
local type FileIter = function(): string

  --- Iterate over files matching a pattern.
  --- Returns an iterator that yields file paths. The fourth return value
  --- is a to-be-closed guard: a plain `for f in fs.files(dir) do ... end`
  --- loop adopts it as the loop's closing value (Lua 5.4), so directory
  --- handles are closed even when the loop exits early via break/error.
  --- If the root directory cannot be opened, the iterator yields nothing
  --- and the error is returned as the second value.
  --- @param dir string The directory to search
  --- @param pattern string Glob pattern (*.lua) - defaults to all files (*)
  --- @return function Iterator yielding file paths
  --- @return string Error if the root directory could not be opened
  --- @return nil Unused (generic-for control slot)
  --- @return any Closing guard that releases open directory handles
  local function files(dir: string, pattern?: string): FileIter, string, any, any
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
    local handle, oerr = unix.opendir(dir)
    if not handle then
      return function(): string return nil end,
      errstr(oerr, "opendir: " .. dir), nil, nil
    end
    table.insert(stack, {dir, handle as WalkDirHandle})

    local function close_all()
      for i = #stack, 1, -1 do
        stack[i][2]:close()
        stack[i] = nil
      end
    end
    local guard = setmetatable({}, {__close = close_all, __gc = close_all})

    local iter = function(): string
      while #stack > 0 do
        local current = stack[#stack]
        local current_dir = current[1]
        local current_handle = current[2]

        local entry, kind = current_handle:read()
        if not entry then
          current_handle:close()
          table.remove(stack)
        elseif entry ~= "." and entry ~= ".." then
          local full_path = cosmo_path.join(current_dir, entry)
          if kind == unix.DT_DIR then
            -- d_type never follows symlinks, so this is a real directory
            -- (a symlinked dir reports DT_LNK), and skips a stat(2) call.
            local subhandle = unix.opendir(full_path)
            if subhandle then
              table.insert(stack, {full_path, subhandle as WalkDirHandle})
            end
          elseif kind ~= unix.DT_UNKNOWN then
            -- Definitely not a directory: files() never needs stat data,
            -- only the path, so just check the pattern without stat(2).
            if entry:match(lua_pattern) then
              return full_path
            end
          else
            -- Filesystem doesn't expose d_type; fall back to a real stat,
            -- using AT_SYMLINK_NOFOLLOW so a symlinked dir reports
            -- S_ISLNK, not S_ISDIR, preserving the same cycle prevention.
            local st = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
            if st then
              if unix.S_ISDIR(st:mode()) then
                local subhandle = unix.opendir(full_path)
                if subhandle then
                  table.insert(stack, {full_path, subhandle as WalkDirHandle})
                end
              elseif entry:match(lua_pattern) then
                return full_path
              end
            end
          end
        end
      end
      return nil
    end
    return iter, nil, nil, guard
  end

  local record FsWalkModule
    --- Iterator over file paths, as returned by files().
    type FileIter = FileIter

    --- Walk dir tree. visitor(path, name, st, ctx): path is the FULL path; name is the basename.
    --- Do NOT join path and name — path is already complete.
    walk: function < T > (dir: string, visitor: function(string, string, WalkStat, T), ctx?: T): T | nil, string
    collect: function(dir: string, pattern: string): {string} | nil, string
    collect_all: function(dir: string): {string: FileInfo} | nil, string
    files: function(dir: string, pattern?: string): FileIter, string, any, any
  end

  local M: FsWalkModule = {
    walk = walk,
    collect = collect,
    collect_all = collect_all,
    files = files,
  }

  return M
