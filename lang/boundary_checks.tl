--- The calls of `__cosmic_tc` that check at run time what [`lang.check`] listed as a typed boundary
--- ([`Check.Checked.boundaries`]): the `checks` a caller of [`lang.codegen`] gives as its argument. A function with typed
--- parameters begins, on the line of the `)` of its parameters (which moves none), with
---
--- ```text
--- if __cosmic_tc and (<mismatch>) then __cosmic_tc(2, "p;<file>:<line>;<function>;<name>=<kinds>;...", <name>, ...) end
--- ```
---
--- where `<mismatch>` is true of a value the hook would record: a parameter is tested by its kinds on the spot (`__cosmic_ty(x)
--- ~= "table"`, `__cosmic_mt(x) ~= "integer"`, `x ~= nil`; the tests of a parameter's kinds joined by `and`, those of the
--- parameters by `or`), so that a call whose values all fit costs a few comparisons and no call of the hook, which a hot
--- function would otherwise pay at every entry. The spec is a literal, read only on a mismatch. `__cosmic_ty` and
--- `__cosmic_mt` are `type` and `math.type`, which [`build.test_worker`]'s `install_checks` defines with the hook: a program's
--- own `type` (a parameter of that name) cannot stand in their place.
---
--- where `<line>` is the line the function begins on and `<kinds>` the kinds of Lua value its parameter's type admits,
--- joined by "|" ([`lang.boundaries`]'s `spec`). The hook ([`build.test_worker`]'s `install_checks` defines one for a checked
--- run) answers nothing and fails nothing: it records a value of another kind as a violation that names the caller's line,
--- and the function runs on. A statement of its own, not a wrapper, so that the body is as it was written: a tail call
--- stays a tail call and the values a `return` gives are the body's own. Where no hook is defined (a process a test
--- starts, a library the worker loads before it installs its own) the test of `__cosmic_tc` skips the call.
---
--- A parameter is left out where its type says nothing of its value (`any`, a type variable), and so are the variadic
--- one and `self`; a function with none left has no statement.
-- TODO: check the parameters of a function literal that takes its types from where it is passed, and the class a table
-- parameter is an instance of ([`Boundaries.Kinds.classes`]), once a report of either is shown to hold no row a test planted:
-- only the parameters a program types are checked, and only by the kinds of Lua value their types admit.
local Boundaries = require("lang.boundaries")
local Check = require("lang.check")

local record BoundaryChecks
  --- The Lua test that the value of the variable `name` is none of `kinds` (the list of [`Boundaries.Kinds`]): true of
  --- exactly the values the worker's hook records as a violation of them.
  mismatch: function(name: string, kinds: {string}): string

  --- The statement that checks the parameters of the function whose parameters are `rows` (all the rows of one function,
  --- by `param`), placed `at` the line the function begins on of the file `file`; nil where no parameter is checked.
  statement: function(rows: {Check.Boundary}, file: string, line: integer): string?

  --- The statement of every function of `boundaries` (the functions of a module whose text is `source`, named `file`), by
  --- the id of the function's node: the `checks` of [`lang.codegen`]'s `generate`.
  of: function(boundaries: {Check.Boundary}, source: string, file: string): {integer: string}
end

--- `text` as a Lua string literal, on one line.
local function quoted(text: string): string
  return (string.format("%q", text):gsub("\\\n", "\\n"))
end

--- A field of the worker's spec: it is split at ";", so none may hold one.
local function field(text: string): string
  return (text:gsub(";", ","))
end

local function among(list: {string}, word: string): boolean
  for _, each in ipairs(list) do
    if each == word then
      return true
    end
  end
  return false
end

--- The test, in Lua, that `name` is none of the `kinds` (the list of [`Boundaries.Kinds`]): true of exactly the values the
--- hook records as a violation of them. `__cosmic_ty` and `__cosmic_mt` are the worker's `type` and `math.type` as it took
--- them, which no local of the program (a parameter named `type`) can shadow.
function BoundaryChecks.mismatch(name: string, kinds: {string}): string
  local tests: mut {string} = {}
  -- A nil is the cheapest to rule out: it comes first.
  if among(kinds, "nil") then
    tests[1] = name .. " ~= nil"
  end
  for _, kind in ipairs(kinds) do
    if kind == "nil" then
      -- Tested already.
    elseif kind == "integer" then
      tests[#tests + 1] = "__cosmic_mt(" .. name .. ') ~= "integer"'
    else
      tests[#tests + 1] = "__cosmic_ty(" .. name .. ') ~= "' .. kind .. '"'
    end
  end
  if #tests == 0 then
    return "true"
  end
  local joined = table.concat(tests, " and ")
  if #tests == 1 then
    return joined
  end
  return "(" .. joined .. ")"
end

function BoundaryChecks.statement(rows: {Check.Boundary}, file: string, line: integer): string?
  local first = rows[1]
  if first == nil then
    return nil
  end
  local spec: mut {string} = { "p", field(file) .. ":" .. tostring(line), field(first.owner) }
  local names: mut {string} = {}
  local tests: mut {string} = {}
  -- A name given to two parameters (`_`) is the later one in the body: the earlier cannot be passed on by name.
  local given: mut {string: integer} = {}
  for _, row in ipairs(rows) do
    given[row.name] = (given[row.name] or 0) + 1
  end
  for _, row in ipairs(rows) do
    local kinds = Boundaries.kinds(row.type)
    if kinds ~= nil and given[row.name] == 1 then
      local list = kinds.list
      if row.optional and not among(list, "nil") then
        local more: mut {string} = {}
        for _, each in ipairs(list) do
          more[#more + 1] = each
        end
        more[#more + 1] = "nil"
        list = more
      end
      spec[#spec + 1] = row.name .. "=" .. Boundaries.spec({ list = list, strings = nil, classes = nil })
      names[#names + 1] = row.name
      tests[#tests + 1] = BoundaryChecks.mismatch(row.name, list)
    end
  end
  if #names == 0 then
    return nil
  end
  local joined = table.concat(tests, " or ")
  if #tests > 1 then
    joined = "(" .. joined .. ")"
  end
  return "if __cosmic_tc and " .. joined .. " then __cosmic_tc(2, " .. quoted(table.concat(spec, ";")) .. ", " .. table.concat(names, ", ") .. ") end"
end

function BoundaryChecks.of(boundaries: {Check.Boundary}, source: string, file: string): {integer: string}
  -- The rows of one function are together: the list is in the order of `at`, then of the function, then of the parameter.
  local groups: mut {mut {Check.Boundary}} = {}
  local last = -1
  for _, row in ipairs(boundaries) do
    if row.id ~= last then
      groups[#groups + 1] = {}
      last = row.id
    end
    local group = groups[#groups]
    if group ~= nil then
      group[#group + 1] = row
    end
  end
  local checks: mut {integer: string} = {}
  -- The functions are in source order: the line is carried from one to the next.
  local line, scanned, at = 1, 1, 1
  for _, group in ipairs(groups) do
    local first = group[1]
    if first ~= nil then
      if first.at < at then
        line, scanned = 1, 1
      end
      at = first.at
      while true do
        local newline = source:find("\n", scanned, true)
        if newline == nil or newline >= at then
          break
        end
        line, scanned = line + 1, newline + 1
      end
      local written = BoundaryChecks.statement(group, file, line)
      if written ~= nil then
        checks[first.id] = written
      end
    end
  end
  return checks
end

return BoundaryChecks
