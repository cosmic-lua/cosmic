--- The error-slot discipline of doc/design.md's third principle,
--- checked against the types tl's checker gave each node of a module it
--- has just compiled. A fallible function is one declared to return a
--- value that admits nil, or a boolean, and then a `string`: `T | nil,
--- string` for a value, `boolean, string` for an effect (a native
--- binding's errno in a third slot changes nothing here).
---
--- 1. A call to a fallible function keeps its error slot: it is bound
---    to at least two names (`local v, err = f()`, or an assignment),
---    returned whole as a `return`'s last value, or passed whole as the
---    last argument of `assert` or of a function that declares a
---    `string` parameter for the reason to land in (`complain(v,
---    why)`). Anywhere else -- `f() or x`, `not f()`, `if f() then`,
---    `(f())`, a non-final argument, `local v = f()`, `{f()}`,
---    `print(f())`, `table.insert(t, f())` -- the reason is dropped. A
---    call standing alone as a statement drops it too. A failure to be
---    ignored on purpose (a cleanup on a path that is already failing,
---    a diagnostic written to stderr) says so by binding both slots to
---    `_`: `local _, _ = Fs.remove(path)`.
--- 2. A failure carries no value: in a fallible function, a `return a,
---    b` whose `b` is not the literal `""` has a literal `nil` (`false`,
---    for an effect) as `a`. So `local v, err = f(); return v, err` is
---    refused too: it hands on a value beside a reason whenever `f`
---    does, and says so nowhere. Return `f()` whole, or split it: `if v
---    == nil then return nil, err end return v, ""`.
--- 3. The reason is exactly a `string`: a function whose first slot
---    admits nil or is a boolean answers no other type that holds a
---    string in its second (`string | nil` included), and one whose
---    first admits nil answers no integer code there.
--- 4. A declared failure can happen: a function declared `T | nil,
---    string` whose every return is a value that cannot be nil and `""`
---    returns the value alone.
---
--- The callee's type is the one the checker stored at the callee's own
--- position (`build.receivers` installs the reporter that keeps it). A
--- callee the checker gave no function type is not judged. Rules 2 to
--- 4 read the declared results of a function that declares two.
---
--- `contracts.exempt` names the functions rules 2 to 4 cannot yet hold,
--- each with its reason; the TODO for each is where its fix goes.

local ast = require("build.ast")
local receivers = require("build.receivers")

local type Node = ast.Node
local type Type = receivers.Type

local record contracts
  --- `"file:function"` to the reason rules 2 to 4 do not hold it.
  exempt: {string: string}
end

contracts.exempt = {
  ["build/reboot.tl:reboot.ensure"] =
    "nil means proceed; the integer is an exit code, not a value",
  ["cosmic/child.tl:Child.wait_any"] =
    "a finished handle comes back with its group's lingering-member " ..
    "trouble, which a caller reports beside the handle's result",
}

--- Whether a module is held to the discipline: every module and main
--- of cosmic's own tree, not its tests, examples, declarations, or
--- generated doctests.
-- TODO: hold ci/'s modules to it too. ci/ builds as a tree of its own,
-- never cosmic's, so the importer never asks; and it runs on the
-- release ci/cosmic-driver.pin names, so a fix there must suit both.
--- @param kind the module's kind as the importer staged it
--- @param generated whether a generator wrote it
function contracts.applies(kind: string, generated: boolean): boolean
  return (kind == "module" or kind == "main") and not generated
end

--- A position as one integer key, the way `build.receivers` keys them.
local function position(y: integer, x: integer): integer
  return (y << 20) | x
end

--- The type under a nominal, declaration, or generic.
local function resolved(t: Type | nil): Type | nil
  local at = t
  for _ = 1, 8 do
    if at == nil then return nil end
    local name = at.typename
    if name == "nominal" then
      local under = at.found or at.resolved
      if under == nil then return at end
      at = under
    elseif name == "typedecl" then
      at = at.def
    elseif name == "generic" then
      at = at.t
    else
      return at
    end
  end
  return at
end

--- Whether `t` is `wanted`, or a union with a member that is.
local function holds(t: Type | nil, wanted: string): boolean
  local r = resolved(t)
  if r == nil then return false end
  if r.typename == wanted then return true end
  local members = r.types
  if r.typename == "union" and members ~= nil then
    for _, alternative in ipairs(members) do
      if holds(alternative, wanted) then return true end
    end
  end
  return false
end

local function typename(t: Type | nil): string
  local r = resolved(t)
  return r ~= nil and r.typename or ""
end

--- Whether results declared as `members` make a fallible function.
local function fallible_results(members: {Type}): boolean
  if #members < 2 or typename(members[2]) ~= "string" then return false end
  return typename(members[1]) == "boolean" or holds(members[1], "nil")
end

--- Whether a callee's type is a fallible function's.
local function fallible_type(fn: Type | nil): boolean
  local f = resolved(fn)
  if f == nil or f.typename ~= "function" then return false end
  local rets = f.rets
  local members = rets ~= nil and rets.tuple or nil
  return members ~= nil and fallible_results(members)
end

--- The fields of a checked node that point back up the tree or
--- sideways, and are never followed.
local skipped: {string: boolean} = {
  if_parent = true, fn_owner = true, expected = true, known = true,
}

--- Calls `visit` on every child node of `n`.
local function each_child(n: Node, visit: function(Node))
  for key, value in pairs(n as {any: any}) do -- cast: every field of the node
    local back = key is string and skipped[key] or false
    if not back and value is {any: any} then
      local map = value as {any: any} -- cast: narrowed just above
      local kind = map["kind"]
      if kind is string then
        visit(map as Node) -- cast: a node of tl's AST
      else
        for _, child in ipairs(map as {any}) do -- cast: a bare array of nodes
          if child is {any: any} then
            local child_map = child as {any: any} -- cast: an element of that array
            local child_kind = child_map["kind"]
            if child_kind is string then
              visit(child as Node) -- cast: a node of tl's AST
            end
          end
        end
      end
    end
  end
end

local function is_call(n: Node): boolean
  local op = n.op
  return n.kind == "op" and op ~= nil and op.op == "@funcall"
end

local function is_function(n: Node): boolean
  return n.kind == "function" or n.kind == "local_function"
    or n.kind == "record_function" or n.kind == "global_function"
end

--- An expression list's, or a block's, own nodes.
local function list_of(n: Node | nil): {Node}
  if n == nil then return {} end
  return n as {Node} -- cast: an expression list's own array part
end

--- How a callee or a function's owner reads in a message: `Fs.read`,
--- `h:digest`, `helper`.
local function spelled(e: Node | nil): string
  if e == nil then return "a call" end
  if (e.kind == "variable" or e.kind == "identifier" or e.kind == "type_identifier")
      and e.tk ~= nil then
    return e.tk
  end
  local op = e.op
  local member = e.e2
  local member_name = member ~= nil and member.tk or nil
  if e.kind == "op" and op ~= nil and (op.op == "." or op.op == ":")
      and member_name ~= nil then
    return spelled(e.e1) .. op.op .. member_name
  end
  return "a call"
end

local function function_name(fn: Node): string
  local name = fn.name
  local tk = name ~= nil and name.tk or nil
  if tk == nil then return "a function literal" end
  if fn.kind == "record_function" and fn.fn_owner ~= nil then
    return spelled(fn.fn_owner) .. (fn.is_method and ":" or ".") .. tk
  end
  return tk
end

local function is_empty_string(n: Node): boolean
  return n.kind == "string" and n.conststr == ""
end

local function is_failure(n: Node, effect: boolean): boolean
  if n.kind == "nil" then return true end
  return effect and n.kind == "boolean" and n.tk == "false"
end

local never_nil_ops: {string: boolean} = {
  [".."] = true, ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true,
  ["//"] = true, ["%"] = true, ["#"] = true, ["not"] = true, ["=="] = true,
  ["~="] = true, ["<"] = true, [">"] = true, ["<="] = true, [">="] = true,
}

local never_nil_types: {string: boolean} = {
  string = true, integer = true, number = true, boolean = true,
  record = true, array = true, map = true, tupletable = true,
  ["function"] = true, enum = true, emptytable = true,
}

--- Whether an expression cannot be nil: a literal, a constructor, an
--- operator whose result is never nil, or a name the checker typed as
--- something that cannot be.
local function never_nil(n: Node, types: {integer: Type}): boolean
  local kind = n.kind
  if kind == "string" or kind == "integer" or kind == "number"
      or kind == "boolean" or kind == "literal_table" or kind == "function" then
    return true
  end
  if kind == "variable" then
    return never_nil_types[typename(types[position(n.y, n.x)])] or false
  end
  local op = n.op
  return kind == "op" and op ~= nil and never_nil_ops[op.op] or false
end

--- Every return statement that belongs to `fn` itself, not to a
--- function nested in it.
local function returns_of(fn: Node): {Node}
  local out: {Node} = {}
  local seen: {Node: boolean} = {}
  local function go(n: Node)
    if seen[n] then return end
    seen[n] = true
    if n.kind == "return" then out[#out + 1] = n end
    each_child(n, function(child: Node)
      if not is_function(child) then go(child) end
    end)
  end
  if fn.body ~= nil then go(fn.body) end
  return out
end

--- Rules 2 to 4, over one function's declared results and returns.
local function check_function(file: string, fn: Node, types: {integer: Type},
                              problems: {string})
  local rets = fn.rets
  local tuple = rets ~= nil and rets.tuple or nil
  -- A third result is a native binding's errno, mirrored by a wrapper
  -- that hands the binding's answer on as it came.
  if tuple == nil or #tuple ~= 2 then return end
  local declared = tuple as {Type} -- cast: a declared type is the checker's own type object
  local effect = typename(declared[1]) == "boolean"
  local value = holds(declared[1], "nil")
  if not effect and not value then return end
  local name = function_name(fn)
  if contracts.exempt[file .. ":" .. name] ~= nil then return end
  local second = declared[2]
  if typename(second) ~= "string" then
    -- A boolean beside a count (`boolean, integer`) is two answers,
    -- not a failure; beside a value that admits nil, an integer is an
    -- error code standing where the reason belongs.
    if (value and typename(second) == "integer") or holds(second, "string") then
      problems[#problems + 1] = string.format(
        "%s:%d: %s: a failure's reason is exactly a string; this second result is not",
        file, fn.y, name)
    end
    return
  end
  local returns = returns_of(fn)
  local all_values = #returns > 0
  for _, r in ipairs(returns) do
    local exps = list_of(r.exps)
    if #exps >= 2 and not is_empty_string(exps[2]) and not is_failure(exps[1], effect) then
      problems[#problems + 1] = string.format(
        "%s:%d: %s: a failure answers %s beside its reason, never a value; "
          .. "a success's reason is \"\"",
        file, r.y, name, effect and "false" or "nil")
    end
    if #exps ~= 2 or not is_empty_string(exps[2]) or not never_nil(exps[1], types) then
      all_values = false
    end
  end
  if value and all_values then
    problems[#problems + 1] = string.format(
      "%s:%d: %s: every return answers a value, so the declared failure "
        .. "never happens; return the value alone",
      file, fn.y, name)
  end
end

--- Whether a call hands its last argument's reason on: `assert`, or a
--- callee that declares a `string` parameter, not a variadic one, just
--- past the one the argument's value lands in.
local function takes_reason(call: Node, count: integer, callees: {integer: Type}): boolean
  local e1 = call.e1
  if e1 == nil then return false end
  if e1.kind == "variable" and e1.tk == "assert" then return true end
  local f = resolved(callees[position(e1.y, e1.x)])
  if f == nil or f.typename ~= "function" then return false end
  local params = f.args
  if params == nil then return false end
  local members = params.tuple
  if members == nil then return false end
  -- A method call's receiver is the first parameter.
  local op = e1.op
  local slot = count + 1 + ((e1.kind == "op" and op ~= nil and op.op == ":") and 1 or 0)
  if slot > #members or (slot == #members and params.is_va) then return false end
  return typename(members[slot]) == "string"
end

--- Every place a call keeps all of its results: the last expression of
--- a list bound to more names than it has expressions, the last value
--- of a return, and the last argument of a call that takes a reason.
local function keeping(root: Node, callees: {integer: Type}): {Node: boolean}
  local kept: {Node: boolean} = {}
  ast.walk(root, function(n: Node)
    if n.kind == "local_declaration" or n.kind == "assignment" then
      local exps, vars = list_of(n.exps), list_of(n.vars)
      if #exps > 0 and #vars > #exps then kept[exps[#exps]] = true end
    elseif n.kind == "return" then
      local exps = list_of(n.exps)
      if #exps > 0 then kept[exps[#exps]] = true end
    elseif is_call(n) then
      local args = list_of(n.e2)
      if #args > 0 and takes_reason(n, #args, callees) then kept[args[#args]] = true end
    end
  end)
  return kept
end

--- Every call standing alone as a statement.
local function standing(root: Node): {Node: boolean}
  local out: {Node: boolean} = {}
  ast.walk(root, function(n: Node)
    if n.kind == "statements" then
      for _, statement in ipairs(list_of(n)) do out[statement] = true end
    end
  end)
  return out
end

local function line_of(problem: string): integer
  return math.tointeger(tonumber(problem:match("^[^:]*:(%d+):"))) or 0
end

--- Every breach of the error-slot discipline in a module the checker
--- has just checked, `file:line: ...` each, in line order.
--- @param file the module's path in the tree, for messages
--- @param root the checked AST
--- @param typed the checker's types, as `build.receivers` kept them
function contracts.check(file: string, root: Node, typed: receivers.State): {string}
  local problems: {string} = {}
  local types, callees = typed.every, typed.callees
  local kept, statements = keeping(root, callees), standing(root)
  ast.walk(root, function(n: Node)
    local e1 = n.e1
    if is_call(n) and not kept[n] and e1 ~= nil
        and fallible_type(callees[position(e1.y, e1.x)]) then
      if statements[n] then
        problems[#problems + 1] = string.format(
          "%s:%d: %s: its failure is ignored; handle it, or discard both "
            .. "results on purpose: local _, _ = ...",
          file, n.y, spelled(e1))
      else
        problems[#problems + 1] = string.format(
          "%s:%d: %s: its error slot is dropped; bind both results, wrap it "
            .. "in assert(...), or return it whole",
          file, n.y, spelled(e1))
      end
    elseif is_function(n) then
      check_function(file, n, types, problems)
    end
  end)
  table.sort(problems, function(a: string, b: string): boolean
    local la, lb = line_of(a), line_of(b)
    if la ~= lb then return la < lb end
    return a < b
  end)
  return problems
end

return contracts
