--- The declarations of the Lua standard library that the new checker reads differently from the fork
--- ([`checker/stdlib.d.tl`]), each a function that answers nil where Lua does and the declaration says it does not.
---
--- The file is the fork's, and the fork reads it too. A corrected signature goes in the file when the fork's own check
--- of the tree takes it (`io`, `os`, `debug`, `next`, `rawget` and the callbacks of `string.gsub` are there). It goes
--- here when the tree relies on the old one: the fork lets a result that may be nil be added, compared, indexed and
--- passed on, as `s:find(p) + 1` and `math.tointeger(x) > 0` do, and a corrected result would fail its check of the
--- tree at every such site (`string.byte`, `string.find`, `table.remove`, `tonumber`, `math.tointeger`, the position
--- `utf8.len` answers on a failure, `getmetatable`), or calls a result that may be nil (`load(text)()`).
---
--- [`Corrections.apply`] replaces, in the text of the file and before [`lang.translate`] reads it, every line a
--- correction names with the lines it gives. A correction holds the lines it replaces too, so that an edit to the file
--- that the correction does not know of is reported, and the correction is then dropped or changed. The lines are in the
--- fork's grammar, or in the new checker's where the fork has no spelling (`load` answers a chunk or nil).
--
-- TODO: write these declarations in the file and delete this module, once the new checker replaces the fork
-- ([`doc/plans/new-checker-types.md`], "the order the pieces land in", "the switch").
--
-- TODO: declare the functions that change a table they are given (`table.insert`, `table.remove`, `table.sort`,
-- `table.move`, `rawset`) with `mut {A}`, once the generics piece types a call of a generic function: the fork has no
-- spelling of `mut`, and until then a correction would change no verdict, since a call of them is `unchecked_generic`.
local record Corrections
  --- A declaration the new checker corrects.
  record Correction
    --- The record of the file the function is a field of: a library (`string`), or `StandardLibrary` for the globals.
    owner: string
    --- The function's name.
    name: string
    --- The lines of the file that declare it, one for each overload, without their indentation.
    was: {string}
    --- The lines that replace them, as many as `was` has, so that no line of the file moves.
    now: {string}
    --- What the declaration said that Lua does not do.
    why: string
  end

  --- The file with the corrections made.
  record Applied
    text: string
    --- A record a correction names that the file lacks, and a function whose lines are not those the correction
    --- replaces. The lines a problem is about are left as they are.
    problems: {string}
  end

  --- The corrections, in the order of the file.
  list: {Correction}

  --- `source`, the text of the file, with the corrections made.
  apply: function(source: string): Applied
end

Corrections.list = {
  {
    owner = "string", name = "byte",
    was = {
      "byte: function(string, ? integer): integer",
      "byte: function(string, integer, ? integer): integer...",
    },
    now = {
      "byte: function(string, ? integer): integer | nil",
      "byte: function(string, integer, ? integer): integer...",
    },
    why = "`s:byte(i)` answers no value for an `i` out of range, and the first overload says it answers an integer",
  },
  {
    owner = "string", name = "find",
    was = {
      "find: function(string, string, ? integer, ? boolean): integer, integer, string... --[[special_function]]",
    },
    now = {
      "find: function(string, string, ? integer, ? boolean): integer | nil, integer | nil, string...",
    },
    why = "a miss answers nil, and the declaration says it answers the two positions",
  },
  {
    owner = "table", name = "remove",
    was = { "remove: function<A>({A}, ? integer): A" },
    now = { "remove: function<A>({A}, ? integer): A | nil" },
    why = "removing from an empty array, or at a position past its end, answers nil",
  },
  {
    owner = "math", name = "tointeger",
    was = { "tointeger: function(any): integer" },
    now = { "tointeger: function(any): integer | nil" },
    why = "a value with no integer value, a fractional number or a string that is none, answers nil",
  },
  {
    owner = "StandardLibrary", name = "tonumber",
    was = {
      "tonumber: function(any): number",
      "tonumber: function(any, integer): integer",
    },
    now = {
      "tonumber: function(any): number | nil",
      "tonumber: function(any, integer): integer | nil",
    },
    why = "text that is no number answers nil",
  },
  {
    owner = "utf8", name = "len",
    was = { "len: function(string, ? number, ? number, ? boolean): integer | nil, integer" },
    now = { "len: function(string, ? number, ? number, ? boolean): integer | nil, integer | nil" },
    why = "a string that is not UTF-8 answers nil and the position of the byte, and a valid one answers the count alone",
  },
  {
    owner = "StandardLibrary", name = "getmetatable",
    was = { "getmetatable: function<T>(T): metatable<T>" },
    now = { "getmetatable: function<T>(T): metatable<T> | nil" },
    why = "a value without a metatable answers nil",
  },
  {
    owner = "StandardLibrary", name = "load",
    was = {
      "load: function((string | LoadFunction), ? string, ? LoadMode, ? {any:any}): (function, string)",
      "load: function((string | LoadFunction), ? string, ? string,   ? {any:any}): (function, string)",
    },
    now = {
      "load: function((string | LoadFunction), ? string, ? LoadMode, ? {any:any}): ((function(...: any): any...)?, string?)",
      "load: function((string | LoadFunction), ? string, ? string,   ? {any:any}): ((function(...: any): any...)?, string?)",
    },
    why = "text that does not compile answers nil and a message and a chunk answers only itself, and the chunk it makes takes " ..
      "any values and answers any",
  },
}

--- `line` without the spaces before and after it.
local function trimmed(line: string): string
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The indentation of `line`.
local function indentation(line: string): string
  return line:match("^(%s*)") or ""
end

--- Where the record `owner` is in `lines`: the first line of its body and the last, or nil.
local function body_of(lines: {string}, owner: string): integer | nil, integer | nil
  for i, line in ipairs(lines) do
    local text = trimmed(line)
    if text == "global record " .. owner or text == "local record " .. owner then
      local indent = indentation(line)
      for j = i + 1, #lines do
        if indentation(lines[j]) == indent and trimmed(lines[j]) == "end" then
          return i + 1, j - 1
        end
      end
      return nil
    end
  end
  return nil
end

function Corrections.apply(source: string): Corrections.Applied
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  local problems: {string} = {}
  for _, c in ipairs(Corrections.list) do
    local from, to = body_of(lines, c.owner)
    local at: {integer} = {}
    local field_indent: string | nil = nil
    if from ~= nil and to ~= nil then
      for i = from, to do
        local text = trimmed(lines[i])
        if text ~= "" and field_indent == nil then
          field_indent = indentation(lines[i])
        end
        if indentation(lines[i]) == field_indent and text:sub(1, #c.name + 1) == c.name .. ":" then
          at[#at + 1] = i
        end
      end
    end
    local label = c.owner .. "." .. c.name
    if from == nil then
      problems[#problems + 1] = label .. ": the file has no record " .. c.owner
    elseif #at ~= #c.was then
      problems[#problems + 1] = label .. ": the file declares it " .. #at .. " times, and the correction replaces " .. #c.was
    else
      local same = true
      for i, line in ipairs(at) do
        same = same and trimmed(lines[line]) == c.was[i]
      end
      if not same then
        problems[#problems + 1] = label .. ": the file declares it otherwise than the correction replaces"
      else
        for i, line in ipairs(at) do
          lines[line] = indentation(lines[line]) .. c.now[i]
        end
      end
    end
  end
  return { text = table.concat(lines, "\n"), problems = problems }
end

return Corrections
