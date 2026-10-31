--- The error-slot discipline of doc/design.md's third principle (the eleven rules below), checked against the new
--- checker's syntax tree and the type it gave each node ([`build.syntax_report`]). The rules, the exemptions
--- ([`build.contract_rules`]'s `own_exemptions`, keyed by `"file:function"`) and the words of a problem are those of the
--- fork's contracts, which this replaced, so a module it held is held here and a breach is told alike. What reads the
--- tree and the types differently is below.
---
--- **The callee.** A call's function is the one the checker took ([`lang.check`]'s `callees`, by the id of the call node):
--- a method call has no node for its callee, and the fork kept the type at the callee's position. A call of an
--- overloaded function is judged by the overload taken, where the fork saw a `poly` and judged none.
---
--- **A function's results** are those of its return list, which the lowering typed ([`lang.declarations`]'s `types`, by the
--- id of each type node), and a function that answers one of several lists of values ([`Ast.Rets`]) is none of the fork's
--- fallible functions. A trailing `T...` is the last result with the list marked variadic.
---
--- **A name** is the fork's by position: the reason a statement binds is followed by the name's text from where its
--- statement ends to the end of its block (rule 6 below says what it does not follow), where the scope
--- builder could say exactly which binding a name reads; the port does not, so that the two read alike.
---
--- **Bindings of C.** [`cosmic.sys`] and the raw process and socket tables are typed from the declarations the build derives
--- from their headers ([`build.gen_syscalls`], whose `targets` are the tables the contract holds), so their
--- calls are judged by rules 1 and 6, rule 11 reads them, and a function stored into a field of one is a stand-in for a
--- binding (rule 5's exception), by the type of the field's owner. A program checked without them (`external` in
--- [`lang.declarations`]) has their calls untyped, and so unjudged.
--
-- TODO: judge the calls the checker could not type (a call has no callee in [`Checked.callees`] where its callee is `invalid`: a
-- value an error already reported, a call through one; the `[untyped]` ceilings of build/ceilings.txt count them per file, and the
-- build's compile with the new checker ([`build.pipeline`]) refuses a module above its ceiling), once the `[checked]` pins that
-- leave them untyped reach 0. Each of these calls follows from a pinned `[checked]` error, so the
-- count is bookkeeping of those pins and no gap of its own. The pins hold the
-- counts, and each later pull request that lowers a `[checked]` row lowers the `[untyped]` row of its file with it. The build's
-- compile declares the bindings of C from the declarations it derives of the headers, as the tree checks do, so their calls are
-- judged.
--
-- TODO: say what the discipline is for a function that answers one of several lists of values (`(true, R) | (false, E)`), which
-- no rule reads here, once the new grammar's convention for a failure is settled
-- (doc/design.md, third principle): until then the usual `T?, string` pair is the only function the rules hold.
--
-- TODO: follow a reason by the binding the scope builder resolves a name to ([`Scopes.Scoped.resolved`]) in place of the
-- name's text and position, which closes the gaps of rule 6 noted below (a reason stored in a field, in an inner block).
local AnalysisSchema = require("build.analysis_schema")
local Ast = require("lang.ast")
local type Driver = require("build.driver")
local GenSyscalls = require("build.gen_syscalls")
local Lexer = require("lang.lexer")
local Rules = require("build.contract_rules")
local Node = require("build.syntax_node")
local Report = require("build.syntax_report")
local String = require("cosmic.string")
local Types = require("lang.types")

local type Subject = Report.Subject

local record SyntaxContracts
  --- What the check of a module found.
  record Result
    --- Every breach, `file:line: ...` each, in line order.
    problems: {string}
    --- The exemptions it found use for, one `<table> <file>:<function>` each, sorted: an entry of the tables that no check
    --- needs is stale.
    used: {string}
    --- How many places each rule judged, by rule: `calls` (rule 1), `functions` (2 to 5), `exports` (10), `wrappers` (11), `readings` (6),
    --- `casts` (7), `types` (8), `modes` (9). A rule that judged nothing over a tree of some size reads nothing.
    sites: {string: integer}
    --- How many calls the checker gave no function (the callee is `invalid`) and that are no `require`: calls no rule judged.
    untyped: integer
  end

  --- The breaches of the discipline in `subject`, a module of cosmic's own tree that was checked with its types kept.
  --- `given` is the exemptions to hold it to in place of the tree's own. `declared` is the modules the build's sources
  --- declare tables of C bindings, which the contract holds besides the ones the generator derives.
  check: function(subject: Subject, given?: Rules.Exemptions, declared?: {string}): Result

  --- The modules of `index` that are declarations of a table of C bindings: a declaration that holds the line
  --- [`analysis_schema.binding_tag`], which `check` holds the calls of besides the ones the generator derives.
  declared_in: function(index: Driver.Index): {string}

  --- Whether the discipline holds the file: every module and main of the tree, not its tests, examples or declarations.
  applies: function(file: string): boolean

  --- The names of [`Result.sites`].
  rules: {string}
end

SyntaxContracts.rules = { "calls", "functions", "exports", "wrappers", "readings", "casts", "types", "modes" }

function SyntaxContracts.declared_in(index: Driver.Index): {string}
  local out: mut {string} = {}
  for _, source in ipairs(index.sources) do
    if source.dialect == "decl" and AnalysisSchema.declares_binding(source.text) then
      out[#out + 1] = source.module
    end
  end
  return out
end

function SyntaxContracts.applies(file: string): boolean
  return Rules.applies(AnalysisSchema.kind_of(file), false)
end

-- Types ------------------------------------------------------------------------------------------------------------

local function tag_of(t: Types.Type?): string
  if t == nil then
    return ""
  end
  return t.tag
end

--- Whether `t` is `wanted`, or a union with a member that is.
local function holds(t: Types.Type?, wanted: string): boolean
  if t == nil then
    return false
  end
  if tostring(t.tag) == wanted then
    return true
  end
  if (t.tag == "union") then
    if wanted == "nil" and t.nilable then
      return true
    end
    for _, member in ipairs(t.members) do
      if holds(member, wanted) then
        return true
      end
    end
  end
  return false
end

--- Whether a value of type `t` can be nil: a union with nil, or `any`.
local function admits_nil(t: Types.Type?): boolean
  -- A type that failed to lower (`invalid`, with its error reported) may be anything: it is taken for what the fork read.
  return holds(t, "nil") or holds(t, "any") or holds(t, "invalid")
end

--- The results a function type declares, the repeated one last, and whether the list ends in a repeated one; nil where it
--- answers one of several lists.
local function results_of(f: Types.Type?): {Types.Type}?, boolean
  if f == nil or not ((f.tag == "fn")) or #f.rets ~= 1 then
    return nil, false
  end
  local alt = f.rets[1]
  local out: mut {Types.Type} = {}
  for _, item in ipairs(alt.items) do
    out[#out + 1] = item
  end
  local tail = alt.tail
  if tail ~= nil then
    out[#out + 1] = tail
  end
  return out, tail ~= nil
end

--- Whether results declared as `members` make a fallible function.
local function fallible_results(members: {Types.Type}): boolean
  if #members < 2 or tag_of(members[2]) ~= "string" then
    return false
  end
  return tag_of(members[1]) == "boolean" or admits_nil(members[1])
end

--- Whether a callee's type is a fallible function's.
local function fallible_type(f: Types.Type?): boolean
  local members = results_of(f)
  return members ~= nil and fallible_results(members)
end

--- How many results a function type declares; 0 when it is not known.
local function result_count(f: Types.Type?): integer
  local members = results_of(f)
  return if members ~= nil then #members else 0 end
end

--- Element `position` of `list`, a position taken from its bounds or from a walk that visited it.
local function nth<T>(list: {T}, position: integer): T
  return (assert(list[position], "a position is within the list"))
end

--- The value kept under `key` in `map`, a key set before it is read.
local function known<K, V>(map: {K: V}, key: K): V
  return (assert(map[key], "the key was set before it is read"))
end

--- The count of parameters a call must give: those up to the last that is not omittable.
local function required(f: Types.Fn): integer
  local n = #f.params
  while n > 0 and nth(f.params, n).omittable == true do
    n = n - 1
  end
  return n
end

-- Nodes ------------------------------------------------------------------------------------------------------------

local function is_call(n: Ast.Node): boolean
  return (n.kind == "Call") or (n.kind == "MethodCall")
end

local function is_function(n: Ast.Node): boolean
  return (n.kind == "LocalFunction") or (n.kind == "Function") or (n.kind == "FunctionLit") or (n.kind == "Method")
end

--- What the rules read of a function: its parameters, return list and body.
local record Parts
  params: {Ast.Param}
  rets: Ast.Rets?
  body: Ast.Block
end

local function parts_of(n: Ast.Node): Parts?
  if (n.kind == "LocalFunction") then
    return { params = n.fn.params, rets = n.fn.rets, body = n.fn.body }
  elseif (n.kind == "Function") then
    return { params = n.fn.params, rets = n.fn.rets, body = n.fn.body }
  elseif (n.kind == "FunctionLit") then
    return { params = n.fn.params, rets = n.fn.rets, body = n.fn.body }
  elseif (n.kind == "Method") then
    return { params = n.params, rets = n.rets, body = n.body }
  end
  return nil
end

--- How a callee or a function's owner reads in a message: [`Fs.read`], `h:digest`, `helper`.
local function spelled(e: Ast.Node?): string
  if e == nil then
    return "a call"
  elseif (e.kind == "Name") then
    return e.text
  elseif (e.kind == "Field") then
    return spelled(e.object) .. "." .. e.name
  elseif (e.kind == "MethodCall") then
    return spelled(e.object) .. ":" .. e.name
  end
  return "a call"
end

--- The callee of a call as a message spells it.
local function callee_text(n: Ast.Node): string
  if (n.kind == "Call") then
    return spelled(n.callee)
  end
  return spelled(n)
end

local function arguments_of(n: Ast.Node): {Ast.Exp}
  if (n.kind == "Call") then
    return n.args
  elseif (n.kind == "MethodCall") then
    return n.args
  end
  return {}
end

--- A walk of the tree kept for every rule to read: the nodes in source order, each one's parent and children by id.
local record Index
  order: {Ast.Node}
  parent: {integer: Ast.Node}
  kids: {integer: {Ast.Node}}
  --- The start of the last node that starts inside each node, by id: where a name a statement binds takes effect.
  last_start: {integer: integer}
end

local function index_of(subject: Subject): Index
  local order: mut {Ast.Node} = {}
  local kids: mut {integer: {Ast.Node}} = {}
  Node.walk(subject.chunk, function(n: Ast.Node)
    order[#order + 1] = n
    kids[Node.base(n).id] = Node.children(n)
  end)
  local tokens = subject.chunk.tokens
  local last_start: mut {integer: integer} = {}
  for i = #order, 1, -1 do
    local n = nth(order, i)
    local id = Node.base(n).id
    local last = nth(tokens.offset, Node.base(n).first)
    for _, child in ipairs(known(kids, id)) do
      local later = known(last_start, Node.base(child).id)
      if later > last then
        last = later
      end
    end
    last_start[id] = last
  end
  return { order = order, parent = Node.parents(subject.chunk), kids = kids, last_start = last_start }
end

--- The name of a function for a message and the exemption tables: a named function's own, a method as `Class:method`
--- under the declarations it is nested in.
local function function_name(index: Index, n: Ast.Node): string
  if (n.kind == "LocalFunction") then
    return n.name.name
  elseif (n.kind == "Function") then
    local names: mut {string} = {}
    for _, part in ipairs(n.path) do
      names[#names + 1] = part.text
    end
    return table.concat(names, ".")
  elseif (n.kind == "Method") then
    local names: mut {string} = {}
    local above = index.parent[Node.base(n).id]
    while above ~= nil do
      if (above.kind == "Class") then
        table.insert(names, 1, above.name.name)
      elseif (above.kind == "Record") then
        table.insert(names, 1, above.name.name)
      elseif (above.kind == "Interface") then
        table.insert(names, 1, above.name.name)
      else
        break
      end
      above = index.parent[Node.base(above).id]
    end
    return table.concat(names, ".") .. ":" .. n.name.name
  end
  return "a function literal"
end

--- Whether a function has a name of its own.
local function is_named(n: Ast.Node): boolean
  return (n.kind == "LocalFunction") or (n.kind == "Function") or (n.kind == "Method")
end

--- Every function literal a top-level statement binds, by what it is bound to: `f` in `f = function`, `R.g` in
--- `R.g = function`, and `t.g` in `local t = { g = function ... end }`.
local function bound_names(subject: Subject): {integer: string}
  local out: mut {integer: string} = {}
  --- The function literals of the items of a table constructor bound to `name`, as `name.key`.
  local function items(name: string, table_node: Ast.Table)
    for _, item in ipairs(table_node.items) do
      if (item.kind == "Named") then
        local held = item.value
        if (held.kind == "FunctionLit") then
          out[Node.base(held).id] = name .. "." .. item.name
        end
      elseif (item.kind == "Keyed") then
        local key, held = item.key, item.value
        if (key.kind == "String") and (held.kind == "FunctionLit") then
          out[Node.base(held).id] = name .. "." .. key.value
        end
      end
    end
  end
  local function bind(name: string, value: Ast.Exp?)
    if value == nil or name == "a call" then
      return
    end
    if (value.kind == "FunctionLit") then
      out[Node.base(value).id] = name
    elseif (value.kind == "Table") then
      items(name, value)
    end
  end
  for _, statement in ipairs(subject.chunk.body.stats) do
    if (statement.kind == "Assign") then
      for i, target in ipairs(statement.targets) do
        bind(spelled(target), statement.values[i])
      end
    elseif (statement.kind == "Local") then
      for i, b in ipairs(statement.bindings) do
        bind(b.name, statement.values[i])
      end
    end
  end
  return out
end

--- The name the exemption tables key the code of every node under (by id): a named function's own, under the named function
--- around it (`outer.inner`); what a top-level statement binds a literal to; and the name around it for any other node.
local function scope_names(index: Index, bound: {integer: string}): {integer: string}
  local out: mut {integer: string} = {}
  for _, n in ipairs(index.order) do
    local above = index.parent[Node.base(n).id]
    local within = ""
    if above ~= nil then
      within = known(out, Node.base(above).id)
    end
    local name = within
    local bound_name = bound[Node.base(n).id]
    if is_named(n) then
      local own = function_name(index, n)
      if within == "" then
        name = own
      else
        name = within .. "." .. own
      end
    elseif bound_name ~= nil then
      name = bound_name
    end
    out[Node.base(n).id] = name
  end
  return out
end

--- The line of the token with index `token`.
local function line_at(subject: Subject, token: integer): integer
  return Lexer.y(subject.chunk.tokens, token)
end

--- The line the fork gives a node: the open parenthesis of a call, the operator of a binary or cast operation, the
--- first token of anything else.
local function line_of(subject: Subject, n: Ast.Node): integer
  local base = Node.base(n)
  if (n.kind == "Call") then
    return line_at(subject, Node.base(n.callee).last + 1)
  elseif (n.kind == "MethodCall") then
    return line_at(subject, Node.base(n.object).last + 3)
  elseif (n.kind == "Binary") then
    return line_at(subject, Node.base(n.left).last + 1)
  elseif (n.kind == "Cast") then
    return line_at(subject, Node.base(n.value).last + 1)
  end
  return line_at(subject, base.first)
end

local function is_empty_string(n: Ast.Node): boolean
  return (n.kind == "String") and n.value == ""
end

local function is_failure(n: Ast.Node, effect: boolean): boolean
  if (n.kind == "Nil") then
    return true
  end
  return effect and (n.kind == "Boolean") and not n.value
end

local NEVER_NIL_BINARY <const>: {string: boolean} = {
  [".."] = true, ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true,
  ["=="] = true, ["~="] = true, ["<"] = true, [">"] = true, ["<="] = true, [">="] = true,
}

local NEVER_NIL_UNARY <const>: {string: boolean} = { ["#"] = true, ["not"] = true, ["-"] = true }

local NEVER_NIL_TAGS <const>: {string: boolean} = {
  string = true, integer = true, number = true, boolean = true, ["true"] = true, ["false"] = true, array = true, map = true,
  fn = true,
}

--- Whether a name's type cannot be nil: a string, number, boolean, collection, function, enum, record or class.
local function never_nil_type(t: Types.Type?): boolean
  if t == nil then
    return false
  end
  if NEVER_NIL_TAGS[t.tag] == true then
    return true
  end
  if (t.tag == "named") and not t.value then
    local kind = t.decl.kind
    return kind == "record" or kind == "class" or kind == "enum"
  end
  return false
end

--- Whether an expression cannot be nil: a literal, a constructor, an operator whose result is never nil, or a name the
--- checker typed as something that cannot be.
local function never_nil(subject: Subject, n: Ast.Node): boolean
  if (n.kind == "String") or (n.kind == "Integer") or (n.kind == "Float") or (n.kind == "Boolean") or (n.kind == "Table") or (n.kind == "FunctionLit") then
    return true
  elseif (n.kind == "Name") then
    return never_nil_type(subject.types[Node.base(n).id])
  elseif (n.kind == "Binary") then
    return NEVER_NIL_BINARY[n.op] == true
  elseif (n.kind == "Unary") then
    return NEVER_NIL_UNARY[n.op] == true
  end
  return false
end

--- The exemptions a check found use for, by table, `"file:function"` each: one never used names nothing it excuses.
local record Used
  exempt: mut {string: boolean}
  parsing: mut {string: boolean}
  casts: mut {string: boolean}
  modes: mut {string: boolean}
end

--- The state one check keeps for its rules.
local record Run
  subject: Subject
  index: Index
  exemptions: Rules.Exemptions
  --- The modules the sources of the build declare tables of C bindings ([`build.driver`]'s `bindings`), beside the ones
  --- the generator derives.
  declared: {string}
  used: Used
  problems: mut {string}
  sites: mut {string: integer}
  --- The name the exemption tables key the code of each node under, by id.
  mut scopes: {integer: string}
  --- The line of each `function M.R.f(...)` statement, by its path.
  static_lines: mut {string: integer}
end

local function judged(run: Run, rule: string)
  run.sites[rule] = (run.sites[rule] or 0) + 1
end

local function report(run: Run, line: integer, text: string)
  table.insert(run.problems, string.format("%s:%d: %s", run.subject.file, line, text))
end

local function callee_fn(run: Run, call: Ast.Node): Types.Type?
  return run.subject.callees[Node.base(call).id]
end

-- Rules 2 to 5 -----------------------------------------------------------------------------------------------------

--- Every return statement that belongs to the function with `body` itself, not to a function nested in it.
local function returns_of(run: Run, body: Ast.Block): {Ast.Return}
  local out: mut {Ast.Return} = {}
  local function go(n: Ast.Node)
    if (n.kind == "Return") then
      out[#out + 1] = n
    end
    for _, child in ipairs(known(run.index.kids, Node.base(n).id)) do
      if not is_function(child) then
        go(child)
      end
    end
  end
  go(body)
  return out
end

--- The types a return list declares: nil where it declares none, or is one of several lists, or names a narrowing.
local function declared_results(run: Run, rets: Ast.Rets?): {Types.Type}?
  if rets == nil or #rets.lists ~= 1 then
    return nil
  end
  local out: mut {Types.Type} = {}
  for _, item in ipairs(rets.lists[1]) do
    local t = run.subject.types[item.id]
    if t == nil then
      return nil
    end
    out[#out + 1] = t
  end
  return out
end

--- Rules 2 to 5, over one function's declared results and returns. A stand-in for a [`cosmic.sys`] binding keeps the
--- binding's third slot, so rule 5 does not read it, nor does rule 2 read a return that hands the binding's whole answer on,
--- errno and all.
local function check_function(run: Run, fn: Ast.Node, parts: Parts, stand_in: boolean)
  local rets = parts.rets
  local declared = declared_results(run, rets)
  if rets == nil or declared == nil or #declared < 2 then
    return
  end
  local effect = tag_of(declared[1]) == "boolean"
  local value = admits_nil(declared[1])
  if not effect and not value then
    return
  end
  judged(run, "functions")
  local file = run.subject.file
  local name = function_name(run.index, fn)
  local scope = known(run.scopes, Node.base(fn).id)
  -- TODO: mark an exemption used only where a rule 2 to 5 would have refused the function, so an entry for a function that
  -- keeps the discipline is reported stale too; that wants the rules run whole and their problems dropped, rather than
  -- skipped at this lookup (carried over from build/contracts.tl).
  if run.exemptions.exempt[file .. ":" .. scope] ~= nil then
    run.used.exempt[file .. ":" .. scope] = true
    return
  end
  local line = line_of(run.subject, fn)
  local second = declared[2]
  if tag_of(second) ~= "string" then
    -- A boolean beside a count (`boolean, integer`) is two answers, not a failure; beside a value that admits nil, an
    -- integer is an error code standing where the reason belongs.
    if (value and tag_of(second) == "integer") or holds(second, "string") then
      report(run, line, string.format("%s: a failure's reason is exactly a string; this second result is not", name))
    end
    return
  end
  -- A variadic tail (`T | nil, string...`) is as many slots as a caller cares to bind.
  if (#declared > 2 or rets.variadic) and not stand_in then
    report(run, line, string.format("%s: a fallible function answers two results and nothing in a third; " ..
        "fold it into the reason or a structured error record (only cosmic.sys answers an errno)", name))
    return
  end
  local returns = returns_of(run, parts.body)
  local all_values = #returns > 0
  for _, r in ipairs(returns) do
    local exps = r.values
    -- A stand-in hands a binding's answer on as three names it bound.
    local e1, e2, e3 = exps[1], exps[2], exps[3]
    local handed_on = stand_in and e1 ~= nil and e2 ~= nil and e3 ~= nil and #exps == 3 and
      (e1.kind == "Name") and (e2.kind == "Name") and (e3.kind == "Name")
    if e1 ~= nil and e2 ~= nil and not handed_on and not is_empty_string(e2) and not is_failure(e1, effect) then
      report(run, line_at(run.subject, Node.base(r).first), string.format(
        "%s: a failure answers %s beside its reason, never a value; a success's reason is \"\"", name,
        if effect then "false" else "nil" end))
    end
    if #exps ~= 2 or e1 == nil or e2 == nil or not is_empty_string(e2) or not never_nil(run.subject, e1) then
      all_values = false
    end
  end
  if value and all_values then
    report(run, line, string.format("%s: every return answers a value, so the declared failure never happens; " ..
        "return the value alone", name))
  end
end

-- Rule 1 -----------------------------------------------------------------------------------------------------------

--- Whether `call` is a call of the global `assert`, which answers what it is given and is no failure of its own: the fork
--- read its type as an overloaded function and judged none.
local function is_assert(call: Ast.Node): boolean
  if (call.kind == "Call") then
    local callee = call.callee
    return (callee.kind == "Name") and callee.text == "assert" and callee.binding == nil
  end
  return false
end

--- Whether a call hands its last argument's reason on: `assert`, or a callee whose required, not variadic parameters end
--- exactly where the argument's results do, with a `string` for the reason to land in.
local function takes_reason(run: Run, call: Ast.Node, count: integer): boolean
  if (call.kind == "Call") then
    local callee = call.callee
    if (callee.kind == "Name") and callee.text == "assert" and callee.binding == nil then
      return true
    end
  end
  local f = callee_fn(run, call)
  if f == nil or not ((f.tag == "fn")) or f.rest ~= nil then
    return false
  end
  -- A method call's receiver is the first parameter.
  local slot = count + 1 + (if (call.kind == "MethodCall") then 1 else 0 end)
  local final = arguments_of(call)[count]
  local last = slot - 2
  if final ~= nil then
    last = last + result_count(callee_fn(run, final))
  end
  if last ~= #f.params or required(f) < last then
    return false
  end
  local param = f.params[slot]
  return param ~= nil and tag_of(param.type) == "string"
end

--- Every place a call keeps all of its results: the last expression of a list bound to more names than it has expressions,
--- the last value of a return, and the last argument of a call that takes a reason.
local function keeping(run: Run): {integer: boolean}
  local kept: mut {integer: boolean} = {}
  for _, n in ipairs(run.index.order) do
    if (n.kind == "Local") then
      if #n.values > 0 and #n.bindings > #n.values then
        kept[Node.base(assert(n.values[#n.values])).id] = true
      end
    elseif (n.kind == "Assign") then
      if #n.values > 0 and #n.targets > #n.values then
        kept[Node.base(assert(n.values[#n.values])).id] = true
      end
    elseif (n.kind == "Return") then
      if #n.values > 0 then
        kept[Node.base(assert(n.values[#n.values])).id] = true
      end
    elseif is_call(n) then
      local args = arguments_of(n)
      local final = args[#args]
      if final ~= nil and takes_reason(run, n, #args) then
        kept[Node.base(final).id] = true
      end
    end
  end
  return kept
end

--- Every call standing alone as a statement.
local function standing(run: Run): {integer: boolean}
  local out: mut {integer: boolean} = {}
  for _, n in ipairs(run.index.order) do
    if (n.kind == "CallStat") then
      out[Node.base(n.call).id] = true
    end
  end
  return out
end

--- Whether a call is of a method of a record some module names quiet (`quieted`).
local function is_quiet(run: Run, call: Ast.Node): boolean
  local object: Ast.Exp?
  local name: string?
  if (call.kind == "Call") then
    local callee = call.callee
    if (callee.kind == "Field") then
      object, name = callee.object, callee.name
    end
  elseif (call.kind == "MethodCall") then
    object, name = call.object, call.name
  end
  if object == nil or name == nil then
    return false
  end
  local decl = Report.decl_of(run.subject.types[Node.base(object).id])
  if decl == nil then
    return false
  end
  local owner = Report.owner_of(run.subject.program, decl)
  if owner == nil then
    return false
  end
  local entry = Rules.quiet_entries()[owner.module .. " " .. owner.path]
  return entry ~= nil and entry.methods[name] == true
end

--- The record each table of C bindings is, by declaration, to its module's name: the tables the new checker types from the
--- declarations of the modules the build derives from their headers ([`build.gen_syscalls`]'s `targets`, which a project's
--- binary carries) and from those the sources of the build declare a binding (`run.declared`,
--- [`build.driver`]'s `bindings`).
local function binding_tables(run: Run): {Types.Decl: string}
  local out: mut {Types.Decl: string} = {}
  local names: mut {string} = {}
  for _, target in ipairs(GenSyscalls.targets) do names[#names + 1] = target.path end
  for _, name in ipairs(run.declared) do names[#names + 1] = name end
  for _, name in ipairs(names) do
    local root = Report.root_of(run.subject.program, name)
    if root ~= nil then
      out[root] = name
    elseif run.subject.program.modules[name] ~= nil then
      -- A program without the module (it requires none, or `external` leaves it untyped) has no calls to judge; one
      -- that holds it as something that is no table has lost it from the contract, which must be told.
      table.insert(run.problems, string.format("%s: %s is a table of C bindings, but the program holds a module of " ..
          "that name that declares no table: its calls are no longer held to the contract", run.subject.file, name))
    end
  end
  return out
end

--- The functions stored into a field of a table of C bindings, which answer in the binding's own shape: the table is known by
--- the type the checker gave the field's owner, whatever the owner is called.
local function stand_ins(run: Run): {integer: boolean}
  local tables = binding_tables(run)
  local out: mut {integer: boolean} = {}
  for _, n in ipairs(run.index.order) do
    if (n.kind == "Assign") then
      for i, target in ipairs(n.targets) do
        local stored = n.values[i]
        if (target.kind == "Field") and stored ~= nil and (stored.kind == "FunctionLit") then
          local decl = Report.decl_of(run.subject.types[Node.base(target.object).id])
          if decl ~= nil and tables[decl] ~= nil then
            out[Node.base(stored).id] = true
          end
        end
      end
    end
  end
  return out
end

-- Rule 6 -----------------------------------------------------------------------------------------------------------

--- The string methods that read a message for what it says, rule 6's concern: a caller that finds, matches, or cuts a
--- reason is parsing it.
local INSPECTING <const>: {string: boolean} = { find = true, match = true, gmatch = true, sub = true, byte = true }

local COMPARING <const>: {string: boolean} = {
  ["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true,
}

--- Methods that answer the text they are called on, reshaped: a read through one is a read of the text itself.
local RESHAPING <const>: {string: boolean} = { lower = true, upper = true }

--- The name under what only wraps it -- `(err)`, `tostring(err)`, `err:lower()` -- or nil when `n` is no name so wrapped.
--- It gives up, answering nil, past 8 wrappers.
local function unwrapped(n: Ast.Node?): Ast.Name?
  local at = n
  for _ = 1, 8 do
    if at == nil then
      return nil
    elseif (at.kind == "Name") then
      return at
    elseif (at.kind == "Paren") then
      at = at.inner
    elseif (at.kind == "Call") then
      local callee = at.callee
      if (callee.kind == "Name") and callee.text == "tostring" and #at.args == 1 then
        at = at.args[1]
      else
        return nil
      end
    elseif (at.kind == "MethodCall") then
      if RESHAPING[at.name] == true and #at.args == 0 then
        at = at.object
      else
        return nil
      end
    else
      return nil
    end
  end
  return nil
end

--- Whether `n` is what a reason may be compared with: `""` or `nil`, or one of the two words every wait answers,
--- [`Poll.TIMEOUT`] and [`Poll.CANCELLED`], which a caller tells a deadline or a cancel from a failure by.
local function neutral(n: Ast.Node): boolean
  if (n.kind == "Nil") or is_empty_string(n) then
    return true
  end
  if (n.kind == "Field") then
    local object = n.object
    return (object.kind == "Name") and object.text == "Poll" and (n.name == "TIMEOUT" or n.name == "CANCELLED")
  end
  return false
end

-- TODO: a reason read any other way is not seen: stored in a field (`t.e = err`, then `t.e:find`), a string function kept
-- in a local (`local sf = string.find`), the reason as another call's argument (`name():find(err)`, a pattern), a table
-- keyed by it (`m[err]`), its length (`#err`), a `gsub`'s count, or a name that an assignment in an inner block rebinds to
-- something else before a later read. Each wants data flow over values and fields rather than names, which waits on the
-- variable resolution of the scope builder being followed (carried over from build/contracts.tl).

--- The names `n` reads a reason's content through: `err` in `err:find(...)`, `string.match(err, ...)`, `err == "timeout"`,
--- and the same through `(err)`, `tostring(err)` and `err:lower()`. Which of them hold a reason is the caller's to decide.
local function inspected(n: Ast.Node): {Ast.Name}
  local out: mut {Ast.Name} = {}
  if (n.kind == "Binary") then
    if COMPARING[n.op] == true then
      local left, right = unwrapped(n.left), unwrapped(n.right)
      if left ~= nil and not neutral(n.right) then
        out[#out + 1] = left
      end
      if right ~= nil and not neutral(n.left) then
        out[#out + 1] = right
      end
    end
  elseif (n.kind == "MethodCall") then
    if INSPECTING[n.name] == true then
      local name = unwrapped(n.object)
      if name ~= nil then
        out[1] = name
      end
    end
  elseif (n.kind == "Call") then
    local callee = n.callee
    if (callee.kind == "Field") and INSPECTING[callee.name] == true then
      local receiver = callee.object
      if (receiver.kind == "Name") and receiver.text == "string" then
        local name = unwrapped(n.args[1])
        if name ~= nil then
          out[1] = name
        end
      end
    end
  end
  return out
end

-- TODO: a reason assigned in an inner block (`local ok, err` then `ok, err = f()` inside an `if`) is followed past the block by
-- `holds_reason` guessing which local it stored into from where the declarations before it end; resolve it exactly with the
-- scope builder's binding of the name (carried over from build/contracts.tl).

--- A name an inspection of a failure's reason reads, and the call or index that inspects it.
local record Reading
  read: Ast.Node
  via: Ast.Node
end

--- One place a name is bound, in source order: rule 6 follows a reason from where a fallible call binds it to where
--- another binding of the name takes over.
local record Binding
  at: integer
  --- Where the name's scope ends: its block's end for a `local`, a loop variable, or a parameter; an assignment's own
  --- block's end, after which rule 6 no longer follows the name.
  ends: integer
  --- Whether the name is declared here (it shadows until `ends`) rather than assigned (it replaces whatever was there).
  declared: boolean
  --- Whether a fallible call's reason is what the name is bound to.
  reason: boolean
  --- The name this one was bound to alone (`local a = err`), whose binding at that point says whether this one holds a
  --- reason.
  alias: Ast.Name?
end

--- A block's end, as one offset: the end of the source for the module's own block.
local function block_end(subject: Subject, block: Ast.Block): integer
  local tokens = subject.chunk.tokens
  if tokens.kind[block.close] == "$EOF$" then
    return math.maxinteger
  end
  return Lexer.offset(tokens, block.close)
end

--- The index of the value a statement binds to a fallible call's reason: 2 in `local v, err = f()`; nil when the
--- statement binds none.
local function reason_slot(run: Run, values: {Ast.Exp}, count: integer): integer?
  local last = values[#values]
  if last == nil or count <= #values or not is_call(last) then
    return nil
  end
  if not fallible_type(callee_fn(run, last)) then
    return nil
  end
  return #values + 1
end

--- Rule 6: a reason bound to a name is passed on, compared with `""`, or made part of a new message, never read for what it
--- says. Every binding of every name is kept with the scope it holds in, and an inspection is flagged when the binding it
--- reads is a reason's. A name bound to another name alone (`local a = err`) holds whatever that one does.
local function check_inspections(run: Run)
  local subject = run.subject
  local index = run.index
  local tokens = subject.chunk.tokens
  local bindings: mut {string: mut {Binding}} = {}
  local reads: mut {Reading} = {}
  --- Binds the name `name` from `at` on. A `local` or an assignment binds after its own right-hand side, which reads the
  --- binding before it.
  local function bind(name: string, at: integer, ends: integer, declared: boolean, reason: boolean, alias?: Ast.Name)
    if name == "_" then
      return
    end
    local list = bindings[name] or {}
    bindings[name] = list
    list[#list + 1] = { at = at, ends = ends, declared = declared, reason = reason, alias = alias }
  end
  local ending: mut {integer: integer} = {}
  for _, n in ipairs(index.order) do
    local id = Node.base(n).id
    local above = index.parent[id]
    local ends = math.maxinteger
    if above ~= nil then
      ends = known(ending, Node.base(above).id)
    end
    if (n.kind == "Block") then
      ends = block_end(subject, n)
    end
    ending[id] = ends
    if (n.kind == "Local") then
      local slot = reason_slot(run, n.values, #n.bindings)
      local after = known(index.last_start, id) + 1
      for i, b in ipairs(n.bindings) do
        bind(b.name, after, ends, true, i == slot, unwrapped(n.values[i]))
      end
    elseif (n.kind == "Assign") then
      local slot = reason_slot(run, n.values, #n.targets)
      local after = known(index.last_start, id) + 1
      for i, target in ipairs(n.targets) do
        if (target.kind == "Name") then
          bind(target.text, after, ends, false, i == slot, unwrapped(n.values[i]))
        end
      end
    elseif (n.kind == "ForIn") then
      for _, v in ipairs(n.vars) do
        bind(v.name, Lexer.offset(tokens, Node.base(v).first), block_end(subject, n.body), true, false)
      end
    elseif (n.kind == "ForNum") then
      bind(n.var.name, Lexer.offset(tokens, Node.base(n.var).first), block_end(subject, n.body), true, false)
    else
      local parts = parts_of(n)
      if parts ~= nil then
        for _, param in ipairs(parts.params) do
          local pname = param.name
          if pname ~= nil then
            bind(pname.name, Lexer.offset(tokens, Node.base(pname).first), block_end(subject, parts.body), true, false)
          end
        end
      end
    end
    local reading = inspected(n)
    if #reading > 0 then
      local scope = known(run.scopes, id)
      local key = subject.file .. ":" .. scope
      if run.exemptions.parsing[key] == nil then
        for _, read in ipairs(reading) do
          reads[#reads + 1] = { read = read, via = n }
        end
      else
        run.used.parsing[key] = true
      end
    end
  end
  for _, list in pairs(bindings) do
    table.sort(list, function(a: Binding, b: Binding): boolean
      return a.at < b.at
    end)
  end
  --- Whether the assignment `list[i]` stored into a local whose scope has closed before `at`: a declaration before it whose
  --- scope holds the assignment's block and ends before `at`. Such a store is not what `at` reads.
  local function into_closed(list: {Binding}, i: integer, at: integer): boolean
    local b = nth(list, i)
    for j = i - 1, 1, -1 do
      local d = nth(list, j)
      if d.declared and d.ends >= b.ends and d.ends < at then
        return true
      end
    end
    return false
  end
  --- Whether `name`, read at `at`, holds a reason. An alias is always bound after the name it copies is read, so this only
  --- looks back.
  local function holds_reason(name: string, at: integer): boolean
    local list = bindings[name] or {}
    for i = #list, 1, -1 do
      local b = nth(list, i)
      -- A declaration whose scope has closed stood in an inner block: the one before it is what this reads.
      if b.at <= at and (not b.declared or b.ends >= at) then
        -- An assignment in an inner block that has closed may not have run: what it stored is read only when it stored a
        -- reason into a name still in scope, and what came before may be read too.
        if b.ends < at then
          if b.reason and not into_closed(list, i, at) then
            return true
          end
        else
          if b.reason then
            return true
          end
          local alias = b.alias
          if alias == nil then
            return false
          end
          local from = nth(tokens.offset, Node.base(alias).first)
          return from < b.at and holds_reason(alias.text, from)
        end
      end
    end
    return false
  end
  local flagged: mut {integer: boolean} = {}
  for _, pair in ipairs(reads) do
    local read, via = pair.read, pair.via
    judged(run, "readings")
    if (read.kind == "Name") and flagged[Node.base(via).id] ~= true and holds_reason(read.text, Lexer.offset(tokens, Node.base(read).first)) then
      flagged[Node.base(via).id] = true
      report(run, line_of(subject, via), string.format("%s: a failure's reason is read for what it says; a failure with " ..
          "meaning answers it in a shape of its own (a value, a field, a record), not a message to parse", read.text))
    end
  end
end

-- Rule 7 -----------------------------------------------------------------------------------------------------------

-- TODO: stop trusting a name a later top-level statement assigns something else (`extra = other`), which this does not
-- follow; it wants the same binding-by-position tracking rule 6 does, shared rather than written again (carried over from
-- build/contracts.tl).

--- Every name a top-level `local` binds to the raw module the core hands this chunk, `select(2, ...)`.
local function handed_names(subject: Subject): {string: boolean}
  local out: mut {string: boolean} = {}
  for _, statement in ipairs(subject.chunk.body.stats) do
    if (statement.kind == "Local") then
      for i, b in ipairs(statement.bindings) do
        local e = statement.values[i]
        if e ~= nil and (e.kind == "Call") then
          local callee = e.callee
          local first, second = e.args[1], e.args[2]
          if (callee.kind == "Name") and callee.text == "select" and #e.args == 2 and first ~= nil and (first.kind == "Integer") and
              first.value == 2 and second ~= nil and (second.kind == "Vararg") then
            out[b.name] = true
          end
        end
      end
    end
  end
  return out
end

--- Rule 7: every cast in a function `casts` does not name, but for the top level's cast of the raw module the core hands the
--- chunk (`local extra: any = select(2, ...)`, then `extra as raw_hash`): a chunk's arguments have no type Teal can give them.
local function check_casts(run: Run)
  local handed = handed_names(run.subject)
  for _, n in ipairs(run.index.order) do
    if (n.kind == "Cast") then
      judged(run, "casts")
      local scope = known(run.scopes, Node.base(n).id)
      local operand: Ast.Exp = n.value
      while (operand.kind == "Paren") do
        operand = operand.inner
      end
      local key = run.subject.file .. ":" .. scope
      if scope == "" and (operand.kind == "Name") and handed[operand.text] == true then
        -- the raw module, handed to the chunk
        local _ = operand
      elseif run.exemptions.casts[key] ~= nil then
        run.used.casts[key] = true
      else
        report(run, line_of(run.subject, n), string.format("%s: a cast tells the checker what it could not prove; tighten the " ..
            "declaration, narrow with `is`, or name the function in build/contract_rules.tl's casts with the reason",
          if scope == "" then "the top level" else scope end))
      end
    end
  end
end

--- The members of a record, interface or class.
local function members_of(n: Ast.Node): {Ast.Member}
  if (n.kind == "Record") then
    return n.members
  elseif (n.kind == "Interface") then
    return n.members
  elseif (n.kind == "Class") then
    return n.members
  end
  return {}
end

-- Rules 10 and 11 --------------------------------------------------------------------------------------------------

--- One function a module exports: its name as a caller spells it (`M.f`, `M.Reader:read`) and the type the checker gave it.
local record Exported
  name: string
  type: Types.Fn
  line: integer
end

--- `key` under `path`, as a caller spells it: `M.f`, `M:f`, or `f` alone at the top of a module that returns a constructor.
local function joined(path: string, key: string, method: boolean): string
  if path == "" then
    return key
  end
  return path .. (if method then ":" else "." end) .. key
end

--- Every function the declaration `root` the module returns holds, and every record declared inside it, by its exported
--- name, in source order: the function-typed fields of a record or interface, and the methods of a class.
local function exported_functions(run: Run): {Exported}
  local out: mut {Exported} = {}
  local subject = run.subject
  local root = Report.root_of(subject.program, subject.lowered.module)
  if root == nil then
    return out
  end
  -- The module's name for its answer is the one its last statement returns (`return Zip`, or `return m` for a local typed as
  -- the record), as a caller spells a member.
  local statements = subject.chunk.body.stats
  local last = statements[#statements]
  local first = if last ~= nil and (last.kind == "Return") then last.values[1] else nil end
  local spelling = root.names[1]
  if spelling == nil then
    return out
  end
  if first ~= nil and (first.kind == "Name") then
    spelling = first.text
  end
  for _, n in ipairs(run.index.order) do
    local decl = subject.lowered.decls[Node.base(n).id]
    if decl ~= nil and decl.module == root.module and decl.names[1] == root.names[1] and
        (decl.kind == "record" or decl.kind == "interface" or decl.kind == "class" or decl.kind == "userdata") then
      local prefix = spelling
      if #decl.names > 1 then
        prefix = spelling .. "." .. table.concat(decl.names, ".", 2)
      end
      -- The functions written `function M.f(...)` are the declaration's statics, not fields of its values.
      local statics = subject.program.statics[decl] or {}
      local static_names: mut {string} = {}
      for static in pairs(statics) do
        static_names[#static_names + 1] = static
      end
      table.sort(static_names)
      for _, static in ipairs(static_names) do
        local f = known(statics, static).type
        if (f.tag == "fn") then
          out[#out + 1] = { name = joined(prefix, static, false), type = f, line = run.static_lines[prefix .. "." .. static] or 0 }
        end
      end
      for _, member in ipairs(members_of(n)) do
        local at = line_at(subject, Node.base(member).first)
        if (member.kind == "FieldDecl") then
          -- A field of a function type is a function the module exports, written as the type or as a name that stands for
          -- it (`local type F = function(...)`, then `spread: F`): the type the checker gave the field is the one judged.
          -- A union of function types holds each function the field may be.
          local f = subject.types[Node.base(member.type).id]
          local held: mut {Types.Type} = {}
          if f ~= nil and (f.tag == "fn") then
            held[1] = f
          elseif f ~= nil and (f.tag == "union") then
            for _, member_type in ipairs(f.members) do
              held[#held + 1] = member_type
            end
          end
          for _, one in ipairs(held) do
            if (one.tag == "fn") then
              out[#out + 1] = { name = joined(prefix, member.name.name, false), type = one, line = at }
            end
          end
        elseif (member.kind == "Method") then
          local f = subject.types[Node.base(member).id]
          if f ~= nil and (f.tag == "fn") then
            out[#out + 1] = { name = joined(prefix, member.name.name, true), type = f, line = at }
          end
        end
      end
    end
  end
  return out
end

--- Rule 10, over every exported function's declared results.
local function check_exports(run: Run, exported: {Exported})
  local file = run.subject.file
  local said: mut {string: boolean} = {}
  for _, e in ipairs(exported) do
    local members, variadic = results_of(e.type)
    local results = members or {}
    local many = #results >= 2 or (variadic and #results >= 1)
    judged(run, "exports")
    if many and not fallible_results(results) then
      local key = file .. ":" .. e.name
      if run.exemptions.exempt[key] ~= nil then
        run.used.exempt[key] = true
      elseif said[key] ~= true then
        -- A field that may be one of several functions is told once.
        said[key] = true
        report(run, e.line, string.format("%s: an exported function answers one result, or a value or an effect and its " ..
            "reason; answer a record to hand back more", e.name))
      end
    end
  end
end

-- Rule 11 ----------------------------------------------------------------------------------------------------------

--- A function a module exports, and the node that defines it.
local record Defined
  node: Ast.Node
  exported: Exported
end

--- A name with its method colon read as a dot: `M.R:f` and `M.R.f` are one field.
local function dotted(name: string): string
  return (name:gsub(":", "."))
end

--- The function nodes that define the exported functions: a function statement named as one is exported (`function M.f`), and
--- so is a method of an exported class, and a literal or a local function a top-level statement stores into an exported
--- field (`M.f = f`, `local M: T = { f = f }`, `return { f = f }`).
local function exported_nodes(run: Run, exported: {Exported}): {Defined}
  local named: mut {string: Exported} = {}
  for _, e in ipairs(exported) do
    named[dotted(e.name)] = e
  end
  local locals: mut {string: Ast.Node} = {}
  local out: mut {Defined} = {}
  local function stored(value: Ast.Exp?, name: string)
    local e = named[name]
    if value == nil or e == nil then
      return
    end
    if (value.kind == "FunctionLit") then
      out[#out + 1] = { node = value, exported = e }
    elseif (value.kind == "Name") then
      local held = locals[value.text]
      if held ~= nil then
        out[#out + 1] = { node = held, exported = e }
      end
    end
  end
  local function fields_of(constructor: Ast.Table, prefix: string)
    for _, item in ipairs(constructor.items) do
      local key: string? = nil
      local value: Ast.Exp? = nil
      if (item.kind == "Named") then
        key, value = item.name, item.value
      elseif (item.kind == "Keyed") then
        local written = item.key
        if (written.kind == "String") then
          key, value = written.value, item.value
        end
      end
      if key ~= nil then
        if prefix == "" then
          stored(value, key)
        else
          stored(value, prefix .. "." .. key)
        end
      end
    end
  end
  for _, statement in ipairs(run.subject.chunk.body.stats) do
    if (statement.kind == "LocalFunction") then
      locals[statement.name.name] = statement
    elseif (statement.kind == "Function") then
      local e = named[dotted(function_name(run.index, statement))]
      if e ~= nil then
        out[#out + 1] = { node = statement, exported = e }
      end
    elseif (statement.kind == "Local") then
      for i, b in ipairs(statement.bindings) do
        local value = statement.values[i]
        if value ~= nil and (value.kind == "Table") then
          fields_of(value, b.name)
        elseif value ~= nil and (value.kind == "FunctionLit") then
          locals[b.name] = value
        else
          stored(value, b.name)
        end
      end
    elseif (statement.kind == "Assign") then
      for i, target in ipairs(statement.targets) do
        local value = statement.values[i]
        if value ~= nil and (value.kind == "Table") then
          fields_of(value, spelled(target))
        else
          stored(value, spelled(target))
        end
      end
    elseif (statement.kind == "Return") then
      local first = statement.values[1]
      if first ~= nil and (first.kind == "Table") then
        fields_of(first, "")
      end
    end
  end
  for _, n in ipairs(run.index.order) do
    if (n.kind == "Method") then
      local e = named[dotted(function_name(run.index, n))]
      if e ~= nil then
        out[#out + 1] = { node = n, exported = e }
      end
    end
  end
  return out
end

--- The fallible C binding the body of a function calls itself, not from a function nested in it, as `module.name`; nil when it
--- calls none.
local function binding_call_in(run: Run, body: Ast.Block): string?
  local tables = binding_tables(run)
  local function go(n: Ast.Node): string?
    local object: Ast.Exp? = nil
    local name: string? = nil
    if (n.kind == "Call") then
      local callee = n.callee
      if (callee.kind == "Field") then
        object, name = callee.object, callee.name
      end
    elseif (n.kind == "MethodCall") then
      object, name = n.object, n.name
    end
    if object ~= nil and name ~= nil and fallible_type(callee_fn(run, n)) then
      local decl = Report.decl_of(run.subject.types[Node.base(object).id])
      local module = decl ~= nil and tables[decl] or nil
      if module ~= nil then
        return module .. "." .. name
      end
    end
    for _, child in ipairs(known(run.index.kids, Node.base(n).id)) do
      if not is_function(child) then
        local found = go(child)
        if found ~= nil then
          return found
        end
      end
    end
    return nil
  end
  return go(body)
end

--- Rule 11, over every exported function defined in this module: one that answers a bare boolean over a fallible call of a
--- binding of C has dropped the reason a caller needs.
local function check_wrappers(run: Run, defined: {Defined})
  local file = run.subject.file
  for _, d in ipairs(defined) do
    local results = results_of(d.exported.type) or {}
    if tag_of(results[1]) == "boolean" and not fallible_results(results) then
      judged(run, "wrappers")
      local parts = parts_of(d.node)
      local binding: string? = nil
      if parts ~= nil then
        binding = binding_call_in(run, parts.body)
      end
      if binding ~= nil then
        local key = file .. ":" .. d.exported.name
        if run.exemptions.exempt[key] ~= nil then
          run.used.exempt[key] = true
        else
          report(run, line_of(run.subject, d.node), string.format("%s: calls %s itself and answers a bare boolean; answer " ..
              "its failure too: boolean, string", d.exported.name, binding))
        end
      end
    end
  end
end

-- Rule 8 -----------------------------------------------------------------------------------------------------------

--- The record, interface or class a top-level `local` declares, by the name it binds.
local function top_records(subject: Subject): {string: Ast.Node}
  local out: mut {string: Ast.Node} = {}
  for _, statement in ipairs(subject.chunk.body.stats) do
    if (statement.kind == "Record") and statement.scope == "local" then
      out[statement.name.name] = statement
    elseif (statement.kind == "Interface") and statement.scope == "local" then
      out[statement.name.name] = statement
    elseif (statement.kind == "Class") and statement.scope == "local" then
      out[statement.name.name] = statement
    end
  end
  return out
end

--- The name a type declaration binds, when `n` is one.
local function declared_name(n: Ast.Node): string?
  if (n.kind == "Record") or (n.kind == "Interface") or (n.kind == "Class") or (n.kind == "Enum") or (n.kind == "Alias") or (n.kind == "Import") then
    return n.name.name
  end
  return nil
end

--- The name the chunk's last statement returns (`return Zip`), when it returns one name, and the record that name holds: one
--- a `local record` of that name declares, or the one a top-level `local` of it is declared as (`local layout: Layout = {...}`).
local function returned(subject: Subject): string?, Ast.Node?
  local statements = subject.chunk.body.stats
  local last = statements[#statements]
  if last == nil or not ((last.kind == "Return")) then
    return nil, nil
  end
  local first = last.values[1]
  if first == nil or not ((first.kind == "Name")) then
    return nil, nil
  end
  local name = first.text
  local records = top_records(subject)
  if records[name] ~= nil then
    return name, records[name]
  end
  for _, statement in ipairs(statements) do
    if (statement.kind == "Local") and #statement.bindings == 1 and assert(statement.bindings[1]).name == name then
      local declared = statement.types[1]
      if declared ~= nil and (declared.kind == "TypeName") and #declared.path == 1 then
        return name, records[assert(declared.path[1])]
      end
    end
  end
  return name, nil
end

--- What follows `owner`'s name at the start of `field`, when `field` repeats it: the rest, empty for the name outright, or
--- starting with a capital. The case of the repeated part is not read, so `SQLiteHandle` repeats `Sqlite`; `Logger` does not
--- repeat `Log`.
local function repeated(owner: string, field: string): string?
  if field:sub(1, #owner):lower() ~= owner:lower() then
    return nil
  end
  local rest = field:sub(#owner + 1)
  if rest == "" or rest:match("^%u") ~= nil then
    return rest
  end
  return nil
end

--- Rule 8: a type the returned record declares, at any depth, whose name repeats the module's.
local function check_stutter(run: Run)
  local name, def = returned(run.subject)
  if name == nil or def == nil then
    return
  end
  local module_name: string = name
  local top: Ast.Node = def
  local function visit(path: string, at: Ast.Node)
    for _, member in ipairs(members_of(at)) do
      local field = declared_name(member)
      if field ~= nil then
        judged(run, "types")
        local rest = repeated(module_name, field)
        if rest ~= nil then
          report(run, line_at(run.subject, Node.base(member).first), string.format(
            "%s.%s: a type repeats its module's name, which every use already says; call it %s", path, field,
            if rest ~= "" then path .. "." .. rest else "by what it is" end))
        end
        if (member.kind == "Record") or (member.kind == "Interface") or (member.kind == "Class") then
          visit(path .. "." .. field, member)
        end
      end
    end
  end
  visit(module_name, top)
end

-- Rule 9 -----------------------------------------------------------------------------------------------------------

--- A string field of a record the chunk declares: where, and how its declaration reads (`Record.field`).
local record Declared
  path: string
  y: integer
end

--- Whether a field declared as `t` holds a string and nothing else but nil: `string`, or `string | nil`.
local function stringish(t: Types.Type?): boolean
  if t == nil then
    return false
  end
  if t.tag == "string" then
    return true
  end
  if (t.tag == "union") then
    local only = t.members[1]
    return #t.members == 1 and only ~= nil and only.tag == "string"
  end
  return false
end

--- Every string field (`stringish`) of every option record (`Options`, `...Options`) the chunk declares at its top level,
--- nested ones included, by the record's declaration and then the field's name.
local function string_fields(run: Run): {Types.Decl: {string: Declared}}
  local out: mut {Types.Decl: mut {string: Declared}} = {}
  local subject = run.subject
  local function visit(path: string, at: Ast.Node)
    local decl = subject.lowered.decls[Node.base(at).id]
    for _, member in ipairs(members_of(at)) do
      if (member.kind == "FieldDecl") then
        if decl ~= nil and stringish(subject.types[Node.base(member.type).id]) and path:match("Options$") ~= nil then
          local own = out[decl] or {}
          own[member.name.name] = { path = path .. "." .. member.name.name, y = line_at(subject, Node.base(member.type).first) }
          out[decl] = own
        end
      elseif (member.kind == "Record") or (member.kind == "Interface") or (member.kind == "Class") then
        visit(path .. "." .. member.name.name, member)
      end
    end
  end
  local names: mut {string} = {}
  local records = top_records(subject)
  for name in pairs(records) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    visit(name, known(records, name))
  end
  return out
end

--- Rule 9: a string field of the module's own option records that the module compares with two or more literals other than
--- `""`.
---
--- A name holding a field's value is kept by the function that binds it -- a `local`, an assignment to one, or a local
--- function's parameter the value is passed to -- and read back from the innermost function around a use that binds that
--- name at all, so a same-named local elsewhere is not taken for it. Blocks within one function are not told apart. A value
--- read any other way is not followed: `o.x:match(...)` or `o.x:find(...)` telling modes apart, a lookup table keyed by it
--- (`handlers[o.x]`), a field of another record it is copied into, or a function that is not a local one (`R.f(o.x)`). Such a
--- mode goes unchecked rather than refused.
local function check_modes(run: Run)
  local declared = string_fields(run)
  if next(declared) == nil then
    return
  end
  local subject = run.subject
  local index = run.index
  -- Each local function by its name, for a call to bind its parameters.
  local functions: mut {string: Ast.Node} = {}
  -- The names each function binds, and those holding a field's value.
  local binds: mut {integer: mut {string: boolean}} = {}
  local holding: mut {integer: mut {string: Declared}} = {}
  local function bind(scope: Ast.Node, name: string?, field: Declared?)
    if name == nil then
      return
    end
    local own = binds[Node.base(scope).id] or {}
    own[name] = true
    binds[Node.base(scope).id] = own
    local held = holding[Node.base(scope).id] or {}
    if field ~= nil then
      held[name] = field
    end
    holding[Node.base(scope).id] = held
  end
  -- The functions around the node being visited, innermost last; the chunk itself is the first.
  local stack: mut {Ast.Node} = { subject.chunk }
  local function scope_binding(name: string): Ast.Node?
    for i = #stack, 1, -1 do
      local scoped = nth(stack, i)
      local own = binds[Node.base(scoped).id]
      if own ~= nil and own[name] == true then
        return scoped
      end
    end
    return nil
  end
  local literals: mut {Declared: mut {string: boolean}} = {}
  local function note(field: Declared, literal: Ast.Node?)
    if literal ~= nil and (literal.kind == "String") and literal.value ~= "" then
      local set = literals[field] or {}
      set[literal.value] = true
      literals[field] = set
    end
  end
  --- The field whose value `e` is, if any.
  local function field_of(e: Ast.Node?): Declared?
    local at = e
    while at ~= nil and (at.kind == "Paren") do
      at = at.inner
    end
    if at == nil then
      return nil
    elseif (at.kind == "Name") then
      local scope = scope_binding(at.text)
      local held = scope ~= nil and holding[Node.base(scope).id] or nil
      return held ~= nil and held[at.text] or nil
    elseif (at.kind == "Field") then
      local decl = Report.decl_of(subject.types[Node.base(at.object).id])
      local own: {string: Declared}? = nil
      if decl ~= nil then
        own = declared[decl]
      end
      if own == nil then
        return nil
      end
      return own[at.name]
    elseif (at.kind == "Binary") and at.op == "or" then
      local field = field_of(at.left)
      if field ~= nil then
        note(field, at.right)
      end
      return field
    end
    return nil
  end
  local function visit(n: Ast.Node)
    if (n.kind == "LocalFunction") then
      functions[n.name.name] = n
      bind(nth(stack, #stack), n.name.name, nil)
    end
    local parts = parts_of(n)
    if parts ~= nil then
      for _, param in ipairs(parts.params) do
        local pname = param.name
        if pname ~= nil then
          bind(n, pname.name, nil)
        end
      end
      stack[#stack + 1] = n
      for _, child in ipairs(known(index.kids, Node.base(n).id)) do
        visit(child)
      end
      stack[#stack] = nil
      return
    end
    if (n.kind == "Local") then
      for i, b in ipairs(n.bindings) do
        local field = field_of(n.values[i])
        bind(nth(stack, #stack), b.name, field)
        -- A name bound again to anything else holds no field from here.
        local held = holding[Node.base(nth(stack, #stack)).id]
        if field == nil and held ~= nil then
          held[b.name] = nil
        end
      end
    elseif (n.kind == "Assign") then
      for i, target in ipairs(n.targets) do
        local field = field_of(n.values[i])
        if field ~= nil and (target.kind == "Name") then
          local scope = scope_binding(target.text)
          if scope ~= nil then
            bind(scope, target.text, field)
          end
        end
      end
    elseif (n.kind == "Call") then
      local callee = n.callee
      local fn: Ast.Node? = nil
      if (callee.kind == "Name") then
        fn = functions[callee.text]
      end
      if fn ~= nil then
        local called = parts_of(fn)
        local params: {Ast.Param} = {}
        if called ~= nil then
          params = called.params
        end
        for i, argument in ipairs(n.args) do
          local field = field_of(argument)
          local param = params[i]
          local pname = param ~= nil and param.name or nil
          if field ~= nil and pname ~= nil then
            bind(fn, pname.name, field)
          end
        end
      end
    elseif (n.kind == "Binary") and (n.op == "==" or n.op == "~=") then
      local left, right = field_of(n.left), field_of(n.right)
      if left ~= nil then
        note(left, n.right)
      end
      if right ~= nil then
        note(right, n.left)
      end
    end
    for _, child in ipairs(known(index.kids, Node.base(n).id)) do
      visit(child)
    end
  end
  -- Twice, so a value passed to a function declared before the call that passes it is followed as one declared after.
  visit(subject.chunk)
  visit(subject.chunk)
  local fields: mut {Declared} = {}
  for field in pairs(literals) do
    fields[#fields + 1] = field
  end
  table.sort(fields, function(a: Declared, b: Declared): boolean
    return a.path < b.path
  end)
  for _, field in ipairs(fields) do
    local spelled_set: mut {string} = {}
    for literal in pairs(known(literals, field)) do
      spelled_set[#spelled_set + 1] = string.format("%q", literal)
    end
    table.sort(spelled_set)
    judged(run, "modes")
    local key = subject.file .. ":" .. field.path
    if #spelled_set >= 2 then
      if run.exemptions.modes[key] ~= nil then
        run.used.modes[key] = true
      else
        report(run, field.y, string.format("%s: a string compared with %s is a closed set of modes; declare an enum, or " ..
            "name it in build/contract_rules.tl's modes with why", field.path, table.concat(spelled_set, ", ")))
      end
    end
  end
end

-- The check ----------------------------------------------------------------------------------------------------------

--- An exemption `file`'s check never needed: its function is gone, or no longer does what the table excuses. No table may
--- name a function of build/importer.tl, whatever module is checked: a test's tree stands a stub in for it, to be taken for
--- cosmic's own, and the stub has none of them, so the entry would be stale in every such tree.
local function stale(run: Run, name: string, exemptions: {string: string}, used: {string: boolean})
  local file = run.subject.file
  local prefix = file .. ":"
  local stubbed = "build/importer.tl:"
  local keys: mut {string} = {}
  for key in pairs(exemptions) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if String.starts_with(key, stubbed) then
      table.insert(run.problems, string.format("%s: contracts.%s names %s; no table may name a function of " ..
          "build/importer.tl, which a test's tree stubs", file, name, key))
    elseif String.starts_with(key, prefix) and used[key] ~= true then
      table.insert(run.problems, string.format("%s: contracts.%s names %s, which no longer needs it; drop the entry",
        file, name, key))
    end
  end
end

local function problem_line(problem: string): integer
  return math.tointeger(tonumber(problem:match("^[^:]*:(%d+):"))) or 0
end

function SyntaxContracts.check(subject: Subject, given?: Rules.Exemptions, declared?: {string}): SyntaxContracts.Result
  local run: Run = {
    subject = subject, index = index_of(subject), exemptions = given or Rules.own_exemptions(), declared = declared or {},
    used = { exempt = {}, parsing = {}, casts = {}, modes = {} }, problems = {}, sites = {}, scopes = {}, static_lines = {},
  }
  run.scopes = scope_names(run.index, bound_names(subject))
  for _, n in ipairs(run.index.order) do
    if (n.kind == "Function") then
      local names: mut {string} = {}
      for _, part in ipairs(n.path) do
        names[#names + 1] = part.text
      end
      run.static_lines[table.concat(names, ".")] = line_at(subject, Node.base(n).first)
    end
  end
  for _, rule in ipairs(SyntaxContracts.rules) do
    run.sites[rule] = 0
  end
  local kept, statements, stood = keeping(run), standing(run), stand_ins(run)
  local untyped = 0
  for _, n in ipairs(run.index.order) do
    if is_call(n) and callee_fn(run, n) == nil then
      local is_require = false
      if (n.kind == "Call") then
        local callee = n.callee
        is_require = (callee.kind == "Name") and callee.text == "require" and callee.binding == nil
      end
      if not is_require then
        untyped = untyped + 1
      end
    end
    local fallible = is_call(n) and not is_assert(n) and fallible_type(callee_fn(run, n))
    if fallible then
      judged(run, "calls")
    end
    if fallible and kept[Node.base(n).id] ~= true then
      if statements[Node.base(n).id] == true then
        if not is_quiet(run, n) then
          report(run, line_of(subject, n), string.format("%s: its failure is ignored; handle it, or discard both " ..
              "results on purpose: local _, _ = ...", callee_text(n)))
        end
      else
        report(run, line_of(subject, n), string.format("%s: its error slot is dropped; bind both results, wrap it in " ..
            "assert(...), or return it whole", callee_text(n)))
      end
    elseif is_function(n) then
      local parts = parts_of(n)
      if parts ~= nil then
        check_function(run, n, parts, stood[Node.base(n).id] == true)
      end
    end
  end
  local exported = exported_functions(run)
  check_exports(run, exported)
  check_wrappers(run, exported_nodes(run, exported))
  check_inspections(run)
  check_casts(run)
  check_stutter(run)
  check_modes(run)
  stale(run, "exempt", run.exemptions.exempt, run.used.exempt)
  stale(run, "parsing", run.exemptions.parsing, run.used.parsing)
  stale(run, "casts", run.exemptions.casts, run.used.casts)
  stale(run, "modes", run.exemptions.modes, run.used.modes)
  table.sort(run.problems, function(a: string, b: string): boolean
    local la, lb = problem_line(a), problem_line(b)
    if la ~= lb then
      return la < lb
    end
    return a < b
  end)
  local used: mut {string} = {}
  local tables: {string: {string: boolean}} = {
    exempt = run.used.exempt, parsing = run.used.parsing, casts = run.used.casts, modes = run.used.modes,
  }
  for table_name, held in pairs(tables) do
    for key in pairs(held) do
      used[#used + 1] = table_name .. " " .. key
    end
  end
  table.sort(used)
  return { problems = run.problems, used = used, sites = run.sites, untyped = untyped }
end

return SyntaxContracts
