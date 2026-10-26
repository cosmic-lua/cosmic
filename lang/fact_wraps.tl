--- The calls of `__fact` that check what [`lang.check`] concluded of a read at run time: the arguments a caller of
--- [`lang.codegen`] gives as its `wraps`. Each read of a place whose type a test narrowed ([`Check.Narrowed`]) is written
--- `__fact(v, taken, place, strings, classes, tag, tags, at)` (after a definition on the first line of the chunk that answers
--- `v` where no hook is defined), where
---
--- * `taken` is the kinds of value (`type`'s words) the checker took the read to have none of, joined by ",";
--- * `place` is the place as the program writes it;
--- * `strings`, `classes`, and `tag` and `tags` are what it concluded of an enum, of the classes (their tables, whose
---   metatable a value there has) and of the field and values that tell a union's members apart, each nil where it
---   concluded nothing (`tags` is the values joined by ",", a string constant a hook keeps the set of);
--- * `at` is `<file>:<line>:<column>` of the read, since the place cannot be found from the call: a read at a `return`
---   is a tail call, which leaves no frame to ask.
---
--- A narrowing is checked once, not at every read ([`FactWraps.once`]): the reads of the same narrowing of the same place
--- that follow a checked one, in a region it dominates, with no call, write or loop between, carry no call of `__fact`. The
--- read of a tag of a union (`x.kind`) carries none either, as it relies on nothing the narrowing says.
---
--- The hook answers `v`, or raises where the conclusion is false of it ([`build.test_worker`]'s `install_checks` defines
--- one for a checked run; [`lang.check_programs`] defines another for the tests of the checker). A chunk with wraps begins,
--- on its first line, by defining one that answers `v` where there is none ([`lang.codegen`]), so the program that runs wrapped
--- code before the worker installs the hook (the worker's own libraries) or in a process that defines none (a relay, a
--- process a test starts) gets the value all the same.
--
-- A checked run writes the facts alone: the fork's checks of arguments, return values and record fields (its "p", "r" and
-- "f" specs of `__cosmic_tc`) went with it. They reported and failed nothing, and the checker keeps nil out of every type
-- itself, so what they could still report is what an `any` or an unchecked binding lets through.
--
-- TODO: keep the name of the place in the error of a wrapped read, once a test of the suite is found to match one: the full
-- checked-narrowing run (`cosmic test --check-types`) shows none, but `x + 1` of a wrapped `x` says "attempt to perform
-- arithmetic on a nil value" and has lost "(local 'x')", as a call or an index does, for the operand is the result of a call.
local Ast = require("lang.ast")
local Check = require("lang.check")

local record FactWraps
  --- The arguments after the value of the call of `__fact` that wraps the read `n`, which is at `at`.
  arguments: function(n: Check.Narrowed, at: string): string

  --- The arguments of every read of `narrowed` (the reads of a module whose text is `source`, named `file`), by the id
  --- of the node of the read: the `wraps` of [`lang.codegen`]'s `generate`.
  of: function(narrowed: {Check.Narrowed}, source: string, file: string, chunk?: Ast.Chunk): {integer: string}

  --- The reads of `narrowed` (the reads of the module `chunk`) that a run checks: the first read of a narrowing, where
  --- nothing since the last read of it can have changed what it holds, in place of every read of it.
  once: function(narrowed: {Check.Narrowed}, chunk: Ast.Chunk): {Check.Narrowed}
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
local function strings_or_nil(list: {string}?): string
  if list == nil then
    return "nil"
  end
  return lua_strings(list)
end

--- The values of `list` joined by "," as a Lua string literal, or `nil` where it is none: the form a hook finds a set of by
--- text, which a table written at each read would cost an allocation and a scan of the list for. A value has no ",".
local function joined_or_nil(list: {string}?): string
  if list == nil then
    return "nil"
  end
  return quoted(table.concat(list, ","))
end

--- The Lua text of `text`, or `nil` where it is.
local function quoted_or_nil(text: string?): string
  if text == nil then
    return "nil"
  end
  return quoted(text)
end

-- What the walk of [`FactWraps.once`] keeps.
local record Walk
  --- The narrowed reads, by the id of the node of the read, and the text that says which narrowing and which place each is.
  want: {integer: Check.Narrowed}
  mut keys: {integer: string}
  --- How many writes and calls the walk has passed: a narrowing noted at one count holds at the same count only.
  mut epoch: integer
  --- The count at which each narrowing was last noted as checked.
  marks: mut {string: integer}
  --- The narrowings noted in each region the walk is in, innermost last: the code of a region may not run, so what it
  --- noted is dropped as the walk leaves it.
  log: mut {mut {string}}
  --- The reads that are the object of a read of their own tag: the field is in every member, and the read relies on no
  --- narrowing of the place.
  mut exempt: mut {integer: boolean}
  --- The reads that an earlier read in the same run covers.
  skip: mut {integer: boolean}
end

local function enter(w: Walk)
  w.log[#w.log + 1] = {}
end

local function leave(w: Walk)
  local noted = table.remove(w.log)
  if noted ~= nil then
    for _, key in ipairs(noted) do
      w.marks[key] = nil
    end
  end
end

--- The read `id`: skipped where the same narrowing of the same place was checked since the last write or call, in a region the
--- read is in, and noted otherwise.
local function read(w: Walk, id: integer)
  local key = w.keys[id]
  if key == nil then
    return
  end
  if w.exempt[id] == true then
    w.skip[id] = true
    return
  end
  local at = w.epoch
  if w.marks[key] == at then
    w.skip[id] = true
    return
  end
  w.marks[key] = at
  local noted = w.log[#w.log]
  if noted ~= nil then
    noted[#noted + 1] = key
  end
end

--- The Lua of a place's identity: the variable it starts at, and the text of the place.
local function root_of(n: Ast.Node): integer
  local at: Ast.Node = n
  while true do
    if (at.kind == "Field") then
      at = at.object
    elseif (at.kind == "Index") then
      at = at.object
    elseif (at.kind == "Paren") then
      at = at.inner
    else
      break
    end
  end
  if (at.kind == "Name") then
    return at.binding or 0
  end
  return -1
end

local function walk_node(w: Walk, n: Ast.Node)
  if (n.kind == "Block") then
    enter(w)
    for _, each in ipairs(n.stats) do
      walk_node(w, each)
    end
    leave(w)
  elseif (n.kind == "Field") then
    -- `x.kind` of a tagged union is valid whatever `x` was narrowed to: its tag is in every member. A narrowing that takes no
    -- kind of value away (so `x` is not nil) is not relied on by the read, and the read is what a chain of tests is made of.
    local object = w.want[n.object.id]
    if object ~= nil and object.tag == n.name and #object.taken == 0 and object.strings == nil and object.classes == nil then
      w.exempt[n.object.id] = true
    end
    walk_node(w, n.object)
  elseif (n.kind == "Call") then
    walk_node(w, n.callee)
    for _, each in ipairs(n.args) do
      walk_node(w, each)
    end
    w.epoch = w.epoch + 1
  elseif (n.kind == "MethodCall") then
    walk_node(w, n.object)
    for _, each in ipairs(n.args) do
      walk_node(w, each)
    end
    w.epoch = w.epoch + 1
  elseif (n.kind == "Binary") and (n.op == "and" or n.op == "or") then
    -- `a and b and c` runs `c` only where `a` and `b` ran, and so does `or`: the operands after the first are one region.
    local rest: mut {Ast.Node} = {}
    local at: Ast.Node = n
    while (at.kind == "Binary") and at.op == n.op do
      rest[#rest + 1] = at.right
      at = at.left
    end
    walk_node(w, at)
    enter(w)
    for i = #rest, 1, -1 do
      walk_node(w, assert(rest[i]))
    end
    leave(w)
  elseif (n.kind == "IfExp") then
    for i, arm in ipairs(n.arms) do
      if i == 1 then
        walk_node(w, arm.cond)
        enter(w)
        walk_node(w, arm.value)
        leave(w)
      else
        enter(w)
        walk_node(w, arm.cond)
        walk_node(w, arm.value)
        leave(w)
      end
    end
    enter(w)
    walk_node(w, n.else_value)
    leave(w)
  elseif (n.kind == "If") then
    for i, arm in ipairs(n.arms) do
      if i == 1 then
        walk_node(w, arm.cond)
        walk_node(w, arm.body)
      else
        enter(w)
        walk_node(w, arm.cond)
        walk_node(w, arm.body)
        leave(w)
      end
    end
    if n.else_body ~= nil then
      walk_node(w, n.else_body)
    end
  elseif (n.kind == "While") then
    -- A loop runs again: nothing known before it holds in it, nor after it.
    w.epoch = w.epoch + 1
    enter(w)
    walk_node(w, n.cond)
    walk_node(w, n.body)
    leave(w)
    w.epoch = w.epoch + 1
  elseif (n.kind == "Repeat") then
    w.epoch = w.epoch + 1
    enter(w)
    walk_node(w, n.body)
    walk_node(w, n.cond)
    leave(w)
    w.epoch = w.epoch + 1
  elseif (n.kind == "ForNum") then
    walk_node(w, n.from)
    walk_node(w, n.to)
    if n.step ~= nil then
      walk_node(w, n.step)
    end
    w.epoch = w.epoch + 1
    enter(w)
    walk_node(w, n.body)
    leave(w)
    w.epoch = w.epoch + 1
  elseif (n.kind == "ForIn") then
    for _, each in ipairs(n.iterators) do
      walk_node(w, each)
    end
    w.epoch = w.epoch + 1
    enter(w)
    walk_node(w, n.body)
    leave(w)
    w.epoch = w.epoch + 1
  elseif (n.kind == "Match") then
    walk_node(w, n.scrutinee)
    w.epoch = w.epoch + 1
    for _, arm in ipairs(n.arms) do
      enter(w)
      walk_node(w, arm.body)
      leave(w)
    end
    w.epoch = w.epoch + 1
  elseif (n.kind == "Assign") then
    for _, each in ipairs(n.values) do
      walk_node(w, each)
    end
    for _, each in ipairs(n.targets) do
      walk_node(w, each)
    end
    w.epoch = w.epoch + 1
  elseif (n.kind == "Fn") or (n.kind == "Method") then
    -- The body runs when the function is called, which may be anywhere.
    w.epoch = w.epoch + 1
    walk_node(w, n.body)
    w.epoch = w.epoch + 1
  else
    Ast.children(n, function(child: Ast.Node)
      walk_node(w, child)
    end)
  end
  read(w, n.id)
end

function FactWraps.once(narrowed: {Check.Narrowed}, chunk: Ast.Chunk): {Check.Narrowed}
  local want: mut {integer: Check.Narrowed} = {}
  for _, n in ipairs(narrowed) do
    want[n.id] = n
  end
  local roots: mut {integer: integer} = {}
  local w: Walk = { want = want, keys = {}, exempt = {}, epoch = 0, marks = {}, log = {}, skip = {} }
  -- The place of each read is told by the variable it starts at: a name that is another variable is another place.
  local function root_all(n: Ast.Node)
    if want[n.id] ~= nil then
      roots[n.id] = root_of(n)
    end
    Ast.children(n, root_all)
  end
  root_all(chunk)
  local keys: mut {integer: string} = {}
  for id, n in pairs(want) do
    local root = roots[id]
    if root ~= nil and root >= 0 then
      keys[id] = table.concat({
        tostring(root), n.text, table.concat(n.taken, ","), table.concat(n.strings or {}, ","),
        table.concat(n.classes or {}, ","), n.tag or "", table.concat(n.tags or {}, ","),
      }, "\0")
    end
  end
  w.keys = keys
  enter(w)
  walk_node(w, chunk)
  leave(w)
  local out: mut {Check.Narrowed} = {}
  for _, n in ipairs(narrowed) do
    if w.skip[n.id] ~= true then
      out[#out + 1] = n
    end
  end
  return out
end

function FactWraps.arguments(n: Check.Narrowed, at: string): string
  local classes = n.classes
  local table_classes = "nil"
  if classes ~= nil then
    table_classes = "{" .. table.concat(classes, ", ") .. "}"
  end
  return table.concat({
    quoted(table.concat(n.taken, ",")), quoted(n.text), strings_or_nil(n.strings), table_classes, quoted_or_nil(n.tag),
    joined_or_nil(n.tags), quoted(at),
  }, ", ")
end

function FactWraps.of(narrowed: {Check.Narrowed}, source: string, file: string, chunk?: Ast.Chunk): {integer: string}
  local wraps: mut {integer: string} = {}
  if chunk ~= nil then
    narrowed = FactWraps.once(narrowed, chunk)
  end
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
