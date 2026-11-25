--- The new checker's expressions and flow: every
--- expression and statement of a module's bodies typed against the declarations [`lang.declarations`] lowered,
--- by the relation of [`lang.relation`], under the facts [`lang.flow`] holds.
---
--- [`Check.check`] walks a lowered module in source order. An expression is inferred ([`expr`]), with the type
--- the position expects where it has one, which only a literal uses: a table, a function, a string for an enum,
--- a boolean for `true`. What is inferred is then required to be below what the position wants, and where it is
--- not the error names the rule, the place and the change that fixes it ([`lang.check_codes`]).
---
--- **Its files.** This file holds the spine of the walk (`expr`, [`lists_of`], the edges out of a condition) and the
--- statements; the modules of lang/check/ it requires hold the rest, each requiring only those below it:
--- [`lang.check.context`] (the state of a check), [`lang.check.naming`], then members, refusals, names, values,
--- table_literals, fields, places, writes, tests, functions, operands, calls, narrowing, generic_calls and operators.
--- A module below the spine calls the walk through `ctx.walk` ([`Context.Ctx.Walk`]), which [`Check.check`] fills with
--- the functions of this file; this file calls them so too above where it defines them.
---
--- **What it checks.** Literals, names, fields, indexes, operators and concatenation; calls, with the first-match rule
--- of overloads; table literals against the expected type (records included); assignments, writes to fields (fixed
--- unless `mut`) and indexes (views are never written, and an array grows by an append); returns against the declared
--- list; conditions (booleans or optionals) and the honest `or` and `and`; numeric keys, views and `mut` collections,
--- records and maps; `match` over a call that returns one of several lists of values.
---
--- **Generic calls.** A call of a generic function, an overload among them, instantiates it: each type parameter is
--- solved from the receiver and the arguments, then from the type the call is expected to return ([`lang.generics`]),
--- and met against its bound, and the instance is applied as any function is. `pcall`, `xpcall`, `ipairs`, `assert`,
--- `table.insert` and the typed `Coroutine<Y, R, S>` are declarations of this ([`lang/stdlib.d.tl`]); a generic
--- function is a value of the function types its parameters can be taken from ([`lang.relation`]).
---
--- **`match`.** The arms cover the lists the call returns exactly: `true`, `false` and `nil` select the lists that have
--- the value at their position (`nil` the lists whose value there is never nil apart), a name takes the union of what
--- the lists it selects have there, a list no arm takes is `match_missing`, an arm that takes no list `match_redundant`,
--- and a pattern that tests a position the lists do not tell apart, or names another number of values, `match_pattern`.
---
--- **Calls.** A method called through a union of declarations is typed when every member declares it alike once the
--- receiver is the union, and reported (`not_callable`) otherwise. The last argument of a call may add values (a call
--- or `...` that ends in `T...`): they fill the parameters after the values known, each of which may stay empty, so
--- the call is held to `T?` for them and `T` for the rest parameter, and its literals are checked against the overload
--- taken. A function literal or a string literal fits an overload by its form: the arguments it takes, the enum that
--- has it.
---
--- **Classes.** A class is a nominal type, and its value is made by a table literal typed as the class that names
--- every field, `?` ones as `name = nil` ([`Check.Checked.literals`] tells the code generator which literals make
--- one); there is no other way to make one, so a declaration used as a value is a type of its own, no `setmetatable`
--- call is typed (`setmetatable_call`), and a literal or an `is` of a class is allowed only where the class's table
--- is in reach (`class_scope`). A `<close>` local holds nil, or a class or userdata record that declares
--- `__close` as a method (`close_not_closable`).
---
--- **Flow.** The walk keeps what is known at the point it has reached ([`lang.flow`]): a place a test narrowed, a local
--- not yet assigned, and whether control reaches the point. A place is a local, or a path of fixed fields (not `mut`) of
--- a record, class or interface from one; it is narrowed by `x ~= nil`, `x == nil` and the truthiness of an optional,
--- `v is T`, `type(v) == "..."`, a tag compared with a literal (`v.kind == "a"`), a call of a function declared `v is T`,
--- `not`, `and` and `or` of these, `assert(c)` and a call of a function declared `asserts v is T`, and by a branch
--- that ends its block (`return`, `break`, `continue`, a call of a function declared `never`). `if` and `match` meet
--- the ends of their arms; the locals of `local ok, r = f()` where `f` returns lists that begin with `true` and `false`
--- (`pcall`, `xpcall`, a function declared so) are tied, and `ok`, `not ok` and `ok == true` narrow `r` to the lists
--- that `ok` selects until a local of the statement is assigned ([`Context.Tie`]); a loop is walked to a fixed point, its head
--- being where the entry and the back edge meet.
--- An assignment drops the fact of the local and of the paths from it, then narrows the local to the view of the value's
--- type where that is below the declared type (an initializer likewise). A function
--- starts from the facts of the code around it except those of a local assigned after the function is made
--- ([`Scopes.Capture.after`]). The flow gives `missing_return`, `not_assigned` (a local declared with no value, read
--- or named by a function made before every path assigns it), `unreachable` and `narrowing_dropped`; a function
--- declared to narrow must show it where it returns (`narrows_unproved`).
---
--- **What it leaves.** A binding of C and a global the declarations lack are typed `invalid` and reported
--- (`unchecked_binding`), so that no `invalid` is silent: the one that stands for a mistake already reported, by this
--- checker or by the lowering of the declarations, is the only other.
---
--- **Types of names.** A local, parameter or loop variable has the type its annotation or value gives;
--- a name of a record or class used as a value ([`Fs.read`]) is the declaration's own type; a module
--- (`require("cosmic.fs")`) is the declaration it returns; a global is the declared global record or the value
--- a declaration file gives it ([`Declarations.Program.values`]).
---
--- **Spines.** A chain that leans left (`a + b + c`, `a.b.c`, `f()()`) is walked without recursion, so one of
--- any length is checked; what nests (arguments, the right operand of `..` and `^`, blocks) recurses as deep as
--- the parser lets it (200).
local Ast = require("lang.ast")
local Codes = require("lang.check_codes")
local Declarations = require("lang.declarations")
local Flow = require("lang.flow")
local Lexer = require("lang.lexer")
local LoadOrder = require("lang.load_order")
local Relation = require("lang.relation")
local Types = require("lang.types")
local Warnings = require("lang.warnings")

local type Type = Types.Type
local type Fn = Types.Fn
local type Alt = Types.Alt
local type Decl = Types.Decl

local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local type Ctx = Context.Ctx
local type Fill = Context.Fill
local type Grow = Context.Grow
local type Loop = Context.Loop
local type Span = Context.Span
local type TieSlot = Context.TieSlot
local base_of = Context.base_of
local below = Context.below
local id_key = Context.id_key
local members_of = Context.members_of
local nilable = Context.nilable
local path_key = Context.path_key
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local text_of = Context.text_of
local tq = Context.tq
local view = Context.view

local Refusals = require("lang.check.refusals")
local Names = require("lang.check.names")
local Lookup = require("lang.check.members")
local ValueLists = require("lang.check.values")
local TableLiterals = require("lang.check.table_literals")
local Fields = require("lang.check.fields")
local Places = require("lang.check.places")
local Writes = require("lang.check.writes")
local Tests = require("lang.check.tests")
local Functions = require("lang.check.functions")
local GenericCalls = require("lang.check.generic_calls")
local Operands = require("lang.check.operands")
local Calls = require("lang.check.calls")
local Narrowing = require("lang.check.narrowing")
local Operators = require("lang.check.operators")
local type Instance = Calls.Instance
local PLACE_KINDS = Places.PLACE_KINDS
local type Pending = Writes.Pending
local type Prepared = Calls.Prepared
local UNDECLARED_CALL_FIX = Operands.UNDECLARED_CALL_FIX
local UNDECLARED_RETURN_FIX = Operands.UNDECLARED_RETURN_FIX
local type Values = ValueLists.Values
local assign_fix = Functions.assign_fix
local boolean_literal = ValueLists.boolean_literal
local column = Writes.column
local condition = Narrowing.condition
local expect = Refusals.expect
local expect_argument = Refusals.expect_argument
local field_unknown = Fields.field_unknown
local first_value = ValueLists.first_value
local function_body = Functions.function_body
local function_literal = Calls.function_literal
local function_type = Functions.function_type
local index_read = Narrowing.index_read
local key_names = Fields.key_names
local key_ok = Fields.key_ok
local lists_text = Functions.lists_text
local member_read = Fields.member_read
local member_types = Fields.member_types
local members_index = Lookup.members_index
local merge = Places.merge
local merge_all = Places.merge_all
local module_value = Names.module_value
local name_value = Names.name_value
local narrows_proved = Functions.narrows_proved
local place_of = Places.place_of
local plural = Calls.plural
local put_in = Lookup.put_in
local read_out = Operands.read_out
local readable = TableLiterals.readable
local returns_call = Operands.returns_call
local static_words = Fields.static_words
local string_literal = Names.string_literal
local subsume = Places.subsume
local tie_key = Narrowing.tie_key
local unchecked_arguments = Names.unchecked_arguments
local union_method = GenericCalls.union_method
local unknown_lists = Names.unknown_lists
local value_at = Writes.value_at
local values_of = ValueLists.values_of
local vararg_rest = ValueLists.vararg_rest

local record Check
  type Error = Codes.Error
  type Argument = Codes.Argument

  --- See [`Context.Narrowed`].
  type Narrowed = Context.Narrowed

  --- See [`Context.Role`].
  type Role = Context.Role

  --- See [`Context.Boundary`].
  type Boundary = Context.Boundary

  --- What checking a module returns.
  record Checked
    --- The errors, in source order.
    errors: {Codes.Error}
    --- The type of each local, parameter and loop variable that was given one, by [`Scopes.Var.id`].
    vars: {integer: Type}
    --- The class of each table literal that makes a value of a class, by the id of its node: what the code
    --- generator writes as the class literal, a class of this module.
    literals: {integer: Decl}
    --- The names of the fields a table literal with a spread copies from its source, in the order the record declares
    --- them, by the id of the literal's node: what the code generator writes before the fields given after the spread.
    spreads: {integer: {string}}
    --- How the code generator tests `v is R` for a record `R` that a run-time tag tells apart, by the id of the tested
    --- type's node: the tag field and then the strings it holds in `R` (`{ "kind", "circle" }`), or `{ "" }` where `R`
    --- is the one table the value may be, which `type(v) == "table"` tells.
    tags: {integer: {string}}
    --- The reads of a place whose type a test narrowed, in source order: what the checker concluded, for a run
    --- that checks it ([`Check.Narrowed`]).
    narrowed: {Narrowed}
    --- The typed boundaries the program declares, in source order ([`Check.Boundary`]): the parameters of every function
    --- whose body was checked, bar the variadic one, a `self`, one whose type is `any`, and one with no type written (a function
    --- literal that takes its parameters' types from where it is passed).
    boundaries: {Boundary}
    --- The type of each expression that was typed, by the id of its node (empty where the check was asked not to keep them,
    --- `typed` false; kept by default): the type report the readers of the build take ([`build.driver`]). A name, a
    --- literal, a call (the first value of the first list it returns), an operator and each link of a chain has one, as the
    --- checker left it after the narrowing there; the callee of a call of an overloaded function has the overload taken. These
    --- have none: the target of an assignment, the string of a `require`, the head name of a `function M.f()` statement, a `...`,
    --- a type name (see [`Declarations.Lowered.types`]) and a node the checker did not reach (a body it skipped).
    types: {integer: Type}
    --- The function each call and method call took, by the id of the call node (empty where `typed` is false): the type of
    --- the callee for a call of one function, the overload taken (instantiated, for a generic one) for a call of several.
    --- A method call has no node for its callee, so this is the only place its function type is kept
    --- ([`build.syntax_contracts`] reads whether a method returns a reason). A call whose callee is no function has none.
    callees: {integer: Type}
    --- The warnings ([`lang.warnings`]), in source order: the unused and unread names, and the `hint` ones.
    warnings: {Warnings.Warning}
  end

  --- Checks `input`, which `program` has lowered into `lowered` ([`Declarations.Program.lower`]), and returns
  --- its errors. The modules it requires must be lowered: a type whose declaration has no body raises
  --- `relation: <declaration> is not defined`. With `typed` false the type of each node is not kept ([`Check.Checked.types`]),
  --- which saves the time of recording them; the hints, which read what they need as they go, are the same.
  check: function(program: Declarations.Program, input: Declarations.Input, lowered: Declarations.Lowered,
                  typed?: boolean): Checked

  --- The values of the enum each type node of `lowered` stands for, by the id of the node: what the code generator
  --- ([`lang.codegen`]'s `enums`) tests membership of for `v is Enum`, since a string that passed `type(v) == "string"` is
  --- no member of the enum for that.
  enums: function(lowered: Declarations.Lowered): {integer: {string}}

  --- Every [`Codes.Code`] an error may have, with its row in [`Check.catalog`] or in [`Declarations.catalog`].
  codes: {Codes.Code}

  --- The rule behind each code of [`lang.check_codes`].
  catalog: {Codes.Row}

  --- What the fix of a value that is none of the arms of a recursive alias adds, and what a table literal wanted as an
  --- interface is told in place of the generic fix, by the type (`<module> <name>`): the library's own advice for the type it
  --- declares, in words that name its functions. A key `<module> <name> .<field>` is what the fix of a field the type
  --- does not have adds: a field it had once.
  advice: {string: string}
end

Check.codes = Codes.codes
Check.catalog = Codes.catalog
Check.advice = Refusals.advice

--- The checks of a table literal against the type it is written for, and the type it has where none is written.

-- Members --------------------------------------------------------------------------------

-- Refusals -----------------------------------------------------------------------------------

-- Not yet checked ----------------------------------------------------------------------------

-- Names ------------------------------------------------------------------------------------

-- Literals --------------------------------------------------------------------------------

-- Value lists ----------------------------------------------------------------------------------

-- Table literals ----------------------------------------------------------------------------

-- TODO: check a literal given to a parameter declared `any` item by item
-- and type it without a join, once the rule for what may reach `any` (a
-- literal's items, or the literal alone) is written into
-- doc/guides/project.md: it is typed by the join of its items today, so
-- `Json.encode_any({ a = 1, b = "x" })` is `arms_differ`, and the files that
-- give such a literal to an `any` parameter hold it by markers.

-- Fields and indexes -------------------------------------------------------------------------

-- Operators ------------------------------------------------------------------------------------

-- Narrowing ------------------------------------------------------------------------------------

-- What a test of the length of an array shows, and what an index read may rely on.
--
-- An array holds the keys 1 to `#t` and no others (`array_of_optional` and `array_hole` keep it so) where its element is
-- never nil at run time ([`Tests.dense`]), so `t[n]` is an element wherever `#t` is at least `n`. A test of `#place`
-- against an integer literal gives the flow that fact for the first indexes ([`Flow.know_length`]) of a place that holds
-- an array: a local, or fixed fields from one. So does a test that `place[k]` is not nil ([`Tests.has_element`]), for a
-- literal `k` of 1 or more or `#place`; for a local `k` it gives that the array has the key `k` holds ([`Flow.know_key`]),
-- until `k` is assigned. The fact stands until code runs that may shorten an array: a call (but `assert`, `type` and an
-- inert call [`Tests.inert_callee`], which run no code of the program), a write of a literal nil to an index (the array
-- may be under another name), the iterator of a generic `for` and the scope of a `<close>` local, whose handler runs when
-- it ends. A function made at the point does not inherit it ([`Flow.enter`]), and an assignment to the place takes it
-- away like any fact of the place.
--
-- A `table.move` that may copy a nil or leave a hole is refused (`array_hole`, [`Writes.move_dense`]), so a move keeps the
-- density this relies on.

--- The edges of the condition `e` in the state `f`: the states where it is true and where it is false. The test of a
--- place narrows it; `not`, `and` and `or` combine what their operands say, the right operand under the left's edge;
--- a call that narrows an argument says it, and a literal `true` or `false` leaves one edge unreachable.
local function edges(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State, Flow.State
  local at = peel(e)
  if (at.kind == "Unary") then
    if at.op == "not" then
      local yes, no = edges(ctx, f, at.operand)
      return no, yes
    end
  elseif (at.kind == "Binary") then
    local op = at.op
    if op == "and" or op == "or" then
      local held = ctx.edges[at.id]
      if held ~= nil and held.post == f then
        return held.yes, held.no
      end
      local ly, ln = edges(ctx, f, at.left)
      if op == "and" then
        local ry, rn = edges(ctx, ly, at.right)
        return ry, merge(ctx, ln, rn)
      end
      local ry, rn = edges(ctx, ln, at.right)
      return merge(ctx, ly, ry), rn
    elseif op == "==" or op == "~=" then
      return Narrowing.compare_edges(ctx, f, at)
    elseif op == "<" or op == "<=" or op == ">" or op == ">=" then
      return Tests.length_edges(ctx, f, op, at.left, at.right)
    end
  elseif (at.kind == "IsTest") then
    local p = place_of(ctx, f, at.value)
    local tested = ctx.lowered.types[at.type.id]
    if p ~= nil and tested ~= nil then
      return Narrowing.is_edges(ctx, f, p, tested)
    end
  elseif (at.kind == "Name") or (at.kind == "Field") or (at.kind == "Index") then
    return Narrowing.truthy_edges(ctx, f, at)
  elseif (at.kind == "Call") or (at.kind == "MethodCall") then
    local g = ctx.guards[at.id]
    local p = g ~= nil and place_of(ctx, f, g.arg) or nil -- checked: and_ternary
    if g ~= nil and p ~= nil then
      return Narrowing.is_edges(ctx, f, p, g.to)
    end
  elseif (at.kind == "Boolean") then
    if at.value then
      return f, Flow.dead(f)
    end
    return Flow.dead(f), f
  end
  return f, f
end

-- Binary and unary operators ---------------------------------------------------------------

-- Functions ------------------------------------------------------------------------------------

-- Calls --------------------------------------------------------------------------------------------

-- Generic calls ----------------------------------------------------------------------------------

--- What a call that has returned shows. A function declared `never` does not return, so the state after it is
--- unreachable. `assert(c)` returns only where `c` holds, and a function declared `asserts v is T` only where `v` is a
--- `T`: the state after is the one where the argument is. A function declared `v is T` is a test of its argument, which
--- [`edges`] reads from `ctx.guards`.
--
-- TODO: drop the special case of `assert` here, once a narrowing declaration can say that a function returns only where
-- its argument holds and returns it (`asserts v` without a type, which the grammar leaves out): `asserts v is T`
-- narrows a place to a type and returns nothing, while `assert(x ~= nil)` and `local s = assert(find())` narrow by the
-- condition and return the value. The type of the call is the declaration's (a generic function, solved as any is); only
-- what follows it is this.
local function after_call(ctx: Ctx, node: Ast.Node, callee: Ast.Exp?, alts: {Alt}, args: {Ast.Exp},
                          receiver: Ast.Exp?)
  ctx.guards[base_of(node).id] = nil
  local id = base_of(node).id
  if #alts == 0 then
    ctx.inert[id] = nil
    ctx.flow = Flow.dead(ctx.flow)
    return
  end
  if Tests.quiet_callee(callee) or (ctx.inert[id] == true and Tests.inert_callee(callee)) then
    ctx.inert[id] = true
  else
    ctx.inert[id] = nil
    ctx.flow = Flow.forget_lengths(ctx.flow)
  end
  local first = args[1]
  if callee ~= nil and (callee.kind == "Name") and callee.binding == nil and callee.text == "assert" and first ~= nil then
    local yes, _ = edges(ctx, ctx.flow, first)
    -- The test is read in the state after the arguments, and a call among them (the test's own or one after it) may have
    -- shortened an array the test showed to be long: the facts of lengths are what the arguments leave, none that the
    -- test adds.
    for _, given in ipairs(args) do
      if Tests.has_call(ctx, given) then
        yes = Flow.forget_lengths(yes)
        break
      end
    end
    ctx.flow = yes
    return
  end
  local alt = alts[1]
  local narrows = #alts == 1 and alt.narrows or nil -- checked: and_ternary, nil_not_allowed
  if narrows == nil then
    return
  end
  local target: Ast.Exp? = args[narrows.param]
  if receiver ~= nil then
    target = narrows.param == 1 and receiver or args[narrows.param - 1] -- checked: and_ternary
  end
  if target == nil then
    return
  end
  if narrows.asserts then
    local p = place_of(ctx, ctx.flow, target)
    if p ~= nil then
      local yes, _ = Narrowing.is_edges(ctx, ctx.flow, p, narrows.to)
      ctx.flow = yes
    end
  else
    ctx.guards[base_of(node).id] = { arg = target, to = narrows.to }
  end
end

--- [`Calls.dispatch`], with the `module` that declares its callee ("" where the walk did not read one) known to the
--- argument errors it files, and the module of the call around it restored after.
local function dispatch_call(ctx: Ctx, node: Ast.Node, callee_node: Ast.Node, callee: string, module: string, ft: Type,
                             cands: {Type}?, args: {Ast.Exp}, recv: Type?, recv_node: Ast.Node?, expected: Type?): {Alt}
  local outer = ctx.callee_module
  ctx.callee_module = module
  local alts = Calls.dispatch(ctx, node, callee_node, callee, ft, cands, args, recv, recv_node, expected)
  ctx.callee_module = outer
  return alts
end

--- A call `callee(args)` whose callee has type `ft`.
local function apply_call(ctx: Ctx, node: Ast.Call, ft: Type, expected: Type?): {Alt}
  local callee = node.callee
  local cands: {Type}? = nil
  if ctx.cand_node == callee then
    cands = ctx.cands
  end
  ctx.cands, ctx.cand_node = nil, nil
  -- The read of a field callee was the last member read, and left its declaration's module.
  local module = if ctx.member_node == callee then ctx.member_module else "" end
  local callee_text = text_of(ctx, callee)
  if (callee.kind == "Name") and callee.binding == nil then
    local mode = if callee.text == "setmetatable" then Calls.weak_mode(node.args) else nil end
    if mode ~= nil then
      -- A weak table: an empty literal with `{ __mode = ... }`, which only tells the collector what it may drop. It is
      -- the map that its place declares.
      local wanted = if expected ~= nil then ctx.store:non_nil(expected) else nil end
      if wanted ~= nil and ((wanted.tag == "map") and wanted.mut or wanted == ctx.invalid) then
        -- An invalid type was refused where it is written.
        if (ft.tag == "fn") and ctx.typed then
          ctx.callees[base_of(node).id] = ft
        end
        return { { items = { wanted } } }
      end
      report(ctx, "setmetatable_call", node, "a weak table is a `mut` map, and nothing here says which",
        "declare the map where it is made: `local m: mut {K: V} = setmetatable({}, { __mode = \"" ..
          mode .. "\" })`")
      return unknown_lists(ctx)
    elseif callee.text == "setmetatable" then
      report(ctx, "setmetatable_call", node, "a program has no `setmetatable`: the metatable of a value is the compiler's, " ..
          "attached to the literal that makes the value of a class",
        "declare a `class` with the methods and write the value as a table literal typed as the class " ..
          "(`local v: C = { field = value }`); for a temporary change to a shared table (an overlay through " ..
          "`__index`), write the keys into the table in place, keep each key's old value, and restore them after")
      unchecked_arguments(ctx, node.args)
      return unknown_lists(ctx)
    elseif callee.text == "require" then
      local named = node.args[1]
      if named ~= nil and (named.kind == "String") and #node.args == 1 then
        return { { items = { module_value(ctx, node, named.value) } } }
      end
    end
  end
  return dispatch_call(ctx, node, callee, callee_text, module, ft, cands, node.args, nil, nil, expected)
end

--- A method call `object:name(args)` whose object has type `object`.
local function apply_method(ctx: Ctx, node: Ast.MethodCall, object: Type, expected: Type?): {Alt}
  local text = text_of(ctx, node.object) .. ":" .. node.name
  local t = readable(ctx, node.object, object, "it has no method " .. quoted(node.name) .. " to call")
  if t == nil then
    unchecked_arguments(ctx, node.args)
    return unknown_lists(ctx)
  end
  ctx.cands, ctx.cand_node = nil, nil
  local ft: Type
  local cands: {Type}? = nil
  local module = ""
  if (t.tag == "union") then
    local common, overloads = union_method(ctx, node, t)
    if common == nil then
      unchecked_arguments(ctx, node.args)
      return unknown_lists(ctx)
    end
    ft, cands = common, overloads
  else
    if node.name == "sub" and (t.tag == "string") then ctx.string_subs[node.id] = true end
    ft = member_read(ctx, node, t, node.name)
    module = ctx.member_module
    if ctx.cand_node == node then
      cands = ctx.cands
    end
    ctx.cands, ctx.cand_node = nil, nil
    if ctx.flow.paths > 0 and nilable(ft) then
      -- An optional method that a test showed is there (`if a.cb ~= nil then a:cb() end`): the place `a.cb` holds the fact.
      local base = path_key(ctx, node.object)
      if base ~= nil then
        local fact = ctx.flow.facts[base .. "." .. node.name]
        if fact ~= nil then
          ft = fact.type
        end
      end
    end
  end
  return dispatch_call(ctx, node, node, text, module, ft, cands, node.args, t, node.object, expected)
end

-- Expressions: the spine --------------------------------------------------------------------

--- The expressions whose first operand the walk descends into, in place of recursing.
local function spine_child(node: Ast.Exp): Ast.Exp?
  if (node.kind == "Binary") then
    return node.left
  elseif (node.kind == "Field") then
    return node.object
  elseif (node.kind == "Index") then
    return node.object
  elseif (node.kind == "Call") then
    return node.callee
  elseif (node.kind == "MethodCall") then
    return node.object
  elseif (node.kind == "IsTest") then
    return node.value
  elseif (node.kind == "Cast") then
    return node.value
  end
  return nil
end

--- The type of the read of a name: the type the facts hold of it, else the type it was declared with. A local that
--- no path has assigned yet is refused (`not_assigned`) and taken as assigned from there on.
local function read_name(ctx: Ctx, e: Ast.Name): Type
  local t = name_value(ctx, e)
  local id = e.binding
  if id == nil then
    return t
  end
  if ctx.load.waiting > 0 and ((t.tag == "fn") or (t.tag == "union")) and ctx.load.given[e.id] ~= true then
    LoadOrder.mention(ctx.load, ctx.within, e, LoadOrder.of_local(id, quoted(e.text)))
  end
  if ctx.flow.unsets > 0 and ctx.flow.unset[id] == true then
    local v = ctx.scoped.vars[id]
    local tokens = ctx.tokens
    local name = quoted(e.text)
    report(ctx, "not_assigned", e, name .. " is read before every path assigns it: `local " .. e.text .. "` was given no value",
      assign_fix(ctx, e.text, t, false), { show(ctx, t) },
      if v ~= nil then
        { y = Lexer.y(tokens, v.declared), x = Lexer.x(tokens, v.declared), offset = Lexer.offset(tokens, v.declared),
          length = Lexer.length(tokens, v.declared) } else nil end)
    ctx.flow = Flow.assigned(ctx.flow, id)
  end
  if next(ctx.flow.facts) ~= nil then
    local key = path_key(ctx, e)
    local fact = key ~= nil and ctx.flow.facts[key] or nil -- checked: and_ternary
    if fact ~= nil then
      Narrowing.note_narrowed(ctx, e, fact.declared, fact.type)
      return fact.type
    end
  end
  return t
end

--- The type of an expression that is not a chain: a name, a literal, a function, a table, a unary operator or an `if`.
local function leaf(ctx: Ctx, e: Ast.Exp, expected: Type?): Type
  local store = ctx.store
  if (e.kind == "Name") then
    return read_name(ctx, e)
  elseif (e.kind == "Integer") then
    return store.integer
  elseif (e.kind == "Float") then
    return store.number
  elseif (e.kind == "String") then
    return string_literal(ctx, e, expected)
  elseif (e.kind == "Boolean") then
    return boolean_literal(ctx, e, expected)
  elseif (e.kind == "Nil") then
    return ctx.nil_type
  elseif (e.kind == "Paren") then
    return ctx.walk.expr(ctx, e.inner, expected)
  elseif (e.kind == "Table") then
    return TableLiterals.table_literal(ctx, e, expected)
  elseif (e.kind == "FunctionLit") then
    return function_literal(ctx, e, expected)
  elseif (e.kind == "Unary") then
    return Operators.unary(ctx, e, ctx.walk.expr(ctx, e.operand, nil))
  elseif (e.kind == "IfExp") then
    return Operators.if_expression(ctx, e, expected)
  elseif (e.kind == "Vararg") then
    local rest = vararg_rest(ctx, e)
    return rest.tag == "invalid" and rest or store:optional(rest) -- checked: and_ternary
  end
  return ctx.invalid
end

--- Applies the chain node `n` to the type `t` of its first operand.
local function apply(ctx: Ctx, n: Ast.Exp, t: Type, expected: Type?, wants_lists: boolean): Type, {Alt}?
  if (n.kind == "Binary") then
    return Operators.binary(ctx, n, t, expected), nil
  elseif (n.kind == "Field") then
    ctx.field_node, ctx.field_base = n, t
    local base = readable(ctx, n.object, t, "it has no field " .. quoted(n.name) .. " to read")
    if base == nil then
      return ctx.invalid, nil
    end
    local read = member_read(ctx, n, base, n.name)
    Writes.note_move(ctx, n, base, n.name)
    if ctx.flow.paths > 0 and read.tag ~= "invalid" then
      local key = path_key(ctx, n)
      local fact = key ~= nil and ctx.flow.facts[key] or nil -- checked: and_ternary
      if fact ~= nil then
        Narrowing.note_narrowed(ctx, n, fact.declared, fact.type)
        return fact.type, nil
      end
    end
    return read, nil
  elseif (n.kind == "Index") then
    return index_read(ctx, n, t), nil
  elseif (n.kind == "Call") then
    local saved = ctx.lenient
    ctx.lenient = 0
    local object: Type? = nil
    if ctx.field_node == n.callee then
      object = ctx.field_base
    end
    ctx.inert[n.id] = nil
    local alts = apply_call(ctx, n, t, expected)
    ctx.lenient = saved
    if ctx.moves[n.callee.id] ~= nil then
      ctx.moves[n.callee.id] = nil
      if not Writes.move_dense(n.args) then
        Writes.move_refuse(ctx, n)
      end
    end
    after_call(ctx, n, n.callee, alts, n.args, nil)
    if object ~= nil then
      Calls.method_dot(ctx, n, t, object)
    end
    if wants_lists then
      return ctx.invalid, alts
    end
    return first_value(ctx, n, alts), nil
  elseif (n.kind == "MethodCall") then
    local saved = ctx.lenient
    ctx.lenient = 0
    ctx.inert[n.id] = nil
    local alts = apply_method(ctx, n, t, expected)
    ctx.lenient = saved
    after_call(ctx, n, nil, alts, n.args, n.object)
    if wants_lists then
      return ctx.invalid, alts
    end
    return first_value(ctx, n, alts), nil
  elseif (n.kind == "IsTest") then
    return Operators.is_test(ctx, n, t), nil
  elseif (n.kind == "Cast") then
    report(ctx, "cast_refused", n, "`as` is not in the language: " .. subject(ctx, n) .. " changes a type by no check",
      "validate the value with a [`cosmic.shape`] validator, test it with `is` or a guard, or delete the cast")
    return ctx.invalid, nil
  end
  return ctx.invalid, nil
end

--- The type of `e`, and the lists it returns where `wants_lists` and it is a call.
local function evaluate(ctx: Ctx, e: Ast.Exp, expected: Type?, wants_lists: boolean): Type, {Alt}?
  local base = #ctx.spine
  local node: Ast.Exp = e
  while true do
    local nxt = spine_child(node)
    if nxt == nil then
      break
    end
    if (node.kind == "Binary") and node.op == "or" and (nxt.kind == "Binary") and nxt.op == "and" then
      ctx.ternaries[nxt.id] = node
    end
    if (node.kind == "Binary") and (node.op == "==" or node.op == "~=") then
      -- A field compared with nil only asks whether it is there.
      local left, right = peel(nxt), peel(node.right)
      if (left.kind == "Field") and (right.kind == "Nil") then
        ctx.probes[left.id] = true
      elseif (left.kind == "Nil") and (right.kind == "Field") then
        ctx.probes[right.id] = true
      end
    end
    ctx.spine[#ctx.spine + 1] = node
    node = nxt
  end
  local t = leaf(ctx, node, #ctx.spine == base and expected or nil) -- checked: and_ternary
  local types = ctx.types
  local typed = ctx.typed
  if typed then
    types[base_of(node).id] = t
  end
  local alts: {Alt}? = nil
  for i = #ctx.spine, base + 1, -1 do
    local n = ctx.spine[i]
    ctx.spine[#ctx.spine] = nil
    t, alts = apply(ctx, n, t, i == base + 1 and expected or nil, wants_lists and i == base + 1) -- checked: and_ternary, nil_not_allowed
    if typed then
      types[base_of(n).id] = t -- checked: nil_not_allowed
    end
  end
  if ctx.cand_node == e then
    ctx.cands, ctx.cand_node = nil, nil
    report(ctx, "overload_value", e, subject(ctx, e) .. " has several overloads, which are no value: only a call picks one",
      "call it where you use it, or write a function of the one you mean: `function(...) return " .. text_of(ctx, e) ..
        "(...) end`")
    return ctx.invalid, alts
  end
  return t, alts
end

local function expr(ctx: Ctx, e: Ast.Exp, expected: Type?): Type
  local t, _ = evaluate(ctx, e, expected, false)
  return t
end

local function lists_of(ctx: Ctx, e: Ast.Exp, expected: Type?): {Alt}
  local t, alts = evaluate(ctx, e, expected, true)
  if alts ~= nil then
    if ctx.typed then
      -- A call that returns lists has the type of the first value of its lists, for the type report.
      local first: mut {Type} = {}
      for _, alt in ipairs(alts) do
        local item = ctx.nil_type
        local head, tail = alt.items[1], alt.tail
        if head ~= nil then
          item = head
        elseif tail ~= nil then
          item = ctx.store:optional(tail)
        end
        first[#first + 1] = item
      end
      ctx.types[base_of(e).id] = ctx.store:union(first)
    end
    return alts
  end
  return { { items = { t } } }
end

-- Statements -----------------------------------------------------------------------------------

--- The fix for names given no value by `values`: a lone call that returns nothing is a statement.
local function no_value_fix(ctx: Ctx, values: {Ast.Exp}, n: integer, what: string): string
  local only = values[1]
  if #values == 1 and only ~= nil then
    local name: string? = nil
    if (only.kind == "Call") then
      name = text_of(ctx, only.callee)
    elseif (only.kind == "MethodCall") then
      name = text_of(ctx, only.object) .. ":" .. only.name
    end
    if name ~= nil then
      return quoted(name) .. " answers nothing: write the call as a statement, " .. subject(ctx, only)
    end
  end
  return "give " .. plural(n, "value") .. ", or remove the " .. what .. "s that have none"
end

--- Checks that `n` names or targets are given `vals`, reporting the names left without a value and the values no name
--- takes. `values` are the expressions written.
local function check_counts(ctx: Ctx, node: Ast.Node, n: integer, vals: Values, values: {Ast.Exp}, what: string): boolean
  local written = #values
  local given = #vals.types
  local open = vals.tail ~= nil or vals.lists ~= nil
  local several, last = vals.lists, vals.last
  if several ~= nil and last ~= nil and n == 1 then
    local _ = first_value(ctx, last, several)
    return false
  end
  if written > n then
    report(ctx, "value_count", node, "this gives " .. plural(written, "value") .. " to " .. plural(n, what) ..
        ", so the " .. (if written - n == 1 then "value" else "values" end) .. " after the last " .. what .. " are dropped",
      "remove the extra " .. (if written - n == 1 then "value" else "values" end) .. ", or add the " .. what .. "s that take them")
    return false
  elseif given < n and not open then
    report(ctx, "value_count", node, "this gives " .. plural(given, "value") .. " to " .. plural(n, what) ..
        ", so the last " .. (if n - given == 1 then what .. " is" else what .. "s are" end) .. " nil",
      if given == 0 then no_value_fix(ctx, values, n, what) else "give " .. plural(n, "value") .. ", or remove the " ..
          what .. "s that have none" end)
    return false
  end
  return true
end

--- Whether a value of type `t` is nil or a value of a class or userdata record that declares `__close` as a method that
--- is what Lua calls ([`Declarations.close_is_callable`], the one check a class's declaration is held to as well): the
--- value, and the error object if it likes, returning nothing. Every overload must be one. That is what a `<close>`
--- local holds. The declaration of a userdata record is
--- taken as true: whether any declaration matches its implementation is not this rule's to ask. A record or interface
--- is made by a table literal and may lack the member. `invalid` and `never` stand for a mistake already reported.
local function closable(t: Type): boolean
  local tag = t.tag
  if tag == "nil" or tag == "invalid" or tag == "never" then
    return true
  elseif (t.tag == "named") then
    local body = t.decl.body
    local kind = t.decl.kind
    if t.value or body == nil or (kind ~= "class" and kind ~= "userdata") then
      return false
    end
    local found = false
    for _, m in ipairs(body.methods) do
      if m.name == "__close" then
        if not Declarations.close_is_callable(m.type) then
          return false
        end
        found = true
      end
    end
    return found
  elseif (t.tag == "union") then
    for _, m in ipairs(t.members) do
      if not closable(m) then
        return false
      end
    end
    return true
  end
  return false
end

--- Reports the `<close>` local `b`, of type `t`, unless it holds nil or a class or userdata record that declares `__close`
--- as a method.
local function check_closable(ctx: Ctx, b: Ast.Binding, t: Type)
  if closable(t) then
    return
  end
  --- The type that `closable` refused in `ty` (`ty` itself, or the first member of a union that is none) when it is an
  --- interface or record with a `__close` function, declared or inherited: what a library can mean to be closed and has not
  --- made a class. Nil for any other type.
  local function close_without_class(ty: Type): Type?
    if ty.tag == "union" then
      for _, m in ipairs(ty.members) do
        if not closable(m) then
          return close_without_class(m)
        end
      end
      return nil
    end
    if ty.tag ~= "named" or ty.value then
      return nil
    end
    local to_visit: mut {Type} = { ty }
    local seen: mut {Decl: boolean} = {}
    local next_at = 1
    while next_at <= #to_visit do
      local at = to_visit[next_at]
      next_at = next_at + 1
      if at ~= nil and at.tag == "named" and seen[at.decl] ~= true then
        seen[at.decl] = true
        local body = at.decl.body
        if body ~= nil and (at.decl.kind == "interface" or at.decl.kind == "record") then
          for _, m in ipairs(body.methods) do
            if m.name == "__close" and m.type.tag == "fn" then
              return ty
            end
          end
          for _, f in ipairs(body.fields) do
            if f.name == "__close" and f.type.tag == "fn" then
              return ty
            end
          end
          for _, super in ipairs(body.supers) do
            to_visit[#to_visit + 1] = super
          end
        end
      end
    end
    return nil
  end
  -- Why `held`, which `closable` refused, is no type of a `<close>` local: for a union, its first member that is none.
  local function because(held: Type): string
    if held.tag == "union" then
      for _, m in ipairs(held.members) do
        if not closable(m) then
          return "the member " .. tq(ctx, m) .. (if m.tag == "named" then " (of " .. m.decl.module .. ")" else "" end) ..
            " of the union is not closable: " .. because(m)
        end
      end
    end
    if (held.tag == "named") and not held.value and (held.decl.kind == "class" or held.decl.kind == "userdata") then
      local what = if held.decl.kind == "class" then "the class " else "the userdata record " end
      local body = held.decl.body
      if body == nil then
        return what .. tq(ctx, held) .. " has no declared body, so it declares no `__close`"
      end
      for _, m in ipairs(body.methods) do
        if m.name == "__close" and not Declarations.close_is_callable(m.type) then
          return what .. tq(ctx, held) .. " declares a `__close` that is not what Lua calls: it must take the value, " ..
            "and the error object as `any` if it likes, and answer nothing"
        end
      end
      for _, f in ipairs(body.fields) do
        if f.name == "__close" then
          return what .. tq(ctx, held) .. " declares `__close` as a field and not a method: a method's first parameter is " ..
            "the record itself (not `any`, a supertype or `mut`), and the member is neither optional nor `mut`"
        end
      end
      return what .. tq(ctx, held) .. " declares no `__close` method"
    end
    local without = close_without_class(held)
    if without ~= nil and without.tag == "named" then
      return tq(ctx, held) .. " is not a class: it is " .. (if without.decl.kind == "interface" then "an " else "a " end) ..
        without.decl.kind .. " with a `__close`, and a `<close>` local needs a class or a userdata record"
    end
    return tq(ctx, held) .. " is not a class or a userdata record"
  end
  local without = close_without_class(t)
  report(ctx, "close_not_closable", b, quoted(b.name) .. " is a `<close>` local of " .. tq(ctx, t) .. ", and " ..
      because(t) .. ": Lua would raise at the declaration, since the value has no `__close` to call at the end of the block",
    (if without ~= nil and without.tag == "named" then
      (if without.decl.module:gsub("@.*$", "") == ctx.input.module then
        "declare " .. tq(ctx, without) .. " as a class with `function __close(self)`, or call its close function by hand and " ..
          "make " .. quoted(b.name) .. " an ordinary local"
        else
        "the library that declares " .. tq(ctx, without) .. " must declare it as a class with `function __close(self)`; until " ..
          "it does, call its close function by hand and make " .. quoted(b.name) .. " an ordinary local"
        end)
      else
      "declare `function __close(self)` as a method on the class or userdata record " .. quoted(b.name) .. " holds (or hold " ..
        "nil), or release the value by hand and make " .. quoted(b.name) .. " an ordinary local"
      end), { show(ctx, t) })
end

--- The type a local declared `declared` has after it is given a value of type `t`: the view of `t` where that is below
--- `declared`, else nil. A `mut` is a capability and no fact of a value, so a fresh `mut {T}` held by a `{T}` stays a view.
local function value_narrowing(ctx: Ctx, t: Type, declared: Type): Type?
  local seen = view(ctx.store, t)
  local tag = seen.tag
  if tag == "invalid" or tag == "never" or declared.tag == "invalid" or seen == declared or not below(ctx, seen, declared) then
    return nil
  end
  return seen
end

--- The local `id` is declared: another place than any of the same name, with no fact, and unset where it has no value.
local function declare_local(ctx: Ctx, id: integer, unset: boolean)
  ctx.flow = Flow.declare(ctx.flow, id, unset)
end

--- Ties the locals of `s` when they take all the values of one call whose lists begin with `true` in some and `false` in the
--- rest (`local ok, r = pcall(f)`): the first is then the tag of the lists, and the others hold what the list it selects
--- gives them, until any of the locals is assigned ([`Narrowing.tie_edges`]). The tie is a fact of each local, so it ends
--- wherever a fact of a local ends. A local that a function assigns is no place, and ties nothing.
local function tie_locals(ctx: Ctx, s: Ast.Local, vals: Values, errors: integer)
  local alts = vals.lists
  local head = s.bindings[1]
  if alts == nil or head == nil or #s.values ~= 1 or #s.bindings < 2 or #ctx.errors ~= errors then
    return
  end
  local call = peel(s.values[1])
  -- TODO: tie the results of the standard library's `coroutine` functions too, once the runtime provides the typed
  -- `coroutine` library that lang/stdlib.d.tl declares: its `resume` is declared to return the body's value, and the
  -- runtime's own `coroutine.resume` returns none to a body that is not given a handle. Keyed on the declaration, so
  -- an alias (`local co = coroutine`) is excluded too, as it is the same record, and a record of the program's own
  -- named `coroutine` is tied.
  if ctx.coroutine_reads[call.id] == true or (call.kind == "Call" and ctx.coroutine_reads[call.callee.id] == true) then
    return
  end
  -- An argument whose type was refused (`invalid`) made overload resolution take the overload that fits what is left
  -- of it, whose lists say nothing of the function: tying them would cascade that error into the tests of the results.
  if call.kind == "Call" or call.kind == "MethodCall" then
    for _, given in ipairs(call.args) do
      local at = peel(given)
      local id = if at.kind == "Name" then at.binding else nil end
      local held = if id ~= nil then ctx.vars[id] else nil end
      if held ~= nil and held.tag == "invalid" then
        return
      end
    end
  end
  for _, b in ipairs(s.bindings) do
    local v = ctx.scoped.vars[b.id]
    if v == nil or v.closure_assigned or PLACE_KINDS[v.kind] ~= true then
      return
    end
  end
  local selected: mut {Alt} = {}
  local rejected: mut {Alt} = {}
  local by_bool, by_nil, truth = true, true, true
  for _, alt in ipairs(alts) do
    local first = alt.items[1]
    by_bool = by_bool and first ~= nil and (first.tag == "true" or first.tag == "false")
    -- A list told by `nil` begins with `nil` or with a value that is never nil; a test of its truth tells it only where
    -- that value is never `false` either.
    local held = first ~= nil and Operands.present(ctx, first)
    by_nil = by_nil and first ~= nil and (first.tag == "nil" or held)
    truth = truth and (first == nil or first.tag == "nil" or not Types.may_be_false(first))
  end
  if not by_bool and not by_nil then
    return
  end
  for _, alt in ipairs(alts) do
    local first = assert(alt.items[1], "each list of a tie has a first value")
    -- Lists of `true` and `false` are never nil too, so they are told by `true` before they are told by `nil`.
    local yes = if by_bool then first.tag == "true" else first.tag ~= "nil" end
    local into = if yes then selected else rejected end
    into[#into + 1] = alt
  end
  if #selected == 0 or #rejected == 0 then
    return
  end
  local rest: mut {TieSlot} = {}
  for i, b in ipairs(s.bindings) do
    if i > 1 then
      rest[#rest + 1] = { id = b.id, yes = column(ctx, selected, i), no = column(ctx, rejected, i) }
    end
  end
  ctx.ties[head.id] = { first = head.id, by_nil = not by_bool, truth = by_bool or truth, rest = rest }
  for _, b in ipairs(s.bindings) do
    ctx.flow = Flow.narrow(ctx.flow, tie_key(ctx, b.id), ctx.store.boolean, ctx.store.integer)
  end
end

--- `local a, b: T, U = f(), g()`.
local function local_statement(ctx: Ctx, s: Ast.Local)
  local n = #s.bindings
  local wants: mut {integer: Type} = {}
  for i, t in ipairs(s.types) do
    wants[i] = ctx.lowered.types[t.id] or ctx.invalid
  end
  if #s.values == 0 then
    for i, b in ipairs(s.bindings) do
      ctx.vars[b.id] = wants[i] or ctx.invalid
      -- A type that admits nil is nil until assigned; any other has no value until a path assigns it.
      local want = wants[i]
      declare_local(ctx, b.id, want ~= nil and want.tag ~= "invalid" and not nilable(want))
      if wants[i] == nil then
        report(ctx, "local_untyped", b, quoted(b.name) .. " has no type and no value",
          "write its type: `local " .. b.name .. ": T` (`T?` if it may stay unset), or give it a value")
      elseif b.attr == "close" then
        check_closable(ctx, b, wants[i]) -- checked: index_may_be_nil
        Tests.closes(ctx)
      end
    end
    return
  end
  if ctx.load.waiting > 0 then
    for i, b in ipairs(s.bindings) do
      local given = s.values[i]
      if given ~= nil then
        LoadOrder.bind(ctx.load, b.id, given)
      end
    end
  end
  local reported = #ctx.errors
  local vals = values_of(ctx, s.values, wants, nil)
  local counted = check_counts(ctx, s, n, vals, s.values, "name")
  for i, b in ipairs(s.bindings) do
    local t = value_at(ctx, vals, i)
    local want = wants[i]
    local written = s.values[i]
    local held = ctx.scoped.vars[b.id]
    if written ~= nil and want == nil then
      local literal = peel(written)
      if literal.kind == "Integer" or (literal.kind == "Unary" and literal.op == "-" and peel(literal.operand).kind == "Integer") then
        ctx.starts[b.id] = text_of(ctx, literal)
      end
    end
    if written ~= nil and held ~= nil and not held.assigned then
      local literal = peel(written)
      if (literal.kind == "String") then
        ctx.consts[b.id] = literal.value
      else
        ctx.library[b.id] = Calls.library_value(ctx, literal) -- checked: nil_not_allowed
        local ddl, given = Calls.schema_call(ctx, literal)
        if ddl ~= nil and given ~= nil then
          local refusal = require("lang.sql").schema(ddl)
          if refusal ~= nil then
            report(ctx, "sql_schema", given, "SQLite refuses the schema's DDL: " .. refusal,
              "write DDL that SQLite runs, and that creates the tables alone", { refusal })
          end
        end
        local columns, many = Calls.result_columns(ctx, literal)
        if columns ~= nil then
          if many then
            ctx.row_lists[b.id] = columns
          else
            ctx.row_columns[b.id] = columns
          end
        end
      end
    end
    if want ~= nil then
      if t ~= nil and counted then
        local at = s.values[math.min(i, #s.values)]
        local _ = expect(ctx, at, t, want, " as the value of " .. quoted(b.name)) -- checked: nil_not_allowed
      end
      ctx.vars[b.id] = want
    elseif t ~= nil and counted then
      -- A local the program assigns may take another string than the literal a test narrowed its value to.
      local from = if written ~= nil and held ~= nil and held.assigned then place_of(ctx, ctx.flow, written) else nil end
      ctx.vars[b.id] = if held ~= nil and held.assigned then TableLiterals.widened(ctx, t, if from ~= nil then from.declared
        else nil end) else t end
    else
      ctx.vars[b.id] = ctx.invalid
    end
    declare_local(ctx, b.id, false)
    local given = want ~= nil and t ~= nil and counted and not (held ~= nil and held.closure_assigned) and -- checked: and_ternary
      value_narrowing(ctx, t, want) or nil
    if given ~= nil and want ~= nil then
      ctx.flow = Flow.narrow(ctx.flow, id_key(ctx, b.id), given, want)
    end
    if b.attr == "close" then
      check_closable(ctx, b, ctx.vars[b.id]) -- checked: index_may_be_nil
      Tests.closes(ctx)
    end
  end
  if counted and next(wants) == nil then
    tie_locals(ctx, s, vals, reported)
  end
end

--- The type of `object` to write a member of, after reporting what it may not be.
local function writable_base(ctx: Ctx, object: Ast.Exp): Type?
  local t = expr(ctx, object, nil)
  return readable(ctx, object, t, "it has no member to write")
end

--- Whether `target`, of the statement `s`, gives the module's table its field, as a `function M.f(...)` statement does. `s`
--- is a statement of the chunk itself, so it runs once, as the module loads, before the last statement `return M` hands the
--- table to `require`, and no `return` of the chunk has been passed that may hand it out before; `M` is the very local that
--- statement returns, not another name that may hold another table; and no statement before gave the field, this or a
--- `function M.f(...)`. Its value is checked against the field's type all the same, and a read of the field as the module
--- loads above the statement is `static_before_definition` ([`assign_statement`]).
local function inits_module(ctx: Ctx, s: Ast.Assign, target: Ast.Field): boolean
  local object = target.object
  if not (ctx.top[s.id] == true and not ctx.handed and (object.kind == "Name") and object.binding ~= nil and
      object.binding == ctx.module_table and ctx.initialized[target.name] ~= true) then
    return false
  end
  ctx.initialized[target.name] = true
  return true
end

--- The place `target` writes, reporting what may not be written. It is the `at`th target of the statement `s`, which `removes`
--- if it is the only one and gives it a literal nil. A write to an array that is no append, or is one in a statement that runs `runs_code`, is left in `pending`.
local function place_of_target(ctx: Ctx, s: Ast.Assign, target: Ast.Exp, at: integer, removes: boolean, runs_code: boolean,
                               pending: mut {Pending}): Type?, boolean
  local store = ctx.store
  if (target.kind == "Name") then
    local t = name_value(ctx, target)
    return t, false
  elseif (target.kind == "Field") then
    local base = writable_base(ctx, target.object)
    if base == nil then
      return nil, false
    end
    if (base.tag == "named") then
      local list = member_types(ctx, base, target.name)
      if list == nil or list[1].method then -- checked: nil_not_allowed
        field_unknown(ctx, target, base, target.name)
        return nil, false
      end
      local field = assert(list[1])
      local fixed = not field.mut and not inits_module(ctx, s, target)
      if fixed and Types.inferred_record(base.decl) then
        TableLiterals.fixed(ctx, target, base, target.name)
      elseif fixed then
        report(ctx, "field_fixed", target, quoted(Types.decl_name(base.decl) .. "." .. target.name) .. " is fixed: it is not declared `mut`",
          (if Types.shape_record(base.decl) then "declare a record (`local record R ... end`) with `mut " .. target.name ..
              ": " .. show(ctx, field.type) .. "`, and name it in place of the braces" else "declare `mut " .. target.name ..
              ": " .. show(ctx, field.type) .. "` in " .. quoted(Types.decl_name(base.decl)) end) ..
            ", or make a new " .. quoted(Types.decl_name(base.decl)), { show(ctx, base) })
      end
      return put_in(ctx, base, field.type), false
    end
    local read = member_read(ctx, target, base, target.name)
    ctx.cands, ctx.cand_node = nil, nil
    if read.tag ~= "invalid" then
      -- A union has no one field to write, and a string's functions are the library's.
      report(ctx, "field_fixed", target, subject(ctx, target) .. " is a field of " .. tq(ctx, base) ..
          ", which is fixed: only a record's `mut` field is written",
        "narrow the value to one record, then write its `mut` field", { show(ctx, base) })
    end
    return nil, false
  elseif (target.kind == "Index") then
    local base = writable_base(ctx, target.object)
    if base == nil then
      local _ = expr(ctx, target.key, nil)
      return nil, false
    end
    local owner = subject(ctx, target.object)
    if (base.tag == "array") then
      local k = expr(ctx, target.key, store.integer)
      local _ = key_ok(ctx, target.key, k, store.integer, owner)
      local integral = below(ctx, k, store.integer)
      if not base.mut then
        if (removes and Writes.is_length_of(target.key, target.object)) or
            (Writes.is_append(target) and not (runs_code and Writes.may_shorten(ctx, target.object, s))) then
          report(ctx, "view_written", target, owner .. " is a view " .. tq(ctx, base) .. ", so " .. subject(ctx, target) ..
              " cannot be assigned",
            "declare " .. owner .. " `mut " .. show(ctx, base) .. "` where it is made or received" .. read_out(ctx, target, base),
            { show(ctx, base) })
        else
          -- The values say whether the write may leave a hole, which is an `array_hole` beside this error: see below.
          pending[#pending + 1] = { target = target, at = at, owner = owner, base = base, view = true, integral = integral }
        end
      elseif removes and Writes.is_length_of(target.key, target.object) then
        -- The last element goes, so the elements left are the first ones. Of several targets, another may write the key
        -- the length names after this one is gone (`t[#t], t[#t + 1] = nil, v`).
        return base.element, true
      elseif not Writes.is_append(target) or (runs_code and Writes.may_shorten(ctx, target.object, s)) then
        pending[#pending + 1] = { target = target, at = at, owner = owner, base = base, view = false, integral = integral }
      end
      return base.element, false
    elseif (base.tag == "map") then
      local k = expr(ctx, target.key, base.key)
      local _ = key_ok(ctx, target.key, k, base.key, owner)
      if not base.mut then
        report(ctx, "view_written", target, owner .. " is a view " .. tq(ctx, base) .. ", so " .. subject(ctx, target) ..
            " cannot be assigned",
          "declare " .. owner .. " `mut " .. show(ctx, base) .. "` where it is made or received" .. read_out(ctx, target, base),
          { show(ctx, base) })
      end
      return base.value, true
    elseif (base.tag == "named") and (base.decl.kind == "record" or base.decl.kind == "class") then
      local k = expr(ctx, target.key, nil)
      if k.tag == "invalid" then
        return nil, false
      end
      local names = key_names(target.key, k)
      local index = members_index(ctx, base.decl, base.value)
      if names == nil and index ~= nil and index.array ~= nil and below(ctx, k, store.integer) then
        -- TODO: let a record declare its array part `mut`, once the grammar can write it (`record R is mut {T}`): the
        -- array part follows the collection rule, a view unless `mut`, and nothing can declare it so yet.
        report(ctx, "view_written", target, subject(ctx, target) .. " writes the array part of " .. tq(ctx, base) ..
            ", which is a view: no declaration can make it `mut`",
          "keep the elements in a field declared `mut {T}`, and write that", { show(ctx, base) })
        return nil, false
      end
      local only: string? = if names ~= nil and #names == 1 then names[1] else nil end
      if only ~= nil then
        local list = member_types(ctx, base, only)
        local field = if list ~= nil then list[1] else nil end
        if field ~= nil and not field.method then
          local fixed = not field.mut
          if fixed and Types.inferred_record(base.decl) then
            TableLiterals.fixed(ctx, target, base, only)
          elseif fixed then
            local written = "`mut " .. only .. ": " .. show(ctx, field.type) .. "`"
            report(ctx, "field_fixed", target, quoted(Types.decl_name(base.decl) .. "." .. only) .. " is fixed: it is not declared `mut`",
              (if Types.shape_record(base.decl) then "declare a record (`local record R ... end`) with " .. written ..
                  ", and name it in place of the braces" else "declare " .. written .. " in " ..
                  quoted(Types.decl_name(base.decl)) end) .. ", or make a new " .. quoted(Types.decl_name(base.decl)),
              { show(ctx, base) })
          end
          return put_in(ctx, base, field.type), false
        end
        field_unknown(ctx, target.key, base, only)
        return nil, false
      end
      report(ctx, "record_index", target, subject(ctx, target.key) .. " is " .. tq(ctx, k) .. ", which names no one field of " ..
          tq(ctx, base) .. ": a record is not a map",
        "write the field (`" .. text_of(ctx, target.object) .. ".field = v`), or index a `{K: V}`", { show(ctx, k) })
      return nil, false
    end
    local _ = expr(ctx, target.key, nil)
    report(ctx, "not_indexable", target, owner .. " is " .. tq(ctx, base) .. ", which has no elements to write",
      "write an element of an array or a map, or a field of a record", { show(ctx, base) })
    return nil, false
  end
  return nil, false
end

local function check_assignment(ctx: Ctx, s: Ast.Assign): Values?
  local named: mut {integer: boolean} = {}
  for _, target in ipairs(s.targets) do
    local id: integer? = nil
    if (target.kind == "Name") then
      id = target.binding
    end
    -- A name that begins with `_` discards the value, so there is no order to leave open.
    if id ~= nil and (target.kind == "Name") and target.text:sub(1, 1) == "_" then
      id = nil
    end
    if id ~= nil and named[id] == true then
      report(ctx, "assign_repeated", target, subject(ctx, target) .. " is assigned twice by one statement, and Lua leaves " ..
          "the order of the two open",
        "assign " .. subject(ctx, target) .. " once, or in two statements in the order you mean")
    elseif id ~= nil then
      named[id] = true
    end
  end
  local outer_assigning = ctx.assigning
  ctx.assigning = named
  local wants: mut {integer: Type} = {}
  local deletes: mut {integer: boolean} = {}
  local pending: mut {Pending} = {}
  local first = s.values[1]
  local removes = #s.targets == 1 and #s.values == 1 and first ~= nil and peel(first).kind == "Nil"
  local runs_code = Writes.runs_code(s)
  for i, target in ipairs(s.targets) do
    local want, deleting = place_of_target(ctx, s, target, i, removes, runs_code, pending)
    if want ~= nil then
      wants[i] = want
      deletes[i] = deleting
    end
  end
  local vals = values_of(ctx, s.values, wants, nil)
  ctx.assigning = outer_assigning
  for _, p in ipairs(pending) do
    if p.view then
      local owner, base = p.owner, p.base
      local destination = "`mut " .. show(ctx, base) .. "`"
      local element = if base.tag == "array" then base.element else nil end
      if element ~= nil and not Writes.leaves_no_hole(ctx, vals, p) then
        destination = "`mut {integer: " .. show(ctx, element) .. "}` (a map: this write may leave a hole in an array)"
      end
      report(ctx, "view_written", p.target, owner .. " is a view " .. tq(ctx, base) .. ", so " .. subject(ctx, p.target) ..
          " cannot be assigned", "declare " .. owner .. " " .. destination .. " where it is made or received" .. read_out(ctx, p.target, base),
        { show(ctx, base) })
    end
    if not Writes.leaves_no_hole(ctx, vals, p) then
      Writes.report_hole(ctx, vals, p)
    end
  end
  local counted = check_counts(ctx, s, #s.targets, vals, s.values, "target")
  if not counted then
    return nil
  end
  for i, target in ipairs(s.targets) do
    local t = value_at(ctx, vals, i)
    local want = wants[i]
    if t ~= nil and want ~= nil then
      local at = s.values[math.min(i, #s.values)]
      -- Only a literal nil deletes the key of a map; any other value is one of its value type.
      local written = peel(at) -- checked: nil_not_allowed
      if not (deletes[i] == true and (written.kind == "Nil")) then
        ctx.written = if target.kind == "Name" then target else nil end
        local _ = expect(ctx, at, t, want, " in the assignment to " .. subject(ctx, target)) -- checked: nil_not_allowed
        ctx.written = nil
      end
    end
  end
  return vals
end

--- Notes the fields of the module's table that the statement `s` of the chunk gives, once its values are evaluated: a read
--- of one as the module loads is no longer before the statement that gives it.
local function given_by(ctx: Ctx, s: Ast.Assign)
  if ctx.top[s.id] ~= true then
    return
  end
  for _, target in ipairs(s.targets) do
    if (target.kind == "Field") then
      local object = target.object
      if (object.kind == "Name") and object.binding ~= nil and object.binding == ctx.module_table then
        local base = name_value(ctx, object)
        local waiting: mut {string: boolean}? = nil
        if (base.tag == "named") then
          waiting = ctx.pending[base.decl]
        end
        if waiting ~= nil and waiting[target.name] == true then
          ctx.load.waiting = ctx.load.waiting - 1
          waiting[target.name] = nil
        end
      end
    end
  end
end

--- An assignment: the values are evaluated and checked, then each local assigned is another value than it was. Its
--- facts and the facts of the paths from it are gone ([`Flow.State`]), it is assigned from here on, and it is known
--- to have the view of the type of the value ([`value_narrowing`]).
local function assign_statement(ctx: Ctx, s: Ast.Assign)
  if ctx.load.waiting > 0 then
    for i, target in ipairs(s.targets) do
      local given = s.values[i]
      if (target.kind == "Name") then
        local binding = target.binding
        if given ~= nil and binding ~= nil then
          LoadOrder.bind(ctx.load, binding, given)
        end
      elseif (target.kind == "Field") then
        local object = target.object
        if given ~= nil and (object.kind == "Name") then
          local base = name_value(ctx, object)
          if (base.tag == "named") and base.value then
            LoadOrder.store(ctx.load, base.decl, target.name, given)
          end
        end
      end
    end
  end
  local vals = check_assignment(ctx, s)
  given_by(ctx, s)
  for i, target in ipairs(s.targets) do
    -- A nil at an index may take the last element of an array, whatever name the array has.
    if (target.kind == "Index") then
      local value = s.values[i]
      if value == nil or peel(value).kind == "Nil" then
        ctx.flow = Flow.forget_lengths(ctx.flow)
      end
    end
    local id: integer? = nil
    if (target.kind == "Name") then
      id = target.binding
    end
    if id ~= nil then
      -- The drop is told to a later use only where it took away a test that showed the value was not nil.
      local fact = ctx.flow.facts[id_key(ctx, id)]
      local told = (fact ~= nil and not nilable(fact.type)) or ctx.flow.paths > 0 or next(ctx.flow.lens) ~= nil
      local tokens, at = ctx.tokens, base_of(target).first
      ctx.flow = Flow.assign(ctx.flow, id, if told then
        { y = Lexer.y(tokens, at), x = Lexer.x(tokens, at), offset = Lexer.offset(tokens, at),
          length = Lexer.length(tokens, at) } else nil end)
      local v = ctx.scoped.vars[id]
      local declared = ctx.vars[id]
      local t = vals ~= nil and value_at(ctx, vals, i) or nil -- checked: and_ternary
      local given = t ~= nil and declared ~= nil and v ~= nil and PLACE_KINDS[v.kind] and not v.closure_assigned and -- checked: or_mix
        value_narrowing(ctx, t, declared) or nil
      if given ~= nil and declared ~= nil then
        ctx.flow = Flow.narrow(ctx.flow, id_key(ctx, id), given, declared)
      end
    end
  end
end

--- Whether `list` fits the return list `alt`: the same number of values, or more with a tail, each below its item.
local function list_fits(ctx: Ctx, types: {Type}, tail: Type?, alt: Alt): boolean
  local n, m = #types, #alt.items
  if tail == nil then
    if n < m or (n > m and alt.tail == nil) then
      return false
    end
  elseif n > m and alt.tail == nil then
    return false
  end
  for i, t in ipairs(types) do
    local want = alt.items[i] or alt.tail
    if want == nil or not below(ctx, t, want) then
      return false
    end
  end
  if tail ~= nil then
    local rest = ctx.store:optional(tail)
    for i = n + 1, m do
      if not below(ctx, rest, alt.items[i]) then -- checked: index_may_be_nil
        return false
      end
    end
    local at = alt.tail
    if at ~= nil and not below(ctx, tail, at) then
      return false
    end
  end
  return true
end

local function check_return(ctx: Ctx, s: Ast.Return)
  local frame = ctx.frames[#ctx.frames]
  if frame.chunk then -- checked: nil_not_allowed
    -- Reports the value `node`, of type `got`, that an entry point returns ([`Declarations.Input.entry`]), where the run
    -- would refuse it: build/dispatch.tl's `run` calls a function, or a record's `main`, with the command line's words,
    -- `{string}`, and reads what it returns as the exit code (build/exit_status.tl: nil, a whole number or text naming
    -- one); a built program's main module must be a function (core/main.c). Here, not at the top, where the main
    -- chunk holds as many locals as it may.
    local function entry_return(node: Ast.Exp, got: Type)
      local store = ctx.store
      local program = ctx.input.module:match("^cmd%.[^.]+%.main$") ~= nil
      -- A file run alone that returns nil is a run that calls nothing; a built program refuses one.
      local value = if program then got else store:non_nil(got) end
      local what = "the function this entry point returns"
      local fix = "declare it `function(argv: {string}): integer`"
      if value.tag == "named" and not program then
        local members = member_types(ctx, value, "main")
        if members == nil or #members ~= 1 then
          -- TODO: hold each `main` of an overloaded declaration, and each member of a union of records.
          return
        end
        value = store:non_nil(put_in(ctx, value, assert(members[1]).type))
        what = "the `main` of the record this entry point returns"
        fix = "declare `main` a field of type `function(argv: {string}): integer`, not a method"
      end
      if value.tag ~= "fn" then
        if program then
          report(ctx, "entry_signature", node, "a built program calls its main module, and this returns " .. tq(ctx, got) ..
              ", which is no function", "return the function `function(argv: {string}): integer`")
        end
        return
      end
      if #value.tparams > 0 then
        -- TODO: hold a generic function as the call with `{string}` would infer it.
        return
      end
      local words = store:array(store.string)
      local takes = true
      local params = value.params
      local p1 = params[1]
      if p1 ~= nil then
        local wanted = p1.type
        -- An array of `any` takes the words whatever the variance of a view of an array.
        takes = wanted == store.any or (wanted.tag == "array" and wanted.element == store.any) or below(ctx, words, wanted) or below(ctx, store:array(store.string, true), wanted) or
          below(ctx, store:map(store.integer, store.string), wanted)
        for i = 2, #params do
          takes = takes and assert(params[i]).omittable == true
        end
      else
        local rest = value.rest
        takes = rest == nil or rest == store.any or below(ctx, words, rest)
      end
      if not takes then
        report(ctx, "entry_signature", node, what .. " is " .. tq(ctx, value) ..
            ", which cannot take the command line's words, `{string}`", fix .. ", or take no parameters")
        return
      end
      local status = store:optional(store:union({ store.number, store.string }))
      for _, alt in ipairs(value.rets) do
        local code = alt.items[1] or alt.tail
        if code ~= nil and code ~= store.any and not below(ctx, code, status) then
          report(ctx, "entry_signature", node, what .. " is " .. tq(ctx, value) .. ", which answers " .. tq(ctx, code) ..
              " where the run reads an exit code", "return an `integer` from 0 to 255, or nothing")
          return
        end
      end
    end
    local returned = values_of(ctx, s.values, nil, nil)
    local first, value = returned.types[1], s.values[1]
    if ctx.input.entry == true and first ~= nil and value ~= nil then
      entry_return(value, first)
    end
    local info = ctx.program.modules[ctx.input.module]
    local ok = #s.values == 0 or (info ~= nil and (info.export ~= nil or info.value ~= nil))
    if not ok then
      report(ctx, "export_not_declared", s, "this module returns " .. subject(ctx, s.values[1]) .. ", which no declaration describes", -- checked: index_may_be_nil
        "return a record, class, interface or enum of the module, or a local declared with its type")
    end
    return
  end
  local alts = frame.alts -- checked: nil_not_allowed
  local n = #s.values
  if #alts == 0 then
    local _ = values_of(ctx, s.values, nil, nil)
    report(ctx, "return_unexpected", s, "this function is declared `never` and cannot return",
      "end it with `error(...)`, or declare the return list")
    return
  end
  -- What each position wants: the item of the one list that has the length, else the union of those that have it.
  local wants: mut {integer: Type} = {}
  local rest_want: Type? = nil
  local candidates: mut {Alt} = {}
  for _, alt in ipairs(alts) do
    if #alt.items == n or (#alt.items < n and alt.tail ~= nil) or (#alt.items > n) then
      candidates[#candidates + 1] = alt
    end
  end
  for i = 1, n do
    local types: mut {Type} = {}
    for _, alt in ipairs(candidates) do
      local item = alt.items[i] or alt.tail
      if item ~= nil then
        types[#types + 1] = item
      end
    end
    if #types > 0 then
      wants[i] = #types == 1 and types[1] or ctx.store:union(types) -- checked: and_ternary
    end
  end
  for _, alt in ipairs(candidates) do
    if alt.tail ~= nil then
      rest_want = alt.tail
    end
  end
  local vals = values_of(ctx, s.values, wants, rest_want)
  if #candidates > 1 then
    -- A boolean written as the value tells the lists apart: `true` and `false` are types of their own here.
    for i, e in ipairs(s.values) do
      local literal = peel(e)
      if (literal.kind == "Boolean") and vals.types[i] == ctx.store.boolean then
        Calls.replace_type(vals.types, i, ctx.store:atom(if literal.value then "true" else "false" end))
      end
    end
  end
  local last = s.values[n]
  local several = vals.lists
  if several ~= nil then
    for _, got in ipairs(several) do
      local fits = false
      for _, alt in ipairs(alts) do
        fits = fits or list_fits(ctx, got.items, got.tail, alt)
      end
      if not fits then
        report(ctx, "not_assignable", last, subject(ctx, last) .. " answers a list of values this function does not", -- checked: nil_not_allowed*2
          "return values of one of the lists this function declares")
        break
      end
    end
    return
  end
  if #alts == 1 then
    local alt = alts[1]
    if #alt.items == 0 and alt.tail == nil then
      if #vals.types > 0 or vals.tail ~= nil then
        report(ctx, "return_unexpected", s, "this function returns nothing, and this returns " .. plural(#vals.types, "value"),
          if frame.declared then "remove the value" elseif returns_call(s) then UNDECLARED_CALL_FIX else UNDECLARED_RETURN_FIX end) -- checked: nil_not_allowed
      end
      return
    end
    local count = #vals.types
    if vals.tail == nil and (count < #alt.items or (count > #alt.items and alt.tail == nil)) then
      -- A last call that returns more values than are left to return is cut to its first by parentheses.
      local cut = ""
      if last ~= nil and (last.kind == "Call" or last.kind == "MethodCall") and n == #alt.items and count > n then
        cut = "; " .. subject(ctx, last) .. " is the last value and answers " .. tostring(count - n + 1) ..
          " values: write `(" .. text_of(ctx, last) .. ")` to return its first value alone"
      end
      report(ctx, "return_arity", s, "this returns " .. plural(count, "value") .. ", where the function answers " ..
          plural(#alt.items, "value") .. (if alt.tail ~= nil then " or more" else "" end),
        "return " .. plural(#alt.items, "value") .. (if alt.tail ~= nil then " or more" else "" end) ..
          ", or change the declared return list" .. cut)
      return
    end
    for i, t in ipairs(vals.types) do
      local want = alt.items[i] or alt.tail
      local at = s.values[math.min(i, n)]
      local value, first = alt.items[1], s.values[1]
      if want ~= nil and i == 2 and n == 2 and #alt.items == 2 and t.tag == "nil" and want.tag == "string" and
          value ~= nil and (nilable(value) or value.tag == "boolean") and first ~= nil and first.kind ~= "Nil" and
          at ~= nil then
        -- The reason of a `T?, string` result is "" on success: `string?` there, which declaring it suggests, is the
        -- tuple that convention replaces.
        local written = text_of(ctx, first)
        if #written > 40 then written = "v" end
        report(ctx, "nil_not_allowed", at, "nil is given as return value 2, the reason of a `" .. show(ctx, value) ..
            ", string` result, where `string` is wanted",
          "a reason is \"\" on success: `return " .. written .. ", \"\"`, and the failure's text beside a failure " ..
            "(`Counts.open` in `cosmic docs project` shows one)")
      elseif want ~= nil then
        local _ = expect(ctx, at, t, want, " as return value " .. tostring(i)) -- checked: nil_not_allowed
      end
    end
    local tail = vals.tail
    if tail ~= nil and tail.tag ~= "invalid" and last ~= nil then
      -- The `T...` the last value ends in: the values it gives are what follows, and any of them may be missing.
      local maybe = ctx.store:optional(tail)
      local fix = "varargs end in nil: test the first value (`local v = ... if v == nil then ... end`) and return it"
      for i = count + 1, #alt.items do
        if not below(ctx, tail, alt.items[i]) then -- checked: index_may_be_nil
          local _ = expect(ctx, last, tail, alt.items[i], " as return value " .. tostring(i)) -- checked: index_may_be_nil
          return
        elseif not below(ctx, maybe, alt.items[i]) then -- checked: index_may_be_nil
          report(ctx, "nil_not_allowed", last, subject(ctx, last) .. " ends in `" .. show(ctx, tail) .. "...`, so return value " ..
              tostring(i) .. " may be missing, where " .. tq(ctx, alt.items[i]) .. " is wanted", -- checked: index_may_be_nil
            fix, { show(ctx, maybe), show(ctx, alt.items[i]) }) -- checked: index_may_be_nil
          return
        end
      end
      local at = alt.tail
      if at ~= nil then
        local _ = expect(ctx, last, tail, at, " as the values after return value " .. tostring(#alt.items))
      elseif count + 1 > #alt.items then
        report(ctx, "return_arity", last, subject(ctx, last) .. " ends in `" .. show(ctx, tail) ..
            "...`, so this may return more values than the function answers (" .. tostring(#alt.items) .. ")",
          "write `(" .. text_of(ctx, last) .. ")` to return its first value alone, or bind the values to locals and return those")
      end
    end
    return
  end
  for _, alt in ipairs(alts) do
    if list_fits(ctx, vals.types, vals.tail, alt) then
      return
    end
  end
  local shown: mut {string} = {}
  for _, t in ipairs(vals.types) do
    shown[#shown + 1] = show(ctx, t)
  end
  report(ctx, "return_arity", s, "no list this function answers takes (" .. table.concat(shown, ", ") .. ")",
    "return the values of one of the lists the function declares")
end

--- A `return`: checked against the list the function declares, and the end of the path. A function that declares a
--- narrowing must show it here.
local function return_statement(ctx: Ctx, s: Ast.Return)
  check_return(ctx, s)
  if ctx.within == 0 then
    ctx.handed = true
  end
  narrows_proved(ctx, s, s.values[1])
  ctx.flow = Flow.dead(ctx.flow)
end

--- The most rounds a loop is walked quietly before it gives up what it knows of its places.
local ROUNDS <const> = 6

--- Walks a loop to a fixed point. `walk` takes the state at the head of the loop and returns the state its pass ends in,
--- which goes back to the head, and the state the loop leaves in. The head is where the entry and the back edge meet,
--- so a place keeps a fact only if the back edge keeps it too, and a local is unset if it may be; the passes that
--- settle it report nothing (`ctx.quiet`), and one more that reports is made from the head they settle on. A loop whose
--- entry knows nothing has no head to settle.
local function run_loop(ctx: Ctx, entry: Flow.State, walk: function(head: Flow.State): Flow.State, Flow.State): Flow.State
  local head = entry
  if next(entry.facts) ~= nil or next(entry.lens) ~= nil or entry.unsets > 0 then
    ctx.quiet = ctx.quiet + 1
    local round = 0
    while true do
      round = round + 1
      local back, _ = walk(head)
      local nxt = merge(ctx, entry, back)
      if round > ROUNDS then
        nxt = Flow.forget(nxt)
      end
      if Flow.same(nxt, head) then
        break
      end
      head = nxt
    end
    ctx.quiet = ctx.quiet - 1
  end
  local _, leaves = walk(head)
  return leaves
end

--- Opens a loop: where its `break`s and `continue`s are met.
local function open_loop(ctx: Ctx, fill?: Fill, grow?: Grow, span?: Span): Loop
  local loop: Loop = { fill = fill, grow = grow, span = span } -- checked: literal_missing
  ctx.loops[#ctx.loops + 1] = loop
  return loop
end

--- Closes the loop `loop`. Returns the state its pass ends in (the end of the body, with the `continue`s) and the
--- states its `break`s left in.
local function close_loop(ctx: Ctx, loop: Loop, body_end: Flow.State): Flow.State, Flow.State?
  ctx.loops[#ctx.loops] = nil
  local continues = loop.continues
  local back = body_end
  if continues ~= nil then
    back = merge(ctx, body_end, continues)
  end
  return back, loop.breaks
end

--- Two states met, either of which may be absent.
local function merge_maybe(ctx: Ctx, a: Flow.State, b: Flow.State?): Flow.State
  if b == nil then
    return a
  end
  return merge(ctx, a, b)
end

local function numeric_bound(ctx: Ctx, e: Ast.Exp, what: string): integer
  local t = expr(ctx, e, nil)
  return Operands.arithmetic_operand(ctx, e, t, "for " .. what)
end

local function for_numeric(ctx: Ctx, s: Ast.ForNum)
  local from = numeric_bound(ctx, s.from, "start")
  local _ = numeric_bound(ctx, s.to, "limit")
  local step_node = s.step
  local step = 1
  if step_node ~= nil then
    step = numeric_bound(ctx, step_node, "step")
  end
  ctx.vars[s.var.id] = (from == 1 and step == 1) and ctx.store.integer or ctx.store.number -- checked: and_ternary
  local entry = ctx.flow
  local fill = Writes.fill_of(s)
  local span = Writes.span_of(s)
  local grow: Grow? = nil
  if Writes.counts_from_one(s) then
    grow = Writes.grow_in(ctx, s, s.var, s.body)
  end
  ctx.flow = run_loop(ctx, entry, function(head: Flow.State): Flow.State, Flow.State
    ctx.flow = head
    local loop = open_loop(ctx, fill, grow, span)
    declare_local(ctx, s.var.id, false)
    ctx.walk.block(ctx, s.body)
    local back, breaks = close_loop(ctx, loop, ctx.flow)
    return back, merge_maybe(ctx, head, breaks)
  end)
end

local function for_generic(ctx: Ctx, s: Ast.ForIn)
  local store = ctx.store
  Calls.for_rows(ctx, s)
  local vals = values_of(ctx, s.iterators, nil, nil)
  local iterator = vals.types[1] or vals.tail
  local types: mut {Type} = {}
  local fourth = s.iterators[4]
  if fourth ~= nil then
    report(ctx, "iterator_extra", fourth, "a generic `for` takes an iterator, a state and a first control value, and " ..
        subject(ctx, fourth) .. " is a fourth: Lua takes it as the value to close, and raises when it has no `__close`",
      "write at most three expressions after `in`")
  else
    -- a call that returns a fourth value in the last place gives the same closing value
    local closing = vals.types[4]
    local last_expression = s.iterators[#s.iterators]
    local tail = vals.tail
    if closing ~= nil and closing ~= ctx.nil_type and last_expression ~= nil then
      report(ctx, "iterator_extra", last_expression, subject(ctx, last_expression) .. " answers a fourth value, which Lua takes " ..
          "as the value to close, and raises when it has no `__close`", "write at most three expressions after `in`")
    elseif closing == nil and tail ~= nil and tail ~= ctx.nil_type and tail.tag ~= "invalid" and last_expression ~= nil then
      -- The values after the third are not counted: any number may follow, and the fourth is the value to close.
      report(ctx, "iterator_extra", last_expression, subject(ctx, last_expression) .. " answers any number of " ..
          tq(ctx, tail) .. " values after those it lists, and Lua takes a fourth as the value to close, raising when it has " ..
          "no `__close`", "name the three values first (`local iterator, state, control = ...`) and write `for x in " ..
          "iterator, state, control do`, or answer exactly an iterator, a state and a control value")
    end
  end
  local several, last = vals.lists, vals.last
  if several ~= nil and last ~= nil then
    local _ = first_value(ctx, last, several)
  elseif iterator == nil then
    local first = s.iterators[1]
    report(ctx, "no_value", first, subject(ctx, first) .. " answers nothing, so there is no iterator to loop over", -- checked: nil_not_allowed*2
      "iterate with `ipairs(...)`, `pairs(...)` or an iterator function")
  end
  local before = #ctx.errors
  local generic_iterator: Fn? = nil
  local solved: Instance? = nil
  if iterator ~= nil and (iterator.tag == "fn") and #iterator.tparams > 0 then
    -- An iterator that is a generic function is called with the state and the control value.
    local known: mut {integer: Type} = {}
    for i = 1, 2 do
      local value = vals.types[i + 1]
      if value ~= nil then
        known[i] = value
      end
    end
    local given: Prepared = { known = known, pending = {}, count = math.max(0, math.min(2, #vals.types - 1)), open = false } -- checked: literal_missing
    before = #ctx.errors
    generic_iterator = iterator
    solved = Calls.solve(ctx, s.iterators[1], text_of(ctx, s.iterators[1]), iterator, s.iterators, given, 0, nil, nil, true) -- checked: index_may_be_nil*2
    local made = solved.fn
    if made ~= nil then
      iterator = made
    end
  end
  if iterator == nil or iterator.tag == "invalid" then
    for i = 1, #s.vars do
      types[i] = ctx.invalid
    end
  elseif (iterator.tag == "fn") and #iterator.tparams > 0 then
    for i = 1, #s.vars do
      types[i] = ctx.invalid
    end
  elseif (iterator.tag == "fn") then
    local alts: mut {Alt} = {}
    for _, alt in ipairs(iterator.rets) do
      local first = alt.items[1]
      if not (first ~= nil and first.tag == "nil") then
        alts[#alts + 1] = alt
      end
    end
    local produces, open = 0, false
    for _, alt in ipairs(alts) do
      produces = math.max(produces, #alt.items)
      open = open or alt.tail ~= nil
    end
    local surplus = s.vars[produces + 1]
    if surplus ~= nil and not open and #alts > 0 then
      report(ctx, "iterator_variables", surplus, quoted(surplus.name) .. " is variable " .. tostring(produces + 1) ..
          " of a `for`, and the iterator answers " .. tostring(produces) .. (if produces == 1 then " value" else " values" end) ..
          ", so it is always nil",
        "name no more variables than the iterator answers values")
    end
    for i = 1, #s.vars do
      local t = column(ctx, alts, i)
      if i == 1 then
        t = store:non_nil(t)
      end
      types[i] = t
    end
    local state, control = vals.types[2], vals.types[3]
    local final = s.iterators[#s.iterators]
    local iterator_state, iterator_control = iterator.params[1], iterator.params[2]
    if state ~= nil and iterator_state ~= nil then
      local _ = expect_argument(ctx, s.iterators[math.min(2, #s.iterators)], state, iterator_state.type, -- checked: index_may_be_nil
        " as the state of the iterator")
    end
    if control ~= nil and iterator_control ~= nil then
      local _ = expect_argument(ctx, s.iterators[math.min(3, #s.iterators)] or final, control, iterator_control.type, -- checked: nil_not_allowed
        " as the first value of the iterator")
    end
  else
    report(ctx, "not_callable", s.iterators[1], subject(ctx, s.iterators[1]) .. " is " .. tq(ctx, iterator) .. -- checked: index_may_be_nil*2
        ", which is no iterator function",
      "iterate a collection with `ipairs(...)` or `pairs(...)`, or pass an iterator function", { show(ctx, iterator) })
    for i = 1, #s.vars do
      types[i] = ctx.invalid
    end
  end
  if solved ~= nil and generic_iterator ~= nil then
    Calls.holes(ctx, s.iterators[1], text_of(ctx, s.iterators[1]), generic_iterator, solved, before) -- checked: index_may_be_nil*2
  end
  for i, v in ipairs(s.vars) do
    ctx.vars[v.id] = types[i] -- checked: index_may_be_nil
  end
  local entry = ctx.flow
  local grow: Grow? = nil
  local index = s.vars[1]
  if index ~= nil and Writes.counts_ipairs(ctx, s) then
    grow = Writes.grow_in(ctx, s, index, s.body)
  end
  ctx.flow = run_loop(ctx, entry, function(head: Flow.State): Flow.State, Flow.State
    -- The iterator runs before each pass and when the loop ends, and may shorten an array.
    local ran = Flow.forget_lengths(head)
    ctx.flow = ran
    local loop = open_loop(ctx, nil, grow)
    for _, v in ipairs(s.vars) do
      declare_local(ctx, v.id, false)
    end
    ctx.walk.block(ctx, s.body)
    local back, breaks = close_loop(ctx, loop, ctx.flow)
    return back, merge_maybe(ctx, ran, breaks)
  end)
  -- The value to close, which the iterator call may return in the fourth place, is closed where the loop ends.
  ctx.flow = Flow.forget_lengths(ctx.flow)
end

--- The bodies of the methods of a class, and of the declarations nested in a record, interface or class.
local function declaration_bodies(ctx: Ctx, node: Ast.Node, decl: Decl?)
  local members: {Ast.Member} = {}
  if (node.kind == "Record") or (node.kind == "Interface") or (node.kind == "Class") then
    members = node.members
  end
  local body = decl ~= nil and decl.body or nil -- checked: and_ternary
  local binder = decl ~= nil and body ~= nil and #body.tparams > 0
  if binder and decl ~= nil and body ~= nil then
    local names: mut {string} = {}
    for _, p in ipairs(body.tparams) do
      names[#names + 1] = p.name
    end
    local tparams = Relation.binder(decl)
    ctx.judge:enter(tparams)
    ctx.binders[#ctx.binders + 1] = names
    ctx.bounds[#ctx.bounds + 1] = tparams
  end
  if decl ~= nil then
    -- Before any body: a method names the others.
    for _, m in ipairs(members) do
      if (m.kind == "Method") then
        LoadOrder.define(ctx.load, decl, m.name.name, m.id)
      end
    end
    -- The interfaces it lists, and those they extend: a method called through one may be a method of this class.
    local to_visit: mut {Type} = {}
    if body ~= nil then
      for _, super in ipairs(body.supers) do
        to_visit[#to_visit + 1] = super
      end
    end
    local seen: mut {Decl: boolean} = {}
    while #to_visit > 0 do
      local super = table.remove(to_visit)
      if (super.tag == "named") and seen[super.decl] ~= true then -- checked: nil_not_allowed
        seen[super.decl] = true
        LoadOrder.implement(ctx.load, super.decl, decl)
        local above = super.decl.body
        if above ~= nil then
          for _, next_super in ipairs(above.supers) do
            to_visit[#to_visit + 1] = next_super
          end
        end
      end
    end
  end
  for _, m in ipairs(members) do
    if (m.kind == "Method") then
      local ft = ctx.lowered.types[m.id] or ctx.invalid
      function_body(ctx, m.params, m.body, ft, Declarations.parameter_names(m.typeparams), m, m.rets ~= nil, m.id,
        (if decl ~= nil then decl.name else "?" end) .. "." .. m.name.name)
    elseif (m.kind == "Record") or (m.kind == "Interface") or (m.kind == "Class") then
      local nested = ctx.lowered.decls[m.id]
      if nested ~= nil then
        ctx.declared[nested] = true
      end
      declaration_bodies(ctx, m, nested)
    end
  end
  if binder then
    ctx.judge:leave()
    ctx.binders[#ctx.binders] = nil
    ctx.bounds[#ctx.bounds] = nil
  end
end

--- `function R.m(...)`: the function implements the field `m` of `R`.
local function function_statement(ctx: Ctx, s: Ast.Function)
  local head = s.path[1]
  if head == nil then
    -- The parser said the statement has no name; its body is still checked.
    function_body(ctx, s.fn.params, s.fn.body, function_type(ctx, s.fn, nil, "this function"), {}, s, s.fn.rets ~= nil,
      s.fn.id, "function")
    return
  end
  local owner = name_value(ctx, head)
  local waiting = (owner.tag == "named") and ctx.pending[owner.decl] or nil -- checked: and_ternary
  if #s.path == 2 and head.binding ~= nil and head.binding == ctx.module_table then
    ctx.initialized[s.path[2].text] = true
  end
  if waiting ~= nil and #s.path == 2 then
    if waiting[s.path[2].text] == true then
      ctx.load.waiting = ctx.load.waiting - 1
    end
    waiting[s.path[2].text] = nil
  end
  local text = head.text
  for i = 2, #s.path do
    text = text .. "." .. s.path[i].text -- checked: nil_not_allowed
  end
  local ft = function_type(ctx, s.fn, nil, quoted(text))
  if (owner.tag == "named") and owner.value and owner.decl.kind == "integer_enum" then
    -- The table of an integer enum is made whole where it is declared: a statement would replace `of` or `name` at run
    -- time with a function the checker does not read as theirs.
    report(ctx, "field_fixed", s, quoted(text) .. " defines a function in the table of the integer enum " ..
        quoted(Types.decl_name(owner.decl)) .. ", which holds its members, `of` and `name` and nothing more",
      "declare the function beside the enum (`local function ...`), and call " .. quoted(Types.decl_name(owner.decl) .. ".of") ..
        " or " .. quoted(Types.decl_name(owner.decl) .. ".name") .. " in it", { show(ctx, owner) })
  elseif owner.tag ~= "invalid" then
    local field_type: Type = owner
    for i = 2, #s.path do
      local part = s.path[i]
      local base = readable(ctx, s.path[i - 1], field_type, "it has no member to define") -- checked: index_may_be_nil
      if base == nil then
        field_type = ctx.invalid
        break
      end
      field_type = member_read(ctx, part, base, part.text) -- checked: nil_not_allowed*2
      ctx.cands, ctx.cand_node = nil, nil
    end
    if field_type.tag ~= "invalid" then
      -- A field of a generic declaration is typed by its type parameters, whose bounds a method's own must meet.
      local arity = if (owner.tag == "named") then owner.decl.arity else nil end
      local generic = arity ~= nil and arity > 0 and (owner.tag == "named") and owner.decl.body ~= nil
      if generic and (owner.tag == "named") then
        ctx.judge:enter(Relation.binder(owner.decl))
      end
      local _ = expect(ctx, s, ft, field_type, " as the declaration of " .. quoted(text))
      if generic then
        ctx.judge:leave()
      end
    end
  end
  if (owner.tag == "named") and #s.path == 2 then
    LoadOrder.define(ctx.load, owner.decl, s.path[2].text, s.fn.id)
  end
  function_body(ctx, s.fn.params, s.fn.body, ft, Declarations.parameter_names(s.typeparams), s, s.fn.rets ~= nil, s.fn.id, text)
end

--- `if`: each arm is walked under the state where its condition holds and those before it do not, and what follows is
--- where the ends of the arms, and of the path that took none, meet.
local function if_statement(ctx: Ctx, s: Ast.If)
  local ends: mut {Flow.State} = {}
  for _, arm in ipairs(s.arms) do
    local _ = condition(ctx, arm.cond)
    local yes, no = edges(ctx, ctx.flow, arm.cond)
    ctx.flow = yes
    local ranges = Writes.ranges_of(arm.cond, arm.body)
    for _, range in ipairs(ranges) do
      ctx.ranges[#ctx.ranges + 1] = range
    end
    ctx.walk.block(ctx, arm.body)
    for _ = 1, #ranges do
      ctx.ranges[#ctx.ranges] = nil
    end
    ends[#ends + 1] = ctx.flow
    ctx.flow = no
  end
  local else_body = s.else_body
  if else_body ~= nil then
    ctx.walk.block(ctx, else_body)
  end
  ends[#ends + 1] = ctx.flow
  ctx.flow = merge_all(ctx, ends)
end

--- `while`: the condition is evaluated at the head, the body under the state where it holds, and the loop is left where
--- it does not hold or at a `break`.
local function while_statement(ctx: Ctx, s: Ast.While)
  ctx.flow = run_loop(ctx, ctx.flow, function(head: Flow.State): Flow.State, Flow.State
    ctx.flow = head
    local _ = condition(ctx, s.cond)
    local yes, no = edges(ctx, ctx.flow, s.cond)
    ctx.flow = yes
    local loop = open_loop(ctx)
    ctx.walk.block(ctx, s.body)
    local back, breaks = close_loop(ctx, loop, ctx.flow)
    return back, merge_maybe(ctx, no, breaks)
  end)
end

--- `repeat ... until c`: the body runs once before `c`, which sees the locals of the body and the `continue`s; the loop
--- is left where `c` holds or at a `break`, and goes back where it does not.
local function repeat_statement(ctx: Ctx, s: Ast.Repeat)
  ctx.flow = run_loop(ctx, ctx.flow, function(head: Flow.State): Flow.State, Flow.State
    ctx.flow = head
    local loop = open_loop(ctx)
    local closers = ctx.closers
    ctx.walk.stats(ctx, s.body)
    local continues = loop.continues
    if continues ~= nil then
      ctx.flow = merge(ctx, ctx.flow, continues)
    end
    local _ = condition(ctx, s.cond)
    local yes, no = edges(ctx, ctx.flow, s.cond)
    ctx.loops[#ctx.loops] = nil
    -- The scope of the body ends after the condition, which both edges leave.
    if ctx.closers ~= closers then
      yes, no = Flow.forget_lengths(yes), Flow.forget_lengths(no)
      ctx.closers = closers
    end
    return no, merge_maybe(ctx, yes, loop.breaks)
  end)
end

--- `break` (`leaves`) and `continue`: the state goes to the innermost loop, and the path ends.
local function jump_statement(ctx: Ctx, leaves: boolean)
  local loop = ctx.loops[#ctx.loops]
  if loop ~= nil then
    local f = ctx.flow
    if leaves then
      loop.breaks = merge_maybe(ctx, f, loop.breaks) -- checked: field_fixed
    else
      loop.continues = merge_maybe(ctx, f, loop.continues) -- checked: field_fixed
    end
  end
  ctx.flow = Flow.dead(ctx.flow)
end

--- How the tests of `arm` stand against the list `alt` the call may return: "yes" when each `true`, `false` and `nil`
--- is the value the list has at its position, "no" when the list has another value there that the test tells from it
--- (`false` at a `true`, `nil` at a `true` or `false`, a value that is never nil at a `nil`), and "unclear" when the
--- test does not tell what the list has there (the position it is, or 0, for the message).
local function arm_against(ctx: Ctx, arm: Ast.MatchArm, alt: Alt): string, integer
  local unclear = 0
  for i, p in ipairs(arm.pats) do
    if (p.kind == "PatBool") or (p.kind == "PatNil") then
      local item = alt.items[i]
      local tag = ""
      if item ~= nil then
        tag = item.tag
      end
      local verdict = "unclear"
      if (p.kind == "PatBool") then
        if tag == "true" or tag == "false" then
          verdict = if (tag == "true") == p.value then "yes" else "no" end
        elseif tag == "nil" then
          verdict = "no"
        end
      elseif tag == "nil" then
        verdict = "yes"
      elseif item ~= nil and Operands.present(ctx, item) then
        verdict = "no"
      end
      if verdict == "no" then
        return "no", i
      elseif verdict == "unclear" and unclear == 0 then
        unclear = i
      end
    end
  end
  if unclear > 0 then
    return "unclear", unclear
  end
  return "yes", 0
end

--- The arm that takes the list `alt`: `true`, `false` and `nil` where the list has them, and a name for each other value.
local function arm_for(alt: Alt): string
  local pats: mut {string} = {}
  for i, item in ipairs(alt.items) do
    local pat = "v" .. tostring(i)
    if item.tag == "true" or item.tag == "false" or item.tag == "nil" then
      pat = item.tag
    end
    pats[i] = pat
  end
  if #pats == 0 and alt.tail ~= nil then
    pats[1] = "v1"
  end
  return "| (" .. table.concat(pats, ", ") .. ") then ..."
end

--- A typed `match`: each arm tests the value for a type, as `is` does, and takes what the arms before it leave of the
--- value of that type. An arm that takes nothing is `match_redundant`; the types no arm takes are `match_missing`,
--- unless an arm `| _` takes them. In an arm the name, and the value where it is a place, have the type the arm takes.
local function typed_match(ctx: Ctx, s: Ast.Match)
  local value = expr(ctx, s.scrutinee, nil)
  local p = place_of(ctx, ctx.flow, s.scrutinee)
  local start = ctx.flow
  local rest = value
  local ends: mut {Flow.State} = {}
  local caught = false
  for _, arm in ipairs(s.arms) do
    local pat = arm.pats[1]
    local kept = rest
    local leaves = ctx.store.never
    if (pat ~= nil) and (pat.kind == "PatType") then
      local tested = ctx.lowered.types[pat.type.id] or ctx.invalid
      if tested.tag == "invalid" or value.tag == "invalid" then
        kept, leaves = ctx.invalid, rest
      elseif rest.tag == "never" or not Operators.testable(ctx, rest, tested) then
        local had = Operators.testable(ctx, value, tested)
        kept, leaves = ctx.store.never, rest
        report(ctx, "match_redundant", pat, if had then "this arm never runs: the arms before it take every " ..
            tq(ctx, tested) .. " " .. subject(ctx, s.scrutinee) .. " may be" else "this arm never runs: " ..
            subject(ctx, s.scrutinee) .. " is " .. tq(ctx, value) .. ", and no value of it is " .. tq(ctx, tested) end,
          "delete the arm, or test a type the arms before it leave" .. (if rest.tag == "never" then "" else " (" ..
              tq(ctx, rest) .. ")" end), { show(ctx, tested) })
      else
        Operators.tested(ctx, pat, pat.type, s.scrutinee, rest, tested, true)
        kept, leaves = Tests.keep_is(ctx, rest, tested), Tests.drop_is(ctx, rest, tested)
        if tested.tag == "any" then
          -- `| any v` takes every value the arms before it leave, as `| _` does.
          kept, leaves = rest, ctx.store.never
        end
      end
      local name = pat.name
      if name ~= nil then
        ctx.vars[name.id] = kept
        declare_local(ctx, name.id, false)
      end
    else
      -- `| _`: every value the arms before it leave.
      caught = true
      if rest.tag == "never" then
        report(ctx, "match_redundant", arm, "this arm never runs: the arms before it take every value " ..
            subject(ctx, s.scrutinee) .. " may be", "delete the arm", {})
      end
    end
    ctx.flow = start
    if p ~= nil and kept.tag ~= "invalid" then
      ctx.flow = Narrowing.narrowed_flow(start, p, kept)
    end
    ctx.walk.block(ctx, arm.body)
    ends[#ends + 1] = ctx.flow
    rest = leaves
  end
  if not caught and rest.tag ~= "never" and rest.tag ~= "invalid" and value.tag ~= "invalid" then
    local arms: mut {string} = {}
    for _, m in ipairs(members_of(ctx.store, rest)) do
      arms[#arms + 1] = Narrowing.type_arm(ctx, m)
    end
    report(ctx, "match_missing", s, "this `match` takes no arm for " .. tq(ctx, rest) .. ", which " ..
        subject(ctx, s.scrutinee) .. " may be", "add " .. (if #arms == 1 then "the arm " else "the arms " end) ..
        table.concat(arms, ", ") .. ", or `| _ then ...` for every value the arms leave", { show(ctx, rest) })
    ends[#ends + 1] = if p ~= nil then Narrowing.narrowed_flow(start, p, rest) else start end
  end
  if #ends > 0 then
    ctx.flow = merge_all(ctx, ends)
  end
end

--- `match`: the arms cover the lists the call may return exactly. An arm
--- takes the lists whose value at each position it tests with `true` or
--- `false` is that one, and a list some earlier arm takes is not its: the
--- names of the arm are the union of what those lists have where the name
--- stands, and each arm names every value of them. An arm that takes no
--- list, or only lists the arms before it took, is `match_redundant`; a
--- list no arm takes is `match_missing`. Each arm is walked from the state
--- after the call, and what follows is where their ends meet.
local function match_statement(ctx: Ctx, s: Ast.Match)
  if s.typed then
    typed_match(ctx, s)
    return
  end
  local c = s.scrutinee
  local alts = unknown_lists(ctx)
  if (c.kind == "Call") or (c.kind == "MethodCall") then
    alts = lists_of(ctx, c, nil)
  end
  local unknown = false
  for _, alt in ipairs(alts) do
    local tail = alt.tail
    unknown = unknown or (tail ~= nil and tail.tag == "invalid")
  end
  local start = ctx.flow
  local ends: mut {Flow.State} = {}
  local taken: mut {integer: boolean} = {}
  for _, arm in ipairs(s.arms) do
    ctx.flow = start
    local mine: mut {Alt} = {}
    local explained = false
    if not unknown then
      local selected = 0
      for k, alt in ipairs(alts) do
        local verdict, at = arm_against(ctx, arm, alt)
        if verdict == "unclear" then
          explained = true
          taken[k] = true
          local pat = assert(arm.pats[at])
          local item = alt.items[at]
          local tested = "nil"
          if (pat.kind == "PatBool") then
            tested = if pat.value then "true" else "false" end
          end
          report(ctx, "match_pattern", pat, "this pattern tests position " .. tostring(at) .. " with `" .. tested ..
              "`, and the list " .. quoted(lists_text(ctx, { alt })) .. " has " ..
              (item ~= nil and tq(ctx, item) or "no value") .. " there, which `" .. tested .. "` does not tell", -- checked: and_ternary
            "test only the positions that are `true`, `false` or `nil` in the lists the call answers, and name the others",
            { lists_text(ctx, { alt }) })
        elseif verdict == "yes" then
          selected = selected + 1
          local have, n = #alt.items, #arm.pats
          -- A list an arm before took is not this arm's, so its count of values does not bind this arm.
          if taken[k] ~= true and (n < have or (alt.tail == nil and n > have)) then
            explained = true
            report(ctx, "match_pattern", arm, "this arm names " .. plural(n, "value") .. ", and the list " ..
                quoted(lists_text(ctx, { alt })) .. " it takes has " .. (if alt.tail ~= nil then "at least " else "" end) ..
                plural(have, "value"),
              "write " .. (if alt.tail ~= nil then "at least " else "" end) .. plural(have, "pattern") .. ", `_` for a value the arm " ..
                "does not use: " .. quoted(arm_for(alt)), { lists_text(ctx, { alt }) })
          end
          if taken[k] ~= true then
            mine[#mine + 1] = alt
            taken[k] = true
          end
        end
      end
      if #mine == 0 and not explained then
        report(ctx, "match_redundant", arm, if selected == 0 then "this arm takes no list the call answers: no list has the " ..
            "values its `true`, `false` and `nil` test" else "this arm takes only lists the arms before it take, so it never runs" end,
          "delete the arm, or change its `true`, `false` and `nil` to take a list no arm before it takes")
      end
    end
    for i, p in ipairs(arm.pats) do
      if (p.kind == "PatBind") then
        local types: mut {Type} = {}
        for _, alt in ipairs(mine) do
          local item = alt.items[i]
          local tail = alt.tail
          if item ~= nil then
            types[#types + 1] = item
          elseif tail ~= nil then
            types[#types + 1] = ctx.store:optional(tail)
          else
            types[#types + 1] = ctx.nil_type
          end
        end
        ctx.vars[p.name.id] = #types > 0 and ctx.store:union(types) or ctx.invalid -- checked: and_ternary
        declare_local(ctx, p.name.id, false)
      end
    end
    ctx.walk.block(ctx, arm.body)
    ends[#ends + 1] = ctx.flow
  end
  if not unknown then
    for k, alt in ipairs(alts) do
      if taken[k] ~= true then
        report(ctx, "match_missing", s, "this `match` takes no arm for the list " .. quoted(lists_text(ctx, { alt })) ..
            " the call may answer",
          "add the arm " .. quoted(arm_for(alt)), { lists_text(ctx, { alt }) })
      end
    end
  end
  if #ends > 0 then
    ctx.flow = merge_all(ctx, ends)
  end
end

local function stat(ctx: Ctx, s: Ast.Stat)
  if (s.kind == "Local") then
    local_statement(ctx, s)
  elseif (s.kind == "CallStat") then
    local c = s.call
    if (c.kind == "Call") or (c.kind == "MethodCall") then
      local alts = lists_of(ctx, c, nil)
      if #alts > 1 then
        local call = Naming.call(ctx, c)
        report(ctx, "failure_ignored", c, subject(ctx, c) .. " answers one of " .. tostring(#alts) .. " lists of values, " ..
            "one of which may be a failure, and as a statement it drops which one it answered, so a failure would pass unseen",
          "bind its values and test the first (`local " .. Naming.bound(alts) .. " = " .. call .. "`), match the call, " ..
            (if ValueLists.asserted(ctx, alts) ~= nil then "raise where it fails with `" .. call .. "!`, " else "" end) ..
            "or discard them on purpose: `local " .. Naming.bound(alts, true) .. " = " .. call .. "`")
      end
    end
  elseif (s.kind == "Assign") then
    assign_statement(ctx, s)
  elseif (s.kind == "If") then
    if_statement(ctx, s)
  elseif (s.kind == "Return") then
    return_statement(ctx, s)
  elseif (s.kind == "Break") then
    jump_statement(ctx, true)
  elseif (s.kind == "Continue") then
    jump_statement(ctx, false)
  elseif (s.kind == "LocalFunction") then
    local ft = function_type(ctx, s.fn, nil, quoted(s.name.name))
    ctx.vars[s.name.id] = ft
    declare_local(ctx, s.name.id, false)
    if ctx.load.waiting > 0 then
      LoadOrder.hold(ctx.load, s.name.id, s.fn.id)
    end
    function_body(ctx, s.fn.params, s.fn.body, ft, Declarations.parameter_names(s.typeparams), s, s.fn.rets ~= nil, s.fn.id,
      s.name.name)
  elseif (s.kind == "Function") then
    function_statement(ctx, s)
  elseif (s.kind == "While") then
    while_statement(ctx, s)
  elseif (s.kind == "Repeat") then
    repeat_statement(ctx, s)
  elseif (s.kind == "Do") then
    ctx.walk.block(ctx, s.body)
  elseif (s.kind == "ForNum") then
    for_numeric(ctx, s)
  elseif (s.kind == "ForIn") then
    for_generic(ctx, s)
  elseif (s.kind == "Match") then
    match_statement(ctx, s)
  elseif (s.kind == "Record") or (s.kind == "Interface") or (s.kind == "Class") then
    local decl = ctx.lowered.decls[s.id]
    if decl ~= nil then
      ctx.declared[decl] = true
    end
    local schema_value = if (s.kind == "Class") then s.schema_value else nil end
    if schema_value ~= nil then
      local _ = expect(ctx, schema_value, expr(ctx, schema_value, ctx.store.string), ctx.store.string, " as the DDL of a schema")
    end
    local body = if decl ~= nil and (s.kind == "Class") and s.schema ~= nil then decl.body else nil end
    local ddl = if body ~= nil then body.schema else nil end
    local refusal = if ddl ~= nil then require("lang.sql").schema(ddl) else nil end
    if refusal ~= nil then
      report(ctx, "sql_schema", s.name, "SQLite refuses the DDL of the schema " .. quoted(s.name.name) .. ": " .. refusal,
        "write DDL that SQLite runs, and that creates the tables alone", { refusal })
    end
    declaration_bodies(ctx, s, decl)
  end
end

--- Whether a statement is code that runs, which a type declaration is not.
local function runs(s: Ast.Stat): boolean
  return not ((s.kind == "Record") or (s.kind == "Interface") or (s.kind == "Class") or (s.kind == "Enum") or (s.kind == "Alias") or
    (s.kind == "Import") or (s.kind == "Error"))
end

--- Walks the statements of `b`. The first that control cannot reach is reported (`unreachable`), where the block was
--- reached; it and the rest are walked from the state at the jump.
local function stats(ctx: Ctx, b: Ast.Block)
  local reported = not ctx.flow.live
  for _, s in ipairs(b.stats) do
    if not ctx.flow.live and not reported and runs(s) then
      reported = true
      report(ctx, "unreachable", s, "control never reaches this statement: what comes before it ends the block",
        "remove it, or move it before the `return`, `break`, `continue`, call that never returns, or loop with no exit " ..
          "that ends the block")
    end
    stat(ctx, s)
  end
end

local function block(ctx: Ctx, b: Ast.Block)
  local closers = ctx.closers
  stats(ctx, b)
  Tests.leaves(ctx, closers)
end

function Check.enums(lowered: Declarations.Lowered): {integer: {string}}
  local out: mut {integer: {string}} = {}
  for id, t in pairs(lowered.types) do
    local body: Types.Body? = nil
    if (t.tag == "named") and not t.value and t.decl.kind == "enum" then
      body = t.decl.body
    end
    if body ~= nil then
      out[id] = body.values
    end
  end
  return out
end

--- The local that the module's last statement, `return M`, returns where `M` is a record the module declares: the module's
--- table, which a statement of the chunk gives its fields ([`inits_module`]). Nil where the module returns anything else.
local function module_table(input: Declarations.Input, lowered: Declarations.Lowered): integer?
  local export, chunk = lowered.export, input.chunk.body.stats
  local last = chunk[#chunk]
  if export == nil or export.instance == true or export.module ~= input.module or last == nil or
      not ((last.kind == "Return")) or #last.values ~= 1 then
    return nil
  end
  local returned = assert(last.values[1])
  local decl = export.decl
  if not ((returned.kind == "Name")) or returned.binding == nil or decl == nil or decl.kind ~= "record" then
    return nil
  end
  local binding = assert(returned.binding)
  local entry = lowered.entries[binding]
  if entry == nil or entry.decl ~= decl then
    return nil
  end
  return binding
end

function Check.check(program: Declarations.Program, input: Declarations.Input, lowered: Declarations.Lowered,
                     typed?: boolean): Check.Checked
  local store = program.store
  local tops: mut {integer: boolean} = {}
  for _, t in ipairs(input.chunk.body.stats) do
    tops[t.id] = true
  end
  local ctx: Ctx = { -- checked: literal_missing
    walk = { expr = expr, lists_of = lists_of, leaf = leaf, evaluate = evaluate, edges = edges, block = block, stats = stats,
      stat = stat },
    program = program, store = store, judge = program.judge, input = input, lowered = lowered, scoped = input.scoped,
    tokens = input.chunk.tokens, filename = input.filename, errors = {}, vars = {}, frames = {}, binders = {},
    bounds = {}, fn_names = Naming.declared(program, input.module), lenient = 0, no_drop = false, members = {}, value_members = {}, pending = {}, within = 0, probes = {},
    load = LoadOrder.new(0, function(_decl: Decl, _name: string): boolean
      return false
    end, function(_node: Ast.Node, _spelled: string, _found: LoadOrder.Found) end),
    literals = {}, spreads = {}, tags = {}, declared = {}, union_fields = {}, spine = {},
    ternaries = {}, spare = {}, invalid = store.invalid, nil_type = store:atom("nil"), flow = Flow.start(), unfixed_now = {}, string_subs = {}, assigning = {}, quiet = 0, closers = 0, callee_module = "", member_module = "", moves = {},
    loops = {}, ranges = {}, map_reads = {}, keys = {}, edges = {}, guards = {}, ties = {}, coroutine_reads = {}, top = tops, module_table = module_table(input, lowered), initialized = {}, given = {}, handed = false, reads = {}, unfixed = {}, narrowed = {}, inert = {}, runs = {}, inferred = {}, boundaries = {}, types = {}, callees = {}, consts = {}, unread_schemas = {}, call_columns = {}, row_lists = {}, row_columns = {}, starts = {}, library = {}, typed = typed ~= false, warnings = {},
    unite = function(a: Type, b: Type): Type
      return store:union({ a, b })
    end,
    covers = function(declared: Type, united: Type): boolean
      return declared == united
    end,
  }
  ctx.covers = function(declared: Type, united: Type): boolean
    return below(ctx, declared, united)
  end
  ctx.unite = function(a: Type, b: Type): Type
    return subsume(ctx, store:union({ a, b }))
  end
  ctx.load = LoadOrder.new(0, function(decl: Decl, name: string): boolean
    local waiting = ctx.pending[decl]
    return waiting ~= nil and waiting[name] == true
  end, function(node: Ast.Node, spelled: string, found: LoadOrder.Found)
    local read = found.read
    local what, statement = static_words(ctx, read.decl, read.name)
    local through = ""
    if #found.via > 0 then
      local names: mut {string} = {}
      for i, via in ipairs(found.via) do
        names[i] = via
      end
      through = " through " .. table.concat(names, ", ")
    end
    report(ctx, "static_before_definition", node, spelled .. " is called, or handed to code that may call it, as " ..
        "the module loads, and" .. through .. " it reads " .. what .. " (line " ..
        tostring(Lexer.y(ctx.tokens, read.first)) .. ") before the statement that defines it has run",
      "move the statement " .. statement .. " above this use of " .. spelled .. ", or use " ..
        spelled .. " in a function that runs after the module has loaded")
  end)
  -- The locals each function reads from outside, and those an assignment may change after the function is made, from the
  -- captures the scope builder found.
  for _, v in ipairs(ctx.scoped.list) do
    for _, c in ipairs(v.captures) do
      local reads = ctx.reads[c.fn]
      if reads == nil then
        reads = {}
        ctx.reads[c.fn] = reads
      end
      reads[#reads + 1] = v -- checked: view_written
      if c.after then
        local unfixed = ctx.unfixed[c.fn]
        if unfixed == nil then
          unfixed = {}
          ctx.unfixed[c.fn] = unfixed
        end
        unfixed[v.id] = true -- checked: view_written
      end
    end
  end
  for _, top in ipairs(input.chunk.body.stats) do
    if (top.kind == "Function") and #top.path == 2 then
      local binding = assert(top.path[1]).binding
      local entry = binding ~= nil and lowered.entries[binding] or nil -- checked: and_ternary
      local decl = entry ~= nil and entry.decl or nil
      if decl ~= nil then
        local names = ctx.pending[decl] or {}
        if names[assert(top.path[2]).text] ~= true then
          ctx.load.waiting = ctx.load.waiting + 1
        end
        names[assert(top.path[2]).text] = true
        ctx.pending[decl] = names
      end
    end
  end
  -- A statement `M.f = v` of the chunk gives the module's table its field as a function statement does.
  local table_entry: Declarations.Entry? = nil
  if ctx.module_table ~= nil then
    table_entry = lowered.entries[ctx.module_table]
  end
  local table_decl: Decl? = nil
  if table_entry ~= nil then
    table_decl = table_entry.decl
  end
  -- Only a fixed field: a `mut` one may be given first in a block or a function, which no statement of the chunk waits on.
  local fixed: mut {string: boolean} = {}
  local body: Types.Body? = nil
  if table_decl ~= nil then
    body = table_decl.body
  end
  if body ~= nil then
    for _, f in ipairs(body.fields) do
      fixed[f.name] = f.mut ~= true
    end
  end
  for _, top in ipairs(input.chunk.body.stats) do
    if table_decl ~= nil and (top.kind == "Assign") then
      for _, target in ipairs(top.targets) do
        local object: Ast.Exp? = nil
        if (target.kind == "Field") then
          object = target.object
        end
        if object ~= nil and (object.kind == "Name") and object.binding ~= nil and object.binding == ctx.module_table and
            (target.kind == "Field") and fixed[target.name] == true then
          local names = ctx.pending[table_decl] or {}
          if names[target.name] ~= true then
            ctx.load.waiting = ctx.load.waiting + 1
            ctx.given[target.name] = true
          end
          names[target.name] = true
          ctx.pending[table_decl] = names
        end
      end
    end
  end
  ctx.frames[1] = {
    alts = {}, rest = store.string, chunk = true, declared = false, narrows = nil, narrowed_id = 0, narrowed_name = "",
    narrowed_type = nil,
  }
  block(ctx, input.chunk.body)
  Writes.move_stray(ctx)
  -- Source order; errors at one place stay in the order they were found.
  local position: mut {Codes.Error: integer} = {}
  for i, e in ipairs(ctx.errors) do
    position[e] = i
  end
  table.sort(ctx.errors, function(a: Codes.Error, b: Codes.Error): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return position[a] < position[b] -- checked: nil_not_allowed
  end)
  local narrowed: mut {Check.Narrowed} = {}
  for _, n in pairs(ctx.narrowed) do
    narrowed[#narrowed + 1] = n
  end
  table.sort(narrowed, function(a: Check.Narrowed, b: Check.Narrowed): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return a.id < b.id
  end)
  local warnings = ctx.warnings
  for _, w in ipairs(Warnings.usage(ctx.filename, ctx.tokens, ctx.scoped, ctx.vars, function(t: Type): string
    return Types.display(t, {})
  end)) do
    warnings[#warnings + 1] = w -- checked: view_written
  end
  table.sort(warnings, function(a: Warnings.Warning, b: Warnings.Warning): boolean -- checked: overload_none -- untyped: call
    return a.offset < b.offset
  end)
  local boundaries: mut {Check.Boundary} = {}
  for _, b in pairs(ctx.boundaries) do
    boundaries[#boundaries + 1] = b
  end
  table.sort(boundaries, function(a: Check.Boundary, b: Check.Boundary): boolean
    if a.at ~= b.at then
      return a.at < b.at
    end
    if a.id ~= b.id then
      return a.id < b.id
    end
    return a.param < b.param
  end)
  return {
    errors = ctx.errors, vars = ctx.vars, literals = ctx.literals, spreads = ctx.spreads, tags = ctx.tags, narrowed = narrowed, boundaries = boundaries,
    types = ctx.types, callees = ctx.callees, warnings = warnings,
  }
end

return Check
