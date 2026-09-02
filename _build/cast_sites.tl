#!/usr/bin/env cosmic
--- Reads and regenerates the committed cast site inventory.
---
--- `docs/dev/explanation/cast-sites.tsv` is half generated, half curated: its
--- path and line columns are a fact about the tree — the same `as`
--- tokens `_build/casts.tl` counts, through the same lexer
--- (`_cli.lint.cast_lines`) — but its class column is a human reading
--- of what each cast is for, which no scan can produce. `--reconcile`
--- re-derives the first two columns from the tree and carries the
--- third column forward from the committed file for every site that
--- still exists; a site with no prior row has no class to carry, so it
--- is refused rather than written in blank, and stays committed
--- unclassified until a person edits the row in by hand. A full
--- rewrite the way `_build/casts.tl --baseline` rewrites its floor
--- would destroy exactly the column nothing else holds.
---
---     bin/cosmic --make run _build/cast_sites.tl --reconcile
---
--- `_build/cast_sites_test.tl` gates the committed file against this
--- module's read of it and against `_build/casts_baseline.tl`.

local casts = require("_build.casts")
local fs = require("cosmic.fs")
local lint = require("_cli.lint")
local proc = require("cosmic.proc")
local str = require("cosmic.string")

--- The committed inventory: where this module reads and writes it,
--- relative to the project root.
local TSV_PATH < const > = "docs/dev/explanation/cast-sites.tsv"

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

--- Reconcile the committed inventory against a fresh walk of the tree:
--- carry the class forward for every site that still exists, drop a
--- row whose site is gone, and refuse to write when a site has
--- appeared with no prior row to carry a class from.
--- @param root string The project root to walk
--- @return {Row}|nil The reconciled rows, sorted by path then line
--- @return {string} Site keys (`path\tline`) with no class on record
local function reconcile(root: string): {Row} | nil, {string}
  local old, err = read_tsv()
  if not old then
    return nil, {err}
  end
  local class_of: {string: string} = {}
  for _, r in ipairs(old) do
    class_of[r.path .. "\t" .. r.line] = r.class
  end
  local rows: {Row} = {}
  local unclassified: {string} = {}
  for _, s in ipairs(scan(root)) do
    local key = s.path .. "\t" .. s.line
    local class = class_of[key]
    if class then
      rows[#rows + 1] = {path = s.path, line = s.line, class = class}
    else
      unclassified[#unclassified + 1] = key
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
      .. " by hand in " .. TSV_PATH .. " (see docs/dev/explanation/casts.md's"
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
  reconcile: function(root: string): {Row} | nil, {string}
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
