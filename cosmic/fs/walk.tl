--- Directory walking and file collection utilities.
--- Provides recursive directory traversal, pattern-based file collection,
--- and file iteration.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")
local types = require("cosmic.fs.types")
local errstr = require("cosmic.errno").wrap
local type WalkStat = types.WalkStat
local FileInfo = types.FileInfo
local type WalkDirHandle = types.DirHandle

--- Visitor verdict for walk(): returning nothing continues as before,
--- "skip" does not descend into the entry (dirs only; no-op for files),
--- "stop" ends the walk immediately.
local enum WalkAction
  "skip"
  "stop"
end

--- Options for walk().
local record WalkOptions
  --- Maximum directory depth to visit: entries directly in dir are at
  --- depth 1, entries one level down at depth 2, and so on. The walk
  --- never descends into directories at the maximum depth. nil (or 0)
  --- means unlimited.
  max_depth: integer
end

local walk_tree: function<T>(string,
function(string, string, WalkStat, T): (WalkAction ...), T, {string}, integer, integer): boolean

--- Shared per-directory loop. Consumes (and closes) an already-open
--- handle, records the first subtree error in errbox[1], and returns
--- true when a visitor asked to stop the walk. Entries visited here are
--- at depth; max_depth of 0 means unlimited.
local function walk_entries<T>(dir: string, h: WalkDirHandle,
    visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx: T,
    errbox: {string}, depth: integer, max_depth: integer): boolean
  while true do
    local entry = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local full_path = cosmo_path.join(dir, entry)
      -- Use AT_SYMLINK_NOFOLLOW so symlinked dirs are seen as S_ISLNK, not S_ISDIR.
      -- This prevents infinite recursion through symlink cycles.
      local st, serr = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
      local wst: WalkStat
      local werr: string
      if st then
        wst, werr = types.wrap(st)
      end
      if wst is WalkStat then
        local action = visitor(full_path, entry, wst, ctx)
        if action == "stop" then
          h:close()
          return true
        end
        -- cast: record union after guard
        if action ~= "skip" and unix.S_ISDIR((st as unix.Stat):mode())
        and (max_depth == 0 or depth < max_depth) then
          if walk_tree(full_path, visitor, ctx, errbox, depth + 1, max_depth) then
            h:close()
            return true
          end
        end
      elseif not errbox[1] then
        errbox[1] = werr or errstr(serr, "stat: " .. full_path)
      end
    end
  end
  h:close()
  return false
end

--- Recursive walk helper. An opendir failure below the root is recorded
--- in errbox[1] rather than swallowed or fatal.
walk_tree = function<T>(dir: string,
    visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx: T,
    errbox: {string}, depth: integer, max_depth: integer): boolean
  local handle, oerr = unix.opendir(dir)
  if not handle then
    if not errbox[1] then
      errbox[1] = errstr(oerr, "opendir: " .. dir)
    end
    return false
  end
  -- cast: userdata boundary
  return walk_entries(dir, handle as WalkDirHandle, visitor, ctx, errbox, depth, max_depth)
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
--- The visitor's return value controls the traversal:
---   nil    — continue (a visitor that returns nothing keeps today's behavior)
---   "skip" — do not descend into this entry (dirs only; no-op for files)
---   "stop" — end the walk now; walk returns ctx plus any first error
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
--- @param visitor function Called for each entry: function(path, name, st, ctx): nil|"skip"|"stop"
--- @param ctx T Optional context passed to every visitor call
--- @param opts WalkOptions? max_depth limits how deep the walk descends
--- @return T | nil The context object, or nil if the root could not be opened
--- @return string First error encountered, if any
local function walk<T>(dir: string, visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string
  ctx = ctx or {} as T -- cast: fresh table as generic T
  local max_depth = 0
  if opts and opts.max_depth then
    max_depth = opts.max_depth
  end
  local handle, oerr = unix.opendir(dir)
  if not handle then
    return nil, errstr(oerr, "opendir: " .. dir)
  end
  local errbox: {string} = {}
  -- cast: userdata boundary
  walk_entries(dir, handle as WalkDirHandle, visitor, ctx, errbox, 1, max_depth)
  return ctx, errbox[1]
end

--- Convert a glob pattern to a Lua pattern.
--- Supports * (any run) and ? (one char); every other character —
--- including [ ] brackets and Lua-pattern magic like % — is literal.
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

--- Shared body of collect/collect_matching: walk the tree gathering
--- files whose basename matches the given Lua pattern.
local function collect_by_pattern(dir: string, lua_pattern: string): {string} | nil, string
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

--- Options for find/find_iter: how a file's BASENAME is selected.
--- At most one of glob/pattern; neither selects every file.
local record FindOptions
  --- glob matched against each basename (`*` any run, `?` one char;
  --- everything else — including `%` and brackets — literal)
  glob: string
  --- Lua pattern matched against each basename, for callers who mean
  --- one (the explicit sibling; never guessed from the string)
  pattern: string
end

--- Resolve FindOptions to the Lua pattern the walkers share.
local function find_pattern(opts?: FindOptions): string
  if opts and opts.pattern then
    return opts.pattern
  end
  return glob_to_pattern((opts and opts.glob) or "*")
end

--- Recursively collect file paths under dir (api-review-8: find/
--- find_iter replace collect/collect_matching/files).
--- If the root directory cannot be opened, returns nil plus the error.
--- Failures below the root do not stop the collection; the first such
--- error is returned alongside the results.
--- @param dir string The directory to search
--- @param opts FindOptions? glob or pattern over basenames (default: all files)
--- @return {string} | nil List of matching paths, or nil if the root failed
--- @return string First error encountered, if any
local function find(dir: string, opts?: FindOptions): {string} | nil, string
  return collect_by_pattern(dir, find_pattern(opts))
end

--- List entries in one directory whose name matches a glob component.
--- Appends matching paths (any entry type) to out; returns an error
--- string on opendir failure, nil otherwise.
local function glob_level(dir: string, lua_pattern: string, out: {string}): string
  local handle, oerr = unix.opendir(dir)
  if not handle then
    return errstr(oerr, "opendir: " .. dir)
  end
  local h = handle as WalkDirHandle -- cast: userdata boundary
  while true do
    local entry = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." and string.match(entry, lua_pattern) then
      table.insert(out, cosmo_path.join(dir, entry))
    end
  end
  h:close()
end

--- Expand a glob pattern against a directory, WITHOUT recursing:
--- unlike collect(), only the levels named by the pattern are read.
--- The pattern may span path components ("src/*.lua", "*/init.tl");
--- each component is a glob (`*` any run, `?` one char, both never
--- crossing a "/"), other characters match literally, and there is no
--- `**`. Unlike a shell, `*` also matches names starting with a dot.
--- Matches of every entry type (files, dirs, symlinks) are returned,
--- sorted. If dir itself cannot be opened, returns nil plus the error;
--- an unreadable directory at a deeper level does not stop expansion,
--- and the first such error is returned alongside the results.
--- @param dir string The directory the pattern is relative to
--- @param pattern string Glob pattern, optionally with "/" components
--- @return {string} | nil Sorted matching paths, or nil if dir failed
--- @return string First error encountered, if any
local function glob(dir: string, pattern: string): {string} | nil, string
  if pattern:sub(1, 1) == "/" then
    return nil, "glob: pattern must be relative to dir: " .. pattern
  end
  local comps: {string} = {}
  for comp in pattern:gmatch("[^/]+") do
    table.insert(comps, comp)
  end
  if #comps == 0 then
    return nil, "glob: empty pattern"
  end
  local current: {string} = {dir}
  local first_err: string = nil
  for i, comp in ipairs(comps) do
    local lua_pattern = glob_to_pattern(comp)
    local next_level: {string} = {}
    for j, d in ipairs(current) do
      -- Below the first level only descend through directories; a file
      -- matching an intermediate component cannot contain entries.
      if i == 1 or cosmo_path.isdir(d) then
        local gerr = glob_level(d, lua_pattern, next_level)
        if gerr then
          -- The root directory failing is fatal; deeper failures are
          -- recorded (first one wins) and expansion continues.
          if i == 1 and j == 1 then
            return nil, gerr
          end
          if not first_err then
            first_err = gerr
          end
        end
      end
    end
    current = next_level
  end
  table.sort(current)
  return current, first_err
end

--- Recursively collect all files with their Unix permissions
--- (api-review-8: was collect_all — find's sibling whose result carries
--- FileInfo rather than bare paths).
--- Returns a map of relative paths to file information.
--- If the root directory cannot be opened, returns nil plus the error.
--- Failures below the root do not stop the collection; the first such
--- error is returned alongside the results.
--- @param dir string The directory to walk
--- @return {string:FileInfo} | nil Map of relative paths to file information
--- @return string First error encountered, if any
local function find_info(dir: string): {string: FileInfo} | nil, string
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
    local h = handle as WalkDirHandle -- cast: userdata boundary

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
            -- cast: record union after guard
            if unix.S_ISDIR((st as unix.Stat):mode()) then
              do_walk(full_path, rel_path)
              -- cast: record union after guard
            elseif unix.S_ISREG((st as unix.Stat):mode()) then
              -- cast: record union after guard
              local mode = (st as unix.Stat):mode() & 0x1ff
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

--- Iterator over file paths, as returned by find_iter(). The second return
--- is nil while paths remain; once the tree is exhausted every further
--- call returns `nil, first_error` (nil when the walk was clean) — the
--- same (result, first-subtree-error) pairing walk()/collect() return,
--- just delayed until the iterator itself is spent rather than bundled
--- with a single return value up front.
local type FileIter = function(): string | nil, string

--- Iterate over files matching a pattern.
--- Returns an iterator that yields file paths. The fourth return value
--- is a to-be-closed guard: a plain `for f in fs.find_iter(dir) do ... end`
--- loop adopts it as the loop's closing value (Lua 5.4), so directory
--- handles are closed even when the loop exits early via break/error.
--- If the root directory cannot be opened, returns nil plus the error.
--- Failures below the root (an unreadable subdirectory, a vanished
--- entry) do NOT stop iteration, matching walk()/collect() — the first
--- such error is captured and, once the iterator is exhausted, returned
--- as its second value from then on. A plain `for f in fs.find_iter(dir) do`
--- never sees it (the loop ends on the first nil without inspecting
--- further returns); call the iterator again after the loop to read it:
---
---     local iter = check.must(fs.find_iter(dir))
---     for f in iter do ... end
---     local _, suberr = iter() -- first subtree error, if any
---
--- in tests/examples iterate the checked value with
--- `for f in check.must(fs.find_iter(dir)) do` (must, like assert, forwards
--- all four returns, keeping the closing guard); in library code use
--- `assert(fs.find_iter(dir)) as fs.FileIter`, which also forwards them.
--- @param dir string The directory to search
--- @param opts FindOptions? glob or pattern over basenames (default: all files)
--- @return function | nil Iterator yielding file paths, or nil if the root could not be opened
--- @return string Error if the root directory could not be opened
--- @return nil Unused (generic-for control slot)
--- @return any Closing guard that releases open directory handles
local function find_iter(dir: string, opts?: FindOptions): FileIter | nil, string, any, any
  local lua_pattern = find_pattern(opts)

  -- Stack of (dir, handle) for depth-first traversal
  local stack: {{string, WalkDirHandle}} = {}
  local handle, oerr = unix.opendir(dir)
  if not handle then
    return nil, errstr(oerr, "opendir: " .. dir)
  end
  table.insert(stack, {dir, handle as WalkDirHandle}) -- cast: userdata boundary

  local function close_all()
    for i = #stack, 1, -1 do
      stack[i][2]:close()
      stack[i] = nil
    end
  end
  local guard = setmetatable({}, {__close = close_all, __gc = close_all})

  -- First error found below the root, same role as walk_entries' errbox.
  local errbox: {string} = {}

  -- Shared by both places a subdirectory gets opened below (the DT_DIR
  -- fast path and the stat() fallback for DT_UNKNOWN): push it onto the
  -- traversal stack, or record the first opendir failure below the
  -- root, matching walk_entries' error-channel contract.
  local function push_subdir(path: string)
    local subhandle, serr = unix.opendir(path)
    if subhandle then
      -- cast: userdata boundary
      table.insert(stack, {path, subhandle as WalkDirHandle})
    elseif not errbox[1] then
      errbox[1] = errstr(serr, "opendir: " .. path)
    end
  end

  local iter = function(): string, string
    -- anchor the guard as an upvalue: a caller that keeps only the
    -- iterator (dropping the fourth return) must not let the guard's
    -- __gc close these handles while the iterator is still running
    local _ = guard
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
          push_subdir(full_path)
        elseif kind ~= unix.DT_UNKNOWN then
          -- Definitely not a directory: find_iter() never needs stat data,
          -- only the path, so just check the pattern without stat(2).
          if string.match(entry, lua_pattern) then
            return full_path
          end
        else
          -- Filesystem doesn't expose d_type; fall back to a real stat,
          -- using AT_SYMLINK_NOFOLLOW so a symlinked dir reports
          -- S_ISLNK, not S_ISDIR, preserving the same cycle prevention.
          local st, serr = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
          if st then
            -- cast: record union after guard
            if unix.S_ISDIR((st as unix.Stat):mode()) then
              push_subdir(full_path)
            elseif string.match(entry, lua_pattern) then
              return full_path
            end
          elseif not errbox[1] then
            errbox[1] = errstr(serr, "stat: " .. full_path)
          end
        end
      end
    end
    return nil, errbox[1]
  end
  return iter, nil, nil, guard
end

local record FsWalkModule
  --- Iterator over file paths, as returned by find_iter().
  type FileIter = FileIter

  --- Visitor verdict: nil continues, "skip" prunes, "stop" ends the walk.
  type WalkAction = WalkAction

  --- Options for walk() (max_depth).
  type WalkOptions = WalkOptions

  --- Walk dir tree. visitor(path, name, st, ctx): path is the FULL path; name is the basename.
  --- Do NOT join path and name — path is already complete.
  --- The visitor may return "skip" (don't descend) or "stop" (end the walk).
  walk: function<T>(dir: string, visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string
  glob: function(dir: string, pattern: string): {string} | nil, string
  type FindOptions = FindOptions
  find: function(dir: string, opts?: FindOptions): {string} | nil, string
  find_iter: function(dir: string, opts?: FindOptions): FileIter | nil, string, any, any
  find_info: function(dir: string): {string: FileInfo} | nil, string
end

local M: FsWalkModule = {
  walk = walk,
  glob = glob,
  find = find,
  find_iter = find_iter,
  find_info = find_info,
}

return M
