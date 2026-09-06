--- Zero-tolerance gate over duplicated prose: doc-comment blocks and
--- markdown paragraphs.
---
--- `_build/dupes.tl` fails on two identical top-level function BODIES.
--- Nothing looks at prose: a doc-comment block or a markdown paragraph
--- pasted into a second place passes fmt, check, lint, coverage and the
--- body gate, and then the two copies drift -- one gets corrected, the
--- other keeps teaching the old shape. This module finds identical
--- normalized prose across the scanned trees and names both sites, the
--- prose sibling of the body gate.
---
--- A unit is a maximal run of `---` lines in a `.tl` file (a `--`
--- comment is an implementation note, already outside this gate's
--- scope), or a paragraph in a `.md` file -- lines between blank lines
--- or headings, with fenced blocks skipped whole. Normalization
--- lowercases the text and collapses every run of non-alphanumerics to
--- one space; a `@param`/`@return` tag line contributes only what
--- follows the tag (and, for `@param`, the parameter name), so two
--- functions with the same parameter set do not fail to match merely
--- because their tags differ. A normalized unit under FLOOR tokens is
--- skipped: it is a one-line summary ("Close the handle") that is
--- legitimately shared. A unit is also skipped when its first line is
--- the `reads:`/`ref:` declared-input header convention, or when its
--- file sits under a `testdata/` directory -- nothing else is excused
--- here, because a legitimate second copy is fixed in the prose, never
--- allowlisted.

local fs = require("cosmic.fs")

--- The trees the scan covers: every tree `_build/dupes.tl` scans, plus
--- the prose-only trees (`docs`, `skills`, `sys`) and the two root
--- files a project's instructions live in. `CLAUDE.md` is never
--- read -- it is a symlink to `AGENTS.md`, and reading both would
--- double every paragraph in it.
local TREES < const >: {string} = {
  "_build", "_cli", "_docs", "_eval", "_fuzz", "_make", "_perf", "_tool",
  "_types", "cmd", "cosmic", "docs", "skills", "sys", "README.md",
  "AGENTS.md",
}

--- Normalized units shorter than this are skipped. Measured basis
--- (2026-09-05): 3843 blocks of 12+ tokens across 704 files, 19 real
--- duplicate groups once the `CLAUDE.md`/`AGENTS.md` symlink pairing
--- and the shared `reads:` header are set aside.
local FLOOR < const > = 12

--- One occurrence of a normalized unit.
local record Site
  path: string
  line: integer
end

--- What a `@param`/`@return` tag line contributes to the normalized
--- text: never the tag itself, and for `@param` never the parameter
--- name either, so a rename-only difference in the signature does not
--- keep two otherwise identical blocks apart.
--- @param line string One line's content, already stripped of the
--- `---` marker
--- @return string The line's contribution: unchanged when it carries
--- no tag
local function strip_tag(line: string): string
  local ret = line:match("^@return%s*(.*)$")
  if ret then
    return ret
  end
  local _name, rest = line:match("^@param%s+([%a_][%w_]*)%s+(.*)$")
  if rest then
    return rest
  end
  local bare = line:match("^@param%s*(.*)$")
  if bare then
    return bare
  end
  return line
end

--- Lowercase, non-alphanumerics collapsed to single spaces, trimmed.
--- @param text string The unit's raw joined text
--- @return string The normalized text
--- @return integer How many whitespace-separated tokens it holds
local function normalize(text: string): string, integer
  local norm = text:lower():gsub("[^%w]+", " ")
  norm = norm:gsub("^ ", ""):gsub(" $", "")
  local ntok = 0
  for _ in norm:gmatch("%S+") do
    ntok = ntok + 1
  end
  return norm, ntok
end

--- Whether a unit is the `reads:`/`ref:` declared-input header
--- convention `_build/*_test.tl` and `_tool/discover_test.tl` carry --
--- excluded because it is meant to be shared, not a copy that drifted.
--- @param text string The unit's raw joined text, unnormalized
--- @return boolean
local function is_declared_input(text: string): boolean
  return text:match("^%s*reads:") ~= nil or text:match("^%s*ref:") ~= nil
end

--- Every `---` doc-comment block in one `.tl` file's text.
--- @param text string The file's bytes
--- @return {{integer, string}} Pairs of start line and raw joined text
local function tl_units(text: string): {{integer, string}}
  local out: {{integer, string}} = {}
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local block: {string} = {}
  local start: integer | nil = nil
  for i, raw in ipairs(lines) do
    local content = raw:match("^%s*%-%-%-%s?(.*)$")
    if content then
      if not start then
        start = i
      end
      block[#block + 1] = strip_tag(content)
    elseif start then
      out[#out + 1] = {start, table.concat(block, " ")}
      block, start = {}, nil
    end
  end
  if start then
    out[#out + 1] = {start, table.concat(block, " ")}
  end
  return out
end

--- Every paragraph in one `.md` file's text, fenced blocks skipped
--- whole -- the same fence tracking `_build/doc_paths_test.tl`'s
--- `spans_of` does.
--- @param text string The file's bytes
--- @return {{integer, string}} Pairs of start line and raw joined text
local function md_units(text: string): {{integer, string}}
  local out: {{integer, string}} = {}
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local para: {string} = {}
  local start: integer | nil = nil
  local in_fence = false
  for i, l in ipairs(lines) do
    if l:match("^%s*```") then
      in_fence = not in_fence
    end
    if in_fence or l:match("^%s*```") or l:match("^%s*$") or l:match("^%s*#") then
      if start then
        out[#out + 1] = {start, table.concat(para, " ")}
      end
      para, start = {}, nil
    else
      if not start then
        start = i
      end
      para[#para + 1] = l
    end
  end
  if start then
    out[#out + 1] = {start, table.concat(para, " ")}
  end
  return out
end

--- Scan one file's units into `groups`, keyed by normalized text.
--- @param groups {string: {Site}} Accumulator, mutated in place
--- @param path string The file to read
--- @param display string The path to report, root-relative
local function scan_file(groups: {string: {Site}}, path: string,
    display: string)
  local text = fs.read(path)
  if not text then
    return
  end
  local units = display:match("%.md$") and md_units(text) or tl_units(text)
  for _, u in ipairs(units) do
    local line, raw = u[1], u[2]
    if not is_declared_input(raw) then
      local norm, ntok = normalize(raw)
      if ntok >= FLOOR then
        local sites = groups[norm]
        if not sites then
          sites = {}
          groups[norm] = sites
        end
        sites[#sites + 1] = {path = display, line = line}
      end
    end
  end
end

--- Scan the trees under `root` for identical normalized prose.
--- @param root string The project root to scan under
--- @return {string} One message per duplicate group, path-sorted
local function scan(root: string): {string}
  local groups: {string: {Site}} = {}
  for _, tree in ipairs(TREES) do
    local path = fs.join(root, tree)
    if fs.is_dir(path) then
      for _, glob in ipairs({"*.tl", "*.md"}) do
        local found = fs.find(path, {glob = glob})
        if found then
          for _, filepath in ipairs(found) do
            local rest = filepath:sub(#path + 2)
            if not ("/" .. rest):find("/testdata/", 1, true) then
              scan_file(groups, filepath, tree .. "/" .. rest)
            end
          end
        end
      end
    elseif fs.is_file(path) then
      scan_file(groups, path, tree)
    end
  end
  local out: {string} = {}
  for norm, sites in pairs(groups) do
    if #sites > 1 then
      local where: {string} = {}
      for _, s in ipairs(sites) do
        where[#where + 1] = ("%s:%d"):format(s.path, s.line)
      end
      table.sort(where)
      out[#out + 1] = table.concat(where, "  ")
      .. ": identical prose — keep one, point the other at it (\""
      .. norm:sub(1, 60) .. "\")"
    end
  end
  table.sort(out)
  return out
end

local record ProseDupesModule
  TREES: {string}
  FLOOR: integer
  scan: function(root: string): {string}
end

local M: ProseDupesModule = {
  TREES = TREES,
  FLOOR = FLOOR,
  scan = scan,
}

return M
