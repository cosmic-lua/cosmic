--- Directory tree walking: `visit` hands an Entry record to its
--- visitor; `walk` is the DEPRECATED positional form (#987), kept
--- because the pinned build engine still calls it — deleted at the
--- next pin advance alongside errno's aliases (#981). File collection
--- (find/find_iter/find_info/glob) lives in cosmic.fs.find, built on
--- this walker.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")
local types = require("cosmic.fs.types")
local errstr = require("cosmic.errno").wrap
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

local walk_tree: function<T>(string,
function(Entry, T): (WalkAction ...), T, {string}, integer, integer): boolean

--- Shared per-directory loop. Consumes (and closes) an already-open
--- handle, appends subtree errors to errs, and returns true when a
--- visitor asked to stop the walk. Entries visited here are at depth;
--- max_depth of 0 means unlimited.
local function walk_entries<T>(dir: string, h: WalkDirHandle,
    visitor: function(Entry, T): (WalkAction ...), ctx: T,
    errs: {string}, depth: integer, max_depth: integer): boolean
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
        local e: Entry = {path = full_path, name = entry, stat = wst, depth = depth}
        local action = visitor(e, ctx)
        if action == "stop" then
          h:close()
          return true
        end
        -- cast: record union after guard
        if action ~= "skip" and unix.S_ISDIR((st as unix.Stat):mode())
        and (max_depth == 0 or depth < max_depth) then
          if walk_tree(full_path, visitor, ctx, errs, depth + 1, max_depth) then
            h:close()
            return true
          end
        end
      else
        errs[#errs + 1] = werr or errstr(serr, "stat: " .. full_path)
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
--- `stat` (fs.Stat) and `depth` (entries directly in dir are depth 1).
--- Its return controls traversal: nil continues, "skip" does not
--- descend into the entry (dirs only), "stop" ends the walk now.
---
---   fs.visit(dir, function(e: fs.Entry, acc: {string})
---     if e.stat:is_file() then table.insert(acc, e.path) end
---   end, {})
---
--- Slot 2 means failure, period: if the root cannot be opened, visit
--- returns nil plus the error. Failures below the root (an unreadable
--- subdirectory, a vanished entry) do not stop the walk; they are
--- returned as a list in slot 3 — nil when the walk was clean — so a
--- partial walk is never mistaken for a complete one.
--- @param dir string The directory to walk
--- @param visitor function Called per entry: function(e: Entry, ctx): nil|"skip"|"stop"
--- @param ctx T Optional context passed to every visitor call
--- @param opts WalkOptions? max_depth limits how deep the walk descends
--- @return T | nil The context object, or nil if the root could not be opened
--- @return string The root-open error when slot 1 is nil
--- @return {string} Subtree errors, in encounter order (nil when none)
local function visit<T>(dir: string, visitor: function(Entry, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string, {string}
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
    return ctx
  end
  return ctx, nil, errs
end

--- DEPRECATED positional walker (#987): visitor(path, name, st, ctx)
--- with the first subtree error folded into slot 2 beside a non-nil
--- result. Use visit() — the Entry record deletes the "do NOT join
--- path and name" trap and exposes depth, and its slot 2 means
--- failure. Kept because the pinned build engine still calls this
--- form; deleted at the next pin advance (#981-class).
--- @param dir string The directory to walk
--- @param visitor function Called per entry: function(path, name, st, ctx): nil|"skip"|"stop"
--- @param ctx T Optional context passed to every visitor call
--- @param opts WalkOptions? max_depth limits how deep the walk descends
--- @return T | nil The context object, or nil if the root could not be opened
--- @return string First error encountered, if any
local function walk<T>(dir: string, visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string
  local rctx, fatal, errs = visit(dir, function(e: Entry, c: T): (WalkAction ...)
      return visitor(e.path, e.name, e.stat, c)
    end, ctx, opts)
  if rctx == nil then
    return nil, fatal
  end
  return rctx, errs and errs[1] or nil
end

local record FsWalkModule
  --- Visitor verdict: nil continues, "skip" prunes, "stop" ends the walk.
  type WalkAction = WalkAction

  --- Options for visit()/walk() max_depth.
  type WalkOptions = WalkOptions

  --- Walk dir tree with an Entry-record visitor; slot 2 is the root
  --- failure, slot 3 the subtree-error list.
  visit: function<T>(dir: string, visitor: function(Entry, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string, {string}

  --- DEPRECATED positional walker; use visit(). Deleted at pin advance.
  walk: function<T>(dir: string, visitor: function(string, string, WalkStat, T): (WalkAction ...), ctx?: T, opts?: WalkOptions): T | nil, string
end

local M: FsWalkModule = {
  visit = visit,
  walk = walk,
}

return M
