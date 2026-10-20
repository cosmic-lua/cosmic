--- The calls of `__fact` that check what [`lang.check`] concluded of a read at run time: the arguments a caller of
--- [`lang.codegen`] gives as its `wraps`. Each read of a place whose type a test narrowed ([`Check.Narrowed`]) is written
--- `__fact(v, taken, place, strings, classes, tag, tags, at)` (after a definition on the first line of the chunk that answers
--- `v` where no hook is defined), where
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
--- one for a checked run; [`lang.check_programs`] defines another for the tests of the checker). A chunk with wraps begins,
--- on its first line, by defining one that answers `v` where there is none ([`lang.codegen`]), so the program that runs wrapped
--- code before the worker installs the hook (the worker's own libraries) or in a process that defines none (a relay, a
--- process a test starts) gets the value all the same.
--
-- TODO: check the arguments, return values and record fields written at run time as the fork's "p", "r" and "f" specs of
-- `__cosmic_tc` do (build/test_worker.tl), which [`lang.codegen`] writes none of: a checked run in the new mode
-- (`COSMIC_GRAMMAR=new cosmic test --check-types`) writes the facts alone. Once the switch (doc/plans/strict-teal.md, "the
-- switch") decides whether `--check-types` keeps them: they report and fail nothing, and the new checker keeps nil out of
-- every type itself, so what they could still report is what an `any`, an unchecked binding or a cast lets through.
--
-- TODO: keep the name of the place in the error of a wrapped read, once a test of the suite is found to match one: the full
-- checked run in the new mode (the rehearsal's) shows none, but `x + 1` of a wrapped `x` says "attempt to perform
-- arithmetic on a nil value" and has lost "(local 'x')", as a call or an index does, for the operand is the result of a call.
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
