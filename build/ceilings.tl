--- The ceilings of the new checker: how many errors of each code each file of the tree may still have, per stage, as data
--- in [`build/ceilings.txt`] and not as Teal compiled into the tool. A ceiling only falls: a rewrite removes the places it
--- counts and lowers the number, and a file that goes over one is refused.
---
--- The file is text, a section per stage (`[checked]`) and a line per ceiling: a file, a code and a count, or for the stage
--- `untyped` a file and a count. A line that begins with `#` is a comment, and a comment before the lines it explains
--- says what brings them to zero. Each ceiling line stands alone between blank lines ([`Ceilings.crowded`]), so two pull
--- requests that move neighbouring pins merge. The stages are the checks of [`build.tree_checks`], and `scoped`, `declared` and
--- `checked` are also the stages of a compile ([`build.driver`]), whose [`Ceilings.over`] a compile calls for a module: the
--- tree's check of a file and the build's refuse the same count, with the same words.
--- `examples` is the check of the examples a reader copies ([`build.example_checks`]): a key is an
--- example file or a guide and a code of any stage, and a count is the findings of that code in all of its examples.
---
--- `testdata` is the check of the Teal under `ci/testdata` ([`build.tree_checks`]'s `ci_testdata`):
--- a key is a file and a code of any stage, and a count is the findings of that code in the file.
---
--- A ceiling is read at the start of a run, from the file or from a database the file filled; a caller that has neither
--- passes a table of its own.
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Fs = require("cosmic.fs")
local Scopes = require("lang.scopes")
local String = require("cosmic.string")

local record Ceilings
  --- The stages a ceiling may name, in the order of the file.
  enum Stage
    "scoped"
    "declared"
    "untyped"
    "checked"
    "examples"
    "testdata"
  end

  --- An error of a file, as a check lists it.
  record Finding
    code: string
    y: integer
    x: integer
    msg: string
    fix: string
  end

  --- The ceilings of each stage, by stage: a key (`<file> <code>`, or `<file>` for `untyped`) to its count.
  record Table
    stages: mut {string: {string: integer}}
    --- Whether the tree has no ceilings to be held to and none to raise: a project's. An error over a ceiling of 0 is then
    --- listed without the pin that is not there.
    none: boolean?
  end

  --- The path of the data file below the root of the tree.
  path: string

  --- The ceilings `text` holds, or nil and what is wrong with it: a line of no section or of the wrong shape, a stage no
  --- check has, a count that is not a positive integer, a key that two lines give, and a key that can never be met: one
  --- of a stage that counts by code whose code is none of that stage's, or whose shape is not the stage's.
  parse: function(text: string): Table?, string

  --- The ceilings of the tree at `root` ([`Ceilings.path`]).
  read: function(root: string): Table?, string

  --- The ceiling lines of `text` that a line follows directly, one line of message each with its place, or "" where there
  --- are none. A ceiling stands alone between blank lines (a comment may sit directly above the one it explains, and a
  --- `[stage]` line above its first): git merges two changes only where an unchanged line lies between them, so a
  --- ceiling that has a neighbour conflicts with every change to that neighbour, and most pull requests move some pin.
  crowded: function(text: string): string

  --- The keys of `ceilings` that name a file `root` lacks, one line each: a ceiling that no run can meet, since the check of
  --- the tree finds no error in a file that is not there.
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
  --- where they are (`bodies`). With `unpinned` (a tree without ceilings, [`Table.none`]) that line says the count alone.
  over: function(file: string, errors: {Finding}, codes: {string}, pinned: {string: integer}, what: string,
                 unpinned?: boolean): Held

  --- The ceilings of `pinned` that are above the counts in `found` (by key), one line each, with where to lower it.
  fallen: function(found: {string: integer}, pinned: {string: integer}, where: string): {string}
end

Ceilings.path = "build/ceilings.txt"

--- The codes of the errors each stage that counts by code counts.
local function codes_of(stage: string): {string}?
  if stage == "scoped" then
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
  if stage == "examples" or stage == "testdata" then
    -- A finding of an example or of a file of ci/testdata is of any stage's code, so the shape is all that can be held.
    if key:match("^%S+ %S+$") == nil then
      return "a ceiling of [" .. stage .. "] is a file and a code, not `" .. key .. "`"
    end
    return ""
  end
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
  scoped = true, declared = true, untyped = true, checked = true, examples = true, testdata = true,
}

function Ceilings.parse(text: string): Ceilings.Table?, string
  local out: Ceilings.Table = { stages = {}, none = nil }
  local held: mut {string: integer}? = nil
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
        local n: integer? = nil
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

function Ceilings.crowded(text: string): string
  local out = ""
  local number = 0
  -- The line before the one being read where it is a ceiling, else "".
  local before = ""
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if before ~= "" and line ~= "" then
      out = out .. Ceilings.path .. ":" .. tostring(number - 1) .. ": `" .. before ..
        "` is followed directly by another line: a ceiling stands alone between blank lines, " ..
        "so that a change to its neighbour merges with a change to it\n"
    end
    if line ~= "" and line:sub(1, 1) ~= "#" and line:match("^%[[a-z]+%]$") == nil then
      before = line
    else
      before = ""
    end
  end
  return out
end

function Ceilings.read(root: string): Ceilings.Table?, string
  local text, why = Fs.read(root .. "/" .. Ceilings.path)
  if text == nil then
    return nil, why
  end
  return Ceilings.parse(text)
end

function Ceilings.dead(root: string, ceilings: Ceilings.Table): {string}
  local out: mut {string} = {}
  for stage, held in pairs(ceilings.stages) do
    for key in pairs(held) do
      local file = key:match("^(%S+)")
      local there, _ = Fs.exists(root .. "/" .. file)
      if file ~= nil and there ~= true then
        out[#out + 1] = key .. ": pinned in [" .. stage .. "], and the tree has no file " .. file
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
                       what: string, unpinned?: boolean): Ceilings.Held
  local out: mut {string} = {}
  local found: mut {string: integer} = {}
  local by_code: mut {string: {Ceilings.Finding}} = {}
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
        local tail = "; follow the fix above"
        if unpinned ~= true then
          tail = ", pinned " .. tostring(limit) .. tail .. " rather than raise the pin"
        end
        out[#out + 1] = file .. ": " .. String.counted(#list, "error") .. " of " .. code .. " in its " .. what .. tail
      end
    end
  end
  return { lines = out, found = found }
end

function Ceilings.fallen(found: {string: integer}, pinned: {string: integer}, where: string): {string}
  local out: mut {string} = {}
  local keys: mut {string} = {}
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
