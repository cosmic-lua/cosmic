#!/usr/bin/env cosmic
--- Reads and regenerates the committed cast site inventory.
---
--- `docs/design/cast-sites.tsv` is half generated, half curated: its
--- `path`/`fn`/`n`/`cast` columns are a fact about the tree, but the
--- `class` column is a human reading of what each cast is for, which
--- no scan can produce. A site is keyed by `(path, enclosing function,
--- ordinal of the cast within that function)` -- never by its line --
--- so an edit anywhere above a cast, which used to shift its line and
--- force a reconcile, changes nothing here: the function a cast sits
--- in and its position among that function's own casts do not move
--- just because an earlier line grew or shrank. `<chunk>` names the
--- top level, for a cast outside every function. `--reconcile`
--- re-derives the first three columns from the tree by walking each
--- file's AST (`cosmic.ast.walk`, one `("as")` op node per line
--- `_cli.lint.cast_lines` already finds -- the same lexer
--- `_build/casts.tl` counts with, so this inventory's per-file count
--- never drifts from that floor) and carries the fourth (`class`)
--- forward from the committed file for every site whose key still
--- matches. A site with no matching key has no class to carry, so it
--- is refused rather than written in blank; when its cast TEXT
--- exactly matches one orphaned key's text (the same cast, moved to a
--- different function), the refusal names both keys so a person can
--- carry the class across by hand in one look rather than rediscover
--- it. A full rewrite the way `_build/casts.tl --baseline` rewrites
--- its floor would destroy exactly the column nothing else holds.
---
---     bin/cosmic --make run _build/cast_sites.tl --reconcile
---
--- `_build/cast_sites_test.tl` gates the committed file against this
--- module's read of it and against `_build/casts_baseline.tl`.

local ast = require("cosmic.ast")
local casts = require("_build.casts")
local fs = require("cosmic.fs")
local lint = require("_cli.lint")
local proc = require("cosmic.proc")
local str = require("cosmic.string")

local type Node = ast.Node

--- The committed inventory: where this module reads and writes it,
--- relative to the project root.
local TSV_PATH < const > = "docs/design/cast-sites.tsv"

--- One `as` cast found by a walk of the tree: a fact, no judgment.
local record Site
  path: string
  fn: string
  n: integer
  cast: string
end

--- One committed inventory row: a `Site` plus its human classification.
local record Row
  path: string
  fn: string
  n: integer
  cast: string
  class: string
end

--- The name given a cast with no enclosing `local_function`,
--- `global_function`, or `record_function` -- the file's top level.
local CHUNK < const > = "<chunk>"

--- The tab-joined key three columns of a `Site`/`Row` share --
--- `path`/`fn`/`n` -- the string reconcile matches on and reports.
--- @param path string
--- @param fn string
--- @param n integer
--- @return string
local function site_key(path: string, fn: string, n: integer): string
  return string.format("%s\t%s\t%d", path, fn, n)
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
    if #fields ~= 5 then
      return nil, string.format(
        "%s:%d: expected 5 tab-separated fields, got %d", p, i, #fields)
    end
    local n, nerr = str.to_integer(fields[3])
    if not n then
      return nil, string.format("%s:%d: %s", p, i, nerr)
    end
    rows[#rows + 1] = {
      path = fields[1], fn = fields[2], n = n, cast = fields[4], class = fields[5],
    }
  end
  return rows
end

--- One candidate enclosing function: its qualified name and the
--- inclusive span (start, end) its whole declaration covers.
local record FnSpan
  name: string
  sy: integer
  sx: integer
  ey: integer
  ex: integer
end

--- Is (`ay`, `ax`) at or before (`by`, `bx`), reading top-to-bottom
--- then left-to-right?
local function at_or_before(ay: integer, ax: integer, by: integer, bx: integer): boolean
  return ay < by or (ay == by and ax <= bx)
end

--- Does `f`'s span cover (`y`, `x`)?
--- @param f FnSpan
--- @param y integer
--- @param x integer
--- @return boolean
local function covers(f: FnSpan, y: integer, x: integer): boolean
  return at_or_before(f.sy, f.sx, y, x) and at_or_before(y, x, f.ey, f.ex)
end

--- A "type_identifier"/"identifier"/"op" owner-chain node's own text --
--- `"R"` for a plain owner, `"R.T"` for one already dotted. tl's own
--- parser builds a record method's owner as a right-leaning chain of
--- "op" nodes (`.`) bottoming out at a "type_identifier" leaf; this
--- reads that shape directly off the raw table, the same way every
--- consumer of a kind `cosmic/ast/node.tl`'s shared `Node` record does
--- not cover reads its own fields off it (see that module's header).
--- @param o any A `fn_owner` node, or an owner-chain "op" node's `e1`/`e2`
--- @return string
local function owner_text(o: any): string
  local ot = o as {string: any} -- cast: tl-parser field this Node kind doesn't name
  if ot.kind == "op" then
    return owner_text(ot.e1) .. "." .. owner_text(ot.e2)
  end
  return tostring(ot.tk)
end

--- The qualified name of a "local_function", "global_function", or
--- "record_function" node -- `"foo"` for the first two,
--- `"R.method"` for a record function, qualified through its own
--- owner chain so two records' same-named methods never collide.
--- `name`/`fn_owner` are tl-parser fields specific to these three
--- kinds, absent from `cosmic/ast/node.tl`'s shared `Node` record, so
--- this reads them off the raw table.
--- @param fn Node
--- @return string
local function function_name(fn: Node): string
  local raw = fn as {string: any} -- cast: tl-parser field this Node kind doesn't name
  local name_field = raw.name as {string: any} -- cast: tl-parser field this Node kind doesn't name
  local name_text = tostring(name_field.tk)
  if fn.kind ~= "record_function" then
    return name_text
  end
  return owner_text(raw.fn_owner) .. "." .. name_text
end

--- One file's cast sites: for each line `_cli.lint.cast_lines` found,
--- the nearest enclosing function's name and this cast's 1-based
--- ordinal within it, in source order.
---
--- A line holding more than one cast (rare; a handful of files pack
--- two or three onto one line) is represented by its LEFTMOST one --
--- `cast_lines` only records that the line holds a cast, never which,
--- so this module's own per-file count matches `_build/casts.tl`'s
--- exactly no matter how many share a line.
--- @param rel string This file's path, relative to the project root
--- @param path string This file's real path, for parse diagnostics
--- @param text string The file's source
--- @param lines {integer} 1-based lines `cast_lines` found in `text`
--- @return {Site}
local function sites_in_file(rel: string, path: string, text: string,
    lines: {integer}): {Site}
  local text_lines = str.lines(text)
  local parsed = ast.parse(text, path)
  if not parsed then
    -- No AST to place these in a function: every line falls back to
    -- the top level, in line order -- the count still agrees with
    -- `_build/casts.tl`, which never needed a parse to begin with.
    local sorted = {table.unpack(lines)}
    table.sort(sorted)
    local out: {Site} = {}
    for i, y in ipairs(sorted) do
      out[#out + 1] = {path = rel, fn = CHUNK, n = i, cast = str.trim(text_lines[y] or "")}
    end
    return out
  end

  local wanted: {integer: boolean} = {}
  for _, y in ipairs(lines) do
    wanted[y] = true
  end
  local chosen_x: {integer: integer} = {}
  local spans: {FnSpan} = {}
  ast.walk(parsed.node, function(n: Node)
      if n.kind == "op" and n.op and n.op.op == "as" and wanted[n.y] then
        local x = chosen_x[n.y]
        if not x or n.x < x then
          chosen_x[n.y] = n.x
        end
      elseif n.kind == "local_function" or n.kind == "global_function"
      or n.kind == "record_function" then
        local sy, sx = ast.span_start(n)
        local ey, ex = ast.span_end(n, parsed.tokens)
        spans[#spans + 1] = {name = function_name(n), sy = sy, sx = sx, ey = ey, ex = ex}
      end
    end)

  local order: {integer} = {table.unpack(lines)}
  table.sort(order)
  local ordinal: {string: integer} = {}
  local out: {Site} = {}
  for _, y in ipairs(order) do
    local x = chosen_x[y] or 0
    local best: FnSpan = nil
    for _, f in ipairs(spans) do
      if covers(f, y, x) and (not best or f.sy > best.sy
        or (f.sy == best.sy and f.sx > best.sx)) then
        best = f
      end
    end
    local fn = best and best.name or CHUNK
    ordinal[fn] = (ordinal[fn] or 0) + 1
    out[#out + 1] = {path = rel, fn = fn, n = ordinal[fn], cast = str.trim(text_lines[y] or "")}
  end
  return out
end

--- Every real cast site the committed tree carries, through the same
--- lexer `_build/casts.tl` counts with to find the lines, then an AST
--- walk of each such file to place each one in its enclosing function.
--- @param root string The project root to walk
--- @return {Site} Sorted by path, then by enclosing function, then ordinal
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
              local lines = lint.cast_lines(text, path)
              if #lines > 0 then
                local rel = tree .. "/" .. rest
                for _, s in ipairs(sites_in_file(rel, path, text, lines)) do
                  out[#out + 1] = s
                end
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
      if a.fn ~= b.fn then
        return a.fn < b.fn
      end
      return a.n < b.n
    end)
  return out
end

--- Reconcile the committed inventory against a fresh walk of the tree:
--- carry the class forward for every site whose `(path, fn, n)` key
--- still matches, drop a row whose key is gone for good, and refuse to
--- write when a key has appeared with no prior row to carry a class
--- from. A refused site whose cast TEXT exactly matches exactly one
--- orphaned key's text -- and no other orphan or newcomer shares that
--- text -- is refused with a finding naming both keys, since the site
--- most likely just moved to a different function rather than being
--- new.
--- @param root string The project root to walk
--- @param tsv_path string? The committed inventory (default `TSV_PATH`)
--- @return {Row}|nil The reconciled rows, sorted by path, fn, n
--- @return {string} Findings: a moved site names both keys, a new one just its own
local function reconcile(root: string, tsv_path?: string): {Row} | nil, {string}
  local old, err = read_tsv(tsv_path)
  if not old then
    return nil, {err}
  end
  local class_of: {string: string} = {}
  for _, r in ipairs(old) do
    class_of[site_key(r.path, r.fn, r.n)] = r.class
  end

  local sites = scan(root)
  local matched: {string: boolean} = {}
  local rows: {Row} = {}
  local unmatched: {Site} = {}
  for _, s in ipairs(sites) do
    local key = site_key(s.path, s.fn, s.n)
    local class = class_of[key]
    if class then
      rows[#rows + 1] = {path = s.path, fn = s.fn, n = s.n, cast = s.cast, class = class}
      matched[key] = true
    else
      unmatched[#unmatched + 1] = s
    end
  end
  if #unmatched == 0 then
    return rows, {}
  end

  local orphans: {Row} = {}
  for _, r in ipairs(old) do
    if not matched[site_key(r.path, r.fn, r.n)] then
      orphans[#orphans + 1] = r
    end
  end
  local orphan_text_count: {string: integer} = {}
  local orphan_of_text: {string: Row} = {}
  for _, o in ipairs(orphans) do
    local tk = o.path .. "\t" .. o.cast
    orphan_text_count[tk] = (orphan_text_count[tk] or 0) + 1
    orphan_of_text[tk] = o
  end
  local newcomer_text_count: {string: integer} = {}
  for _, s in ipairs(unmatched) do
    local tk = s.path .. "\t" .. s.cast
    newcomer_text_count[tk] = (newcomer_text_count[tk] or 0) + 1
  end

  local findings: {string} = {}
  for _, s in ipairs(unmatched) do
    local tk = s.path .. "\t" .. s.cast
    local new_key = site_key(s.path, s.fn, s.n)
    if orphan_text_count[tk] == 1 and newcomer_text_count[tk] == 1 then
      local o = orphan_of_text[tk]
      findings[#findings + 1] = string.format(
        "%s (was %s, class %q -- same cast text, different function;"
        .. " reclassify by hand)", new_key, site_key(o.path, o.fn, o.n), o.class)
    else
      findings[#findings + 1] = new_key
    end
  end
  table.sort(findings)
  return nil, findings
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
  local out = {"path\tfn\tn\tcast\tclass\n"}
  local files: {string: boolean} = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = string.format("%s\t%s\t%d\t%s\t%s\n", r.path, r.fn, r.n, r.cast, r.class)
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
