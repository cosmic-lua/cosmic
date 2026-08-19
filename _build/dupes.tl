--- Zero-tolerance gate over duplicated function bodies.
---
--- A copy-pasted function passes every other gate -- fmt, check, lint,
--- coverage -- so the only thing between a duplicate and main was a
--- reviewer noticing; three copies of one body survived four green CI
--- runs that way. This module finds identical top-level function
--- bodies across the two trees where that happened and names both
--- sites, so the gate fails before the review starts.
---
--- Extraction is textual and rests on a gate: `fmt` enforces 2-space
--- indentation, so a top-level body spans from a line matching
--- `^(local )?function ` to the next line that is exactly `end` --
--- nested closers are indented and cannot match. Normalization strips
--- comments and blank lines, collapses whitespace, and renames the
--- header's parameters to positional placeholders, so a rename-only
--- copy still matches. A normalized body under FLOOR lines is skipped:
--- measured over these trees, the only sub-floor duplicate is a
--- trivial forwarder, and one-line accessors are not worth exporting.
--- The gate starts and stays at zero findings -- no baseline, no
--- allowlist.

local fs = require("cosmic.fs")

--- The trees the scan covers: where the observed duplications lived,
--- and small enough that a false positive is cheap to inspect.
local TREES < const >: {string} = {"_make", "_cli"}

--- Normalized bodies shorter than this are skipped. Measured basis
--- (2026-08-19, comment/whitespace normalization over the same scope):
--- 812 top-level functions, one non-test duplicate group at 4 lines --
--- a `fail` forwarder tripled -- and the historical defect normalizes
--- to ~14 lines. Five exempts the forwarder and catches the defect.
local FLOOR < const > = 5

--- One occurrence of a normalized body.
local record Site
  path: string
  line: integer
end

--- Parameter names from a function header, reading forward from the
--- opening paren to its closing one (signatures wrap across lines).
--- @param header string The header text through the closing paren
--- @return {string} Parameter names in order
local function param_names(header: string): {string}
  local names: {string} = {}
  local inside = header:match("%((.-)%)")
  if not inside then
    return names
  end
  for piece in (inside .. ","):gmatch("(.-),") do
    local name = piece:match("^%s*([%a_][%w_]*)")
    if name and name ~= "" then
      names[#names + 1] = name
    end
  end
  return names
end

--- Normalize one body: comments and blanks dropped, whitespace
--- collapsed, parameters renamed to positional placeholders.
--- @param lines {string} The body's raw lines, header first
--- @return string The normalized body
--- @return integer How many normalized lines it holds
local function normalize(lines: {string}): string, integer
  local header = table.concat(lines, " ")
  local out: {string} = {}
  for _, raw in ipairs(lines) do
    local line = raw:gsub("%-%-.*$", ""):gsub("%s+", " ")
    line = line:gsub("^ ", ""):gsub(" $", "")
    if line ~= "" then
      out[#out + 1] = line
    end
  end
  local body = table.concat(out, "\n")
  for i, name in ipairs(param_names(header)) do
    -- gsub: name is [%a_][%w_]* and replacement __p<n> — no % possible
    body = body:gsub("%f[%w_]" .. name .. "%f[^%w_]", "__p" .. i)
  end
  return body, #out
end

--- Collect every top-level function body in one file's text.
--- @param text string The file's bytes
--- @return {{integer, string}} Pairs of start line and normalized body
local function bodies(text: string): {{integer, string}}
  local out: {{integer, string}} = {}
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local i = 1
  while i <= #lines do
    if lines[i]:match("^local function [%a_]")
    or lines[i]:match("^function [%a_]") then
      local start = i
      local j = i
      while j <= #lines and lines[j] ~= "end" do
        j = j + 1
      end
      if j <= #lines then
        local raw: {string} = {}
        for k = start, j do
          raw[#raw + 1] = lines[k]
        end
        local body, n = normalize(raw)
        if n >= FLOOR then
          out[#out + 1] = {start, body}
        end
        i = j
      end
    end
    i = i + 1
  end
  return out
end

--- Scan the trees under `root` for identical normalized bodies.
--- @param root string The project root to scan under
--- @return {string} One message per duplicate group, path-sorted
local function scan(root: string): {string}
  local groups: {string: {Site}} = {}
  for _, tree in ipairs(TREES) do
    local dir = fs.join(root, tree)
    if fs.is_dir(dir) then
      local found = fs.find(dir, {glob = "*.tl"})
      if found then
        for _, path in ipairs(found) do
          local rest = path:sub(#dir + 2)
          if not ("/" .. rest):find("/testdata/", 1, true)
          and not rest:find("_test%.tl$") then
            local text = fs.read(path)
            if text then
              for _, b in ipairs(bodies(text)) do
                local key = b[2] as string -- cast: tuple element
                local sites = groups[key]
                if not sites then
                  sites = {}
                  groups[key] = sites
                end
                sites[#sites + 1] = {
                  path = tree .. "/" .. rest,
                  line = b[1] as integer, -- cast: tuple element
                }
              end
            end
          end
        end
      end
    end
  end
  local out: {string} = {}
  for _, sites in pairs(groups) do
    if #sites > 1 then
      local where: {string} = {}
      for _, s in ipairs(sites) do
        where[#where + 1] = ("%s:%d"):format(s.path, s.line)
      end
      table.sort(where)
      out[#out + 1] = ("identical body at %s — export one and require it")
      :format(table.concat(where, " and "))
    end
  end
  table.sort(out)
  return out
end

local record DupesModule
  TREES: {string}
  FLOOR: integer
  scan: function(root: string): {string}
end

local M: DupesModule = {
  TREES = TREES,
  FLOOR = FLOOR,
  scan = scan,
}

return M
