--- Directory tree walking: `visit` hands an Entry record to its
--- visitor. File collection (find/find_iter/find_info/glob) lives in
--- cosmic.fs.find, built on this walker.
local unix = require("cosmo.unix")
local fs_path = require("cosmic.fs.path")
local types = require("cosmic.fs.types")
local errstr = require("cosmic.errno").format
local type WalkStat = types.WalkStat
local type Entry = types.Entry
local type WalkDirHandle = types.DirHandle

--- Visitor verdict: returning nothing continues as before, "skip"
--- does not descend into the entry (dirs only; no-op for files),
--- "stop" ends the walk immediately.
local enum WalkAction
  "skip"
  "stop"
end

--- Options for visit()/walk().
local record WalkOptions
  --- Maximum directory depth to visit: entries directly in dir are at
  --- depth 1, entries one level down at depth 2, and so on. The walk
  --- never descends into directories at the maximum depth. nil (or 0)
  --- means unlimited.
  max_depth: integer
end

--- What a completed walk produced: the subtree failures it survived.
--- The accumulator is the caller's own — they passed it in — so the
--- one thing a walk produces that they do NOT already hold is what
--- went wrong, and it belongs on the result rather than in a third
--- slot they have to know to ask for.
local record Walked
  --- Subtree failures, in the order a stat was actually attempted:
  --- an opendir failure or a DT_UNKNOWN stat fallback lands here
  --- immediately; a decisive-d_type entry's stat failure lands here
  --- only if and when a visitor calls e:stat(). nil when the walk was
  --- clean.
  errors: {string}
end

local record FsWalkModule
  --- One visited entry: path (full), name, stat, depth. In visit()'s
  --- public signature, so it is exported.
  type Entry = Entry

  --- Visitor verdict: nil continues, "skip" prunes, "stop" ends the walk.
  type WalkAction = WalkAction

  --- Options for visit()/walk() max_depth.
  type WalkOptions = WalkOptions

  --- What a completed walk produced.
  type Walked = Walked

  --- Walk dir tree with an Entry-record visitor; slot 2 is the root
  --- failure, `.errors` on the result the subtree-error list.
  visit: function<T>(dir: string, visitor: function(Entry, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): Walked | nil, string
end

local walk_tree: function<T>(string,
function(Entry, T): (WalkAction ...), T, {string}, integer, integer): boolean

--- Build the lazy, memoized Stat accessor for one entry. The stat runs
--- at most once, on the first call; AT_SYMLINK_NOFOLLOW keeps a
--- symlinked directory reporting S_ISLNK rather than S_ISDIR, the same
--- guard walk_entries relies on for cycle safety. A failure is pushed
--- onto errs — the walk's shared subtree-error list — so it surfaces
--- as Walked.errors whether the stat ran here or from a visitor's own
--- e:stat() call.
local function lazy_stat(full_path: string, errs: {string}):
  function(self: Entry): WalkStat | nil, string
  local wst: WalkStat | nil
  local werr: string
  local done = false
  return function(_self: Entry): WalkStat | nil, string
    if not done then
      done = true
      local st, serr = unix.stat(full_path, unix.AT_SYMLINK_NOFOLLOW)
      if st then
        wst, werr = types.wrap(st)
      end
      if not wst then
        werr = werr or errstr(serr, "stat: " .. full_path)
        errs[#errs + 1] = werr
      end
    end
    return wst, werr
  end
end

--- Shared per-directory loop. Consumes (and closes) an already-open
--- handle, appends subtree errors to errs, and returns true when a
--- visitor asked to stop the walk. Entries visited here are at depth;
--- max_depth of 0 means unlimited.
---
--- Classifies from the dirent d_type — DT_DIR descends without a
--- stat (a symlinked dir always reports DT_LNK, never DT_DIR, so cycle
--- safety holds by construction); a decisive non-DT_DIR kind also
--- skips the stat; only DT_UNKNOWN forces one immediately, since the
--- recursion decision needs it. Mirrors find.tl's identical fallback.
local function walk_entries<T>(dir: string, h: WalkDirHandle,
    visitor: function(Entry, T): (WalkAction ...), ctx: T,
    errs: {string}, depth: integer, max_depth: integer): boolean
  while true do
    local entry, kind = h:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local full_path = fs_path.join(dir, entry)
      local e: Entry = {path = full_path, name = entry, depth = depth,
        stat = lazy_stat(full_path, errs)}
      local is_dir: boolean
      local skip_entirely = false
      if kind == unix.DT_DIR then
        -- d_type never follows symlinks, so this is a real directory
        -- (a symlinked dir reports DT_LNK); no stat(2) needed.
        is_dir = true
      elseif kind ~= unix.DT_UNKNOWN then
        is_dir = false
      else
        -- Filesystem doesn't expose d_type: force the stat now, since
        -- the recursion decision needs it. A failure is recorded by
        -- lazy_stat itself and the entry is skipped, matching
        -- find.tl's identical DT_UNKNOWN fallback (find.tl:219-235)
        -- and this function's own prior behavior.
        local st = e:stat()
        if st then
          is_dir = st:is_dir()
        else
          skip_entirely = true
        end
      end
      if not skip_entirely then
        local action = visitor(e, ctx)
        if action == "stop" then
          h:close()
          return true
        end
        if action ~= "skip" and is_dir
        and (max_depth == 0 or depth < max_depth) then
          if walk_tree(full_path, visitor, ctx, errs, depth + 1, max_depth) then
            h:close()
            return true
          end
        end
      end
    end
  end
  h:close()
  return false
end

--- Recursive walk helper. An opendir failure below the root is
--- appended to errs rather than swallowed or fatal.
walk_tree = function<T>(dir: string,
    visitor: function(Entry, T): (WalkAction ...), ctx: T,
    errs: {string}, depth: integer, max_depth: integer): boolean
  local handle, oerr = unix.opendir(dir)
  if not handle then
    errs[#errs + 1] = errstr(oerr, "opendir: " .. dir)
    return false
  end
  -- cast: userdata boundary
  return walk_entries(dir, handle as WalkDirHandle, visitor, ctx, errs, depth, max_depth)
end

--- Walk a directory tree, calling visitor with an Entry per entry.
--- Recursively traverses all subdirectories; does NOT recurse into
--- symlinked directories, preventing symlink cycles.
---
--- The visitor receives (fs.Entry, ctx): Entry carries `path` (the
--- FULL path — never join it with name), `name` (the basename),
--- `depth` (entries directly in dir are depth 1), and `stat()` — a
--- lazy, memoized `fs.Stat | nil, string` accessor, computed only on
--- the first call a visitor actually makes. Its return controls
--- traversal: nil continues, "skip" does not descend into the entry
--- (dirs only), "stop" ends the walk now.
---
---   fs.visit(dir, function(e: fs.Entry, acc: {string})
---     local st = e:stat()
---     if st and st:is_file() then table.insert(acc, e.path) end
---   end, {})
---
--- Slot 2 means failure, period: if the root cannot be opened, visit
--- returns nil plus the error. Failures below the root (an unreadable
--- subdirectory, a vanished entry) do not stop the walk; they ride on
--- the result as `walked.errors` — nil when the walk was clean — so a
--- partial walk is never mistaken for a complete one, and a two-slot
--- return still says everything. Because a stat is now only ever taken
--- when something asks for it, a walk can finish with `errors == nil`
--- even though some entry no visitor called `stat()` on would have
--- failed to stat — the walk no longer stats what nobody asked for.
--- @param dir string The directory to walk
--- @param visitor function Called per entry: function(e: Entry, ctx): nil|"skip"|"stop"
--- @param ctx T Optional context passed to every visitor call
--- @param opts WalkOptions? max_depth limits how deep the walk descends
--- @return Walked | nil The walk's `.errors`, or nil if the root could not be opened
--- @return string The root-open error when slot 1 is nil
local function visit<T>(dir: string, visitor: function(Entry, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): Walked | nil, string
  ctx = ctx or {} as T -- cast: fresh table as generic T
  local max_depth = 0
  if opts and opts.max_depth then
    max_depth = opts.max_depth
  end
  local handle, oerr = unix.opendir(dir)
  if not handle then
    return nil, errstr(oerr, "opendir: " .. dir)
  end
  local errs: {string} = {}
  -- cast: userdata boundary
  walk_entries(dir, handle as WalkDirHandle, visitor, ctx, errs, 1, max_depth)
  if #errs == 0 then
    return {}
  end
  return {errors = errs}
end

local M: FsWalkModule = {
  visit = visit,
}

return M
