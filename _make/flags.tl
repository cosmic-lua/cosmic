--- Parse `--make <verb>`'s own flags out of argv, once -- split out of
--- `_make/init.tl` (which sits at the repo's 500-line file cap) so the
--- parse can grow without the dispatcher outgrowing it.
---
--- Everything starting with `-` (other than a bare `-`) that this
--- module does not recognize is a refusal, not a path: selection space
--- had no bottom before the registry reserved it (`--make fmt --fix`
--- used to die as `nothing to do under: --fix`), and reserving the
--- flag namespace here is the same durability move.

local check_scope = require("_make.check_scope")

local record Flags
  --- `fmt --fix`: rewrite rather than report. Valid on `fmt` only.
  fix: boolean
  --- `coverage --min PCT` (or `ci --min PCT`, threaded to the coverage
  --- stage `ci` runs): refuse below this overall percentage.
  min: number | nil
  --- `coverage --min-file PCT` (or `ci`'s): refuse any file below this
  --- percentage.
  min_file: number | nil
  --- Everything else: selection paths.
  paths: {string}
end

--- Parse argv words as this verb's flags plus selection paths.
--- @param name string The verb being run, for scoping `--fix`/`--min`/`--min-file`
--- @param words {string} argv words after the verb name
--- @return Flags | nil The parsed flags, or nil on a refusal
--- @return string The refusal message, when parsing failed
local function parse(name: string, words: {string}): Flags | nil, string
  local remaining, err = check_scope.extract(name, words)
  if not remaining then return nil, err end
  words = remaining
  local out: Flags = {fix = false, min = nil, min_file = nil, paths = {}}
  local i = 1
  while i <= #words do
    local w = words[i]
    if w == "--fix" then
      out.fix = true
      i = i + 1
    elseif w == "--min" or w == "--min-file" then
      local raw = words[i + 1]
      local n = raw and tonumber(raw)
      if not n then
        return nil, "make: " .. w .. " needs a percentage, got " ..
        (raw and ("'" .. raw .. "'") or "nothing")
      end
      if w == "--min" then
        out.min = n
      else
        out.min_file = n
      end
      i = i + 2
    elseif w:sub(1, 1) == "-" and w ~= "-" then
      return nil, "make: unknown flag '" .. w .. "' for " .. name
    else
      out.paths[#out.paths + 1] = w
      i = i + 1
    end
  end
  if out.fix and name ~= "fmt" then
    return nil, "make: --fix belongs to `fmt`, not '" .. name .. "'"
  end
  if (out.min ~= nil or out.min_file ~= nil) and
  name ~= "coverage" and name ~= "ci" then
    return nil, "make: --min/--min-file belong to `coverage` (or `ci`), not '" ..
    name .. "'"
  end
  return out
end

local record FlagsModule
  type Flags = Flags
  parse: function(name: string, words: {string}): Flags | nil, string
end

local M: FlagsModule = {
  parse = parse,
}

return M
