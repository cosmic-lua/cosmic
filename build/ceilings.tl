--- The ceilings of the new checker: how many errors of each code each file of the tree may still have, per stage, as data
--- in [`build/ceilings.txt`] and not as Teal compiled into the tool. A ceiling only falls: a rewrite removes the places it
--- counts and lowers the number, and a file that goes over one is refused.
---
--- The file is text, a section per stage (`[checked]`) and a line per ceiling: a file, a code and a count, or for the stage
--- `generated` a file and a count, and for `hazards` a name and a count. A line that begins with `#` is a comment, and a comment before the lines it explains
--- says what brings them to zero. The stages are the checks of [`build.tree_checks`], and `scoped`, `declared` and
--- `checked` are also the stages of a compile ([`build.driver`]), whose [`Ceilings.over`] a compile calls for a module (`scoped`
--- for a module in the new grammar, `translated` for one that is the fork's Teal, translated): the tree's check of a file and
--- the build's refuse the same count, with the same words.
---
--- A ceiling is read at the start of a run, from the file or from a database the file filled; a caller that has neither
--- passes a table of its own.
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local String = require("cosmic.string")

local record Ceilings
  --- The stages a ceiling may name, in the order of the file.
  enum Stage
    "lexed"
    "translated"
    "scoped"
    "declared"
    "hazards"
    "generated"
    "checked"
  end

  --- An error of a file, as a check lists it.
  record Finding
    code: string
    y: integer
    x: integer
    msg: string
    fix: string
  end

  --- The ceilings of each stage, by stage: a key (`<file> <code>`, or `<file>` for `generated`) to its count.
  record Table
    stages: {string: {string: integer}}
  end

  --- The path of the data file below the root of the tree.
  path: string

  --- The ceilings `text` holds, or nil and what is wrong with it: a line of no section or of the wrong shape, a stage no
  --- check has, a count that is not a positive integer, a key that two lines give, and a key that can never be met: one
  --- of a stage that counts by code whose code is none of that stage's, or whose shape is not the stage's.
  parse: function(text: string): Table | nil, string

  --- The ceilings of the tree at `root` ([`Ceilings.path`]).
  read: function(root: string): Table | nil, string

  --- The keys of `ceilings` that name a file `root` lacks, one line each: a ceiling that no run can meet, since the check of
  --- the tree finds no error in a file that is not there. `hazards` names none.
  dead: function(root: string, ceilings: Table): {string}

  --- The ceilings of `stage` in `ceilings`: empty for a stage the table has none of.
  of: function(ceilings: Table, stage: Stage): {string: integer}

  --- What [`Ceilings.over`] found.
  record Held
    --- The errors over their ceilings, listed.
    lines: {string}
    --- The count of the errors of each code the file has, by key, for the check that a ceiling is not above what the file
    --- has.
    found: {string: integer}
  end

  --- The errors of the file `file` over its ceilings in `pinned`, listed: each error of a code over its ceiling with its
  --- place, message and fix, then a line that says how many there are and what the ceiling is (`pinned N`). `what` says
  --- where they are (`bodies`).
  over: function(file: string, errors: {Finding}, codes: {string}, pinned: {string: integer}, what: string): Held

  --- The ceilings of `pinned` that are above the counts in `found` (by key), one line each, with where to lower it.
  fallen: function(found: {string: integer}, pinned: {string: integer}, where: string): {string}
end

Ceilings.path = "build/ceilings.txt"

--- The codes of the errors each stage that counts by code counts.
local function codes_of(stage: string): {string} | nil
  if stage == "lexed" then
    return Lexer.codes
  elseif stage == "translated" then
    return Parser.codes
  elseif stage == "scoped" then
    return Scopes.codes
  elseif stage == "declared" then
    return Declarations.codes
  elseif stage == "checked" then
    return Check.codes
  end
  return nil
end

--- Why `key`, a ceiling of `stage`, can never be met, or "" where it can.
local function unmeetable(stage: string, key: string): string
  local codes = codes_of(stage)
  if codes == nil then
    if key:find("%s") ~= nil then
      return "a ceiling of [" .. stage .. "] is one word, not `" .. key .. "`"
    end
    return ""
  end
  local file, code = key:match("^(%S+) (%S+)$")
  if file == nil or code == nil then
    return "a ceiling of [" .. stage .. "] is a file and a code, not `" .. key .. "`"
  end
  for _, known in ipairs(codes) do
    if known == code then
      return ""
    end
  end
  return "`" .. code .. "` is no code of [" .. stage .. "]"
end

local STAGES <const>: {string: boolean} = {
  lexed = true, translated = true, scoped = true, declared = true, hazards = true, generated = true, checked = true,
}

function Ceilings.parse(text: string): Ceilings.Table | nil, string
  local out: Ceilings.Table = { stages = {} }
  local held: {string: integer} | nil = nil
  local stage = ""
  local number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local name = line:match("^%[([a-z]+)%]$")
      if name ~= nil then
        if STAGES[name] ~= true then
          return nil, Ceilings.path .. ":" .. tostring(number) .. ": no stage " .. name .. " in a check of the tree"
        end
        stage = name
        held = out.stages[name] or {}
        out.stages[name] = held
      else
        local key, count = line:match("^(%S.-)%s+(%d+)$")
        local n: integer | nil = nil
        if count ~= nil then
          n = math.tointeger(tonumber(count))
        end
        local at = Ceilings.path .. ":" .. tostring(number) .. ": "
        if held == nil then
          return nil, at .. "a ceiling before any [stage] line"
        elseif key == nil or n == nil or n < 1 then
          return nil, at .. "expected `<file> <code> <count>` with a count of 1 or more, not `" .. line .. "`"
        elseif held[key] ~= nil then
          return nil, at .. "`" .. key .. "` has a ceiling twice in [" .. stage .. "]"
        end
        local why = unmeetable(stage, key)
        if why ~= "" then
          return nil, at .. why
        end
        held[key] = n
      end
    end
  end
  return out, ""
end

function Ceilings.read(root: string): Ceilings.Table | nil, string
  local text, why = Fs.read(root .. "/" .. Ceilings.path)
  if text == nil then
    return nil, why
  end
  return Ceilings.parse(text)
end

function Ceilings.dead(root: string, ceilings: Ceilings.Table): {string}
  local out: {string} = {}
  for stage, held in pairs(ceilings.stages) do
    if stage ~= "hazards" then
      for key in pairs(held) do
        local file = key:match("^(%S+)")
        local there, _ = Fs.exists(root .. "/" .. file)
        if file ~= nil and there ~= true then
          out[#out + 1] = key .. ": pinned in [" .. stage .. "], and the tree has no file " .. file
        end
      end
    end
  end
  table.sort(out)
  return out
end

function Ceilings.of(ceilings: Ceilings.Table, stage: Ceilings.Stage): {string: integer}
  return ceilings.stages[tostring(stage)] or {}
end

function Ceilings.over(file: string, errors: {Ceilings.Finding}, codes: {string}, pinned: {string: integer},
                       what: string): Ceilings.Held
  local out: {string} = {}
  local found: {string: integer} = {}
  local by_code: {string: {Ceilings.Finding}} = {}
  for _, e in ipairs(errors) do
    local held = by_code[e.code] or {}
    held[#held + 1] = e
    by_code[e.code] = held
  end
  for _, code in ipairs(codes) do
    local list = by_code[code]
    if list ~= nil then
      local key = file .. " " .. code
      found[key] = #list
      local limit = pinned[key] or 0
      if #list > limit then
        for _, e in ipairs(list) do
          out[#out + 1] = file .. ":" .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. code .. "): " ..
            e.fix
        end
        out[#out + 1] = file .. ": " .. String.counted(#list, "error") .. " of " .. code .. " in its " .. what ..
          ", pinned " .. tostring(limit) .. "; follow the fix above rather than raise the pin"
      end
    end
  end
  return { lines = out, found = found }
end

function Ceilings.fallen(found: {string: integer}, pinned: {string: integer}, where: string): {string}
  local out: {string} = {}
  local keys: {string} = {}
  for key in pairs(pinned) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local count = found[key] or 0
    local limit = pinned[key]
    if limit ~= nil and count < limit then
      out[#out + 1] = key .. ": pinned " .. tostring(limit) .. " but " .. tostring(count) .. " found; lower the pin in " ..
        where
    end
  end
  return out
end

return Ceilings
