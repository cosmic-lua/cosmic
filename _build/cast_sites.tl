#!/usr/bin/env cosmic
--- Reads and regenerates the committed cast site inventory.
---
--- `docs/design/cast-sites.tsv` is half generated, half curated: its
--- path and line columns are a fact about the tree — the same `as`
--- tokens `_build/casts.tl` counts, through the same lexer
--- (`_cli.lint.cast_lines`) — but its class column is a human reading
--- of what each cast is for, which no scan can produce. `--reconcile`
--- re-derives the first two columns from the tree and carries the
--- third column forward from the committed file for every site that
--- still exists; a cast whose line TEXT is unchanged keeps its class
--- across a move, matched against the committed text at `git show
--- HEAD:<path>` rather than against the old line number, so a shift
--- carries forward but an edited cast line asks for its class again. A
--- site with no prior row has no class to carry, so it is refused
--- rather than written in blank, and stays committed unclassified
--- until a person edits the row in by hand. A full
--- rewrite the way `_build/casts.tl --baseline` rewrites its floor
--- would destroy exactly the column nothing else holds.
---
---     bin/cosmic --make run _build/cast_sites.tl --reconcile
---
--- `_build/cast_sites_test.tl` gates the committed file against this
--- module's read of it and against `_build/casts_baseline.tl`.

local casts = require("_build.casts")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local lint = require("_cli.lint")
local proc = require("cosmic.proc")
local str = require("cosmic.string")

--- The committed inventory: where this module reads and writes it,
--- relative to the project root.
local TSV_PATH < const > = "docs/design/cast-sites.tsv"

--- One `as` token found by a walk of the tree: a fact, no judgment.
local record Site
  path: string
  line: integer
end

--- One committed inventory row: a `Site` plus its human classification.
local record Row
  path: string
  line: integer
  class: string
end

--- Parse the committed inventory.
--- @param path string? The tsv file (default `TSV_PATH`)
--- @return {Row}|nil The rows, in file order
--- @return string The error when the file is unreadable or malformed
local function read_tsv(path?: string): {Row} | nil, string
  local p = path or TSV_PATH
  local text, err = fs.read(p)
  if not text then
    return nil, err
  end
  local rows: {Row} = {}
  local file_lines = str.lines(text)
  for i = 2, #file_lines do
    local fields = str.split(file_lines[i], "\t")
    if #fields ~= 3 then
      return nil, string.format(
        "%s:%d: expected 3 tab-separated fields, got %d", p, i, #fields)
    end
    local n, nerr = str.to_integer(fields[2])
    if not n then
      return nil, string.format("%s:%d: %s", p, i, nerr)
    end
    rows[#rows + 1] = {path = fields[1], line = n, class = fields[3]}
  end
  return rows
end

--- Every real cast site the committed tree carries, through the same
--- lexer `_build/casts.tl` counts with — `_cli.lint.cast_lines`, not a
--- grep for the word `as`, which also matches the word in prose.
--- @param root string The project root to walk
--- @return {Site} Sorted by path, then by line
local function scan(root: string): {Site}
  local out: {Site} = {}
  for _, tree in ipairs(casts.TREES) do
    local dir = fs.join(root, tree)
    if fs.is_dir(dir) then
      local found = fs.find(dir, {glob = "*.tl"})
      if found then
        for _, path in ipairs(found) do
          -- The path under the tree, so it reads root-relative
          -- whatever spelling of the root the caller passed.
          local rest = path:sub(#dir + 2)
          if not ("/" .. rest):find("/testdata/", 1, true) then
            local text = fs.read(path)
            if text then
              for _, y in ipairs(lint.cast_lines(text, path)) do
                out[#out + 1] = {path = tree .. "/" .. rest, line = y}
              end
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a: Site, b: Site): boolean
      if a.path ~= b.path then
        return a.path < b.path
      end
      return a.line < b.line
    end)
  return out
end

--- A scanned site with no exact-key match: where in the output it
--- belongs, so a class found later can be dropped in without
--- disturbing the scan's own path-then-line order.
local record Pending
  site: Site
  index: integer
end

--- A file's committed text at `HEAD`, read once per file that has
--- both orphans and newcomers to try to pair by text.
--- @param root string Working directory to run `git` in
--- @param path string The file, relative to `root`
--- @return string|nil The committed text, or nil when `git` is not on
--- `PATH` or `path` is not tracked at `HEAD`
local function committed_text(root: string, path: string): string | nil
  local r = child.run({"git", "show", "HEAD:" .. path}, {cwd = root})
  if not r or not r.ok then
    return nil
  end
  return r.stdout
end

--- Reconcile the committed inventory against a fresh walk of the tree:
--- carry the class forward for every site that still exists, drop a
--- row whose site is gone, and refuse to write when a site has
--- appeared with no prior row to carry a class from.
---
--- Two passes. The first keys on the exact `path\tline` pair, as
--- before. Sites and rows the first pass could not match are, per
--- file, the NEWCOMERS and the ORPHANS. For a file with at least one
--- of each, the second pass reads the file's committed text at `git
--- show HEAD:<path>` and compares each orphan's committed line,
--- trimmed, against each newcomer's CURRENT line, also trimmed: a
--- newcomer whose trimmed text matches exactly one orphan's trimmed
--- text inherits that orphan's class, because that is the same cast,
--- moved. A newcomer matching zero or several orphan lines has no
--- honest single class to take, so it stays unclassified, and every
--- orphan simply drops — order and count are never consulted, so
--- reordering two casts cannot swap their classes, and editing a
--- cast's line asks for its class again exactly as a brand-new site
--- would. A file `git` cannot read at `HEAD` (untracked, or no `git`
--- on `PATH`) carries nothing: without committed text there is
--- nothing to compare against.
--- @param root string The project root to walk
--- @param tsv_path string? The committed inventory (default `TSV_PATH`)
--- @return {Row}|nil The reconciled rows, sorted by path then line
--- @return {string} Site keys (`path\tline`) with no class on record
local function reconcile(root: string, tsv_path?: string): {Row} | nil, {string}
  local old, err = read_tsv(tsv_path)
  if not old then
    return nil, {err}
  end
  local class_of: {string: string} = {}
  for _, r in ipairs(old) do
    class_of[r.path .. "\t" .. r.line] = r.class
  end

  local sites = scan(root)
  local matched: {string: boolean} = {}
  local resolved: {integer: Row} = {}
  local pending_by_path: {string: {Pending}} = {}
  local pending_order: {string} = {}
  for i, s in ipairs(sites) do
    local key = s.path .. "\t" .. s.line
    local class = class_of[key]
    if class then
      resolved[i] = {path = s.path, line = s.line, class = class}
      matched[key] = true
    else
      local pending = pending_by_path[s.path]
      if not pending then
        pending = {}
        pending_by_path[s.path] = pending
        pending_order[#pending_order + 1] = s.path
      end
      pending[#pending + 1] = {site = s, index = i}
    end
  end

  local orphans_by_path: {string: {Row}} = {}
  for _, r in ipairs(old) do
    if not matched[r.path .. "\t" .. r.line] then
      local orphans = orphans_by_path[r.path]
      if not orphans then
        orphans = {}
        orphans_by_path[r.path] = orphans
      end
      orphans[#orphans + 1] = r
    end
  end

  for _, path in ipairs(pending_order) do
    local pending = pending_by_path[path]
    local orphans = orphans_by_path[path]
    if orphans then
      local committed = committed_text(root, path)
      local current = fs.read(fs.join(root, path))
      if committed and current then
        local committed_lines = str.lines(committed)
        local current_lines = str.lines(current)
        -- How many orphans share each trimmed text, and which class
        -- that text carries — a text seen once is a safe carry, a
        -- text seen zero or several times is not.
        local text_count: {string: integer} = {}
        local text_class: {string: string} = {}
        for _, o in ipairs(orphans) do
          local line = committed_lines[o.line]
          if line then
            local trimmed = str.trim(line)
            text_count[trimmed] = (text_count[trimmed] or 0) + 1
            text_class[trimmed] = o.class
          end
        end
        for _, p in ipairs(pending) do
          local line = current_lines[p.site.line]
          if line then
            local trimmed = str.trim(line)
            if text_count[trimmed] == 1 then
              resolved[p.index] = {
                path = p.site.path,
                line = p.site.line,
                class = text_class[trimmed],
              }
            end
          end
        end
      end
    end
  end

  local rows: {Row} = {}
  local unclassified: {string} = {}
  for i, s in ipairs(sites) do
    local row = resolved[i]
    if row then
      rows[#rows + 1] = row
    else
      unclassified[#unclassified + 1] = s.path .. "\t" .. s.line
    end
  end
  if #unclassified > 0 then
    table.sort(unclassified)
    return nil, unclassified
  end
  return rows, {}
end

--- Regenerate the committed inventory.
--- @param ... string Command-line arguments
--- @return integer The exit status
local function main(...: string): integer
  local args = {...}
  if args[1] ~= "--reconcile" then
    io.stderr:write(
      "usage: cosmic --make run _build/cast_sites.tl --reconcile\n")
    return 1
  end
  local rows, problems = reconcile(".")
  if not rows then
    io.stderr:write(
      "cast_sites: new site(s) with no class on record — classify each"
      .. " by hand in " .. TSV_PATH .. " (see docs/design/casts.md's"
      .. " Classes section), then rerun:\n")
    for _, p in ipairs(problems) do
      io.stderr:write("  " .. p .. "\n")
    end
    return 1
  end
  local out = {"path\tline\tclass\n"}
  local files: {string: boolean} = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = string.format("%s\t%d\t%s\n", r.path, r.line, r.class)
    files[r.path] = true
  end
  local nfiles = 0
  for _ in pairs(files) do
    nfiles = nfiles + 1
  end
  local ok, werr = fs.write(TSV_PATH, table.concat(out))
  if not ok then
    io.stderr:write("cast_sites: " .. werr .. "\n")
    return 1
  end
  print(string.format("cast_sites: wrote %s — %d sites in %d files",
      TSV_PATH, #rows, nfiles))
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record CastSitesModule
  TSV_PATH: string
  read_tsv: function(path?: string): {Row} | nil, string
  scan: function(root: string): {Site}
  reconcile: function(root: string, tsv_path?: string): {Row} | nil, {string}
  main: function(...: string): integer
end

local M: CastSitesModule = {
  TSV_PATH = TSV_PATH,
  read_tsv = read_tsv,
  scan = scan,
  reconcile = reconcile,
  main = main,
}

return M
