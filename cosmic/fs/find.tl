--- File collection: one find family over cosmic.fs.walk's visitor.
--- find/find_iter/find_info share FindOptions and one error contract —
--- slot 2 means the root failed, period, and the walk is over — so
--- `if err then return nil, err end` is correct at every call site.
--- Subtree failures are not fatal and are not a second error channel:
--- they ride on the RESULT, in its `errors` field, which is where a
--- two-slot return has to put them. glob stays the
--- component-path expander (a different capability: its pattern spans
--- "/" components and it never recurses) with the same contract.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")
local types = require("cosmic.fs.types")
local fs_walk = require("cosmic.fs.walk")
local fs_path = require("cosmic.fs.path")
local errstr = require("cosmic.errno").format
local FileInfo = types.FileInfo
local type Entry = types.Entry
local type WalkDirHandle = types.DirHandle

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

--- Options for the find family: how entries are selected and how far
--- the search descends.
local record FindOptions
  --- glob matched against each basename (`*` any run, `?` one char;
  --- everything else — including `%` and brackets — literal)
  glob: string
  --- Lua pattern matched against each basename, for callers who mean
  --- one (the explicit sibling; never guessed from the string)
  pattern: string
  --- Maximum depth to visit (entries directly in dir are depth 1);
  --- nil or 0 means unlimited.
  max_depth: integer
  --- false searches only the top level (same as max_depth = 1);
  --- default true.
  recursive: boolean
  --- Also return directories whose basename matches (default: files
  --- and every other non-directory entry type only).
  include_dirs: boolean
  --- Sort the returned list (find only; find_iter yields discovery
  --- order — an iterator cannot sort without materializing).
  sorted: boolean
end

--- The paths a find/glob produced, plus the failures it walked past.
---
--- The ARRAY PART is the path list: `#found`, `found[1]`, `ipairs`,
--- `table.sort` and passing it where a `{string}` is wanted all work
--- unchanged, which is the whole reason the extras are a field on the
--- list rather than a wrapper around it.
local record Found
  {string}
  --- Subtree failures, in encounter order; nil when the walk was clean.
  errors: {string}
end

--- What find_info produced: the file map, plus the same error field.
--- A map cannot be a record's array part, so this one names its value.
local record FoundInfo
  --- Matching files by FULL path.
  files: {string: FileInfo}
  --- Subtree failures, in encounter order; nil when the walk was clean.
  errors: {string}
end

--- Resolve FindOptions to the Lua pattern the walkers share.
local function find_pattern(opts?: FindOptions): string
  if opts and opts.pattern then
    return opts.pattern
  end
  return glob_to_pattern((opts and opts.glob) or "*")
end

--- Resolve FindOptions to walk's max_depth (recursive=false wins).
local function find_depth(opts?: FindOptions): integer
  if opts and opts.recursive == false then
    return 1
  end
  return (opts and opts.max_depth) or 0
end

--- Recursively collect paths under dir whose basename matches.
--- Slot 2 means the root failed; subtree failures ride on the result
--- as `found.errors`, never beside a non-nil result.
--- @param dir string The directory to search
--- @param opts FindOptions? Selection and depth options (default: all files)
--- @return Found | nil Matching paths (plus .errors), or nil if the root failed
--- @return string The root-open error when slot 1 is nil
local function find(dir: string, opts?: FindOptions): Found | nil, string
  local lua_pattern = find_pattern(opts)
  local include_dirs = opts and opts.include_dirs
  local results: Found = {}
  local walked, fatal = fs_walk.visit(dir, function(e: Entry, acc: Found)
      if (include_dirs or not e.stat:is_dir()) and e.name:match(lua_pattern) then
        table.insert(acc, e.path)
      end
    end, results, {max_depth = find_depth(opts)})
  if not walked then
    return nil, fatal
  end
  if opts and opts.sorted then
    table.sort(results)
  end
  results.errors = walked.errors
  return results
end

--- Recursively collect matching files with their FileInfo, keyed by
--- FULL path like every sibling. Directories are never included
--- (FileInfo describes regular files); selection and depth follow
--- FindOptions.
--- @param dir string The directory to search
--- @param opts FindOptions? Selection and depth options (default: all files)
--- @return FoundInfo | nil .files by full path (plus .errors), or nil if the root failed
--- @return string The root-open error when slot 1 is nil
local function find_info(dir: string, opts?: FindOptions): FoundInfo | nil, string
  local lua_pattern = find_pattern(opts)
  local files: {string: FileInfo} = {}
  local walked, fatal = fs_walk.visit(dir, function(e: Entry, acc: {string: FileInfo})
      if e.stat:is_file() and e.name:match(lua_pattern) then
        acc[e.path] = {mode = e.stat:mode() & 0x1ff}
      end
    end, files, {max_depth = find_depth(opts)})
  if not walked then
    return nil, fatal
  end
  return {files = files, errors = walked.errors}
end

--- Iterator over file paths, as returned by find_iter(). Callable:
--- `for f in iter do ... end`. The second return is nil while paths
--- remain; once the tree is exhausted every further call returns
--- `nil, errs` — the subtree-error list, nil when the walk was clean.
---
--- It owns the open directory handles, so it is also CLOSEABLE, the
--- same shape `cosmic.sqlite`'s Rows has: draining it releases them,
--- and so do `iter:close()`, leaving a `local iter <close> = ...`
--- scope, and (as the backstop) collection. That is why the guard is
--- not a fourth return value — a to-be-closed slot past the error
--- would break the two-slot error contract every fallible call relies on.
local record FileIter
  metamethod __call: function(self: FileIter): string | nil, {string}
  metamethod __close: function(self: FileIter)
  --- Release every open directory handle without draining the walk.
  --- Idempotent; the iterator yields nothing afterwards.
  close: function(self: FileIter)
end

--- Iterate over matching paths lazily; same selection as find(),
--- except `sorted` (an iterator yields discovery order).
--- If the root directory cannot be opened, returns nil plus the error.
--- Failures below the root do NOT stop iteration; they accumulate and,
--- once the iterator is exhausted, come back as its second value
--- (a list) from then on. A plain `for` loop never sees them — call
--- the iterator once more after the loop:
---
---     local iter = check.must(fs.find_iter(dir))
---     for f in iter do ... end
---     local _, errs = iter() -- subtree errors, nil when clean
---
--- Draining the iterator closes every directory handle it opened. A
--- loop that exits EARLY (`break`, or a `return` from inside it) has
--- not drained it: the handles stay open until collection, which pins
--- directory fds — and on Windows can block deleting the tree just
--- walked. An early-break loop compiles without any signal that it is
--- leaking handles (`cosmic --docs guide.gotchas` has the entry). So
--- say so — the attribute Lua 5.4 has for exactly this:
---
---     local iter <close> = check.must(fs.find_iter(dir))
---     for f in iter do if done(f) then break end end
---
--- (`iter:close()` is the explicit form.) Collection is the backstop,
--- not the contract.
---
--- When stopping early is the POINT rather than an exception, reach
--- for `fs.visit` instead: its visitor returns "stop", and because
--- visit owns the loop it closes on the way out without the caller
--- remembering anything. find_iter is for the case a callback cannot
--- serve — the consumer driving the walk, interleaving it with other
--- work.
--- @param dir string The directory to search
--- @param opts FindOptions? Selection and depth options (default: all files)
--- @return FileIter | nil Iterator yielding paths, or nil if the root failed
--- @return string The root-open error when slot 1 is nil
local function find_iter(dir: string, opts?: FindOptions): FileIter | nil, string
  local lua_pattern = find_pattern(opts)
  local include_dirs = opts and opts.include_dirs
  local max_depth = find_depth(opts)

  -- Stack of (dir, handle, depth) for depth-first traversal; entries
  -- read from a stack top at depth d are themselves at depth d.
  local stack: {{string, WalkDirHandle, integer}} = {}
  local handle, oerr = unix.opendir(dir)
  if not handle then
    return nil, errstr(oerr, "opendir: " .. dir)
  end
  table.insert(stack, {dir, handle as WalkDirHandle, 1}) -- cast: userdata boundary

  local function close_all()
    for i = #stack, 1, -1 do
      stack[i][2]:close()
      stack[i] = nil
    end
  end

  -- Subtree errors, in encounter order; the exhausted iterator's
  -- second return (nil while any path remains).
  local errs: {string} = {}

  -- Shared by both places a subdirectory gets opened below (the DT_DIR
  -- fast path and the stat() fallback for DT_UNKNOWN): push it onto
  -- the traversal stack — unless the depth limit says stop — or record
  -- the opendir failure.
  local function push_subdir(path: string, child_depth: integer)
    if max_depth ~= 0 and child_depth > max_depth then
      return
    end
    local subhandle, serr = unix.opendir(path)
    if subhandle then
      -- cast: userdata boundary
      table.insert(stack, {path, subhandle as WalkDirHandle, child_depth})
    else
      errs[#errs + 1] = errstr(serr, "opendir: " .. path)
    end
  end

  local step = function(): string, {string}
    while #stack > 0 do
      local current = stack[#stack]
      local current_dir = current[1]
      local current_handle = current[2]
      local current_depth = current[3]

      local entry, kind = current_handle:read()
      if not entry then
        current_handle:close()
        table.remove(stack)
      elseif entry ~= "." and entry ~= ".." then
        local full_path = fs_path.join(current_dir, entry)
        if kind == unix.DT_DIR then
          -- d_type never follows symlinks, so this is a real directory
          -- (a symlinked dir reports DT_LNK), and skips a stat(2) call.
          push_subdir(full_path, current_depth + 1)
          if include_dirs and string.match(entry, lua_pattern) then
            return full_path
          end
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
            if unix.S_ISDIR(st:mode()) then
              push_subdir(full_path, current_depth + 1)
              if include_dirs and string.match(entry, lua_pattern) then
                return full_path
              end
            elseif string.match(entry, lua_pattern) then
              return full_path
            end
          else
            errs[#errs + 1] = errstr(serr, "stat: " .. full_path)
          end
        end
      end
    end
    if #errs == 0 then
      return nil
    end
    return nil, errs
  end

  -- The iterator IS the resource handle: closing it — by draining, by
  -- `iter:close()`, by leaving a `<close>` scope, or by collection —
  -- runs the same close_all. __gc stays the backstop it always was.
  local iter = setmetatable({}, {
      __call = step,
      __close = close_all,
      __gc = close_all,
      __index = {close = close_all},
    })
  return iter
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
      table.insert(out, fs_path.join(dir, entry))
    end
  end
  h:close()
end

--- Expand a glob pattern against a directory, WITHOUT recursing — the
--- component-path expander, a different capability from find's
--- recursive basename selection: the pattern may span path components
--- ("src/*.lua", "*/init.tl"); each component is a glob (`*` any run,
--- `?` one char, both never crossing a "/"), other characters match
--- literally, and there is no `**`. Unlike a shell, `*` also matches
--- names starting with a dot. Matches of every entry type are
--- returned, sorted. Slot 2 means dir itself failed to open; an
--- unreadable directory at a deeper level does not stop expansion, and
--- those errors ride on the result as `found.errors` (nil when clean).
--- @param dir string The directory the pattern is relative to
--- @param pattern string Glob pattern, optionally with "/" components
--- @return Found | nil Sorted matching paths (plus .errors), or nil if dir failed
--- @return string The root-open error when slot 1 is nil
local function glob(dir: string, pattern: string): Found | nil, string
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
  local current: Found = {dir}
  local errs: {string} = {}
  for i, comp in ipairs(comps) do
    local lua_pattern = glob_to_pattern(comp)
    local next_level: Found = {}
    for j, d in ipairs(current) do
      -- Below the first level only descend through directories; a file
      -- matching an intermediate component cannot contain entries.
      if i == 1 or cosmo_path.isdir(d) then
        local gerr = glob_level(d, lua_pattern, next_level)
        if gerr then
          -- The root directory failing is fatal; deeper failures are
          -- recorded and expansion continues.
          if i == 1 and j == 1 then
            return nil, gerr
          end
          errs[#errs + 1] = gerr
        end
      end
    end
    current = next_level
  end
  table.sort(current)
  if #errs > 0 then
    current.errors = errs
  end
  return current
end

local record FsFindModule
  --- Iterator over paths, as returned by find_iter().
  type FileIter = FileIter
  type FindOptions = FindOptions
  --- A path list with the subtree failures it walked past.
  type Found = Found
  --- find_info's file map with the same error field.
  type FoundInfo = FoundInfo

  find: function(dir: string, opts?: FindOptions): Found | nil, string
  find_iter: function(dir: string, opts?: FindOptions): FileIter | nil, string
  find_info: function(dir: string, opts?: FindOptions): FoundInfo | nil, string
  glob: function(dir: string, pattern: string): Found | nil, string
end

local M: FsFindModule = {
  find = find,
  find_iter = find_iter,
  find_info = find_info,
  glob = glob,
}

return M
