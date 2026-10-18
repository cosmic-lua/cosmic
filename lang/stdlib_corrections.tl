--- The declarations of the Lua standard library that the new checker reads differently from the fork
--- ([`checker/stdlib.d.tl`]): a function that answers nil where Lua does and the declaration says it does not, one that
--- changes a collection it is given (`mut`), one that the fork types by a special case in its checker (`assert`), and
--- one that took any type (`math.abs`, `math.max`).
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
-- TODO: accept a function that answers `T...` as an argument of `pcall` and `xpcall`, once the grammar spells a list
-- with a tail among alternatives (`plist` in doc/plans/new-checker-grammar.md, "types"): `(true, R...) | (false, any)`
-- cannot be written until then, and a call that passes one is `overload_none`.
--
-- TODO: provide the typed `coroutine` library in the runtime, once the runtime cut keeps only the globals a `.d.tl`
-- declares (doc/plans/strict-teal.md, "the runtime cut"): the declarations here describe a body that is given a handle
-- and a `Coroutine` that is not a thread, and the runtime has Lua's own `coroutine`, which [`cosmic.poll`] calls.
local record Corrections
  --- A declaration the new checker corrects.
  record Correction
    --- The record of the file the function is a field of: a library (`string`), or `StandardLibrary` for the globals.
    owner: string
    --- The function's name.
    name: string
    --- The lines of the file that declare it, one for each overload, without their indentation.
    was: {string}
    --- The lines that replace them, one entry for each line of `was`. An entry may hold several lines, separated by
    --- `\n`, or none (""), so that a function the new checker declares as overloads is written as such.
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

  --- The declarations the file lacks, in the new checker's grammar, written at the end of the file's `do` block:
  --- the types of a typed coroutine.
  added: {string}

  --- The lines a correction writes for `owner.name`, one declaration to a line, or {} where there is none.
  lines: function(owner: string, name: string): {string}

  --- The declarations of `create` and `wrap` of a typed coroutine as overloads, one for each form a body takes (a handle
  --- and a value, a handle, neither) and each number of values it answers (none, one).
  coroutines: function(name: string): {string}

  --- The declarations of `pcall` (`handler` false) or `xpcall` as overloads, one for each number of values passed on
  --- (0 to `args`) and of values answered (0 to `rets`), written in the new checker's grammar: the result is
  --- `(true, R...) | (false, any)`, and for `xpcall` `(false, H | string)`: what the message handler answers, or the string Lua
  --- answers when the handler itself raises.
  protected: function(name: string, args: integer, rets: integer): {string}
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
    now = { "remove: function<A>(mut {A}, ? integer): A | nil" },
    why = "removing from an empty array, or at a position past its end, answers nil, and it changes the array",
  },
  {
    owner = "StandardLibrary", name = "assert",
    was = { "assert: function<A, B>(A | nil, ? B, ...: any): (A, B, any...) --[[special_function]]" },
    now = {
      "assert: function<A>(A | nil): A\nassert: function<A, B>(A | nil, B, ...: any): (A, B, any...)",
    },
    why = "a call with no message has no type for the message to be, and one with a message answers it too",
  },
  {
    owner = "table", name = "insert",
    was = { "insert: function<A>({A}, integer, A)", "insert: function<A>({A}, A)" },
    now = { "insert: function<A>(mut {A}, integer, A)", "insert: function<A>(mut {A}, A)" },
    why = "it changes the array it is given, which a view is not",
  },
  {
    owner = "table", name = "move",
    was = { "move: function<A>({A}, integer, integer, integer, ? {A}): {A}" },
    now = {
      "move: function<A>(mut {A}, integer, integer, integer): mut {A}\n" ..
        "move: function<A>({A}, integer, integer, integer, mut {A}): mut {A}",
    },
    why = "it copies into the array it answers, which is the destination if one is given and else the source",
  },
  {
    owner = "table", name = "sort",
    was = { "sort: function<A>({A}, ? SortFunction<A>)" },
    now = {
      "sort: function(mut {integer}, ? function(integer, integer): boolean)\n" ..
        "sort: function(mut {number}, ? function(number, number): boolean)\n" ..
        "sort: function(mut {string}, ? function(string, string): boolean)\n" ..
        "sort: function<A>(mut {A}, function(A, A): boolean)",
    },
    why = "it changes the array it is given, `SortFunction<A>` names a generic function type applied to an argument, and " ..
      "without a comparator it compares with `<`, which only numbers and strings take",
  },
  {
    owner = "StandardLibrary", name = "rawset",
    was = { "rawset: function<K, V>({K:V}, K, V): {K:V}" },
    now = { "rawset: function<K, V>(mut {K:V}, K, V): mut {K:V}" },
    why = "it changes the table it is given, which a view is not",
  },
  {
    owner = "math", name = "abs",
    was = { "abs: function<N is Numeric>(N): N" },
    now = { "abs: function(integer): integer\nabs: function(number): number" },
    why = "`Numeric` is an alias of a union, which no type parameter is bounded by, so any type was taken",
  },
  {
    owner = "math", name = "max",
    was = {
      "max: function(integer...): integer",
      "max: function((number | integer)...): number",
      "max: function<T>(T...): T",
      "max: function(any...): any",
    },
    now = {
      "max: function(integer, ...: integer): integer",
      "max: function(number, ...: number): number",
      "",
      "",
    },
    why = "Lua raises with no argument and for a value that is no number, and the last two overloads took any",
  },
  {
    owner = "math", name = "min",
    was = {
      "min: function(integer...): integer",
      "min: function((number | integer)...): number",
      "min: function<T>(T...): T",
      "min: function(any...): any",
    },
    now = {
      "min: function(integer, ...: integer): integer",
      "min: function(number, ...: number): number",
      "",
      "",
    },
    why = "Lua raises with no argument and for a value that is no number, and the last two overloads took any",
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

Corrections.added = {
  "global record Yielder<Y, S>",
  "   is userdata",
  "",
  "   yield: function(Yielder<Y, S>, Y): S",
  "end",
  "",
  "global record Coroutine<Y, R, S>",
  "   is userdata",
  "end",
}

function Corrections.lines(owner: string, name: string): {string}
  local out: {string} = {}
  for _, c in ipairs(Corrections.list) do
    if c.owner == owner and c.name == name then
      for _, entry in ipairs(c.now) do
        for line in (entry .. "\n"):gmatch("(.-)\n") do
          if line ~= "" then
            out[#out + 1] = line
          end
        end
      end
    end
  end
  return out
end

function Corrections.coroutines(name: string): {string}
  local out: {string} = {}
  for _, form in ipairs({ "both", "handle", "neither" }) do
    for r = 0, 1 do
      local params: {string} = {}
      local body = "function("
      local yields = form == "neither" and "never" or "Y"
      local sent = form == "both" and "S" or "nil"
      if form ~= "neither" then
        params[#params + 1] = "Y"
      end
      if r == 1 then
        params[#params + 1] = "R"
      end
      if form == "both" then
        params[#params + 1] = "S"
        body = body .. "Yielder<Y, S>, S"
      elseif form == "handle" then
        body = body .. "Yielder<Y, nil>"
      end
      body = body .. ")" .. (r == 1 and ": R" or "")
      local head = "function" .. (#params > 0 and "<" .. table.concat(params, ", ") .. ">" or "")
      local answers = r == 1 and "R" or "nil"
      if name == "create" then
        out[#out + 1] = "create: " .. head .. "(" .. body .. "): Coroutine<" .. yields .. ", " .. answers .. ", " .. sent .. ">"
      else
        local back: string
        if form == "neither" then
          back = r == 1 and ": R" or ""
        elseif r == 1 then
          back = ": Y | R"
        else
          back = ": Y?"
        end
        out[#out + 1] = "wrap: " .. head .. "(" .. body .. "): function(" .. (form == "both" and "S" or "") .. ")" .. back
      end
    end
  end
  return out
end

function Corrections.protected(name: string, args: integer, rets: integer): {string}
  local out: {string} = {}
  local handler = name == "xpcall"
  for n = 0, args do
    for r = 0, rets do
      local params: {string} = {}
      local passed: {string} = {}
      local answered: {string} = {}
      for i = 1, n do
        params[#params + 1] = "A" .. i
        passed[#passed + 1] = "A" .. i
      end
      for i = 1, r do
        params[#params + 1] = "R" .. i
        answered[#answered + 1] = "R" .. i
      end
      if handler then
        params[#params + 1] = "H"
      end
      local made = "function(" .. table.concat(passed, ", ") .. ")"
      if r == 1 then
        made = made .. ": R1"
      elseif r > 1 then
        made = made .. ": (" .. table.concat(answered, ", ") .. ")"
      end
      -- A function type is parenthesized where a parameter follows it, or the parameter would be a value it returns.
      local declared: {string} = { "(" .. made .. ")" }
      if handler then
        declared[#declared + 1] = "(function(any): H)"
      end
      for i = 1, n do
        declared[#declared + 1] = "A" .. i
      end
      local success = "true"
      if r > 0 then
        success = success .. ", " .. table.concat(answered, ", ")
      end
      out[#out + 1] = name .. ": function" .. (#params > 0 and "<" .. table.concat(params, ", ") .. ">" or "") .. "(" ..
        table.concat(declared, ", ") .. "): (" .. success .. ") | (false, " .. (handler and "H | string" or "any") .. ")"
    end
  end
  return out
end

table.insert(Corrections.list, {
  owner = "coroutine", name = "close",
  was = { "close: function(thread): boolean, string" },
  now = { "close: function<Y, R, S>(Coroutine<Y, R, S>): (true) | (false, any)" },
  why = "it answers a message only when closing failed, and a coroutine is a typed value",
})

table.insert(Corrections.list, {
  owner = "coroutine", name = "create",
  was = { "create: function(Function): thread" },
  now = { table.concat(Corrections.coroutines("create"), "\n") },
  why = "a coroutine is a `Coroutine<Y, R, S>`: the type it yields, answers and is sent, and its body gets the handle " ..
    "that yields, since no type says which coroutine a bare `yield` feeds",
})

table.insert(Corrections.list, {
  owner = "coroutine", name = "resume",
  was = { "resume: function(thread, any...): boolean, any..." },
  now = {
    "resume: function<Y, R>(Coroutine<Y, R, nil>): (true, Y | R) | (false, any)\n" ..
      "resume: function<Y, R, S>(Coroutine<Y, R, S>, S): (true, Y | R) | (false, any)",
  },
  why = "it sends the value the coroutine is sent, and answers what it yielded or returned, or the error that ended it",
})

table.insert(Corrections.list, {
  owner = "coroutine", name = "running",
  was = { "running: function(): thread, boolean" },
  now = { "" },
  why = "a program holds the handle of its coroutine, and `thread` is no type",
})

table.insert(Corrections.list, {
  owner = "coroutine", name = "status",
  was = { "status: function(thread): string" },
  now = {
    "enum Status\n   \"suspended\"\n   \"running\"\n   \"normal\"\n   \"dead\"\nend\n" ..
      "status: function<Y, R, S>(Coroutine<Y, R, S>): Status",
  },
  why = "the status of a coroutine is one of four strings, and a coroutine is a typed value",
})

table.insert(Corrections.list, {
  owner = "coroutine", name = "wrap",
  was = { "wrap: function(Function): function(any...): any..." },
  now = { table.concat(Corrections.coroutines("wrap"), "\n") },
  why = "the function it answers is sent the value the coroutine is, and answers what it yields or returns",
})

table.insert(Corrections.list, {
  owner = "coroutine", name = "yield",
  was = { "yield: function(any...): any..." },
  now = { "" },
  why = "`yield` is dynamically scoped, so no type says which coroutine a bare `yield` feeds: a coroutine yields through " ..
    "the handle its body is given",
})

table.insert(Corrections.list, {
  owner = "StandardLibrary", name = "pcall",
  was = { "pcall: function(function(any...):(any...), any...): boolean, any... --[[special_function]]" },
  now = { table.concat(Corrections.protected("pcall", 6, 3), "\n") },
  why = "its result is the tagged alternatives of a call that returned the values of the function and of one that raised, " ..
    "and what it answers depends on the values passed and answered, which no type pack is adopted to say",
})

table.insert(Corrections.list, {
  owner = "StandardLibrary", name = "xpcall",
  was = { "xpcall: function(function(any...):(any...), XpcallMsghFunction, any...): boolean, any... --[[special_function]]" },
  now = { table.concat(Corrections.protected("xpcall", 3, 3), "\n") },
  why = "its failure is what the message handler answers, or the string Lua answers when the handler raises, and the rest is as " ..
    "for `pcall`",
})

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
          local indent = indentation(lines[line])
          local written: {string} = {}
          for part in (c.now[i] .. "\n"):gmatch("(.-)\n") do
            written[#written + 1] = part == "" and "" or indent .. part
          end
          lines[line] = table.concat(written, "\n")
        end
      end
    end
  end
  for i = #lines, 1, -1 do
    if trimmed(lines[i]) == "end" then
      for k = #Corrections.added, 1, -1 do
        local line = Corrections.added[k]
        table.insert(lines, i, line == "" and "" or "   " .. line)
      end
      break
    end
  end
  return { text = table.concat(lines, "\n"), problems = problems }
end

return Corrections
