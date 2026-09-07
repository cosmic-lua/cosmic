#!/usr/bin/env cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
--- reads: cmd
--- reads: cosmic
-- Ratchet over the tree's `as` casts: an allowlist of KINDS, not a
-- floor of counts.
--
-- `_build/casts_kinds.tl` names every kind `docs/design/casts.md`'s
-- `### ` headings describe, each as a `cosmic.ast` pattern plus the
-- files it applies to, or (where a predicate cannot tell a kind apart
-- from a neighbour sharing its file) an explicit list of exact sites.
-- This file walks a fresh `cosmic.ast` parse of the whole tree and
-- checks three things against that allowlist: every cast matches
-- exactly one kind, no kind matches more sites than its committed
-- ceiling (shrunk by hand in `casts_kinds.tl` as sites close), and
-- every kind still has at least one site (a kind at zero is deleted,
-- never kept at zero). A cast nothing here recognizes fails naming
-- `file:line` and, when some kind's PATTERN would have matched had its
-- `where` scope reached that file, the kinds it nearly matched --
-- `docs/design/casts.md`'s Classes section is where a real new site
-- gets triaged into an existing kind or a new one.

local ast = require("cosmic.ast")
local casts = require("_build.casts")
local kinds_mod = require("_build.casts_kinds")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local str = require("cosmic.string")

local type Kind = kinds_mod.Kind
local type Node = ast.Node

--- One `as` cast the tree carries: where it is, its exact trimmed
--- source line (an `explicit` entry's key), and the `cast` node itself
--- (what a kind's pattern is matched against).
local record Site
  path: string
  y: integer
  text: string
  node: Node
end

--- One kind, with its pattern compiled once (nil when the kind is
--- `explicit`-only) rather than re-parsed per site.
local record Compiled
  kind: Kind
  pattern_node: Node
end

--- The unconstrained cast pattern every site is first found by; each
--- kind's own (possibly predicated) pattern is matched again, directly
--- against the same node, once a site's file narrows which kinds apply.
local ANY_CAST < const > = check.must(ast.compile_pattern("$X as $T"))

--- Does `path` fall under one of a kind's `where` prefixes -- a
--- directory (`"cosmic/fs/"`) or one exact file?
--- @param path string
--- @param where {string}
--- @return boolean
local function is_in_scope(path: string, where: {string}): boolean
  for _, w in ipairs(where) do
    if path:sub(1, #w) == w then
      return true
    end
  end
  return false
end

--- Compile every kind's pattern once.
--- @param kinds {Kind}
--- @return {Compiled}
local function compile_kinds(kinds: {Kind}): {Compiled}
  local out: {Compiled} = {}
  for _, k in ipairs(kinds) do
    local pn: Node = nil
    if k.pattern ~= "" then
      pn = check.must(ast.compile_pattern(k.pattern))
    end
    out[#out + 1] = {kind = k, pattern_node = pn}
  end
  return out
end

--- Every `as` cast the committed tree carries, via one `cosmic.ast`
--- parse and walk per file -- the same trees and `testdata/` exclusion
--- `_build/casts.tl` and the deleted `_build/cast_sites.tl` used.
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
          -- The path under the tree, so the key is root-relative
          -- whatever spelling of the root the caller passed.
          local rest = path:sub(#dir + 2)
          if not ("/" .. rest):find("/testdata/", 1, true) then
            local text = fs.read(path)
            if text then
              local parsed = ast.parse(text, path)
              if parsed then
                local text_lines = str.lines(text)
                local rel = tree .. "/" .. rest
                for _, hit in ipairs(ast.find_all(parsed.node, ANY_CAST)) do
                  local y = ast.span_start(hit.node)
                  out[#out + 1] = {
                    path = rel, y = y,
                    text = str.trim(text_lines[y] or ""),
                    node = hit.node,
                  }
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
      return a.y < b.y
    end)
  return out
end

--- Does `c`'s kind claim `site` -- its pattern matched within scope, or
--- one of its explicit entries names this exact (path, line)?
--- @param site Site
--- @param c Compiled
--- @return boolean
local function kind_matches(site: Site, c: Compiled): boolean
  if c.pattern_node and is_in_scope(site.path, c.kind.where) then
    if ast.match(c.pattern_node, site.node) then
      return true
    end
  end
  for _, e in ipairs(c.kind.explicit) do
    if e.path == site.path and e.text == site.text then
      return true
    end
  end
  return false
end

--- Every kind name whose PATTERN matches `site` structurally, ignoring
--- `where` -- what a zero-match failure's "near" list reports, since a
--- pattern that matches outside its own scope is the likely home for a
--- genuinely new site.
--- @param site Site
--- @param compiled {Compiled}
--- @return {string}
local function near_matches(site: Site, compiled: {Compiled}): {string}
  local out: {string} = {}
  for _, c in ipairs(compiled) do
    if c.pattern_node and ast.match(c.pattern_node, site.node) then
      out[#out + 1] = c.kind.name
    end
  end
  return out
end

--- `site`'s claiming kind names, in `KINDS` order.
--- @param site Site
--- @param compiled {Compiled}
--- @return {string}
local function matching_kinds(site: Site, compiled: {Compiled}): {string}
  local out: {string} = {}
  for _, c in ipairs(compiled) do
    if kind_matches(site, c) then
      out[#out + 1] = c.kind.name
    end
  end
  return out
end

local function test_every_cast_site_matches_exactly_one_kind()
  local sites = scan(".")
  local compiled = compile_kinds(kinds_mod.KINDS)
  local problems: {string} = {}
  for _, s in ipairs(sites) do
    local matched = matching_kinds(s, compiled)
    if #matched == 0 then
      local near = near_matches(s, compiled)
      local suffix = ""
      if #near > 0 then
        suffix = " (near: " .. table.concat(near, ", ") .. ")"
      end
      problems[#problems + 1] = string.format("%s:%d: matches no kind%s",
        s.path, s.y, suffix)
    elseif #matched > 1 then
      problems[#problems + 1] = string.format("%s:%d: matches %d kinds: %s",
        s.path, s.y, #matched, table.concat(matched, ", "))
    end
  end
  table.sort(problems)
  assert(#problems == 0,
    "site(s) not classified into exactly one kind:\n  " ..
    table.concat(problems, "\n  "))
end

local function test_no_kind_exceeds_its_committed_ceiling()
  local sites = scan(".")
  local compiled = compile_kinds(kinds_mod.KINDS)
  local problems: {string} = {}
  for _, c in ipairs(compiled) do
    local n = 0
    for _, s in ipairs(sites) do
      if kind_matches(s, c) then
        n = n + 1
      end
    end
    if n > c.kind.sites then
      problems[#problems + 1] = string.format(
        "%s: %d site(s), over its committed ceiling of %d -- lower the" ..
        " ceiling in _build/casts_kinds.tl, or this kind grew a site",
        c.kind.name, n, c.kind.sites)
    end
  end
  table.sort(problems)
  assert(#problems == 0, table.concat(problems, "\n  "))
end

local function test_every_kind_has_at_least_one_site()
  local sites = scan(".")
  local compiled = compile_kinds(kinds_mod.KINDS)
  local problems: {string} = {}
  for _, c in ipairs(compiled) do
    local n = 0
    for _, s in ipairs(sites) do
      if kind_matches(s, c) then
        n = n + 1
      end
    end
    if n == 0 then
      problems[#problems + 1] = c.kind.name ..
      " -- delete this entry and its docs/design/casts.md heading"
    end
  end
  table.sort(problems)
  assert(#problems == 0,
    "kind(s) with no site left:\n  " .. table.concat(problems, "\n  "))
end

print("all cast kind ratchet tests passed")
