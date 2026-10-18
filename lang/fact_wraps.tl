--- The calls of `__fact` that check what [`lang.check`] concluded of a read at run time: the arguments a caller of
--- [`lang.codegen`] gives as its `wraps`. Each read of a place whose type a test narrowed ([`Check.Narrowed`]) is written
--- `__fact(v, taken, place, strings, classes, tag, tags, at)`, where
---
--- * `taken` is the kinds of value (`type`'s words) the checker took the read to have none of, joined by ",";
--- * `place` is the place as the program writes it;
--- * `strings`, `classes`, and `tag` and `tags` are what it concluded of an enum, of the classes (their tables, whose
---   metatable a value there has) and of the field and values that tell a union's members apart, each nil where it
---   concluded nothing;
--- * `at` is `<file>:<line>:<column>` of the read, since the place cannot be found from the call: a read at a `return`
---   is a tail call, which leaves no frame to ask.
---
--- The hook answers `v`, or raises where the conclusion is false of it ([`build.test_worker`]'s `install_checks` defines
--- one for a checked run; [`lang.check_programs`] defines another for the tests of the checker).
--
-- TODO: check the arguments, return values and record fields written at run time as the fork's "p", "r" and "f" specs of
-- `__cosmic_tc` do (build/test_worker.tl), which [`lang.codegen`] writes none of, once the tool wires `--check-types` to
-- the new checker (doc/plans/strict-teal.md, "the switch"): they report and fail nothing until nil is out of every type.
--
-- TODO: define `__fact` wherever wrapped code can run, or compile the modules of a test's child process without the
-- wraps, once the tool wires `--check-types` to the new checker (doc/plans/strict-teal.md, "the switch"): only the test
-- worker's `install_checks` defines the global, so a wrapped chunk in a child process raises "attempt to call a nil value
-- (global '__fact')", where the fork's checked compile falls back to `select` and answers the value.
--
-- TODO: keep the name of the place in the error of a wrapped read, once the tool wires `--check-types` to the new
-- checker (doc/plans/strict-teal.md, "the switch") shows whether a test matches one: `x + 1` of a wrapped `x` says
-- "attempt to perform arithmetic on a nil value" and has lost "(local 'x')", as a call or an index does, for the
-- operand is the result of a call.
local Check = require("lang.check")

local record FactWraps
  --- The arguments after the value of the call of `__fact` that wraps the read `n`, which is at `at`.
  arguments: function(n: Check.Narrowed, at: string): string

  --- The arguments of every read of `narrowed` (the reads of a module whose text is `source`, named `file`), by the id
  --- of the node of the read: the `wraps` of [`lang.codegen`]'s `generate`.
  of: function(narrowed: {Check.Narrowed}, source: string, file: string): {integer: string}
end

--- `text` as a Lua string literal, on one line.
local function quoted(text: string): string
  return (string.format("%q", text):gsub("\\\n", "\\n"))
end

--- The Lua text of the strings of `list`, as a table.
local function lua_strings(list: {string}): string
  local out = ""
  for i, v in ipairs(list) do
    if i > 1 then
      out = out .. ", "
    end
    out = out .. quoted(v)
  end
  return "{" .. out .. "}"
end

--- The Lua text of `list`, or `nil` where it is.
local function strings_or_nil(list: {string} | nil): string
  if list == nil then
    return "nil"
  end
  return lua_strings(list)
end

--- The Lua text of `text`, or `nil` where it is.
local function quoted_or_nil(text: string | nil): string
  if text == nil then
    return "nil"
  end
  return quoted(text)
end

function FactWraps.arguments(n: Check.Narrowed, at: string): string
  local classes = n.classes
  local table_classes = "nil"
  if classes ~= nil then
    table_classes = "{" .. table.concat(classes, ", ") .. "}"
  end
  return table.concat({
    quoted(table.concat(n.taken, ",")), quoted(n.text), strings_or_nil(n.strings), table_classes, quoted_or_nil(n.tag),
    strings_or_nil(n.tags), quoted(at),
  }, ", ")
end

function FactWraps.of(narrowed: {Check.Narrowed}, source: string, file: string): {integer: string}
  local wraps: {integer: string} = {}
  -- The reads are in source order: the line and the start of the line are carried from one to the next.
  local line, line_start, scanned = 1, 1, 1
  for _, n in ipairs(narrowed) do
    if n.offset < scanned then
      line, line_start, scanned = 1, 1, 1
    end
    while true do
      local newline = source:find("\n", scanned, true)
      if newline == nil or newline >= n.offset then
        break
      end
      line, line_start, scanned = line + 1, newline + 1, newline + 1
    end
    wraps[n.id] = FactWraps.arguments(n, file .. ":" .. tostring(line) .. ":" .. tostring(n.offset - line_start + 1))
  end
  return wraps
end

return FactWraps
