--- The `cast-justify` rule behind `--check lint`'s `_cli.lint`: every
--- `as` cast in a `.tl` file is deliberate, either because it
--- structurally matches an allowlisted kind in this repo's own
--- `_build/casts_kinds.tl` (no comment needed) or because it carries a
--- trailing `-- cast: <reason>` justification (checked by
--- `_tool.lint.is_justified`, the same helper `assert-justify` and
--- `throw-justify` use).
---
--- The allowlist is read opportunistically off disk rather than
--- required as a module: `_build/casts_kinds.tl` is this repo's own
--- data, absent from every other project `--check lint` runs against,
--- and a static `require` of it here would run at `_cli.lint` load
--- time and break every one of them. `loaded_kinds` below falls back
--- to the empty table on a missing file, a compile failure, or a load
--- failure — the same outcome as a project that never had the file.

local ast = require("cosmic.ast")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local str = require("cosmic.string")
local style = require("_tool.lint")
local teal = require("cosmic.teal")

local type Diagnostic = style.Diagnostic
local type Node = ast.Node

--- One `as` cast in the file under lint: its line, its exact trimmed
--- source text (an `explicit` allowlist entry's key), and the `cast`
--- node itself (what a kind's pattern is matched against).
local record Site
  path: string
  y: integer
  text: string
  node: Node
end

--- `_build/casts_kinds.tl`'s `Kind` shape, duplicated here rather than
--- imported (see the module comment above).
local record ExplicitSite
  path: string
  text: string
end

local record Kind
  name: string
  pattern: string
  where: {string}
  explicit: {ExplicitSite}
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

local CASTS_KINDS_PATH < const > = "_build/casts_kinds.tl"
local kinds_loaded = false
local compiled_kinds: {Compiled} = {}

--- This repo's own cast-kind allowlist, compiled once and cached at
--- module scope -- the path is fixed and the same for every file one
--- run of `--check lint` walks.
--- @return {Compiled}
local function loaded_kinds(): {Compiled}
  if kinds_loaded then
    return compiled_kinds
  end
  kinds_loaded = true
  if fs.is_file(CASTS_KINDS_PATH) then
    local code = teal.compile_cached(CASTS_KINDS_PATH)
    if code then
      local chunk = load(code)
      if chunk then
        local ok, mod = pcall(chunk)
        if ok and mod then
          -- pcall's second return is untyped; the module loaded here is
          -- this repo's own, whose shape `KINDS` above already mirrors.
          local kinds = (mod as {string: any}).KINDS as {Kind} -- cast: dynamic module boundary, this repo's own trusted data
          if kinds then
            compiled_kinds = compile_kinds(kinds)
          end
        end
      end
    end
  end
  return compiled_kinds
end

--- Every `as` cast is an unchecked hole in the type system, so each one
--- must be deliberate: either it structurally matches an allowlisted
--- kind in `_build/casts_kinds.tl` (no comment needed), or it says why
--- with a trailing `-- cast: <reason>` (or one on the line directly
--- above, when 90 columns will not fit it).
--- @param file string Path, for the diagnostic and for scoping kinds
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per unjustified, unallowlisted cast
local function check_cast_justification(file: string, content: string,
    lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  local parsed = ast.parse(content, file)
  if not parsed then
    return diagnostics
  end
  local compiled = loaded_kinds()
  for _, hit in ipairs(ast.find_all(parsed.node, ANY_CAST)) do
    local y = ast.span_start(hit.node)
    local site: Site = {path = file, y = y,
      text = str.trim(lines[y] or ""), node = hit.node}
    local allowlisted = false
    for _, c in ipairs(compiled) do
      if kind_matches(site, c) then
        allowlisted = true
        break
      end
    end
    if not allowlisted and not style.is_justified(lines, y, "cast") then
      diagnostics[#diagnostics + 1] = {
        file = file, line = y, col = 1, rule = "cast-justify",
        message = string.format(
          "%s:%d: `as` cast without justification: prefer `is` narrowing"
          .. " or check.must (see `cosmic --docs guide.checking`); a"
          .. " deliberate cast either matches an allowlisted kind in"
          .. " `_build/casts_kinds.tl` or takes a trailing `-- cast:"
          .. " <reason>` (or one on the line above)",
          file, y),
      }
    end
  end
  return diagnostics
end

local record CastLintModule
  check_cast_justification: function(file: string, content: string,
  lines: {string}): {Diagnostic}
end

local M: CastLintModule = {
  check_cast_justification = check_cast_justification,
}

return M
