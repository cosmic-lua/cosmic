--- The error-slot discipline of doc/design.md's third principle,
--- checked against the types tl's checker gave each node of a module it
--- has just compiled. A fallible function is one declared to return a
--- value that admits nil (`any` does), or a boolean, and then a
--- `string`: `T | nil, string` for a value, `boolean, string` for an
--- effect.
---
--- 1. A call to a fallible function keeps its error slot: it is bound
---    to at least two names (`local v, err = f()`, or an assignment),
---    returned whole as a `return`'s last value, or passed whole as the
---    last argument of `assert` or of a function whose last required
---    parameters take every result, a `string` where the reason lands
---    (`complain(v, why)`). Anywhere else -- `f() or x`, `not f()`, `if f() then`,
---    `(f())`, a non-final argument, `local v = f()`, `{f()}`,
---    `print(f())`, `table.insert(t, f())` -- the reason is dropped. A
---    call standing alone as a statement drops it too. A failure to be
---    ignored on purpose (a cleanup on a path that is already failing,
---    a diagnostic written to stderr) says so by binding both slots to
---    `_`: `local _, _ = Fs.remove(path)`. A method of a record
---    `quieted` names (`cosmic.log`'s Logger) may stand alone.
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
--- 5. Two slots, and nothing in a third: a fallible function declares
---    exactly two results, and no variadic tail. What else a failure means goes in its
---    reason, or in a structured error record standing as the value.
---    The one exception is `cosmic.sys`, whose C bindings answer
---    `nil | false, error, errno`: a function a module stores into one
---    of its fields (`sys.stat = function(...) ... end`, a stand-in for
---    a binding) keeps the binding's shape: this rule does not read it,
---    nor does rule 2 read a return that hands on the binding's whole
---    answer. A caller that needs the errno calls the binding itself.
--- 6. A reason is for a person, never parsed: a name a statement binds
---    to a fallible call's reason (`err` in `local v, err = f()`, or in
---    an assignment) may be passed on, logged, made part of a new
---    message, or compared with `""`, but not read for what it says --
---    `err:find(...)`, `:match`, `:gmatch`, `:sub`, `:byte`, the same
---    through `string.find(err, ...)`, or `err == "timeout"` (`~=`
---    too) against any literal but `""`. The name is followed from its
---    binding through the rest of its block, until another binding of
---    it takes over. A failure a caller must tell apart answers in a
---    shape of its own: `nil, ""` for no answer and no failure (a
---    deadline passed), a count or a field the caller reads, or a
---    structured record standing where the value would. A reason
---    reached any other way (`select(2, f())`) drops the slot, rule 1.
--- 7. No escape hatch in the type layer, doc/design.md's fourth
---    principle: a cast (`e as T`) tells the checker what it could not
---    prove, so none is written but in a function `casts`
---    names, with the reason no declaration, narrowing (`if e is T`), or
---    typed helper can stand in its place. The one cast the top level
---    makes without one is of the raw module the core hands the chunk
---    as its second argument (`local extra: any = select(2, ...)`),
---    which Teal can give no type.
--- 8. A function a module exports answers one result, or a value or an
---    effect and its reason: `string, string`, `integer, integer` or
---    `boolean, integer` from an exported function is a tuple whose
---    later slots a caller drops as silently as a reason (`f() or x`,
---    `{f()}`), and says nowhere what each slot is. Answer a record
---    to hand back more. Exported means a field of the record the
---    module returns, or of a record declared inside it, as the
---    checker typed the module's answer.
--- 9. An exported function that calls a fallible `cosmic.sys` binding
---    itself, not from a function nested in it, and answers a boolean
---    answers the binding's failure too: `boolean, string`. A bare
---    `boolean` over a binding has already dropped the reason a caller
---    needs, however carefully it bound it.
---
--- The exemption tables key a function as `"file:function"`: a named
--- function by its name (`f`, `R.f`, `R:f`), under the named function
--- it is nested in (`outer.inner`); a literal a top-level statement
--- binds by what it is bound to (`f = function`, `local t = { g =
--- function ... }` as `t.g`); anything else by the function around
--- it, or `"file:"` at the top level. An entry the check of its file
--- finds no use for is refused as stale.
---
--- The callee's type is the one the checker stored at the callee's own
--- position (`build.receivers` installs the reporter that keeps it). A
--- callee the checker gave no function type is not judged. Rules 2 to
--- 5 read a function's declared results.
---
--- `exempt` names the functions rules 2 to 5, 8 and 9 cannot yet hold,
--- `parsing` the functions rule 6 cannot, and `casts`
--- the functions rule 7 lets cast, each with its reason; the TODO for
--- each is where its fix goes.

local ast = require("build.ast")
local receivers = require("build.receivers")
local type compiler = require("build.compiler")

local type Node = ast.Node
local type Type = receivers.Type

local record contracts
  --- The functions the rules let off, each table `"file:function"` to
  --- the reason; `check` holds a module to this module's own unless it
  --- is handed others.
  record Exemptions
    --- The functions rules 2 to 5, 8 and 9 do not hold.
    exempt: {string: string}
    --- The functions rule 6 does not hold.
    parsing: {string: string}
    --- The functions rule 7 lets cast.
    casts: {string: string}
  end
  --- Methods of one record whose failure a statement may ignore.
  record Quiet
    reason: string
    methods: {string: boolean}
  end
end

local exempt: {string: string} = {
  ["build/reboot.tl:ensure"] =
    "nil means proceed; the integer is an exit code, not a value",
  ["cosmic/child.tl:Child.wait_any"] =
    "a finished handle comes back with its group's lingering-member " ..
    "trouble, which a caller reports beside the handle's result",
}

local parsing: {string: string} = {
  ["build/zig.tl:Zig.fetch.attempt"] =
    "bin/zig runs on the release ci/cosmic-driver.pin names, whose " ..
    "Http.download names the URL in one failure's reason and no other",
}

local casts: {string: string} = {
  ["build/ast/match.tl:arr"] =
    "tl's AST reached by reflection: a node's own array part, " ..
    "whose elements' shape depends on their kind",
  ["build/ast/match.tl:attach_predicates"] =
    "a cast node's casttype is a parsed type no Node field names",
  ["build/ast/match.tl:match_value"] =
    "a pattern matched field by field, by reflection: a candidate " ..
    "found under any field is bound as the Node it is",
  ["build/ast/match_cast.tl:match"] =
    "a candidate cast node, reached by reflection, bound as the Node it is",
  ["build/ast/match_cast.tl:type_array"] =
    "a parsed type's fields, which no Node field names, by reflection",
  ["build/ast/match_cast.tl:type_view"] =
    "a parsed type's fields, which no Node field names, by reflection",
  ["build/ast/node.tl:parse"] =
    "vendored tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/ast/walk.tl:map_of"] =
    "a node's fields read by reflection: which it has depends on its kind",
  ["build/contracts.tl:exported_functions"] =
    "vendored tl hands a module's checked type as any (build/compiler.d.tl)",
  ["build/contracts.tl:check_function"] =
    "build.ast declares tl's type objects as TypeNode and " ..
    "build.receivers as Type: two declarations of one thing",
  ["build/receivers.tl:receivers.record_named"] =
    "vendored tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/receivers.tl:receivers.references"] =
    "vendored tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/receivers.tl:reporter_for"] =
    "vendored tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/teal.tl:teal.lazy.real"] =
    "the loaded compiler, indexed by whatever key the capsule is asked for",
  ["build/teal.tl:teal.lazy"] =
    "a capsule standing for the compiler until it loads",
  ["build/teal.tl:teal.load"] =
    "the one boundary where the vendored compiler's untyped chunk " ..
    "becomes its declared surface (build/compiler.d.tl)",
  ["cosmic/archive.tl:wrap_tar"] =
    "Tar.Entry has every field Archive.Entry has, but the two are " ..
    "unrelated records",
  ["cosmic/archive.tl:wrap_zip"] =
    "Zip.Entry has every field Archive.Entry has, but the two are " ..
    "unrelated records",
  ["cosmic/shape.tl:Shape.into"] =
    "the one cast from any, to the caller's annotation, of a value " ..
    "walk has just built to the spec",
  ["cosmic/sqlite.tl:bind"] =
    "a caller's parameter table is checked for keys its " ..
    "declaration does not name, which only a map view of it lists",
}

--- This module's own exemptions, which `check` holds a module to.
local own_exemptions: contracts.Exemptions = { exempt = exempt, parsing = parsing, casts = casts }

--- The methods whose failures a statement may ignore without saying
--- so, by record, with the reason: a diagnostic written to a stream has
--- nowhere else to report that the write failed, as `cosmic.log` says.
--- Each method is named, so one a record gains later is held to rule 1
--- until it is listed here. Only a call standing alone as a statement
--- is let through; a result used any other way is held to rule 1 too.
-- TODO: refuse a stale entry here too, as `stale` does the other
-- tables': one whose record no module declares, or whose method the
-- record lacks. quiet_records resolves them against whatever
-- environment compiles the module at hand, which need not have loaded
-- the record's module, so a miss there is no proof; it waits on a check
-- run once the whole tree is compiled.
local quieted: {string: contracts.Quiet} = {
  ["cosmic.log Logger"] = {
    reason = "a line written for a person; its failure has nowhere to go",
    methods = { say = true, complain = true, verdict = true },
  },
}

--- `quieted`'s methods by the type id of their record, as the
--- checker in `env` holds it: what `check` takes as `quiet`.
function contracts.quiet_records(env: compiler.Env): {integer: {string: boolean}}
  local out: {integer: {string: boolean}} = {}
  for key, entry in pairs(quieted) do
    local module, path = key:match("^(%S+) (%S+)$")
    if module ~= nil and path ~= nil then
      local found = receivers.record_named(env, module, path)
      if found ~= nil and found.typeid ~= nil then out[found.typeid] = entry.methods end
    end
  end
  return out
end

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

local position = receivers.position

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

--- Whether a value of type `t` can be nil: a union with nil, or `any`.
local function admits_nil(t: Type | nil): boolean
  return holds(t, "nil") or holds(t, "any")
end

--- Whether results declared as `members` make a fallible function.
local function fallible_results(members: {Type}): boolean
  if #members < 2 or typename(members[2]) ~= "string" then return false end
  return typename(members[1]) == "boolean" or admits_nil(members[1])
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
  for _, child in ipairs(ast.children(n, skipped)) do visit(child) end
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
  return n
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

--- The exemptions a check found use for, by table, `"file:function"`
--- each: one never used names nothing it excuses.
local record Used
  exempt: {string: boolean}
  parsing: {string: boolean}
  casts: {string: boolean}
end

--- Every function literal a top-level statement binds, by what it is
--- bound to: `f` in `f = function`, `R.g` in `R.g = function`, and
--- `t.g` in `local t = { g = function ... end }`.
local function bound_names(root: Node): {Node: string}
  local out: {Node: string} = {}
  for _, statement in ipairs(list_of(root)) do
    if statement.kind == "assignment" or statement.kind == "local_declaration" then
      local exps = list_of(statement.exps)
      for i, var in ipairs(list_of(statement.vars)) do
        local value, name = exps[i], spelled(var)
        if value ~= nil and name ~= "a call" then
          if value.kind == "function" then
            out[value] = name
          elseif value.kind == "literal_table" then
            for _, item in ipairs(list_of(value)) do
              local key, field = item.key, item.value
              if key ~= nil and key.kind == "string" and key.conststr ~= nil
                  and field ~= nil and field.kind == "function" then
                out[field] = name .. "." .. key.conststr
              end
            end
          end
        end
      end
    end
  end
  return out
end

--- The name the code inside `n` goes by, for the exemption tables: a
--- named function's own, under the named function around it
--- (`outer.inner`); what a top-level statement binds a literal to; and
--- `within`, the name around it, for any other node.
local function scope_of(n: Node, within: string, bound: {Node: string}): string
  if is_function(n) and n.name ~= nil then
    local own = function_name(n)
    return within == "" and own or within .. "." .. own
  end
  return bound[n] or within
end

--- Every function in `root` by the name the exemption tables key its
--- code under (`scope_of`).
local function scope_names(root: Node, bound: {Node: string}): {Node: string}
  local out: {Node: string} = {}
  local seen: {Node: boolean} = {}
  local function go(n: Node, within: string)
    if seen[n] then return end
    seen[n] = true
    within = scope_of(n, within, bound)
    if is_function(n) then out[n] = within end
    each_child(n, function(child: Node) go(child, within) end)
  end
  go(root, "")
  return out
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

--- Rules 2 to 5, over one function's declared results and returns. A
--- stand-in for a `cosmic.sys` binding keeps the binding's third slot,
--- so rule 5 does not read it, nor does rule 2 read a return that
--- hands the binding's whole answer on, errno and all.
local function check_function(file: string, fn: Node, scope: string, exemptions: contracts.Exemptions,
                              types: {integer: Type}, used: Used,
                              problems: {string}, stand_in: boolean)
  local rets = fn.rets
  local tuple = rets ~= nil and rets.tuple or nil
  if rets == nil or tuple == nil or #tuple < 2 then return end
  -- TODO: read `tuple` uncast once build.ast.node's TypeNode and
  -- build.receivers' Type are one declaration of tl's type objects.
  local declared = tuple as {Type} -- cast: a declared type is the checker's own type object
  local effect = typename(declared[1]) == "boolean"
  local value = admits_nil(declared[1])
  if not effect and not value then return end
  local name = function_name(fn)
  -- TODO: mark an exemption used only where a rule 2 to 5 would have
  -- refused the function, so one whose function now keeps the
  -- discipline is reported stale too; that wants the rules run whole
  -- and their problems dropped, rather than skipped at this lookup.
  if exemptions.exempt[file .. ":" .. scope] ~= nil then
    used.exempt[file .. ":" .. scope] = true
    return
  end
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
  -- A variadic tail (`T | nil, string...`) is as many slots as a
  -- caller cares to bind.
  if (#declared > 2 or rets.is_va) and not stand_in then
    problems[#problems + 1] = string.format(
      "%s:%d: %s: a fallible function answers two results and nothing in a third; "
        .. "fold it into the reason or a structured error record (only cosmic.sys "
        .. "answers an errno)",
      file, fn.y, name)
    return
  end
  local returns = returns_of(fn)
  local all_values = #returns > 0
  for _, r in ipairs(returns) do
    local exps = list_of(r.exps)
    -- A stand-in hands a binding's answer on as three names it bound.
    local handed_on = stand_in and #exps == 3 and exps[1].kind == "variable"
      and exps[2].kind == "variable" and exps[3].kind == "variable"
    if #exps >= 2 and not handed_on and not is_empty_string(exps[2])
        and not is_failure(exps[1], effect) then
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

--- How many results a call's callee declares; 0 when it is not known.
local function result_count(n: Node, callees: {integer: Type}): integer
  local e1 = n.e1
  if not is_call(n) or e1 == nil then return 0 end
  local f = resolved(callees[position(e1.y, e1.x)])
  local rets = f ~= nil and f.rets or nil
  local members = rets ~= nil and rets.tuple or nil
  return members ~= nil and #members or 0
end

--- Whether a call hands its last argument's reason on: `assert`, or a
--- callee whose required, not variadic parameters end exactly where the
--- argument's results do, with a `string` for the reason to land in.
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
  local last = slot - 2 + result_count(list_of(call.e2)[count], callees)
  if last ~= #members or params.is_va or (f.min_arity or 0) < last then return false end
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

--- Every function literal a module stores into a field of `cosmic.sys`:
--- a stand-in for a binding, which answers in the binding's own shape.
--- The table is known by the type the checker gave the field's owner,
--- the record `cosmic.sys` declares, whatever the owner is called.
local function sys_stand_ins(root: Node, records: {integer: Type},
                             sys: Type | nil): {Node: boolean}
  local out: {Node: boolean} = {}
  local wanted = resolved(sys)
  if wanted == nil or wanted.typeid == nil then return out end
  ast.walk(root, function(n: Node)
    if n.kind ~= "assignment" then return end
    local exps = list_of(n.exps)
    for i, var in ipairs(list_of(n.vars)) do
      local op, owner, stored = var.op, var.e1, exps[i]
      if var.kind == "op" and op ~= nil and op.op == "." and owner ~= nil
          and stored ~= nil and stored.kind == "function" then
        local record_type = records[position(owner.y, owner.x)]
        if record_type ~= nil and record_type.typeid == wanted.typeid then
          out[stored] = true
        end
      end
    end
  end)
  return out
end

--- The string methods that read a message for what it says, rule 6's
--- concern: a caller that finds, matches, or cuts a reason is parsing it.
local inspecting: {string: boolean} = {
  find = true, match = true, gmatch = true, sub = true, byte = true,
}

--- One place a name is bound, in source order: rule 6 follows a reason
--- from where a fallible call binds it to where another binding of the
--- name takes over.
local record Binding
  at: integer
  --- Where the name's scope ends: its block's end for a `local`, a
  --- loop variable, or a parameter; an assignment's own block's end,
  --- after which rule 6 no longer follows the name.
  -- TODO: follow a reason assigned in an inner block (`local ok, err`
  -- then `ok, err = f()` inside an `if`) to the end of the name's own
  -- scope, not of the assignment's block, once build.receivers keeps
  -- the declaration each variable node resolves to; tl's checker finds
  -- it but stores it nowhere this can read.
  ends: integer
  --- Whether the name is declared here (it shadows until `ends`) rather
  --- than assigned (it replaces whatever was there).
  declared: boolean
  --- Whether a fallible call's reason is what the name is bound to.
  reason: boolean
  --- The name this one was bound to alone (`local a = err`), whose
  --- binding at that point says whether this one holds a reason.
  alias: Node | nil
end

--- A block's end, as one position; the end of the source when the
--- parser stamped none (the module's own top-level block).
local function block_end(block: Node | nil): integer
  local y, x = block ~= nil and block.yend or nil, block ~= nil and block.xend or nil
  if y == nil or x == nil then return math.maxinteger end
  return position(y, x)
end

--- The index of the name a statement binds to a fallible call's reason:
--- 2 in `local v, err = f()`; nil when the statement binds none.
local function reason_slot(n: Node, callees: {integer: Type}): integer | nil
  local exps = list_of(n.exps)
  local last = exps[#exps]
  if last == nil or #list_of(n.vars) <= #exps or not is_call(last) then return nil end
  local e1 = last.e1
  if e1 == nil or not fallible_type(callees[position(e1.y, e1.x)]) then return nil end
  return #exps + 1
end

local function is_name(n: Node | nil, name: string): boolean
  return n ~= nil and n.kind == "variable" and n.tk == name
end

--- Methods that answer the text they are called on, reshaped: a read
--- through one is a read of the text itself.
local reshaping: {string: boolean} = { lower = true, upper = true }

--- The name under what only wraps it -- `(err)`, `tostring(err)`,
--- `err:lower()` -- or nil when `n` is no name so wrapped. It gives up,
--- answering nil, past 8 wrappers.
local function unwrapped(n: Node | nil): Node | nil
  local at = n
  for _ = 1, 8 do
    if at == nil then return nil end
    if at.kind == "variable" then return at end
    if at.kind == "paren" then
      at = at.e1
    elseif not is_call(at) then
      return nil
    else
      local callee, args = at.e1, list_of(at.e2)
      local how = callee ~= nil and callee.op or nil
      local member = callee ~= nil and callee.e2 or nil
      if is_name(callee, "tostring") and #args == 1 then
        at = args[1]
      elseif callee ~= nil and how ~= nil and how.op == ":" and member ~= nil
          and reshaping[member.tk or ""] and #args == 0 then
        at = callee.e1
      else
        return nil
      end
    end
  end
  return nil
end

--- Whether `n` is what a reason may be compared with: `""` or `nil`.
local function neutral(n: Node): boolean
  return n.kind == "nil" or (n.kind == "string" and n.conststr == "")
end

local comparing: {string: boolean} = {
  ["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true,
}

--- The names `n` reads a reason's content through: `err` in
--- `err:find(...)`, `string.match(err, ...)`, `err == "timeout"`, or
--- `err == TIMEOUT`, and the same through `(err)`, `tostring(err)`,
--- and `err:lower()`. Which of them hold a reason is the caller's to
--- decide.
-- TODO: a reason read any other way is not seen: stored in a field
-- (`t.e = err`, then `t.e:find`), a string function kept in a local
-- (`local sf = string.find`), the reason as another call's argument
-- (`name():find(err)`, a pattern), a table keyed by it (`m[err]`), its
-- length (`#err`), a `gsub`'s count, or a name that an assignment in an
-- inner block rebinds to something else before a later read. Each
-- wants data flow over values and fields rather than names, which
-- waits on the variable resolution build.receivers does not keep (see
-- Binding.ends's TODO).
local function inspected(n: Node): {Node}
  local op = n.op
  if n.kind ~= "op" or op == nil then return {} end
  if comparing[op.op] then
    local out: {Node} = {}
    local a, b = n.e1, n.e2
    if a == nil or b == nil then return out end
    local left, right = unwrapped(a), unwrapped(b)
    if left ~= nil and not neutral(b) then out[#out + 1] = left end
    if right ~= nil and not neutral(a) then out[#out + 1] = right end
    return out
  end
  local callee = n.e1
  if op.op ~= "@funcall" or callee == nil then return {} end
  local how, member = callee.op, callee.e2
  if callee.kind ~= "op" or how == nil or member == nil
      or not inspecting[member.tk or ""] then
    return {}
  end
  local receiver = callee.e1
  if how.op == ":" then
    local name = unwrapped(receiver)
    return name ~= nil and { name } or {}
  end
  if how.op == "." and is_name(receiver, "string") then
    local name = unwrapped(list_of(n.e2)[1])
    return name ~= nil and { name } or {}
  end
  return {}
end

--- The last position any node of `n`'s subtree stands at.
local function last_position(n: Node): integer
  local last = 0
  ast.walk(n, function(child: Node)
    -- A list the parser built without a position of its own has none.
    if child.y == nil or child.x == nil then return end
    local at = position(child.y, child.x)
    if at > last then last = at end
  end)
  return last
end

--- Rule 6: a reason bound to a name is passed on, compared with `""`,
--- or made part of a new message, never read for what it says. Every
--- binding of every name is kept with the scope it holds in, and an
--- inspection is flagged when the binding it reads is a reason's. A
--- name bound to another name alone (`local a = err`) holds whatever
--- that one does.
local function check_inspections(file: string, root: Node, callees: {integer: Type},
                                 bound: {Node: string}, exemptions: contracts.Exemptions,
                                 used: Used, problems: {string})
  local bindings: {string: {Binding}} = {}
  local reads: {{Node}} = {}
  --- Binds `name_node`'s name from `at` on. A `local` or an assignment
  --- binds after its own right-hand side, which reads the binding
  --- before it.
  local function bind(name_node: Node | nil, at: integer, ends: integer,
                      declared: boolean, reason: boolean, alias?: Node)
    local name = name_node ~= nil and name_node.tk or nil
    if name_node == nil or name == nil or name == "_" then return end
    local list = bindings[name] or {}
    bindings[name] = list
    list[#list + 1] = {
      at = at, ends = ends, declared = declared, reason = reason, alias = alias,
    }
  end
  local seen: {Node: boolean} = {}
  local function go(n: Node, ends: integer, within: string)
    if seen[n] then return end
    seen[n] = true
    local kind = n.kind
    if kind == "statements" then ends = block_end(n) end
    within = scope_of(n, within, bound)
    if kind == "local_declaration" or kind == "assignment" then
      local slot = reason_slot(n, callees)
      local exps = list_of(n.exps)
      local after = last_position(n) + 1
      for i, var in ipairs(list_of(n.vars)) do
        if var.kind == "identifier" or var.kind == "variable" then
          bind(var, after, ends, kind == "local_declaration", i == slot, unwrapped(exps[i]))
        end
      end
    elseif kind == "forin" then
      for _, var in ipairs(list_of(n.vars)) do
        bind(var, position(var.y, var.x), block_end(n.body), true, false)
      end
    elseif kind == "fornum" then
      local var = n.var
      if var ~= nil then
        bind(var, position(var.y, var.x), block_end(n.body), true, false)
      end
    elseif is_function(n) then
      for _, param in ipairs(list_of(n.args)) do
        bind(param, position(param.y, param.x), block_end(n.body), true, false)
      end
    end
    local reading = inspected(n)
    if exemptions.parsing[file .. ":" .. within] == nil then
      for _, read in ipairs(reading) do reads[#reads + 1] = { read, n } end
    elseif #reading > 0 then
      used.parsing[file .. ":" .. within] = true
    end
    each_child(n, function(child: Node) go(child, ends, within) end)
  end
  go(root, math.maxinteger, "")
  for _, list in pairs(bindings) do
    table.sort(list, function(a: Binding, b: Binding): boolean return a.at < b.at end)
  end
  --- Whether `name`, read at `at`, holds a reason. An alias is always
  --- bound after the name it copies is read, so this only looks back.
  local function holds_reason(name: string, at: integer): boolean
    local list = bindings[name] or {}
    for i = #list, 1, -1 do
      local b = list[i]
      -- A declaration whose scope has closed stood in an inner block:
      -- the one before it is what this reads.
      if b.at <= at and (not b.declared or b.ends >= at) then
        if b.ends < at then return false end
        if b.reason then return true end
        local alias = b.alias
        if alias == nil or alias.tk == nil then return false end
        local from = position(alias.y, alias.x)
        return from < b.at and holds_reason(alias.tk, from)
      end
    end
    return false
  end
  local flagged: {Node: boolean} = {}
  for _, pair in ipairs(reads) do
    local read, via = pair[1], pair[2]
    if not flagged[via] and holds_reason(read.tk or "", position(read.y, read.x)) then
      flagged[via] = true
      problems[#problems + 1] = string.format(
        "%s:%d: %s: a failure's reason is read for what it says; a "
          .. "failure with meaning answers it in a shape of its own "
          .. "(a value, a field, a record), not a message to parse",
        file, via.y, read.tk)
    end
  end
end

--- Every name a top-level `local` binds to the raw module the core
--- hands this chunk, `select(2, ...)`.
-- TODO: stop trusting a name a later top-level statement assigns
-- something else (`extra = other`), which this does not follow; it
-- wants the same binding-by-position tracking rule 6 does
-- (check_inspections' Binding), shared rather than written again.
local function handed_names(root: Node): {string: boolean}
  local out: {string: boolean} = {}
  for _, statement in ipairs(list_of(root)) do
    if statement.kind == "local_declaration" then
      local exps = list_of(statement.exps)
      for i, var in ipairs(list_of(statement.vars)) do
        local e = exps[i]
        local args = e ~= nil and is_call(e) and is_name(e.e1, "select") and list_of(e.e2) or {}
        local first, second = args[1], args[2]
        if #args == 2 and first.kind == "integer" and first.tk == "2"
            and second.kind == "..." and var.tk ~= nil then
          out[var.tk] = true
        end
      end
    end
  end
  return out
end

--- Rule 7: every cast in a function `casts` does not name,
--- but for the top level's cast of the raw module the core hands the
--- chunk (`local extra: any = select(2, ...)`, then `extra as
--- raw_hash`): a chunk's arguments have no type Teal can give them.
local function check_casts(file: string, root: Node, bound: {Node: string},
                           exemptions: contracts.Exemptions, used: Used, problems: {string})
  local handed = handed_names(root)
  local seen: {Node: boolean} = {}
  local function go(n: Node, within: string)
    if seen[n] then return end
    seen[n] = true
    within = scope_of(n, within, bound)
    local op = n.op
    if n.kind == "op" and op ~= nil and op.op == "as" then
      local operand = n.e1
      while operand ~= nil and operand.kind == "paren" do operand = operand.e1 end
      local key = file .. ":" .. within
      if within == "" and operand ~= nil and operand.kind == "variable"
          and handed[operand.tk or ""] then
        -- the raw module, handed to the chunk
      elseif exemptions.casts[key] ~= nil then
        used.casts[key] = true
      else
        problems[#problems + 1] = string.format(
          "%s:%d: %s: a cast tells the checker what it could not prove; "
            .. "tighten the declaration, narrow with `is`, or name the "
            .. "function in build/contracts.tl's casts with the reason",
          file, n.y, within == "" and "the top level" or within)
      end
    end
    each_child(n, function(child: Node) go(child, within) end)
  end
  go(root, "")
end

--- One function a module exports: its name as a caller spells it
--- (`M.f`, `M.Reader:read`) and the type the checker gave it.
local record Exported
  name: string
  type: Type
end

--- The name of the table a module returns, `M` in `return M`; `""`
--- when its last statement returns something else.
local function export_name(root: Node): string
  local statements = list_of(root)
  local last = statements[#statements]
  local exps = last ~= nil and last.kind == "return" and list_of(last.exps) or {}
  local first = exps[1]
  if first ~= nil and first.kind == "variable" and first.tk ~= nil then return first.tk end
  return ""
end

--- Every function the record `export` holds, and every record declared
--- inside it (not one another module declares that it only names), by
--- its exported name under `root`.
local function exported_functions(export: any, root: string): {Exported}
  local out: {Exported} = {}
  local seen: {Type: boolean} = {}
  local function walk(t: Type | nil, path: string)
    local r = resolved(t)
    if r == nil or seen[r] or (r.typename ~= "record" and r.typename ~= "interface") then
      return
    end
    seen[r] = true
    local fields = r.fields
    if fields == nil then return end
    for _, key in ipairs(r.field_order or {}) do
      local field = fields[key]
      if field ~= nil and field.typename == "function" then
        out[#out + 1] = { name = path .. (field.is_method and ":" or ".") .. key, type = field }
      elseif field ~= nil and field.typename == "typedecl" and not field.is_alias then
        walk(field, path .. "." .. key)
      end
    end
  end
  walk(export as Type, root) -- cast: the checker's own type object, handed over as any
  return out
end

--- The function nodes that define the exported functions: one defined
--- where its exported type was met (`function M.f`), and one a
--- top-level statement stores into an exported field, as a literal or
--- a local function by name (`M.f = f`, `local M: T = { f = f }`).
local function exported_nodes(root: Node, exported: {Exported}): {Node: Exported}
  local at: {integer: Exported} = {}
  local named: {string: Exported} = {}
  for _, e in ipairs(exported) do
    local y, x = e.type.y, e.type.x
    if y ~= nil and x ~= nil then at[position(y, x)] = e end
    named[(e.name:gsub(":", "."))] = e
  end
  local locals: {string: Node} = {}
  local out: {Node: Exported} = {}
  local function stored(value: Node | nil, name: string)
    local e = named[name]
    if value == nil or e == nil then return end
    if value.kind == "function" then
      out[value] = e
    elseif value.kind == "variable" and value.tk ~= nil and locals[value.tk] ~= nil then
      out[locals[value.tk]] = e
    end
  end
  for _, statement in ipairs(list_of(root)) do
    local name = statement.name
    if statement.kind == "local_function" and name ~= nil and name.tk ~= nil then
      locals[name.tk] = statement
    end
    if is_function(statement) then
      local e = at[position(statement.y, statement.x)]
      if e ~= nil then out[statement] = e end
    elseif statement.kind == "assignment" or statement.kind == "local_declaration" then
      local exps = list_of(statement.exps)
      for i, var in ipairs(list_of(statement.vars)) do
        local value, spelling = exps[i], spelled(var)
        if value ~= nil and value.kind == "literal_table" then
          for _, item in ipairs(list_of(value)) do
            local key = item.key
            if key ~= nil and key.kind == "string" and key.conststr ~= nil then
              stored(item.value, spelling .. "." .. key.conststr)
            end
          end
        else
          stored(value, spelling)
        end
      end
    end
  end
  return out
end

--- Rule 8, over every exported function's declared results.
local function check_exports(file: string, exported: {Exported}, exemptions: contracts.Exemptions,
                             used: Used, problems: {string})
  for _, e in ipairs(exported) do
    local rets = e.type.rets
    local results = rets ~= nil and rets.tuple or {}
    local many = #results >= 2 or (rets ~= nil and rets.is_va == true and #results >= 1)
    local key = file .. ":" .. e.name
    if many and not fallible_results(results) then
      if exemptions.exempt[key] ~= nil then
        used.exempt[key] = true
      else
        problems[#problems + 1] = string.format(
          "%s:%d: %s: an exported function answers one result, or a value or an "
            .. "effect and its reason; answer a record to hand back more",
          file, e.type.y or 0, e.name)
      end
    end
  end
end

--- The fallible `cosmic.sys` binding `fn` calls itself, not from a
--- function nested in it, by name; nil when it calls none.
local function sys_call_in(fn: Node, callees: {integer: Type}, records: {integer: Type},
                           sys: Type | nil): string | nil
  local wanted = resolved(sys)
  if wanted == nil or wanted.typeid == nil or fn.body == nil then return nil end
  local sys_id = wanted.typeid
  local found: string | nil = nil
  local seen: {Node: boolean} = {}
  local function go(n: Node)
    if found ~= nil or seen[n] then return end
    seen[n] = true
    local e1 = n.e1
    local receiver = e1 ~= nil and e1.e1 or nil
    local member = e1 ~= nil and e1.e2 or nil
    if is_call(n) and e1 ~= nil and receiver ~= nil and member ~= nil
        and fallible_type(callees[position(e1.y, e1.x)]) then
      local owner = records[position(receiver.y, receiver.x)]
      if owner ~= nil and owner.typeid == sys_id then found = member.tk end
    end
    each_child(n, function(child: Node)
      if not is_function(child) then go(child) end
    end)
  end
  go(fn.body)
  return found
end

--- Rule 9, over every exported function defined in this module.
local function check_wrappers(file: string, nodes: {Node: Exported}, callees: {integer: Type},
                              records: {integer: Type}, sys: Type | nil,
                              exemptions: contracts.Exemptions, used: Used, problems: {string})
  for fn, e in pairs(nodes) do
    local rets = e.type.rets
    local results = rets ~= nil and rets.tuple or {}
    if typename(results[1]) == "boolean" and not fallible_results(results) then
      local binding = sys_call_in(fn, callees, records, sys)
      local key = file .. ":" .. e.name
      if binding ~= nil then
        if exemptions.exempt[key] ~= nil then
          used.exempt[key] = true
        else
          problems[#problems + 1] = string.format(
            "%s:%d: %s: calls cosmic.sys.%s itself and answers a bare boolean; "
              .. "answer its failure too: boolean, string",
            file, fn.y, e.name, binding)
        end
      end
    end
  end
end

--- An exemption `file`'s check never needed: its function is gone, or
--- no longer does what the table excuses. No table may name a function
--- of build/importer.tl, whatever module is checked: a test's tree
--- stands a stub in for it, to be taken for cosmic's own, and the stub
--- has none of them, so the entry would be stale in every such tree.
local function stale(file: string, name: string, exemptions: {string: string},
                     used: {string: boolean}, problems: {string})
  local prefix = file .. ":"
  local stubbed = "build/importer.tl:"
  for key in pairs(exemptions) do
    if key:sub(1, #stubbed) == stubbed then
      problems[#problems + 1] = string.format(
        "%s: contracts.%s names %s; no table may name a function of " ..
          "build/importer.tl, which a test's tree stubs",
        file, name, key)
    elseif key:sub(1, #prefix) == prefix and not used[key] then
      problems[#problems + 1] = string.format(
        "%s: contracts.%s names %s, which no longer needs it; drop the entry",
        file, name, key)
    end
  end
end

local function line_of(problem: string): integer
  return math.tointeger(tonumber(problem:match("^[^:]*:(%d+):"))) or 0
end

--- Every breach of the error-slot discipline in a module the checker
--- has just checked, `file:line: ...` each, in line order.
--- @param file the module's path in the tree, for messages
--- @param root the checked AST
--- @param typed the checker's types, as `build.receivers` kept them
--- @param quiet `quiet_records`' answer, when the caller has an environment
--- @param sys the record `cosmic.sys` declares, as the checker holds it
--- (`receivers.record_named(env, "cosmic.sys", "")`), when the caller
--- has an environment that has loaded it
--- @param given the exemptions to hold the module to, in place of this
--- module's own
--- @param export the type the checker gave the module's answer, for
--- rules 8 and 9; without it they hold nothing
function contracts.check(file: string, root: Node, typed: receivers.State,
                         quiet?: {integer: {string: boolean}}, sys?: Type,
                         given?: contracts.Exemptions, export?: any): {string}
  local exemptions = given or own_exemptions
  local problems: {string} = {}
  local types, callees = typed.every, typed.callees
  local records = typed.types
  --- Whether a statement calls a method of a quiet record.
  local function is_quiet(e1: Node): boolean
    local receiver, member = e1.e1, e1.e2
    if quiet == nil or receiver == nil or member == nil or member.tk == nil
        or e1.kind ~= "op" then
      return false
    end
    local owner = records[position(receiver.y, receiver.x)]
    local methods = owner ~= nil and quiet[owner.typeid] or nil
    return methods ~= nil and methods[member.tk] == true
  end
  local used: Used = { exempt = {}, parsing = {}, casts = {} }
  local bound = bound_names(root)
  local scopes = scope_names(root, bound)
  local kept, statements = keeping(root, callees), standing(root)
  local stand_ins = sys_stand_ins(root, records, sys)
  ast.walk(root, function(n: Node)
    local e1 = n.e1
    if is_call(n) and not kept[n] and e1 ~= nil
        and fallible_type(callees[position(e1.y, e1.x)]) then
      if statements[n] then
        if not is_quiet(e1) then
          problems[#problems + 1] = string.format(
            "%s:%d: %s: its failure is ignored; handle it, or discard both "
              .. "results on purpose: local _, _ = ...",
            file, n.y, spelled(e1))
        end
      else
        problems[#problems + 1] = string.format(
          "%s:%d: %s: its error slot is dropped; bind both results, wrap it "
            .. "in assert(...), or return it whole",
          file, n.y, spelled(e1))
      end
    elseif is_function(n) then
      check_function(file, n, scopes[n] or function_name(n), exemptions, types, used, problems,
        stand_ins[n] or false)
    end
  end)
  local exported = exported_functions(export, export_name(root))
  check_exports(file, exported, exemptions, used, problems)
  check_wrappers(file, exported_nodes(root, exported), callees, records, sys, exemptions,
    used, problems)
  check_inspections(file, root, callees, bound, exemptions, used, problems)
  check_casts(file, root, bound, exemptions, used, problems)
  stale(file, "exempt", exemptions.exempt, used.exempt, problems)
  stale(file, "parsing", exemptions.parsing, used.parsing, problems)
  stale(file, "casts", exemptions.casts, used.casts, problems)
  table.sort(problems, function(a: string, b: string): boolean
    local la, lb = line_of(a), line_of(b)
    if la ~= lb then return la < lb end
    return a < b
  end)
  return problems
end

return contracts
