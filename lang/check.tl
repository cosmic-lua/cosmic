--- The new checker's expressions and flow ([`doc/plans/new-checker-types.md`], "checking" and "errors"): every
--- expression and statement of a module's bodies typed against the declarations [`lang.declarations`] lowered,
--- by the relation of [`lang.relation`], under the facts [`lang.flow`] holds.
---
--- [`Check.check`] walks a lowered module in source order. An expression is inferred ([`expr`]), with the type
--- the position expects where it has one, which only a literal uses: a table, a function, a string for an enum,
--- a boolean for `true`. What is inferred is then required to be below what the position wants, and where it is
--- not the error names the rule, the place and the change that fixes it ([`lang.check_codes`]).
---
--- **What it checks.** Literals, names, fields, indexes, operators and concatenation; calls, with the first-match rule
--- of overloads; table literals against the expected type (records included); assignments, writes to fields (fixed
--- unless `mut`) and indexes (views are never written, and an array grows by an append); returns against the declared
--- list; conditions (booleans or optionals) and the honest `or` and `and`; numeric keys, views and `mut` collections,
--- records and maps; `match` over a call that answers one of several lists of values.
---
--- **Generic calls.** A call of a generic function, an overload among them, instantiates it: each type parameter is
--- solved from the receiver and the arguments, then from the type the call is expected to answer ([`lang.generics`]),
--- and met against its bound, and the instance is applied as any function is. `pcall`, `xpcall`, `ipairs`, `assert`,
--- `table.insert` and the typed `Coroutine<Y, R, S>` are declarations of this ([`lang/stdlib.d.tl`]); a generic
--- function is a value of the function types its parameters can be taken from ([`lang.relation`]).
---
--- **`match`.** The arms cover the lists the call answers exactly: `true` and `false` select the lists that have the
--- value at their position, a name takes the union of what the lists it selects have there, a list no arm takes is
--- `match_missing`, an arm that takes no list `match_redundant`, and a pattern that tests a position the lists do not give
--- as `true` or `false`, or names another number of values, `match_pattern`.
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
--- is in reach (`class_scope`). A `<close>` local holds nil or a class that declares `__close`
--- (`close_not_closable`).
---
--- **Flow.** The walk keeps what is known at the point it has reached ([`lang.flow`]): a place a test narrowed, a local
--- not yet assigned, and whether control reaches the point. A place is a local, or a path of fixed fields (not `mut`) of
--- a record, class or interface from one; it is narrowed by `x ~= nil`, `x == nil` and the truthiness of an optional,
--- `v is T`, `type(v) == "..."`, a tag compared with a literal (`v.kind == "a"`), a call of a function declared `v is T`,
--- `not`, `and` and `or` of these, `assert(c)` and a call of a function declared `asserts v is T`, and by a branch
--- that ends its block (`return`, `break`, `continue`, a call of a function declared `never`). `if` and `match` meet
--- the ends of their arms; a loop is walked to a fixed point, its head being where the entry and the back edge meet.
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
local Generics = require("lang.generics")
local Lexer = require("lang.lexer")
local Literals = require("lang.literals")
local LoadOrder = require("lang.load_order")
local Relation = require("lang.relation")
local Scopes = require("lang.scopes")
local Types = require("lang.types")
local Warnings = require("lang.warnings")

local type Type = Types.Type
local type Named = Types.Named
local type Fn = Types.Fn
local type Union = Types.Union
local type Alt = Types.Alt
local type Decl = Types.Decl
local type Store = Types.Store
local type Code = Codes.Code

local record Check
  type Error = Codes.Error
  type Argument = Codes.Argument

  --
  -- TODO: record in [`Narrowed`] the facts it leaves out, and have [`lang.fact_wraps`] pass them: a number that a test took
  -- to be an integer or a float ([`Tests.lua_kind`] maps both to `"number"`), a `thread` (`LUA_KINDS` has none), an enum or
  -- a string that an `==` test narrowed (no read is wrapped), and `true` against `false` of a boolean. A run misses a
  -- false conclusion of these and refuses nothing valid. Once a full `cosmic test --check-types` run (CI's `checked-narrowing`
  -- job) has a time to compare, so that the cost of a call per read of each decides which are worth it.
  --- A read of a local, or of a path of fixed fields from one, whose type a test narrowed. The checker took the value
  --- to have none of the kinds of Lua value in `taken`, and the values of the enums, classes and tags the other fields
  --- name, which a run can check at the read.
  record Narrowed
    --- The id of the node of the read, and where the place is read: the offset of its first token, and its length in bytes.
    id: integer
    offset: integer
    length: integer
    --- The place as the program writes it.
    text: string
    --- The kinds of value (`nil`, `number`, `string`, `boolean`, `table`, `function`, `userdata`) the read has none of.
    taken: {string}
    --- Where the read is of an enum: the strings a string there is one of. Nil where the type says no more of a string.
    strings: {string}?
    --- Where the read is of classes: their names, a table there has the metatable of one. Nil where it says no more.
    classes: {string}?
    --- Where the read is of members of a union that a field with values of its own in each tells apart: the field, and
    --- the values of the members the read is of (all of a member's, where its enum has several).
    tag: string?
    tags: {string}?
  end

  enum Role
    "parameter"
  end

  --- A value that crosses a typed boundary of the program, for a run that checks it at the boundary
  --- ([`lang.boundary_checks`]). Only parameters are listed so far: `id` is the id of the node of the function (its [`Fn`],
  --- or the `Method` of a class), and a function with several checked parameters has a row for each, by `param`.
  record Boundary
    id: integer
    role: Role
    --- The name of the parameter, and its position among the function's parameters, from 1.
    name: string
    param: integer
    --- The function as the program calls it (`f`, `R.m`, `C.m`, or `function` for one with no name).
    owner: string
    --- The type the program declares there, and whether the parameter is optional (`name?: T`), which admits nil as well. It
    --- is turned into the kinds of Lua value only where a run checks it ([`lang.boundaries`]'s `kinds`).
    type: Type
    optional: boolean
    --- The offset of the first token of the function.
    at: integer
  end

  --- What checking a module answers.
  record Checked
    --- The errors, in source order.
    errors: {Codes.Error}
    --- The type of each local, parameter and loop variable that was given one, by [`Scopes.Var.id`].
    vars: {integer: Type}
    --- The class of each table literal that makes a value of a class, by the id of its node: what the code
    --- generator writes as the class literal, a class of this module.
    literals: {integer: Decl}
    --- The reads of a place whose type a test narrowed, in source order: what the checker concluded, for a run
    --- that checks it ([`Check.Narrowed`]).
    narrowed: {Narrowed}
    --- The typed boundaries the program declares, in source order ([`Check.Boundary`]): the parameters of every function
    --- whose body was checked, bar the variadic one, a `self`, one whose type is `any`, and one with no type written (a function
    --- literal that takes its parameters' types from where it is passed).
    boundaries: {Boundary}
    --- The type of each expression that was typed, by the id of its node (empty where the check was asked not to keep them,
    --- `typed` false; kept by default): the type report the readers of the build take ([`build.driver`]). A name, a
    --- literal, a call (the first value of the first list it answers), an operator and each link of a chain has one, as the
    --- checker left it after the narrowing there; the callee of a call of an overloaded function has the overload taken. These
    --- have none: the target of an assignment, the string of a `require`, the head name of a `function M.f()` statement, a `...`,
    --- a type name (see [`Declarations.Lowered.types`]) and a node the checker did not reach (a body it skipped).
    types: {integer: Type}
    --- The function each call and method call took, by the id of the call node (empty where `typed` is false): the type of
    --- the callee for a call of one function, the overload taken (instantiated, for a generic one) for a call of several.
    --- A method call has no node for its callee, so this is the only place its function type is kept
    --- ([`build.syntax_contracts`] reads whether a method answers a reason). A call whose callee is no function has none.
    callees: {integer: Type}
    --- The warnings ([`lang.warnings`]), in source order: the unused and unread names, and the `hint` ones.
    warnings: {Warnings.Warning}
  end

  --- Checks `input`, which `program` has lowered into `lowered` ([`Declarations.Program.lower`]), and answers
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

  --- What the fix of a value that is none of the arms of a recursive alias adds, by the alias (`<module> <name>`): the library's
  --- own advice for the type it declares, in words that name its functions.
  advice: {string: string}
end

Check.codes = Codes.codes
Check.catalog = Codes.catalog
Check.advice = {
  ["cosmic.json Json.Value empty"] = "write an empty array as `Json.array()`, which encodes as `[]`, and an empty object as a typed " ..
    "local (`local none: {string: Json.Value} = {}`): an unmarked empty table encodes as `{}`",
  ["cosmic.json Json.Value"] = "for a record or a class of your own, or a value you decoded, call `Json.encode_any`, which takes any value",
}

-- State ----------------------------------------------------------------------------------

--- The members called one name in a declaration, in the order they are declared.
local record Member
  type: Type
  mut: boolean
  method: boolean
end

--- A declaration's members by name, and its array part.
local record Members
  --- The functions of the declaration used as a value that take a value of the declaration first, by name: the shape of a
  --- method, whether or not a value of the declaration can reach it.
  selfish: mut {string: boolean}
  by_name: mut {string: {Member}}
  array: Type?
end

--- What a numeric loop `for i = 1, #t do` whose body leaves the length of `t` alone knows: `i` is a key `t` has for as long
--- as the body runs, so a non-nil value written at it overwrites a slot and leaves no hole ([`Writes.leaves_no_hole`]).
local record Fill
  --- The id of the binding of `i`.
  var: integer
  --- The local `t`, as the loop writes it.
  object: Ast.Exp
end

--- A loop being walked: where its `break`s and `continue`s leave from.
local record Loop
  --- The states at the `break`s, met: nil where none.
  breaks: Flow.State?
  --- The states at the `continue`s, met.
  continues: Flow.State?
  --- What the loop knows of the keys it counts, where it counts the keys of an array.
  fill: Fill?
end

--- A call that tests a value: the argument it narrows, and the type it takes it to ([`Types.Narrows`]).
local record Guarded
  arg: Ast.Exp
  to: Type
end

--- The edges of an `and` or an `or`: the state after it, and the states where it is true and false.
local record Edges
  post: Flow.State
  yes: Flow.State
  no: Flow.State
end

--- A function being checked.
local record Frame
  --- What it may return: a set of lists. Empty, it never returns.
  alts: {Alt}
  --- The narrowing declaration it makes good, the id of the parameter it names and the type that parameter was
  --- declared with, or nil.
  narrows: Types.Narrows?
  narrowed_id: integer
  narrowed_name: string
  narrowed_type: Type?
  --- The type of each value `...` stands for, or nil where it has no rest parameter.
  rest: Type?
  --- Whether it is the module's own chunk, whose `return` is what `require` answers.
  chunk: boolean
  --- Whether the return list was written, for the message.
  declared: boolean
end

--- What one `check` holds.
local record Ctx
  program: Declarations.Program
  store: Store
  judge: Relation.Judge
  input: Declarations.Input
  lowered: Declarations.Lowered
  scoped: Scopes.Scoped
  tokens: Lexer.Tokens
  filename: string
  errors: mut {Codes.Error}
  vars: mut {integer: Type}
  frames: mut {Frame}
  --- The names of the type parameters of the binders in scope, outermost first, for display, and their bounds.
  binders: mut {{string}}
  bounds: mut {{Types.TParam}}
  --- How many generic-call arguments are being checked: a literal there has no type to be checked against.
  mut lenient: integer
  members: {Decl: Members}
  --- The same for a declaration used as a value, which also has its statics.
  value_members: {Decl: Members}
  --- The `function R.m(...)` statements at the top of the module that the walk has not passed, by declaration and name.
  pending: mut {Decl: {string: boolean}}
  --- What the functions read of those statics, for the functions the module runs as it loads ([`lang.load_order`]).
  mut load: LoadOrder.State
  --- The id of the function being walked, 0 in the chunk.
  mut within: integer
  --- The class each table literal of a class is a literal of, by the id of its node.
  literals: mut {integer: Decl}
  --- The classes whose declaration the walk has passed: a literal or a test of a class before that reads a name that
  --- is not yet its table.
  declared: mut {Decl: boolean}
  --- The type of a field read through a union, by the union and the field.
  union_fields: mut {string: Type}
  --- The field reads that only ask whether a method is there (`a.cb ~= nil`, `if a.cb then`): nothing of the method
  --- escapes through them, so they are no use of it as a value.
  probes: mut {integer: boolean}
  --- The nodes a left-leaning chain visits, and how many are in use.
  spine: mut {Ast.Exp}
  mut top: integer
  --- The overloads the callee last found, and the node that found them.
  mut cands: {Type}?
  mut cand_node: Ast.Node?
  --- The `or` that has an `and` for its left operand, by the id of the `and`.
  ternaries: mut {integer: Ast.Binary}
  --- The offsets of the names the scope builder reported unknown, once asked for.
  mut unknown: {integer: boolean}?
  invalid: Type
  nil_type: Type
  --- What is known at the point the walk has reached ([`lang.flow`]), and how many passes of a loop that is
  --- settling are open: they report nothing and skip the bodies of functions, since the pass that follows reports.
  mut flow: Flow.State
  --- The locals of the code around the function being walked that an assignment may change after the function is made:
  --- no place inside it, for a test there narrows only a local that is fixed from then on.
  mut unfixed_now: {integer: boolean}
  --- The locals the assignment being checked assigns, whose function literals name them while they are unset.
  mut assigning: {integer: boolean}
  mut quiet: integer
  --- The module that declares the callee of the call being dispatched, "" where the walk does not know it.
  mut callee_module: string
  --- The module of the declaration the last member read took its member from, "" where it had none.
  mut member_module: string
  --- The expression that read it.
  mut member_node: Ast.Node?
  --- The call argument being checked: [`report`] gives it to the error it files.
  mut argument: Codes.Argument?
  --- The loops being walked, innermost last.
  mut loops: mut {Loop}
  --- The key of each local's place, by id.
  keys: mut {integer: string}
  --- The edges of the `and`s and `or`s evaluated, by the id of the node.
  edges: mut {integer: Edges}
  --- The calls that narrow an argument, by the id of the node.
  guards: mut {integer: Guarded}
  --- By the id of a function: the locals it reads from outside (named where it is made), and those an assignment may
  --- change after it is made ([`Scopes.Capture.after`]), which no fact of the code around it holds inside it.
  reads: mut {integer: {Scopes.Var}}
  unfixed: mut {integer: {integer: boolean}}
  --- The reads of narrowed places, by the offset of the place.
  narrowed: mut {integer: Check.Narrowed}
  --- The parameters of the functions checked, by the id of the binding of the parameter.
  boundaries: mut {integer: Check.Boundary}
  --- The type of each expression typed, by the id of its node, and the warnings found.
  types: mut {integer: Type}
  --- The function each call took, by the id of the call node ([`Check.Checked.callees`]).
  callees: mut {integer: Type}
  --- The text of each local that is given a string literal and never assigned, by id: what a literal pattern or format
  --- held in a local says.
  consts: mut {integer: string}
  --- The name of the function of the string library each local that is given one and never assigned holds, by id.
  library: mut {integer: string}
  --- Whether the type of each node is kept in `types`.
  typed: boolean
  --- The field read last in a chain and the type of the value it was read from, for the hint of a method called with `.`.
  mut field_node: Ast.Node?
  mut field_base: Type?
  warnings: {Warnings.Warning}
  mut unite: function(Type, Type): Type
  mut covers: function(Type, Type): boolean
  --- What [`lang.generics`] reads types through, made when a generic call first needs it.
  mut hooks: Generics.Hooks?
end

-- Helpers ------------------------------------------------------------------------------------

local function base_of(node: Ast.Node): Ast.Base
  return node
end

local function quoted(s: string): string
  return "`" .. s .. "`"
end

local function show(ctx: Ctx, t: Type): string
  return Types.display(t, ctx.binders)
end

local function tq(ctx: Ctx, t: Type): string
  return quoted(show(ctx, t))
end

--- The text of the tokens of `node`, cut at a length a message can hold.
local function text_of(ctx: Ctx, node: Ast.Node): string
  local b = base_of(node)
  local tokens = ctx.tokens
  local last = math.min(b.last, b.first + 24)
  local parts: mut {string} = {}
  for i = b.first, last do
    if i > b.first and Lexer.offset(tokens, i) > Lexer.stop(tokens, i - 1) then
      parts[#parts + 1] = " "
    end
    parts[#parts + 1] = Lexer.text(tokens, i)
  end
  local text = table.concat(parts)
  if last < b.last or #text > 60 then
    text = text:sub(1, 57) .. "..."
  end
  return text
end

local function subject(ctx: Ctx, node: Ast.Node): string
  return quoted(text_of(ctx, node))
end

local function peel(e: Ast.Node): Ast.Node
  local at = e
  while (at.kind == "Paren") do
    at = at.inner
  end
  return at
end

--- The key of the place of the local `id`.
local function id_key(ctx: Ctx, id: integer): string
  local key = ctx.keys[id]
  if key == nil then
    key = tostring(id)
    ctx.keys[id] = key
  end
  return key
end

--- The key of the place a name or a chain of fields from a name is, whatever the facts hold of it: a local's id, then
--- `.` and each field. Nil for any other expression.
local function path_key(ctx: Ctx, e: Ast.Exp): string?
  local at = peel(e)
  if (at.kind == "Name") then
    local id = at.binding
    return id ~= nil and id_key(ctx, id) or nil
  elseif (at.kind == "Field") then
    local base = path_key(ctx, at.object)
    return if base ~= nil then base .. "." .. at.name else nil end
  end
  return nil
end

--- Where an assignment dropped the fact the place of `node` had, or nil.
local function dropped_by(ctx: Ctx, node: Ast.Node): Scopes.Place?
  if next(ctx.flow.gone) == nil then
    return nil
  end
  local at = peel(node)
  if (at.kind == "Name") or (at.kind == "Field") then
    local key = path_key(ctx, at)
    return key ~= nil and ctx.flow.gone[key] or nil
  end
  return nil
end

--- Reports `code` on the tokens of `node`. A value that may be nil because an assignment dropped what a test had
--- shown is told that (`narrowing_dropped`), with the assignment as the second place.
local function report(ctx: Ctx, code: Code, node: Ast.Node, msg: string, fix: string, shown?: {string},
                      other?: Scopes.Place)
  if ctx.quiet > 0 then
    return
  end
  local b = base_of(node)
  local tokens = ctx.tokens
  local first, last = b.first, math.max(b.first, b.last)
  local why = code == "nil_not_allowed" and dropped_by(ctx, node) or nil
  if why ~= nil then
    code = "narrowing_dropped"
    other = why
    local at = why.y .. ":" .. why.x
    local name = text_of(ctx, node)
    msg = msg .. " (a test showed it was not nil, and the assignment at " .. at .. " dropped that)"
    fix = "test " .. quoted(name) .. " again after the assignment at " .. at .. " (`if " .. name ..
      " == nil then return nil, why end`), or read the value into a new local that nothing assigns (`local v = " ..
      name .. "`) and test that"
  end
  ctx.errors[#ctx.errors + 1] = {
    filename = ctx.filename, code = code, msg = msg, fix = fix, y = Lexer.y(tokens, first), x = Lexer.x(tokens, first),
    offset = Lexer.offset(tokens, first), length = math.max(0, Lexer.stop(tokens, last) - Lexer.offset(tokens, first)),
    other = other, types = shown or {}, argument = ctx.argument,
  }
end

--- Whether `t` is `nil` or has the nil flag.
local function nilable(t: Type): boolean
  return t.tag == "nil" or ((t.tag == "union") and t.nilable)
end

local function is_bool(t: Type): boolean
  local tag = t.tag
  return tag == "boolean" or tag == "true" or tag == "false"
end

local function is_text(t: Type): boolean
  return t.tag == "string" or ((t.tag == "named") and t.decl.kind == "enum")
end

local function is_enum(t: Type): boolean
  return (t.tag == "named") and t.decl.kind == "enum"
end

--- `t` as a reader of the collection it is through sees it: a `mut` collection in it is a view, through arrays,
--- maps and unions and not through a named type.
local function view(store: Store, t: Type): Type
  if not t.has_mut then
    return t
  elseif (t.tag == "array") then
    return store:array(view(store, t.element), false)
  elseif (t.tag == "map") then
    return store:map(t.key, view(store, t.value), false)
  elseif (t.tag == "union") then
    local members: mut {Type} = {}
    for i, m in ipairs(t.members) do
      members[i] = view(store, m)
    end
    if t.nilable then
      members[#members + 1] = store:atom("nil")
    end
    return store:union(members)
  end
  return t
end

--- The members of a union (the nil flag as `nil`), or the type alone. A recursive alias is read as the type it
--- names, one level: its members stand for it, a member of a union that is one as well, so a test or a literal sees
--- the forms a value of it is. What a member of that holds (`{Json.Value}`) is left as it is.
local function members_of(store: Store, t: Type): {Type}
  local out: mut {Type} = {}
  local function add(m: Type)
    if (m.tag == "union") then
      for _, inner in ipairs(m.members) do
        out[#out + 1] = inner
      end
      if m.nilable then
        out[#out + 1] = store:atom("nil")
      end
    else
      out[#out + 1] = m
    end
  end
  local whole = Types.unfold(t)
  if (whole.tag == "union") then
    for _, m in ipairs(whole.members) do
      add(Types.unfold(m))
    end
    if whole.nilable then
      out[#out + 1] = store:atom("nil")
    end
  else
    add(whole)
  end
  return out
end

--- Whether `t` is an enum, or a union with one.
local function has_enum(ctx: Ctx, t: Type): boolean
  for _, m in ipairs(members_of(ctx.store, t)) do
    if is_enum(m) then
      return true
    end
  end
  return false
end

--- Whether `a` is below `b`, as the program's judge says.
local function below(ctx: Ctx, a: Type, b: Type): boolean
  if a == b or a.tag == "invalid" or b.tag == "invalid" or a.tag == "never" then
    return true
  end
  return ctx.judge:subtype(a, b)
end

--- Whether `a` may be passed to a parameter of type `b`.
local function accepts(ctx: Ctx, a: Type, b: Type): boolean
  return b.tag == "any" or below(ctx, a, b)
end

--- The type every type of `list` is below, or nil where there is none. A `nil` in the list makes the answer
--- optional; `never` is ignored; an empty list is `never`.
local function join(ctx: Ctx, list: {Type}): Type?
  local store = ctx.store
  local best: Type? = nil
  local saw_nil = false
  for _, t in ipairs(list) do
    if t.tag == "nil" then
      saw_nil = true
    elseif t.tag ~= "never" then
      local held = best
      if held == nil or t.tag == "invalid" then
        best = t
      elseif t ~= held and held.tag ~= "invalid" then
        if below(ctx, held, t) then
          best = t
        end
      end
    end
  end
  if best == nil then
    return saw_nil and ctx.nil_type or store.never
  end
  for _, t in ipairs(list) do
    if t.tag ~= "nil" and t.tag ~= "never" and not below(ctx, t, best) then
      return nil
    end
  end
  return saw_nil and store:optional(best) or best
end

--- A text for the list of `items` joined by ", " and a last `joiner` ("or" by default).
local function listed(items: {string}, joiner?: string): string
  if #items <= 1 then
    return items[1] or ""
  end
  local head: mut {string} = {}
  for i = 1, #items - 1 do
    head[i] = items[i]
  end
  return table.concat(head, ", ") .. " " .. (joiner or "or") .. " " .. items[#items]
end

--- The name of `names` nearest to `name`, within an edit or two, or "".
local function nearest(name: string, names: {string}): string
  --- How far apart two names are, up to `limit`: `limit + 1` for more.
  local function distance(a: string, b: string, limit: integer): integer
    local la, lb = #a, #b
    if la - lb > limit or lb - la > limit then
      return limit + 1
    end
    local previous: mut {integer} = {}
    for j = 0, lb do
      previous[j] = j
    end
    for i = 1, la do
      local row: mut {integer} = { [0] = i }
      local least = i
      for j = 1, lb do
        local cost = if a:byte(i) == b:byte(j) then 0 else 1 end
        local best = math.min(previous[j - 1] + cost, previous[j] + 1, row[j - 1] + 1)
        row[j] = best
        least = math.min(least, best)
      end
      if least > limit then
        return limit + 1
      end
      previous = row
    end
    return previous[lb]
  end
  local limit = if #name <= 2 then 0 elseif #name <= 5 then 1 else 2 end
  local best, found = limit + 1, ""
  for _, other in ipairs(names) do
    if other ~= name then
      local d = distance(name, other, limit)
      if d < best or (d == best and found ~= "" and other < found) then
        best, found = d, other
      end
    end
  end
  return found
end

local expr: function(ctx: Ctx, e: Ast.Exp, expected: Type?): Type

-- Members --------------------------------------------------------------------------------

--- Whether the function type `given`, or the function it is when optional, takes a value of the declaration `decl` first: the
--- shape of a method of it. An optional method (`cb?: function(P): string`) is the function or nil: the receiver is the
--- function's.
local function takes_receiver(ctx: Ctx, decl: Decl, given: Type): boolean
  local ft = ctx.store:non_nil(given)
  if not ((ft.tag == "fn")) then
    return false
  end
  local first = ft.params[1]
  local receiver: Type? = nil
  if first ~= nil then
    receiver = first.type
  end
  return receiver ~= nil and (receiver.tag == "named") and receiver.decl == decl
end

--- The members of `decl` by name, or nil where it has no body to read. Where `value` they are those of the
--- declaration used as a value: the statics its `function R.m(...)` statements gave it besides, and no array part. The
--- table of a class holds its methods and statics and none of the fields of its values, so a class's value has no
--- field. A record's value keeps the fields it declares, since a module record declares its functions and constants
--- as fields.
local function members_index(ctx: Ctx, decl: Decl, value: boolean): Members?
  local cache = value and ctx.value_members or ctx.members
  local held = cache[decl]
  if held ~= nil then
    return held
  end
  local body = decl.body
  if body == nil then
    return nil
  end
  local index: Members = { by_name = {}, array = not value and body.array or nil, selfish = {} }
  local absent = ctx.program.absent[decl] or {}
  for _, f in ipairs(body.fields) do
    -- A function field that every value holds and no statement gives the table of the functions is not in that table.
    if not (value and (decl.kind == "class" or absent[f.name] == true)) then
      local list = index.by_name[f.name] or {}
      list[#list + 1] = { type = f.type, mut = f.mut or false, method = false }
      index.by_name[f.name] = list
    end
  end
  for _, m in ipairs(body.methods) do
    local list = index.by_name[m.name] or {}
    list[#list + 1] = { type = m.type, mut = false, method = true }
    index.by_name[m.name] = list
  end
  if not value then
    -- An interface that lists another has the fields it leaves out from it (a record or class declares every one).
    for _, f in ipairs(Declarations.inherited(ctx.store, ctx.judge, decl)) do
      index.by_name[f.name] = { { type = f.type, mut = f.mut == true, method = false } }
    end
  end
  if value then
    for name, f in pairs(ctx.program.statics[decl] or {}) do
      local list = index.by_name[name] or {}
      list[#list + 1] = { type = f.type, mut = false, method = false }
      index.by_name[name] = list
    end
  else
    -- A function that takes a value of the declaration first (`function R.m(self: R, ...)`) has the shape of a method. The
    -- table of a class is the metatable of its values, so `v:m(...)` reaches it at run time, as it reaches the methods
    -- inside the class. A record's value has no metatable and holds no such function: the name is listed in `selfish` for
    -- [`field_unknown`] to say so. The name cannot be one of the declaration's own: a class holds its members in one
    -- namespace, and a record's function statement for a field it declares is not a static.
    --
    -- TODO: make the function of a generic class that takes a value of it first (`function Box.size<T>(self: Box<T>)`)
    -- a method of its values, once a call can bind the function's own type parameters to the arguments of the value it is
    -- called on: it is left out today, since `Box<T>` there is not the class's `T`.
    --
    -- TODO: make the function of a record that takes a value of it first a method of its values, once the code generator
    -- reads the checker's types and writes `v:m(...)` of such a function as the call `R.m(v, ...)`: a record's value holds
    -- only its fields, so the method call finds no function at run time, and today it is refused.
    for name, f in pairs(ctx.program.statics[decl] or {}) do
      if takes_receiver(ctx, decl, f.type) then
        index.selfish[name] = true
        if decl.kind == "class" and (decl.arity or 0) == 0 then
          index.by_name[name] = { { type = f.type, mut = false, method = true } }
        end
      end
    end
  end
  cache[decl] = index
  return index
end

--- `t`, a type written in the declaration of `n`, with the type arguments of `n` put in.
local function put_in(ctx: Ctx, n: Named, t: Type): Type
  if #n.args == 0 or t.open == 0 then
    return t
  end
  local made = Relation.instantiate(ctx.store, t, n.args)
  if made == nil then
    return ctx.invalid
  end
  return made
end

--- The names of the members of `n`, for the nearest to a name that is none.
local function names_of(ctx: Ctx, n: Named): {string}
  local out: mut {string} = {}
  local index = members_index(ctx, n.decl, n.value)
  if index ~= nil then
    for name in pairs(index.by_name) do
      out[#out + 1] = name
    end
    table.sort(out)
  end
  return out
end

--- What a program writes for a declaration kind.
local KIND_WORDS <const>: {Types.DeclKind: string} = {
  record = "record", class = "class", interface = "interface", enum = "enum", userdata = "userdata record",
}

-- Refusals -----------------------------------------------------------------------------------

--- The fix for a value that may be nil.
local function nil_fix(ctx: Ctx, node: Ast.Node): string
  local e = peel(node)
  if (e.kind == "Call") or (e.kind == "MethodCall") then
    local call = subject(ctx, e)
    return "take the value with `local v = assert(" .. text_of(ctx, e) .. ")`, or test it first (`if v == nil then " ..
      "return nil, why end`); " .. call .. " answers nil when it fails"
  end
  local s = text_of(ctx, e)
  if (e.kind == "Field") then
    return "copy " .. quoted(s) .. " to a local and test that: `local v = " .. s .. " if v ~= nil then ... end`, or " ..
      "take it with `assert(" .. s .. ")`"
  end
  return "test it first (`if " .. s .. " == nil then return nil, why end`), or take it with `assert(" .. s .. ")`"
end

--- Whether the type `t` names `invalid` anywhere.
local function names_invalid(t: Type): boolean
  if t.tag == "invalid" then
    return true
  end
  for _, part in ipairs(Types.parts(t)) do
    if names_invalid(part) then
      return true
    end
  end
  return false
end

--- Reports that the value of `node`, of type `got`, is not below `want`, and `r` says why. `where` is a phrase that
--- says what wants it, with a space before it, or "". `named` is how to write `want` where the program spells it
--- otherwise than the type is (a parameter of a generic function that a failed inference made `invalid`).
local function refused(ctx: Ctx, node: Ast.Node, got: Type, want: Type, r: Relation.Refusal, where: string, named?: string)
  local s = subject(ctx, node)
  local g, w = show(ctx, got), named or show(ctx, want)
  local shown = { g, w }
  local code = r.code
  local from, into = r.sub, r.super
  if code ~= "declaration_value" then
    -- A module held in what is given (the `Box<Queue>` of `Bx.of(Queues)`, the `Queue` of an argument beside a `{Queue}`)
    -- where a value of its declaration is wanted, whatever the place around it (`Queue?`, a generic, an optional field).
    -- The module in `t` where `decl` is nil, else the type of values of `decl`.
    local function find(t: Type, decl: Decl?): Type?
      if (t.tag == "named") then
        if decl == nil and t.value and (t.decl.kind == "record" or t.decl.kind == "class") then
          return t
        elseif decl ~= nil and not t.value and t.decl == decl then
          return t
        end
      end
      for _, part in ipairs(Types.parts(t)) do
        local found = find(part, decl)
        if found ~= nil then
          return found
        end
      end
      return nil
    end
    local held = find(got, nil)
    if held ~= nil and (held.tag == "named") then
      local wanted = find(want, held.decl)
      if wanted ~= nil then
        code, from, into = "declaration_value", held, wanted
      end
    end
  end
  local e = peel(node)
  if code == "nil" then
    if got.tag == "nil" then
      report(ctx, "nil_not_allowed", node, "nil is given" .. where .. ", where " .. quoted(w) .. " is wanted",
        "give a value, or declare what takes it `" .. w .. "?` (a parameter or field `name?: T`)", shown)
    elseif (e.kind == "Index") then
      local xs = e.object
      report(ctx, "index_may_be_nil", node, s .. " is " .. quoted(g) .. " (an index read may be nil), where " ..
          quoted(w) .. " is wanted" .. where,
        "read it into a local and test it (`local v = " .. text_of(ctx, e) .. " if v ~= nil then ... end`), or iterate " ..
          "with `for _, v in ipairs(" .. text_of(ctx, xs) .. ")`", shown)
    else
      report(ctx, "nil_not_allowed", node, s .. " is " .. quoted(g) .. ", so it may be nil, where " .. quoted(w) ..
          " is wanted" .. where, nil_fix(ctx, node), shown)
    end
  elseif code == "view_as_mut" then
    -- A view where a `mut` collection of a parameter that nothing else solved is wanted taints it: the collection
    -- wanted is the view, made `mut`.
    local super = Types.display(r.super, ctx.binders)
    local made = w
    if names_invalid(r.super) and g:sub(1, 1) == "{" then
      made = "mut " .. g
      super = made
    end
    report(ctx, "view_as_mut", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        ": the view " .. quoted(Types.display(r.sub, ctx.binders)) .. " is not " .. quoted(super) ..
        ", which the receiver may change",
      "declare " .. s .. " `" .. made .. "` where it is made or received, or pass a collection made `mut`", shown)
  elseif code == "invariant_mut" or code == "invariant_key" then
    report(ctx, "invariant_mut", node, quoted(Types.display(r.sub, ctx.binders)) .. " is not " ..
        quoted(Types.display(r.super, ctx.binders)) .. " (" .. s .. " is " .. quoted(g) .. ", where " .. quoted(w) ..
        " is wanted" .. where .. "): a receiver could store another element type through a `mut` collection",
      "pass a view, or declare the receiver's type " .. quoted(g) .. " as the argument has it", shown)
  elseif code == "declaration_value" then
    local decl: Decl? = nil
    if from.tag == "named" then
      decl = from.decl
    elseif into.tag == "named" then
      decl = into.decl
    end
    local name, kind = g, "record"
    if decl ~= nil then
      name, kind = decl.name, decl.kind
    end
    if kind ~= "class" then
      -- A module is a record used as a value, and the places that hold one (a field `Seatbelt: Seatbelt`, an array
      -- `{Child}`, `local raw: hash = require(...)`) are typed with the record, whose values are not the module.
      -- The fix is the statement that requires it where it is used, unless the declaration is this module's own or
      -- declared in a block of it.
      local fix = "call a function on the module (" .. quoted(name .. ".f(...)") .. ") or pass the function itself, not the module"
      if decl ~= nil and decl.module ~= ctx.input.module and not decl.module:find("@", 1, true) then
        fix = "require the module where you use it (`local " .. decl.name .. " = require(\"" .. decl.module .. "\")`), " ..
          "instead of passing it" .. where
      end
      report(ctx, "declaration_value", node, s .. " is " .. quoted(g) .. ", the table of the functions of " .. quoted(name) ..
          ", where " .. quoted(w) .. " is wanted" .. where, fix, shown)
    elseif (from.tag == "named") and from.value then
      local fix = "make a value with a table literal typed as the type (`local v: " .. name .. " = { ... }`), or call a " ..
        "function of " .. quoted(name) .. " that makes one (`" .. name .. ".new(...)`)"
      if decl ~= nil and decl.module ~= ctx.input.module and not decl.module:find("@", 1, true) then
        -- A class of another module, stored where its values belong: the module is required where it is used.
        fix = "require the module where you use it (`local " .. decl.name .. " = require(\"" .. decl.module .. "\")`), " ..
          "instead of passing it" .. where .. "; to make a value, call a function of " .. quoted(name) ..
          " that makes one (`" .. name .. ".new(...)`)"
      end
      report(ctx, "declaration_value", node, s .. " is " .. quoted(g) .. ", the table of the functions of " .. quoted(name) ..
          ", where a value of " .. quoted(w) .. " is wanted" .. where, fix, shown)
    else
      report(ctx, "declaration_value", node, s .. " is a value of " .. quoted(name) .. ", where the declaration " ..
          quoted(name) .. " itself is wanted" .. where,
        "pass the declaration " .. quoted(name) .. ", not a value of it", shown)
    end
  elseif code == "record_as_map" or code == "map_as_record" then
    report(ctx, "record_as_map", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        ": " .. (if code == "record_as_map" then "a record is not a map" else "a map is not a record" end),
      "pass a value of the declared type, or declare a map `{K: V}` for the data that is keyed", shown)
  elseif code == "any_source" or code == "any_sink" then
    if code == "any_source" then
      report(ctx, "any_use", node, s .. " is untrusted data (`any`), where " .. quoted(w) .. " is wanted" .. where,
        "validate it with a [`cosmic.shape`] validator, or test its tag (`type(" .. text_of(ctx, e) ..
          ") == \"string\"`), and use the checked value", shown)
    else
      report(ctx, "any_use", node, s .. " is " .. quoted(g) .. " and would be stored as untrusted data (`any`)" .. where,
        "declare what holds it with the type it has: `any` takes a value only as an argument to a parameter declared `any`",
        shown)
    end
  else
    local leaf = ""
    if r.sub ~= got or r.super ~= want then
      leaf = " (" .. quoted(Types.display(r.sub, ctx.binders)) .. " is not below " ..
        quoted(Types.display(r.super, ctx.binders)) .. ")"
    end
    local fix = "pass a value of type " .. quoted(w) .. ", or change the declaration to " .. quoted(g)
    local body = Types.unfold(want)
    if body ~= want then
      -- A recursive alias is wanted: its arms are what the program has to choose among.
      local arms: mut {string} = {}
      for _, m in ipairs(members_of(ctx.store, body)) do
        if m.tag ~= "nil" then
          arms[#arms + 1] = quoted(show(ctx, m))
        end
      end
      table.sort(arms)
      leaf = leaf .. "; " .. quoted(w) .. " is " .. listed(arms)
      fix = "make the value one of the arms of " .. quoted(w) .. ": " .. listed(arms) .. ", which " .. quoted(g) .. " is none of"
      if (want.tag == "named") then
        local advised = Check.advice[want.decl.module .. " " .. want.decl.name]
        if advised ~= nil then
          fix = fix .. "; " .. advised
        end
      end
    end
    if code == "number_for_integer" then
      fix = "convert with `math.tointeger(" .. text_of(ctx, e) .. ")` or `math.floor(" .. text_of(ctx, e) ..
        ")`, or declare what takes it `number`"
    elseif code == "not_listed" then
      fix = "list the interface in the declaration of " .. quoted(Types.display(r.sub, ctx.binders)) .. " with `is " ..
        Types.display(r.super, ctx.binders) .. "`: a type conforms to an interface only by listing it"
    elseif code == "may_return" then
      fix = "declare the function `: never` and end it with `error`, or pass a function that returns"
    end
    report(ctx, "not_assignable", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        leaf, fix, shown)
  end
end

--- Whether the value of `node`, of type `got`, may stand where `want` is wanted, reporting it where not.
local function expect(ctx: Ctx, node: Ast.Node, got: Type, want: Type, where: string, named?: string): boolean
  if below(ctx, got, want) then
    return true
  end
  local r = ctx.judge:refuse(got, want)
  if r ~= nil then
    refused(ctx, node, got, want, r, where, named)
  end
  return false
end

--- [`expect`] for a position that accepts any value as `any`: an argument to a parameter declared `any`.
local function expect_argument(ctx: Ctx, node: Ast.Node, got: Type, want: Type, where: string, named?: string): boolean
  if want.tag == "any" then
    return true
  end
  return expect(ctx, node, got, want, where, named)
end

-- Not yet checked ----------------------------------------------------------------------------

--- Reports a form a later piece of the checker types, whose result is `invalid`.
local function unchecked(ctx: Ctx, code: Code, node: Ast.Node, what: string)
  local row = Codes.row(code)
  report(ctx, code, node, what .. ", which the checker types in a later piece: its result is `invalid`, and reported " ..
      "here so that no `invalid` is silent", row ~= nil and row.fix or "none yet")
end

--- Checks the arguments of a call that is not typed, with no type expected of them: a literal there
--- has none to be checked against.
local function unchecked_arguments(ctx: Ctx, args: {Ast.Exp})
  ctx.lenient = ctx.lenient + 1
  for _, a in ipairs(args) do
    local _ = expr(ctx, a, nil)
  end
  ctx.lenient = ctx.lenient - 1
end

--- The lists an expression whose type is unknown answers: any number of `invalid`.
local function unknown_lists(ctx: Ctx): {Alt}
  return { { items = {}, tail = ctx.invalid } }
end

-- Names ------------------------------------------------------------------------------------

--- A declaration used as a value: the table of its functions, a type of its own that is no instance of the
--- declaration ([`Types.Named`]'s `value`). A module stored in a place typed with its record (a field `Seatbelt: Seatbelt`,
--- `Relay.Address = Address`, an array `{Child}`) is [`declaration_value`], and a program requires the module where it uses it
--- instead. A record's value still carries the fields its instances have, so the table of a record with a field it never
--- defines is typed as if it did.
local function declaration_value(ctx: Ctx, decl: Decl): Type
  local args: mut {Type} = {}
  for i = 1, decl.arity or 0 do
    args[i] = ctx.store:var(0, i - 1)
  end
  return ctx.store:named(decl, args, true)
end

--- The value `require("name")` answers: the declaration the module returns.
local function module_value(ctx: Ctx, node: Ast.Node, name: string): Type
  local program = ctx.program
  if program.external[name] then
    unchecked(ctx, "unchecked_binding", node, "the module " .. quoted(name) .. " is a binding of C that has no declarations")
    return ctx.invalid
  end
  local info = program.modules[name]
  local provider = program.provider
  if info == nil and provider ~= nil and provider(program, name) then
    info = program.modules[name]
  end
  if info == nil then
    report(ctx, "require_unknown", node, "the project has no module " .. quoted(name),
      "require a module of the project: `bin/cosmic docs` lists them")
    return ctx.invalid
  end
  local export = info.export
  if export == nil then
    local value = info.value
    if value ~= nil then
      return value
    end
    unchecked(ctx, "unchecked_binding", node, "the module " .. quoted(name) .. " returns no declaration and no value of a written type")
    return ctx.invalid
  end
  local decl = export.decl
  if decl ~= nil and export.instance == true then
    -- The module returns a value of the declaration (`local x: T = ... return x`; a declaration file's record is the
    -- table with its fields), which has none of the functions the declaration's statements gave its table.
    if (decl.arity or 0) == 0 then
      return ctx.store:named(decl, {})
    end
    local value = info.value
    if value ~= nil then
      return value
    end
    unchecked(ctx, "unchecked_binding", node, "the module " .. quoted(name) .. " returns a value of the generic " ..
        quoted(decl.name) .. " whose type arguments the checker has not read")
    return ctx.invalid
  elseif decl ~= nil then
    return declaration_value(ctx, decl)
  end
  local alias = export.alias
  local aliased = alias ~= nil and alias.type or nil
  if aliased == nil then
    return ctx.invalid
  end
  return aliased
end

--- The offsets of the names the scope builder said are unknown.
local function unknown_offsets(ctx: Ctx): {integer: boolean}
  local held = ctx.unknown
  if held ~= nil then
    return held
  end
  local out: mut {integer: boolean} = {}
  for _, e in ipairs(ctx.scoped.errors) do
    out[e.offset] = true
  end
  ctx.unknown = out
  return out
end

--- The type of a global the declaration files declare. The standard library's ([`lang/stdlib.d.tl`]) say that a function that
--- answers nil where Lua does says so (`s:find(p)` is `integer?`), so each use of its result is held to that.
local function global_value(ctx: Ctx, node: Ast.Name): Type
  local program = ctx.program
  local values = program.values[node.text]
  if values ~= nil then
    if #values > 1 then
      ctx.cands = values
      ctx.cand_node = node
    end
    return values[1]
  end
  local entry = program.globals[node.text]
  local decl = entry ~= nil and entry.decl or nil
  if decl ~= nil then
    return declaration_value(ctx, decl)
  end
  if unknown_offsets(ctx)[Lexer.offset(ctx.tokens, base_of(node).first)] then
    return ctx.invalid
  end
  unchecked(ctx, "unchecked_binding", node, "the global " .. quoted(node.text) .. " has no declaration the checker can read")
  return ctx.invalid
end

local function name_value(ctx: Ctx, node: Ast.Name): Type
  local id = node.binding
  if id == nil then
    return global_value(ctx, node)
  end
  local held = ctx.vars[id]
  if held ~= nil then
    return held
  end
  local v = ctx.scoped.vars[id]
  if v == nil then
    return ctx.invalid
  end
  local made = ctx.invalid
  if v.kind == "record" or v.kind == "class" then
    local entry = ctx.lowered.entries[id]
    local decl = entry ~= nil and entry.decl or nil
    if decl ~= nil then
      made = declaration_value(ctx, decl)
    end
  elseif v.kind == "import" then
    made = module_value(ctx, node, v.module)
  end
  -- A type used as a value was reported by the scope builder; a pattern of a `match` by the `match`.
  ctx.vars[id] = made
  return made
end

-- Literals --------------------------------------------------------------------------------

--- A string whose contents are `value`, written as `node`: an enum member where an enum is expected and it is one.
local function string_value(ctx: Ctx, node: Ast.Node, value: string, expected: Type?): Type
  local store = ctx.store
  if expected == nil then
    return store.string
  end
  local enums = 0
  local values: mut {string} = {}
  for _, m in ipairs(members_of(store, expected)) do
    if (m.tag == "named") and m.decl.kind == "enum" then
      enums = enums + 1
      local body = m.decl.body
      local enum_values: {string} = {}
      if body ~= nil then
        enum_values = body.values
      end
      for _, v in ipairs(enum_values) do
        if v == value then
          return m
        end
        values[#values + 1] = v
      end
    end
  end
  if enums == 0 then
    return store.string
  end
  local close = nearest(value, values)
  local shown: mut {string} = {}
  for i, v in ipairs(values) do
    if i > 8 then
      shown[#shown + 1] = "..."
      break
    end
    shown[#shown + 1] = quoted(string.format("%q", v))
  end
  report(ctx, "enum_member", node, quoted(string.format("%q", value)) .. " is not a member of " .. tq(ctx, expected) ..
      (if close ~= "" then ", nearest " .. quoted(string.format("%q", close)) else "" end),
    "write " .. listed(shown), { show(ctx, expected) })
  return ctx.invalid
end

local function string_literal(ctx: Ctx, e: Ast.String, expected: Type?): Type
  return string_value(ctx, e, e.value, expected)
end

--- A boolean literal: `true` or `false` where the position wants that and not `boolean`.
local function boolean_literal(ctx: Ctx, e: Ast.Boolean, expected: Type?): Type
  local store = ctx.store
  if expected ~= nil and not below(ctx, store.boolean, expected) then
    local exact = store:atom(if e.value then "true" else "false" end)
    if below(ctx, exact, expected) then
      return exact
    end
  end
  return store.boolean
end

-- Value lists ----------------------------------------------------------------------------------

--- The values of an expression list.
local record Values
  --- One type for each value, a call or `...` at the end expanded to what it answers.
  types: mut {Type}
  --- Set when the last expression ends in `T...` or is `...`: any number more values of this type.
  mut tail: Type?
  --- Set when the last expression is a call with several lists, which are no values.
  mut lists: {Alt}?
  --- The last expression, when it was expanded.
  mut last: Ast.Exp?
end

local lists_of: function(ctx: Ctx, e: Ast.Exp, expected: Type?): {Alt}

--- The type of `...` in the function being checked, reporting the one that has none.
local function vararg_rest(ctx: Ctx, e: Ast.Node): Type
  local rest = ctx.frames[#ctx.frames].rest
  if rest == nil then
    report(ctx, "vararg_outside", e, "`...` is used in a function that has no rest parameter",
      "declare the rest parameter `...: T`")
    return ctx.invalid
  end
  return rest
end

--- The one value a call answering `alts` gives where a value is wanted.
local function first_value(ctx: Ctx, node: Ast.Node, alts: {Alt}): Type
  if #alts == 0 then
    return ctx.store.never
  elseif #alts > 1 then
    report(ctx, "alternatives_as_value", node, subject(ctx, node) .. " answers one of " .. #alts ..
        " lists of values, which is no value",
      "match the call: `match " .. text_of(ctx, node) .. " do | (true, v) then ... end`")
    return ctx.invalid
  end
  local alt = alts[1]
  local first = alt.items[1]
  if first ~= nil then
    return first
  end
  local tail = alt.tail
  if tail ~= nil then
    return tail.tag == "invalid" and tail or ctx.store:optional(tail)
  end
  report(ctx, "no_value", node, subject(ctx, node) .. " answers nothing, so it has no value here",
    "use the call as a statement, or call a function that answers a value")
  return ctx.invalid
end

--- The types of the expressions of `list`, each checked with the type its position expects (`wants[i]`, else
--- `rest_want`), the last expanded when it is a call or `...`.
local function values_of(ctx: Ctx, list: {Ast.Exp}, wants: {Type}?, rest_want: Type?): Values
  local out: Values = { types = {} }
  local n = #list
  for i, e in ipairs(list) do
    local want = rest_want
    if wants ~= nil and wants[i] ~= nil then
      want = wants[i]
    end
    if i < n then
      out.types[i] = expr(ctx, e, want)
    elseif (e.kind == "Call") or (e.kind == "MethodCall") then
      local alts = lists_of(ctx, e, want)
      out.last = e
      if #alts == 1 then
        for _, item in ipairs(alts[1].items) do
          out.types[#out.types + 1] = item
        end
        out.tail = alts[1].tail
      elseif #alts == 0 then
        out.types[#out.types + 1] = ctx.store.never
      else
        out.lists = alts
      end
    elseif (e.kind == "Vararg") then
      out.last = e
      out.tail = vararg_rest(ctx, e)
    else
      out.types[i] = expr(ctx, e, want)
    end
  end
  return out
end

--- The distinct types of `types` (the first four), quoted and in order, for a message.
local function type_names(ctx: Ctx, types: {Type}): {string}
  local out: mut {string} = {}
  local seen: mut {integer: boolean} = {}
  for _, t in ipairs(types) do
    if not seen[t.id] and #out < 4 then
      seen[t.id] = true
      out[#out + 1] = tq(ctx, t)
    end
  end
  table.sort(out)
  return out
end

-- Table literals ----------------------------------------------------------------------------

--- Checks the values of the items of a literal that has no shape to be checked against, so that what is in them
--- is checked.
local function items_unshaped(ctx: Ctx, items: {Ast.Item})
  ctx.lenient = ctx.lenient + 1
  for _, item in ipairs(items) do
    if (item.kind == "Keyed") then
      local _ = expr(ctx, item.key, nil)
      local _ = expr(ctx, item.value, nil)
    elseif (item.kind == "Named") then
      local _ = expr(ctx, item.value, nil)
    elseif (item.kind == "Positional") then
      local _ = expr(ctx, item.value, nil)
    end
  end
  ctx.lenient = ctx.lenient - 1
end

--- The kinds of item a literal holds: "positional", "named", "keyed", "mixed" or "empty".
local function shape_of(items: {Ast.Item}): string
  local shape = "empty"
  for _, item in ipairs(items) do
    local kind = if (item.kind == "Positional") then "positional" elseif (item.kind == "Named") then "named" else "keyed" end
    if shape == "empty" then
      shape = kind
    elseif shape ~= kind then
      return "mixed"
    end
  end
  return shape
end

--- The values of the positional items of `items`.
local function positional_values(items: {Ast.Item}): {Ast.Exp}
  local out: mut {Ast.Exp} = {}
  for _, item in ipairs(items) do
    if (item.kind == "Positional") then
      out[#out + 1] = item.value
    end
  end
  return out
end

--- Whether a map is keyed by `k`: the key types of [`lang.declarations`].
local function valid_key(k: Type): boolean
  local tag = k.tag
  return tag == "integer" or tag == "string" or tag == "boolean" or k.tag == "invalid" or
    ((k.tag == "named") and k.decl.kind ~= "enum" or is_enum(k))
end

--- A literal with no type expected: an array or a map of the join of its items.
local function literal_inferred(ctx: Ctx, e: Ast.Table): Type
  local store = ctx.store
  local items = e.items
  local shape = shape_of(items)
  if shape == "empty" then
    if ctx.lenient > 0 then
      return ctx.invalid
    end
    report(ctx, "literal_needs_type", e, "this literal has no items and no type to make it from",
      "declare the type: `local name: mut {T} = {}` (or `mut {K: V}`)")
    return ctx.invalid
  elseif shape == "mixed" then
    report(ctx, "literal_shape", e, "this literal mixes positional, named and keyed items, which no array or map holds",
      "write one kind of item, or declare a record and write its fields by name")
    items_unshaped(ctx, items)
    return ctx.invalid
  end
  if shape == "positional" then
    local types = values_of(ctx, positional_values(items), nil, nil)
    local all = types.types
    local tail = types.tail
    if tail ~= nil then
      all[#all + 1] = tail
    end
    local several, last = types.lists, types.last
    if several ~= nil and last ~= nil then
      local _ = first_value(ctx, last, several)
      return ctx.invalid
    end
    local element = join(ctx, all)
    if element == nil then
      report(ctx, "arms_differ", e, "the elements of this literal have no common type: " .. listed(type_names(ctx, all)),
        "type the literal: `local name: {" .. show(ctx, all[1]) .. "} = ...`, or make the elements one type")
      return ctx.invalid
    end
    if nilable(element) then
      report(ctx, "array_of_optional", e, "an element of this literal may be nil, and an array is dense",
        "use a map `{integer: T}` for sparse data, or keep the missing element out", { show(ctx, element) })
      return ctx.invalid
    end
    return store:array(element, true)
  end
  local keys: mut {Type} = {}
  local values: mut {Type} = {}
  for _, item in ipairs(items) do
    if (item.kind == "Named") then
      keys[#keys + 1] = store.string
      values[#values + 1] = expr(ctx, item.value, nil)
    elseif (item.kind == "Keyed") then
      keys[#keys + 1] = expr(ctx, item.key, nil)
      values[#values + 1] = expr(ctx, item.value, nil)
    end
  end
  local key = join(ctx, keys)
  local value = join(ctx, values)
  if key == nil or value == nil then
    report(ctx, "arms_differ", e, "the " .. (if key == nil then "keys" else "values" end) .. " of this literal have no common type",
      "declare a record for the fields (`record R ... end`) and write the literal against it, or make the values one type")
    return ctx.invalid
  end
  if key.tag == "number" then
    report(ctx, "float_key", e, "a key of this literal is a `number`, and a map is keyed by `integer`",
      "key by `integer`, and convert a float with `math.tointeger(n)` or `math.floor(n)`")
    return ctx.invalid
  end
  if not valid_key(key) then
    report(ctx, "literal_shape", e, "the keys of this literal are " .. tq(ctx, key) .. ", which no map is keyed by",
      "key by `integer`, `string`, `boolean`, an enum, or a record, class, interface or userdata")
    return ctx.invalid
  end
  if nilable(value) then
    report(ctx, "array_of_optional", e, "a value of this literal may be nil, and `m[k] = nil` deletes the key",
      "keep the missing value out of the literal", { show(ctx, value) })
    return ctx.invalid
  end
  return store:map(key, value, true)
end

--- An item of the wrong shape for what the literal is checked against.
local function wrong_shape(ctx: Ctx, item: Ast.Node, got: string, want: Type, fix: string)
  report(ctx, "literal_shape", item, "this " .. got .. " item cannot be in a literal of " .. tq(ctx, want), fix,
    { show(ctx, want) })
end

--- Checks the values `vals` of the positional items `exps` against `element`: each, the `T...` a last item ends in,
--- and the lists of a last item that answers several (which are no values).
local function check_elements(ctx: Ctx, exps: {Ast.Exp}, vals: Values, element: Type, of: string)
  for i, t in ipairs(vals.types) do
    local _ = expect(ctx, exps[math.min(i, #exps)], t, element, " as an element of " .. of)
  end
  local tail, several, last = vals.tail, vals.lists, vals.last
  if tail ~= nil and tail.tag ~= "invalid" then
    local _ = expect(ctx, exps[#exps], tail, element, " as an element of " .. of)
  end
  if several ~= nil and last ~= nil then
    local _ = first_value(ctx, last, several)
  end
end

--- A literal checked against an array type.
local function literal_array(ctx: Ctx, e: Ast.Table, want: Types.Array): Type
  local reported = false
  for _, item in ipairs(e.items) do
    if not ((item.kind == "Positional")) and not reported then
      reported = true
      wrong_shape(ctx, item, if (item.kind == "Named") then "named" else "keyed" end, want,
        "write the elements by position, or declare a record for the named fields")
    end
  end
  if reported then
    items_unshaped(ctx, e.items)
    return ctx.invalid
  end
  local exps = positional_values(e.items)
  check_elements(ctx, exps, values_of(ctx, exps, nil, want.element), want.element, tq(ctx, want))
  return ctx.store:array(want.element, true)
end

--- A literal checked against a map type.
local function literal_map(ctx: Ctx, e: Ast.Table, want: Types.Map): Type
  local store = ctx.store
  for _, item in ipairs(e.items) do
    if (item.kind == "Positional") then
      wrong_shape(ctx, item, "positional", want, "write `[key] = value` or `name = value` items")
      items_unshaped(ctx, e.items)
      return ctx.invalid
    elseif (item.kind == "Named") then
      local k = string_value(ctx, item, item.name, want.key)
      local _ = expect(ctx, item, k, want.key, " as a key of " .. tq(ctx, want))
      local v = expr(ctx, item.value, want.value)
      local _ = expect(ctx, item.value, v, want.value, " as a value of " .. tq(ctx, want))
    elseif (item.kind == "Keyed") then
      local k = expr(ctx, item.key, want.key)
      local _ = expect(ctx, item.key, k, want.key, " as a key of " .. tq(ctx, want))
      local v = expr(ctx, item.value, want.value)
      local _ = expect(ctx, item.value, v, want.value, " as a value of " .. tq(ctx, want))
    end
  end
  return store:map(want.key, want.value, true)
end

--- The field of `n` called `name`, not a method.
local function plain_field(ctx: Ctx, n: Named, name: string): Member?
  local index = members_index(ctx, n.decl, n.value)
  local list = index ~= nil and index.by_name[name] or nil
  if list ~= nil and not list[1].method then
    return list[1]
  end
  return nil
end

--- The field a literal item names: `name = v`, or `["name"] = v`.
local function item_name(item: Ast.Item): string?
  if (item.kind == "Named") then
    return item.name
  elseif (item.kind == "Keyed") then
    local key = peel(item.key)
    if (key.kind == "String") then
      return key.value
    end
  end
  return nil
end

--- Why the table of the class `decl` is out of reach of the module being checked, or "" where it is in reach: the
--- class is one of this module's (its module is this one, or a module of a declaration in a function's body, which is
--- this one with `@` and the node's id after it, [`lang.declarations`]), and is no member of another type, which has
--- no table of its own at run time.
local function out_of_reach(ctx: Ctx, decl: Decl): string
  if decl.module:gsub("@.*$", "") ~= ctx.input.module then
    return "a class of the module " .. quoted(decl.module) .. ", whose metatable only that module reaches"
  elseif decl.module:find("@", 1, true) ~= nil then
    return "a class declared in a block, whose table is made again each time the block runs, so values of one run " ..
      "are no values of the next"
  elseif not ctx.declared[decl] then
    return "a class declared further down the module, whose table is not made yet where this stands"
  elseif #decl.names > 1 then
    return "a class declared inside " .. quoted(table.concat(decl.names, ".", 1, #decl.names - 1)) ..
      ", which has no table of its own at run time"
  end
  return ""
end

--- The fix for a class out of reach: made, or tested, by a function of the class in the module that has its table.
local function reach_fix(ctx: Ctx, decl: Decl, function_name: string): string
  if decl.module == ctx.input.module and not ctx.declared[decl] and #decl.names == 1 then
    return "move the declaration of " .. quoted(decl.name) .. " above this, or make the value with a function of the " ..
      "class declared after it"
  elseif decl.module:find("@", 1, true) ~= nil and decl.module:gsub("@.*$", "") == ctx.input.module then
    return "declare " .. quoted(decl.name) .. " at the top level of the module, as a statement of it"
  elseif #decl.names > 1 and decl.module == ctx.input.module then
    return "declare " .. quoted(decl.name) .. " beside the type around it, as a statement of the module"
  end
  return function_name
end

--- A literal checked against a record or a class: each field given once and none the declaration lacks, every field
--- that is not omittable given (a class names every field), each value checked against its field. A literal of a
--- class of this module is noted for the code generator, which writes the class literal; the table of a class of
--- another module is out of reach, so it is refused.
local function literal_record(ctx: Ctx, e: Ast.Table, n: Named): Type
  local body = n.decl.body
  local index = members_index(ctx, n.decl, false)
  if body == nil or index == nil then
    items_unshaped(ctx, e.items)
    return n
  end
  local is_class = n.decl.kind == "class"
  if is_class then
    local why = out_of_reach(ctx, n.decl)
    if why == "" then
      ctx.literals[e.id] = n.decl
      if ctx.load.waiting > 0 then
        -- Lua runs the two metamethods a class admits by itself, at a `tostring` or the end of a `<close>` local, on any value
        -- the literals make: the value is mentioned with them.
        for _, meta in ipairs({ "__tostring", "__close" }) do
          LoadOrder.mention(ctx.load, ctx.within, e, LoadOrder.of_static(n.decl, meta, quoted(n.decl.name .. "." .. meta)))
        end
      end
    else
      report(ctx, "class_scope", e, "this literal makes a value of " .. quoted(n.decl.name) .. ", " .. why,
        reach_fix(ctx, n.decl, "make the value in " .. quoted(n.decl.module) .. " with a function of the class (`function " ..
            n.decl.name .. ".new(...): " .. n.decl.name .. "`), and call it here"), { show(ctx, n) })
    end
  end
  local given: mut {string: boolean} = {}
  local owner = quoted(n.decl.name)
  local array_part = index.array
  local shaped = true
  for _, item in ipairs(e.items) do
    local name = item_name(item)
    if name ~= nil and not ((item.kind == "Positional")) then
      local value = (item.kind == "Named") and item.value or (item.kind == "Keyed") and item.value or nil
      local field = plain_field(ctx, n, name)
      if field == nil then
        local close = nearest(name, names_of(ctx, n))
        report(ctx, "literal_unknown", item, owner .. " has no field " .. quoted(name) ..
            (if close ~= "" then ", nearest " .. quoted(close) else "" end),
          (if close ~= "" then "write " .. quoted(close) .. ", or declare " else "declare " end) .. quoted(name) .. " in " .. owner)
      elseif value ~= nil then
        given[name] = true
        local want = put_in(ctx, n, field.type)
        local v = expr(ctx, value, want)
        local _ = expect(ctx, value, v, want, " as the field " .. quoted(name) .. " of " .. owner)
      end
      if field == nil and value ~= nil then
        ctx.lenient = ctx.lenient + 1
        local _ = expr(ctx, value, nil)
        ctx.lenient = ctx.lenient - 1
      end
    elseif (item.kind == "Positional") and array_part ~= nil then
      -- Checked together below, so that the last item may expand.
    else
      if shaped then
        shaped = false
        wrong_shape(ctx, item, if (item.kind == "Positional") then "positional" else "keyed" end, n,
          "write the fields of " .. owner .. " by name: `field = value`")
      end
      items_unshaped(ctx, { item })
    end
  end
  if array_part ~= nil then
    local exps = positional_values(e.items)
    if #exps > 0 then
      local element = put_in(ctx, n, array_part)
      check_elements(ctx, exps, values_of(ctx, exps, nil, element), element, owner)
    end
  end
  local missing: mut {string} = {}
  for _, f in ipairs(body.fields) do
    if (is_class or not f.omittable) and not given[f.name] then
      missing[#missing + 1] = quoted(f.name)
    end
  end
  if #missing > 0 and shaped then
    report(ctx, "literal_missing", e, "this literal of " .. owner .. " leaves out " .. listed(missing, "and"),
      if is_class then "add " .. listed(missing, "and") .. " to the literal: a class literal names every field, a field " ..
          "not yet known as its empty value (`fd = -1`) and a `?` field as `name = nil`" else
        "add " .. listed(missing, "and") .. " to the literal (`name = nil` for a value that may be nil), or declare " ..
          (if #missing == 1 then "the field" else "them" end) .. " `name?: T`" end)
  end
  return n
end

--- The member of the union `u` that the literal `e` is, or nil with the error reported. `written` is `u` as the program
--- names it, where `u` is the type a recursive alias names.
local function literal_member(ctx: Ctx, e: Ast.Table, u: Union, written: Type): Type?
  -- Every type of `types` quoted once, in order, without the `nil`: the arms of a type a message names.
  local function arms_named(types: {Type}): {string}
    local out: mut {string} = {}
    local seen: mut {integer: boolean} = {}
    for _, t in ipairs(types) do
      if t.tag ~= "nil" and not seen[t.id] then
        seen[t.id] = true
        out[#out + 1] = tq(ctx, t)
      end
    end
    table.sort(out)
    return out
  end

  -- Whether a literal of the given `shape` could make a value of `m`, an array, a map, a record or a class: positional
  -- items make an array, or a record with an array part; items with keys make a map or a record.
  local function made_from(m: Type, shape: string): boolean
    if (m.tag == "array") then
      return shape == "positional"
    elseif (m.tag == "map") then
      return shape == "keyed"
    elseif (m.tag == "named") then
      if shape == "positional" then
        local index = members_index(ctx, m.decl, false)
        return index ~= nil and index.array ~= nil
      end
      return shape ~= "mixed"
    end
    return false
  end
  local candidates: mut {Type} = {}
  for _, m in ipairs(members_of(ctx.store, u)) do
    if ((m.tag == "named") and not m.value and (m.decl.kind == "record" or m.decl.kind == "class")) or (m.tag == "array") or (m.tag == "map") then
      candidates[#candidates + 1] = m
    end
  end
  local arms = if written ~= u then ", which is " .. listed(arms_named(members_of(ctx.store, u)), "or") else "" end
  if #candidates == 0 then
    report(ctx, "literal_shape", e, "a table literal is checked against " .. tq(ctx, written) .. arms .. ", which has no member a " ..
        "table makes",
      "write a value of one of its members", { show(ctx, written) })
    return nil
  end
  -- The kinds of item tell an array from a map, and a record that has an array part from one that has not.
  -- `name =` and `[k] =` are one kind of item here: both give a key. Only a positional item beside them mixes.
  local shape = "empty"
  local positional, keyed = false, false
  for _, item in ipairs(e.items) do
    if (item.kind == "Positional") then
      positional = true
    else
      keyed = true
    end
  end
  if positional and keyed then
    shape = "mixed"
  elseif positional then
    shape = "positional"
  elseif keyed then
    shape = "keyed"
  end
  if #candidates > 1 and shape ~= "empty" then
    local fitting: mut {Type} = {}
    for _, m in ipairs(candidates) do
      if made_from(m, shape) then
        fitting[#fitting + 1] = m
      end
    end
    if #fitting == 0 then
      report(ctx, "literal_shape", e, "this literal's items (" .. (if shape == "mixed" then "some by position and some by key" elseif shape == "positional" then
        "by position" else "by key" end) .. ") make none of " .. listed(type_names(ctx, candidates), "or") ..
          ", the tables " .. tq(ctx, written) .. " takes",
        "write the items by position for an array, or `key = value` for a map, and not both", { show(ctx, written) })
      return nil
    end
    candidates = fitting
  end
  if #candidates == 1 then
    return candidates[1]
  end
  -- A tag: a named item whose string value is a value of the enum a member's field of that name has, where every
  -- candidate has an enum there, as a tag is. Another member with the value too is `untagged_union` where the union is
  -- declared, and leaves the literal ambiguous here.
  for _, item in ipairs(e.items) do
    local name = item_name(item)
    local value = (item.kind == "Named") and peel(item.value) or (item.kind == "Keyed") and peel(item.value) or nil
    if name ~= nil and value ~= nil and (value.kind == "String") then
      local tagged: mut {Type} = {}
      local everywhere = true
      for _, m in ipairs(candidates) do
        local field = (m.tag == "named") and plain_field(ctx, m, name) or nil
        local t = field ~= nil and field.type or nil
        local body = t ~= nil and (t.tag == "named") and t.decl.kind == "enum" and t.decl.body or nil
        if body == nil then
          everywhere = false
        else
          local has = false
          for _, v in ipairs(body.values) do
            has = has or v == value.value
          end
          if has then
            tagged[#tagged + 1] = m
          end
        end
      end
      if everywhere and #tagged == 1 then
        return tagged[1]
      end
    end
  end
  local records = false
  for _, m in ipairs(candidates) do
    records = records or (m.tag == "named")
  end
  if records then
    report(ctx, "literal_ambiguous", e, "this literal could be any of " .. listed(type_names(ctx, candidates)),
      "give the tag field of the member it is (`kind = \"...\"`), or type the literal first: `local v: Member = {...}`")
  elseif shape == "empty" then
    local fix = "write an item, or type the literal as the one it is: `local v: " .. show(ctx, candidates[1]) .. " = {}`"
    if (written.tag == "named") then
      local advised = Check.advice[written.decl.module .. " " .. written.decl.name .. " empty"]
      if advised ~= nil then
        fix = advised
      end
    end
    report(ctx, "literal_ambiguous", e, "this literal has no items, so it could be any of " .. listed(type_names(ctx, candidates)), fix)
  else
    report(ctx, "literal_ambiguous", e, "this literal could be any of " .. listed(type_names(ctx, candidates)),
      "type the literal as the one it is: `local v: " .. show(ctx, candidates[1]) .. " = {...}`")
  end
  return nil
end

-- TODO: check a literal given to a parameter declared `any` item by item and answer it without a join, once the plan says
-- whether a value reaches `any` as the items of a literal or only as the literal (doc/plans/new-checker-types.md, "what
-- `any` may do"): it is typed by the join of its items today, so `Json.encode_any({ a = 1, b = "x" })` is `arms_differ`, and
-- the files that give such a literal to an `any` parameter hold that count in [`build/ceilings.txt`].

--- A table literal. Checked against a type it is a record, a class, an array or a map as that type is; with no type it
--- is an array or a map of the join of its items.
local function table_literal(ctx: Ctx, e: Ast.Table, expected: Type?): Type
  -- Reports each key a table literal gives a second time: a name (`a = 1`), a constant key (`["a"]`, `[1]`, `[true]`), or the
  -- place of a positional item (`{ "x", [1] = "y" }`). The second value would replace the first, whatever type the literal is
  -- checked against, so this stands apart from the shape of the literal. A name and the same string as a key are one key.
  local seen: mut {string: boolean} = {}
  local place = 0
  for _, item in ipairs(e.items) do
    local key: string? = nil
    local shown = ""
    if (item.kind == "Positional") then
      place = place + 1
      key, shown = "n" .. tostring(place), tostring(place)
    elseif (item.kind == "Named") then
      key, shown = "s" .. item.name, quoted(item.name)
    elseif (item.kind == "Keyed") then
      local at = peel(item.key)
      if (at.kind == "String") then
        key, shown = "s" .. at.value, quoted(at.value)
      elseif (at.kind == "Integer") then
        key, shown = "n" .. tostring(at.value), tostring(at.value)
      elseif (at.kind == "Boolean") then
        key, shown = "b" .. tostring(at.value), tostring(at.value)
      end
    end
    if key ~= nil then
      if seen[key] == true then
        report(ctx, "literal_repeated", item, "the key " .. shown .. " is written twice in this literal",
          "remove the second " .. shown .. ", or give the two different keys")
      end
      seen[key] = true
    end
  end
  if expected == nil or ctx.lenient > 0 then
    return literal_inferred(ctx, e)
  end
  local want = ctx.store:non_nil(expected)
  if want.tag == "invalid" then
    items_unshaped(ctx, e.items)
    return want
  elseif want.tag == "any" or want.tag == "never" then
    return literal_inferred(ctx, e)
  end
  local written = want
  want = Types.unfold(want)
  if (want.tag == "union") then
    local member = literal_member(ctx, e, want, written)
    if member == nil then
      items_unshaped(ctx, e.items)
      return ctx.invalid
    end
    want = member
  end
  if (want.tag == "named") then
    local kind = want.decl.kind
    if want.value then
      report(ctx, "literal_shape", e, "a table literal cannot make " .. tq(ctx, want) .. ", the table of the functions of " ..
          quoted(want.decl.name),
        "write a value of " .. quoted(want.decl.name) .. " where one is wanted, or the declaration itself", { show(ctx, want) })
      items_unshaped(ctx, e.items)
      return ctx.invalid
    elseif kind == "record" or kind == "class" then
      return literal_record(ctx, e, want)
    end
    report(ctx, "literal_shape", e, "a table literal cannot make " .. tq(ctx, want) .. ", " ..
        (if kind == "interface" then "an interface" elseif kind == "enum" then "an enum" else "a userdata record" end),
      if kind == "interface" then "make the value with a class that lists " .. quoted(want.decl.name) ..
          " (`class C is " .. want.decl.name .. "`)" else "write a value of " .. quoted(want.decl.name) end, { show(ctx, want) })
    items_unshaped(ctx, e.items)
    return ctx.invalid
  elseif (want.tag == "array") then
    return literal_array(ctx, e, want)
  elseif (want.tag == "map") then
    return literal_map(ctx, e, want)
  end
  report(ctx, "literal_shape", e, "a table literal cannot make " .. tq(ctx, want),
    "write a value of " .. tq(ctx, want), { show(ctx, want) })
  items_unshaped(ctx, e.items)
  return ctx.invalid
end

-- Fields and indexes -------------------------------------------------------------------------

--- The type to read from when the value of `node` has type `t`: `t` without its nil, after reporting that it may
--- be nil. Nil where the access has nothing to read (an error already reported, or `invalid`).
local function readable(ctx: Ctx, node: Ast.Node, t: Type, what: string): Type?
  local tag = t.tag
  if tag == "invalid" or tag == "never" then
    return nil
  elseif tag == "any" then
    report(ctx, "any_use", node, subject(ctx, node) .. " is untrusted data (`any`), so " .. what,
      "validate it with a [`cosmic.shape`] validator, or test its tag, and use the checked value", { "any" })
    return nil
  elseif tag == "nil" then
    report(ctx, "nil_not_allowed", node, subject(ctx, node) .. " is nil, so " .. what,
      "give it a value, or do not read it", { "nil" })
    return nil
  elseif nilable(t) then
    report(ctx, "nil_not_allowed", node, subject(ctx, node) .. " is " .. tq(ctx, t) .. ", so it may be nil, and " .. what,
      nil_fix(ctx, node), { show(ctx, t) })
    return ctx.store:non_nil(t)
  end
  return t
end

--- The members called `name` of `t`, each with the type arguments put in.
local function member_types(ctx: Ctx, t: Named, name: string): {Member}?
  local index = members_index(ctx, t.decl, t.value)
  return index ~= nil and index.by_name[name] or nil
end

local function field_unknown(ctx: Ctx, node: Ast.Node, t: Type, name: string)
  if (t.tag == "named") and t.value and (ctx.program.absent[t.decl] or {})[name] == true then
    -- The function is a field every value holds, filled where the value is made: the table of the functions has none.
    local owner = quoted(t.decl.name)
    report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) .. " in the table of its functions: " ..
        quoted(name) .. " is a function field of the values of " .. owner .. ", which no statement of its module gives " ..
        "that table",
      "call it on a value of " .. owner .. ": `v:" .. name .. "(...)`", { show(ctx, t) })
    return
  end
  if (t.tag == "named") and not t.value and (ctx.program.statics[t.decl] or {})[name] ~= nil then
    -- A module stored in a field typed with its record is typed as the record's value, which has none of its functions.
    local decl: Decl = t.decl
    local owner = quoted(decl.name)
    local through_field = false
    if (node.kind == "Field") then
      local object = node.object
      through_field = (object.kind == "Field")
    end
    local call = "call it on the declaration: `" .. decl.name .. "." .. name .. "(...)`"
    local fix = call
    local held = members_index(ctx, decl, false)
    local selfish = held ~= nil and held.selfish[name] == true
    -- A class has no module among its values, so its fix is the call alone.
    if decl.kind ~= "class" and through_field and decl.module ~= ctx.input.module and
        not decl.module:find("@", 1, true) then
      -- A record read through a field holds a module stored there, which a program requires where it uses it.
      fix = "require the module where you use it (`local " .. decl.name .. " = require(\"" .. decl.module .. "\")`) " ..
        "instead of reading it through a field; " .. call
    elseif decl.kind ~= "class" and selfish then
      -- It takes the record first, but the value is a table with the record's fields and no metatable to reach the function.
      fix = call .. "; `v:" .. name .. "(...)` finds no function in a value of a record, which has no metatable: declare " ..
        owner .. " as a class, or declare " .. quoted(name) .. " as a function field `" .. name .. ": function(" ..
        decl.name .. ", ...)` that every value holds"
    end
    report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) .. ": " .. quoted(name) ..
        " is a function of the declaration " .. owner .. " used as a value, and this is typed as a value of it",
      fix, { show(ctx, t) })
    return
  end
  local owner = (t.tag == "named") and quoted(t.decl.name) or tq(ctx, t)
  if is_enum(t) then
    -- A method call on an enum is served by `string` and never gets here: this reads a field, or a function as a value.
    report(ctx, "field_unknown", node, owner .. " is an enum, whose values have no fields: " .. quoted(name) .. " is not one",
      "call a function of `string` on it, `v:" .. name .. "(...)`, or compare it with `==` to a member", { show(ctx, t) })
    return
  end
  local names: {string} = {}
  if (t.tag == "named") then
    names = names_of(ctx, t)
  end
  local close = nearest(name, names)
  report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) ..
      (if close ~= "" then ", nearest " .. quoted(close) else "" end),
    if close ~= "" then "write " .. quoted(close) .. ", or declare " .. quoted(name) .. " in " .. owner else
      "declare " .. quoted(name) .. " in " .. owner end, { show(ctx, t) })
end

--- The type of the field or method `name` of the value of type `t`, reported where it has none. `node` is the
--- expression that reads it; it holds the overloads of the field in `ctx.cands` when it has several.
local function member_read(ctx: Ctx, node: Ast.Node, t: Type, name: string): Type
  local store = ctx.store
  ctx.member_module, ctx.member_node = "", node
  -- A method call on an enum value is a call in `string`, which each enum is below; the read of a member as a value is not.
  local called = (node.kind == "MethodCall")
  if (t.tag == "named") and not (is_enum(t) and called) then
    local decl = t.decl
    ctx.member_module = decl.module
    local waiting = ctx.pending[decl]
    local as_declared = t.value or decl.kind == "class" or decl.kind == "interface"
    if waiting ~= nil and waiting[name] == true and as_declared then
      if ctx.within == 0 then
        -- The module's own code that runs as it loads reads the function before the statement that defines it has run.
        report(ctx, "static_before_definition", node, subject(ctx, node) .. " reads the function " ..
            quoted(decl.name .. "." .. name) .. " before the statement that defines it has run",
          "move the statement `function " .. decl.name .. "." .. name .. "(...)` above this use, or use it in a function " ..
            "that runs after the module has loaded", { show(ctx, t) })
      else
        LoadOrder.read(ctx.load, ctx.within, { decl = decl, name = name, first = base_of(node).first })
      end
    end
    if as_declared and ctx.load.waiting > 0 then
      LoadOrder.mention(ctx.load, ctx.within, node, LoadOrder.of_static(decl, name, quoted(decl.name .. "." .. name)))
    end
    local list = member_types(ctx, t, name)
    if list == nil then
      field_unknown(ctx, node, t, name)
      return ctx.invalid
    end
    local first = assert(list[1])
    if t.decl.kind == "interface" and not called and not first.method and ctx.probes[node.id] ~= true and
        takes_receiver(ctx, t.decl, first.type) then
      -- The implementation depends on the receiver, which agreement fixes to the implementing type: read as a value, it
      -- would be called with another implementer.
      local receiver = (node.kind == "Field") and text_of(ctx, node.object) or "v"
      local fix = "call it as `" .. receiver .. ":" .. name .. "(...)`"
      if nilable(first.type) then
        -- An optional method is there or not: a call needs the test of the place first, which narrows it.
        fix = "test that it is there, then call it: `if " .. receiver .. "." .. name .. " ~= nil then " .. receiver .. ":" ..
          name .. "(...) end`"
      end
      report(ctx, "interface_method_value", node, subject(ctx, node) .. " reads the method " .. quoted(name) ..
          " of the interface " .. tq(ctx, t) .. " as a value, and its implementation depends on the receiver",
        fix, { show(ctx, t) })
      return ctx.invalid
    end
    if #list > 1 then
      local all: mut {Type} = {}
      for i, m in ipairs(list) do
        all[i] = put_in(ctx, t, m.type)
      end
      ctx.cands = all
      ctx.cand_node = node
    end
    return put_in(ctx, t, list[1].type)
  elseif (t.tag == "union") then
    -- Read as a value, the member is the union of their types; a call is typed by [`union_method`] and not by this.
    local key = tostring(t.id) .. "." .. name
    local held = ctx.union_fields[key]
    if held ~= nil then
      return held
    end
    local types: mut {Type} = {}
    for _, m in ipairs(t.members) do
      if (m.tag == "named") and member_types(ctx, m, name) ~= nil then
        types[#types + 1] = member_read(ctx, node, m, name)
      elseif is_enum(m) then
        report(ctx, "field_unknown", node, quoted(name) .. " is not a field of " .. tq(ctx, m) ..
            ", an enum and a member of " .. tq(ctx, t),
          "call a function of `string` on it, `v:" .. name .. "(...)`, or narrow the value to the member that has it " ..
            "(`x is T`)", { show(ctx, t) })
        return ctx.invalid
      else
        report(ctx, "field_unknown", node, quoted(name) .. " is not a field of " .. tq(ctx, m) ..
            ", a member of " .. tq(ctx, t),
          "narrow the value to the member that has it (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(name) ..
            " in every member", { show(ctx, t) })
        return ctx.invalid
      end
    end
    local made = store:union(types)
    ctx.union_fields[key] = made
    return made
  elseif (t.tag == "map") then
    report(ctx, "map_field", node, subject(ctx, node) .. " reads a field of a map, " .. tq(ctx, t) ..
        ", which is read by a key",
      "write `[\"" .. name .. "\"]` after the map, or declare a record for the fields",
      { show(ctx, t) })
    return ctx.invalid
  elseif is_text(t) then
    local entry = ctx.program.globals["string"]
    local decl = entry ~= nil and entry.decl or nil
    local index = decl ~= nil and members_index(ctx, decl, false) or nil
    local list = index ~= nil and index.by_name[name] or nil
    if list == nil then
      report(ctx, "field_unknown", node, (if is_enum(t) then tq(ctx, t) .. " is an enum, a string with no method " else
        "a string has no field " end) .. quoted(name),
        "call a function of `string` on it: `s:upper()`, `s:sub(i, j)`", { show(ctx, t) })
      return ctx.invalid
    end
    if #list > 1 then
      local all: mut {Type} = {}
      for i, m in ipairs(list) do
        all[i] = m.type
      end
      ctx.cands = all
      ctx.cand_node = node
    end
    return list[1].type
  elseif (t.tag == "var") then
    local scope = ctx.bounds[#ctx.bounds - t.depth]
    local parameter = scope ~= nil and scope[t.index + 1] or nil
    local bound = parameter ~= nil and parameter.bound or nil
    if bound ~= nil then
      return member_read(ctx, node, bound, name)
    end
    report(ctx, "not_indexable", node, "the type parameter " .. tq(ctx, t) .. " has no field " .. quoted(name),
      "bound it by an interface that declares " .. quoted(name) .. " (`T is I`)", { show(ctx, t) })
    return ctx.invalid
  end
  report(ctx, "not_indexable", node, subject(ctx, node) .. " reads a field of " .. tq(ctx, t) .. ", which has none",
    "read a field of a record, class or interface", { show(ctx, t) })
  return ctx.invalid
end

--- The method `name` called as `object:name(...)` through the union `u`: the function type every member declares it as
--- once the receiver is `u`, with its overloads, or nil after reporting that a member lacks it or declares it
--- differently. The value is one member at run time and each member's method takes that member as its receiver, so a
--- receiver that is the member itself (as a method has it) is replaced by `u`, and the call is typed when the members then
--- agree exactly: the same parameters, rest and return lists. A method that differs in any of them is the call of one of
--- several functions, which only a test of the value tells apart.
local function union_method(ctx: Ctx, node: Ast.MethodCall, u: Union): Type?, {Type}?
  local store = ctx.store
  local common: {Type}? = nil
  local first: Type? = nil
  local first_declared: Type = ctx.invalid
  for _, m in ipairs(u.members) do
    -- A member that is text (an enum or `string`) has the functions of `string`, which only a call reaches.
    if not is_text(m) and (not ((m.tag == "named")) or member_types(ctx, m, node.name) == nil) then
      report(ctx, "field_unknown", node, quoted(node.name) .. " is not a field of " .. tq(ctx, m) .. ", a member of " ..
          tq(ctx, u),
        "narrow the value to the member that has it (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(node.name) ..
          " in every member", { show(ctx, u) })
      return nil, nil
    end
    ctx.cands, ctx.cand_node = nil, nil
    local read = member_read(ctx, node, m, node.name)
    local declared: {Type} = { read }
    if ctx.cand_node == node and ctx.cands ~= nil then
      declared = ctx.cands
    end
    ctx.cands, ctx.cand_node = nil, nil
    if read.tag == "invalid" then
      return nil, nil
    end
    local replaced: mut {Type} = {}
    for i, each in ipairs(declared) do
      local f = each
      local receiver: Types.Param? = nil
      if f.tag == "fn" then
        receiver = f.params[1]
      end
      if (f.tag == "fn") and receiver ~= nil and receiver.type == m and not is_text(m) then
        local params: mut {Types.Param} = {}
        for j, p in ipairs(f.params) do
          params[j] = p
        end
        params[1] = { type = u, omittable = receiver.omittable }
        f = store:fn({ tparams = f.tparams, params = params, rest = f.rest, rets = f.rets })
      end
      replaced[i] = f
    end
    local held = common
    if held == nil then
      common = replaced
      first = m
      first_declared = declared[1] or read
    else
      local agree = #held == #replaced
      for i = 1, if agree then #held else 0 end do
        agree = agree and held[i] == replaced[i]
      end
      if not agree then
        local other = first
        report(ctx, "not_callable", node, subject(ctx, node) .. " calls the method " .. quoted(node.name) .. " of each member " ..
            "of " .. tq(ctx, u) .. ", and " .. tq(ctx, other ~= nil and other or m) .. " and " .. tq(ctx, m) ..
            " declare it differently: " .. quoted(show(ctx, first_declared)) .. " and " ..
            quoted(show(ctx, declared[1] or read)),
          "narrow the value to one member first (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(node.name) ..
            " the same in every member", { show(ctx, first_declared), show(ctx, declared[1] or read) })
        return nil, nil
      end
    end
  end
  local list = common
  if list == nil or list[1] == nil then
    return nil, nil
  end
  return list[1], #list > 1 and list or nil
end

--- Checks that `key`, of type `kt`, may index a collection keyed by `want`: an `integer` where that is wanted, never
--- a `number`.
local function key_ok(ctx: Ctx, key_node: Ast.Node, kt: Type, want: Type, of: string): boolean
  if below(ctx, kt, want) then
    return true
  end
  if kt.tag == "number" and want.tag == "integer" then
    report(ctx, "float_key", key_node, subject(ctx, key_node) .. " is a `number`, and " .. of .. " is keyed by `integer`",
      "convert it: `math.tointeger(" .. text_of(ctx, key_node) .. ")` or `math.floor(" .. text_of(ctx, key_node) .. ")`",
      { show(ctx, kt), show(ctx, want) })
    return false
  end
  return expect(ctx, key_node, kt, want, " as the key of " .. of)
end

--- The field names a key of type `kt` stands for when it is a string literal or an enum, or nil.
local function key_names(key: Ast.Exp, kt: Type): {string}?
  local literal = peel(key)
  if (literal.kind == "String") then
    return { literal.value }
  end
  if (kt.tag == "named") and kt.decl.kind == "enum" then
    local body = kt.decl.body
    if body ~= nil then
      return body.values
    end
  end
  return nil
end

--- `object[key]` read: the element of an array or the value of a map as an optional (an index read may be nil), the
--- fields a literal or enum key names in a record.
local function index_read(ctx: Ctx, node: Ast.Index, object: Type): Type
  local store = ctx.store
  local t = readable(ctx, node.object, object, "it has no elements to read")
  if t == nil then
    local _ = expr(ctx, node.key, nil)
    return ctx.invalid
  end
  if (t.tag == "array") then
    local k = expr(ctx, node.key, store.integer)
    local _ = key_ok(ctx, node.key, k, store.integer, subject(ctx, node.object))
    local element = t.element
    if not t.mut then
      element = view(store, element)
    end
    return store:optional(element)
  elseif (t.tag == "map") then
    local k = expr(ctx, node.key, t.key)
    local _ = key_ok(ctx, node.key, k, t.key, subject(ctx, node.object))
    local value = t.value
    if not t.mut then
      value = view(store, value)
    end
    return store:optional(value)
  elseif (t.tag == "named") and (t.decl.kind == "record" or t.decl.kind == "class" or t.decl.kind == "userdata") then
    local k = expr(ctx, node.key, nil)
    if k.tag == "invalid" then
      return ctx.invalid
    end
    local names = key_names(node.key, k)
    if names == nil then
      local index = members_index(ctx, t.decl, t.value)
      local array_part = index ~= nil and index.array or nil
      if array_part ~= nil and below(ctx, k, store.integer) then
        return store:optional(put_in(ctx, t, array_part))
      end
      report(ctx, "record_index", node, subject(ctx, node.key) .. " is " .. tq(ctx, k) .. ", which names no field of " ..
          tq(ctx, t) .. ": a record is not a map",
        "write the field (`" .. text_of(ctx, node.object) .. ".field`), or index a `{K: V}`", { show(ctx, k) })
      return ctx.invalid
    end
    local types: mut {Type} = {}
    for _, name in ipairs(names) do
      local list = member_types(ctx, t, name)
      if list == nil or list[1].method then
        field_unknown(ctx, node.key, t, name)
        return ctx.invalid
      end
      types[#types + 1] = put_in(ctx, t, list[1].type)
    end
    return store:union(types)
  end
  local _ = expr(ctx, node.key, nil)
  report(ctx, "not_indexable", node, subject(ctx, node.object) .. " is " .. tq(ctx, t) .. ", which has no elements to index",
    "index an array, a map or a record", { show(ctx, t) })
  return ctx.invalid
end

-- Operators ------------------------------------------------------------------------------------

--- Reports that the operand `node`, of type `t`, is not what `op` takes.
local function bad_operand(ctx: Ctx, node: Ast.Node, t: Type, op: string, takes: string, fix: string)
  local s = subject(ctx, node)
  if t.tag == "any" then
    report(ctx, "any_use", node, s .. " is untrusted data (`any`), and " .. quoted(op) .. " takes " .. takes,
      "validate it with a [`cosmic.shape`] validator, or test its tag, and use the checked value", { "any" })
  elseif (t.tag == "var") then
    report(ctx, "generic_op", node, s .. " is the type parameter " .. tq(ctx, t) .. ", which ranges over every type, and " ..
        quoted(op) .. " takes " .. takes,
      "bound the type parameter by an interface that declares the operation (`T is Ordered`)", { show(ctx, t) })
  elseif nilable(t) then
    report(ctx, "nil_not_allowed", node, s .. " is " .. tq(ctx, t) .. ", so it may be nil, and " .. quoted(op) .. " takes " .. takes,
      nil_fix(ctx, node), { show(ctx, t) })
  else
    report(ctx, "operand_type", node, s .. " is " .. tq(ctx, t) .. ", and " .. quoted(op) .. " takes " .. takes, fix,
      { show(ctx, t) })
  end
end

--- What `t` is as an operand of a number operator: 1 `integer`, 2 `number`, 0 anything else (reported unless it is
--- `invalid`).
local function arithmetic_operand(ctx: Ctx, node: Ast.Node, t: Type, op: string): integer
  local tag = t.tag
  if tag == "integer" or tag == "never" then
    return 1
  elseif tag == "number" then
    return 2
  elseif tag == "invalid" then
    return 0
  end
  local inner = nilable(t) and ctx.store:non_nil(t) or t
  local fix = if is_text(t) then "convert it with `tonumber(" .. text_of(ctx, node) .. ")`" else
    "use a number: " .. quoted(op) .. " converts nothing" end
  bad_operand(ctx, node, t, op, "numbers", fix)
  if nilable(t) and inner.tag == "integer" then
    return 1
  elseif nilable(t) and inner.tag == "number" then
    return 2
  end
  return 0
end

--- Whether `t` is an `integer`, as the operand of a bit operator; reports it where not.
local function integer_operand(ctx: Ctx, node: Ast.Node, t: Type, op: string): boolean
  if t.tag == "integer" or t.tag == "never" then
    return true
  elseif t.tag == "invalid" then
    return false
  end
  local fix = if t.tag == "number" then "convert it with `math.tointeger(" .. text_of(ctx, node) .. ")` or `math.floor(" ..
      text_of(ctx, node) .. ")`" else "use an integer: " .. quoted(op) .. " converts nothing" end
  bad_operand(ctx, node, t, op, "integers", fix)
  return false
end

--- Whether `t` is a string, as an operand of `..`; reports it where not.
local function string_operand(ctx: Ctx, node: Ast.Node, t: Type): boolean
  if is_text(t) or t.tag == "never" then
    return true
  end
  -- A union of enums and strings, none of it nil, is a string whichever member it is.
  -- TODO: take the same union as the operand of `#` and of the orderings, which [`is_text`] refuses where it is not one enum or
  -- `string`, once a program of the tree writes one.
  if (t.tag == "union") and not t.nilable then
    local text = true
    for _, m in ipairs(t.members) do
      text = text and is_text(m)
    end
    if text then
      return true
    end
  end
  if t.tag == "invalid" then
    return false
  end
  if t.tag == "integer" or t.tag == "number" or is_bool(t) then
    report(ctx, "concat_type", node, subject(ctx, node) .. " is " .. tq(ctx, t) .. ", and `..` takes strings",
      "write `tostring(" .. text_of(ctx, node) .. ")` or `string.format(\"%d\", " .. text_of(ctx, node) .. ")`",
      { show(ctx, t) })
    return false
  end
  bad_operand(ctx, node, t, "..", "strings", "convert it to a string first: `tostring(" .. text_of(ctx, node) .. ")`")
  return false
end

--- Whether `t` has a length: a string, an array, a record with an array part.
local function length_operand(ctx: Ctx, node: Ast.Node, t: Type): boolean
  if is_text(t) or (t.tag == "array") or t.tag == "never" then
    return true
  elseif t.tag == "invalid" then
    return false
  elseif (t.tag == "named") then
    local index = members_index(ctx, t.decl, t.value)
    if index ~= nil and index.array ~= nil then
      return true
    end
  end
  bad_operand(ctx, node, t, "#", "a string or an array", if (t.tag == "map") then
    "a map has no length: keep a count, or use an array" else "take the length of a string or an array" end)
  return false
end

--- Whether the type of an `==` operand and another may be equal: they overlap, some member of one is below some member
--- of the other. `any` and `invalid` overlap everything; a type variable overlaps itself and nil.
local function overlaps(ctx: Ctx, a: Type, b: Type): boolean
  if a == b or a.tag == "any" or b.tag == "any" or a.tag == "invalid" or b.tag == "invalid" or a.tag == "never" or
      b.tag == "never" then
    return true
  end
  local store = ctx.store
  for _, x in ipairs(members_of(store, a)) do
    for _, y in ipairs(members_of(store, b)) do
      if x == y or below(ctx, x, y) or below(ctx, y, x) then
        return true
      end
      if ((x.tag == "var") and y.tag == "nil") or ((y.tag == "var") and x.tag == "nil") then
        return true
      end
    end
  end
  return false
end

--- What a condition of type `t` is: "bool", "opt" (a `T?` for a `T` that is not a boolean), or "bad" after the error.
local function condition_kind(ctx: Ctx, node: Ast.Node, t: Type): string
  local tag = t.tag
  if is_bool(t) or tag == "never" or tag == "invalid" then
    return "bool"
  end
  local s = subject(ctx, node)
  if nilable(t) then
    local inner = ctx.store:non_nil(t)
    local boolean = false
    for _, m in ipairs(members_of(ctx.store, inner)) do
      boolean = boolean or is_bool(m)
    end
    if not boolean then
      return "opt"
    end
    report(ctx, "condition_type", node, s .. " is " .. tq(ctx, t) .. ": nil and false would not be told apart",
      "write the test: `" .. text_of(ctx, node) .. " == true` or `" .. text_of(ctx, node) .. " == nil`", { show(ctx, t) })
    return "bad"
  elseif tag == "any" then
    report(ctx, "any_use", node, s .. " is untrusted data (`any`) and is used as a condition",
      "test its tag (`type(" .. text_of(ctx, node) .. ") == \"string\"`) or validate it, and use the checked value", { "any" })
    return "bad"
  end
  local fix = "remove the condition: " .. s .. " is never false"
  if is_text(t) then
    fix = "write the test: `" .. text_of(ctx, node) .. " ~= \"\"`"
  elseif tag == "integer" or tag == "number" then
    fix = "write the test: `" .. text_of(ctx, node) .. " ~= 0`"
  elseif (t.tag == "var") then
    fix = "a type parameter may be nil or false: test it with `" .. text_of(ctx, node) .. " ~= nil` where it is bounded"
  end
  report(ctx, "condition_type", node, s .. " is " .. tq(ctx, t) .. ", which is no boolean or optional, so it is no condition",
    fix, { show(ctx, t) })
  return "bad"
end

--- Checks the condition `node`.
local function condition(ctx: Ctx, node: Ast.Exp): Type
  -- Each operand of `not`, `and` and `or` of a condition is only asked whether it holds: a field read there is a probe.
  local function mark_probes(operand: Ast.Exp)
    local at = peel(operand)
    if (at.kind == "Field") then
      ctx.probes[at.id] = true
    elseif (at.kind == "Unary") and at.op == "not" then
      mark_probes(at.operand)
    elseif (at.kind == "Binary") and (at.op == "and" or at.op == "or") then
      mark_probes(at.left)
      mark_probes(at.right)
    end
  end
  mark_probes(node)
  local t = expr(ctx, node, nil)
  local _ = condition_kind(ctx, node, t)
  return t
end

local edges: function(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State, Flow.State

-- Narrowing ------------------------------------------------------------------------------------

--- A place the facts may hold: a local, or a path of fixed fields from one.
local record Place
  key: string
  --- What the program declared it with.
  declared: Type
end

--- The union `t` without a member that is below another, so that the join of two facts is the wider one (`{T}` for
--- `mut {T} | {T}`, a class for the interface it lists): a fact never carries a type its edges' do not need.
local function subsume(ctx: Ctx, t: Type): Type
  if not ((t.tag == "union")) then
    return t
  end
  local members = members_of(ctx.store, t)
  -- A record or a class is nominal: it is below another named type only when that is an interface it lists, or its own
  -- declaration ([`lang.relation`]). Members that are all records and classes of declarations apart (a tagged union
  -- is one), and `nil`, are below none of each other, and the pairs need not be asked: for a union of many members
  -- that is all the cost of a join, and a left fold of joins asks every pair of every union it makes.
  local declared: mut {Decl: boolean} = {}
  local apart = true
  for _, m in ipairs(members) do
    if m.tag == "nil" then
      -- Kept, whatever it is beside.
    elseif m.tag == "named" and not m.value and (m.decl.kind == "record" or m.decl.kind == "class") and
        declared[m.decl] == nil then
      declared[m.decl] = true
    else
      apart = false
      break
    end
  end
  if apart then
    return t
  end
  local kept: mut {Type} = {}
  for i, m in ipairs(members) do
    local covered = false
    for j, n in ipairs(members) do
      if m.tag == "invalid" or n.tag == "invalid" then
        return t
      elseif i ~= j and m.tag ~= "nil" and below(ctx, m, n) and (j < i or not below(ctx, n, m)) then
        covered = true
        break
      end
    end
    if not covered then
      kept[#kept + 1] = m
    end
  end
  if #kept < #members then
    return ctx.store:union(kept)
  end
  return t
end

--- The states `a` and `b` meet in.
local function merge(ctx: Ctx, a: Flow.State, b: Flow.State): Flow.State
  return Flow.join(a, b, ctx.unite, ctx.covers)
end

--- The state where all of `list` meet; the first where there is one.
local function merge_all(ctx: Ctx, list: {Flow.State}): Flow.State
  local at = list[1]
  for i = 2, #list do
    at = merge(ctx, at, list[i])
  end
  return at
end

--- The type of `place` in `f`: what it was narrowed to, else what it was declared with.
local function current(f: Flow.State, place: Place): Type
  local fact = f.facts[place.key]
  if fact ~= nil then
    return fact.type
  end
  return place.declared
end

--- The kinds of binding a place may be.
local PLACE_KINDS <const>: {Scopes.Kind: boolean} = {
  ["local"] = true, ["function"] = true, param = true, loop = true, pattern = true,
}

--- The place the expression `e` names in the state `f`, or nil: a local, or `a.b.c` from one with each field fixed
--- (not declared `mut`) of a record, class or interface, read through the type the facts hold of what is before it.
--- A global, a `mut` field, an index and a field of anything else are not places: code that runs between a test and a
--- use can change them.
local function place_of(ctx: Ctx, f: Flow.State, e: Ast.Node): Place?
  local at = peel(e)
  if (at.kind == "Name") then
    local id = at.binding
    if id == nil then
      return nil
    end
    local v = ctx.scoped.vars[id]
    local declared = ctx.vars[id]
    local key = path_key(ctx, at)
    if v == nil or declared == nil or key == nil or not PLACE_KINDS[v.kind] or ctx.unfixed_now[id] then
      return nil
    end
    return { key = key, declared = declared }
  elseif (at.kind == "Field") then
    local base = place_of(ctx, f, at.object)
    if base == nil then
      return nil
    end
    local owner = ctx.store:non_nil(current(f, base))
    if not ((owner.tag == "named")) or owner.value then
      return nil
    end
    local kind = owner.decl.kind
    if kind ~= "record" and kind ~= "class" and kind ~= "interface" then
      return nil
    end
    local list = member_types(ctx, owner, at.name)
    local m = list ~= nil and list[1] or nil
    if list == nil or m == nil or #list ~= 1 or m.method or m.mut then
      return nil
    end
    return { key = base.key .. "." .. at.name, declared = put_in(ctx, owner, m.type) }
  end
  return nil
end

--- The tests of a type: what Lua value it is, which strings, tables and tags it holds, and what a test of a place leaves of it.
local record Tests
  lua_kind: function(t: Type): string
  kinds_of: function(ctx: Ctx, t: Type): {string: boolean}?
  enum_strings: function(ctx: Ctx, t: Type): {string}?
  table_members: function(ctx: Ctx, t: Type): {Type}?
  tag_field: function(ctx: Ctx, list: {Type}): string?, {string}?
  tag_values: function(ctx: Ctx, m: Type, name: string): {string}?
  nil_of: function(ctx: Ctx, cur: Type): Type
  not_nil_of: function(ctx: Ctx, cur: Type): Type
  by_kind: function(ctx: Ctx, cur: Type, kind: string, keep: boolean): Type
  keep_is: function(ctx: Ctx, cur: Type, tested: Type): Type
  drop_is: function(ctx: Ctx, cur: Type, tested: Type): Type
  --- Adds the warning `code` on the tokens of `node`; none in a pass that reports nothing.
  warn: function(ctx: Ctx, code: Warnings.Code, node: Ast.Node, msg: string, fix: string)
  --- Reports `type(x) == "name"` where `type` never answers the name.
  type_name: function(ctx: Ctx, node: Ast.Binary)
  --- Reports `(x) is T` where `x` is a place, which the parentheses make a value.
  parenthesized: function(ctx: Ctx, node: Ast.IsTest)
end

function Tests.warn(ctx: Ctx, code: Warnings.Code, node: Ast.Node, msg: string, fix: string)
  if ctx.quiet > 0 then
    return
  end
  local b = base_of(node)
  Warnings.add(ctx.warnings, ctx.filename, ctx.tokens, code, b.first, b.last, msg, fix)
end

function Tests.type_name(ctx: Ctx, node: Ast.Binary)
  local left, right = peel(node.left), peel(node.right)
  local call: Ast.Call? = nil
  local name: Ast.String? = nil
  if (left.kind == "Call") and (right.kind == "String") then
    call, name = left, right
  elseif (right.kind == "Call") and (left.kind == "String") then
    call, name = right, left
  end
  if call == nil or name == nil then
    return
  end
  local callee = call.callee
  if not ((callee.kind == "Name")) or callee.text ~= "type" or #call.args ~= 1 then
    return
  end
  local answers = { "nil", "boolean", "number", "string", "table", "function", "thread", "userdata" }
  for _, each in ipairs(answers) do
    if each == name.value then
      return
    end
  end
  report(ctx, "type_name", name, "`type` never answers \"" .. name.value .. "\": it answers " ..
      table.concat(answers, ", ", 1, #answers - 1) .. " or " .. answers[#answers] .. ", so the test is always " ..
      (if node.op == "==" then "false" else "true" end),
    "compare with a name `type` answers; `math.type(x)` tells \"integer\" from \"float\", and `x is T` tests a type declared in the program")
end

function Tests.parenthesized(ctx: Ctx, node: Ast.IsTest)
  local written = node.value
  if not ((written.kind == "Paren")) then
    return
  end
  local inner = peel(written)
  if (inner.kind == "Name") or (inner.kind == "Field") then
    report(ctx, "paren_is", written, "`" .. text_of(ctx, written) .. " is ...` tests a value: the parentheses make " ..
        subject(ctx, inner) .. " no place, so the test narrows nothing",
      "write `" .. text_of(ctx, inner) .. " is " .. text_of(ctx, node.type) .. "` without the parentheses, so that the test narrows it")
  end
end

--- The kind of Lua value a value of type `t` is, or "" where the type does not say (`any`, a type variable, a union).
function Tests.lua_kind(t: Type): string
  local tag = t.tag
  if tag == "integer" or tag == "number" then
    return "number"
  elseif tag == "string" then
    return "string"
  elseif tag == "boolean" or tag == "true" or tag == "false" then
    return "boolean"
  elseif tag == "nil" then
    return "nil"
  elseif tag == "fn" then
    return "function"
  elseif tag == "array" or tag == "map" then
    return "table"
  elseif (t.tag == "named") then
    local kind = t.decl.kind
    if kind == "enum" then
      return "string"
    elseif kind == "userdata" then
      return "userdata"
    end
    return "table"
  end
  return ""
end

local LUA_KINDS <const>: {string} = { "nil", "number", "string", "boolean", "table", "function", "userdata" }

--- The kinds of Lua value a value of type `t` may be, or nil where it may be any.
function Tests.kinds_of(ctx: Ctx, t: Type): {string: boolean}?
  local out: mut {string: boolean} = {}
  for _, m in ipairs(members_of(ctx.store, t)) do
    local kind = Tests.lua_kind(m)
    if kind ~= "" then
      out[kind] = true
    elseif m.tag ~= "never" then
      return nil
    end
  end
  return out
end

--- The values of the enum a field of `m` is declared with, or nil where `m` has no such field or the field is `mut`.
function Tests.tag_values(ctx: Ctx, m: Type, name: string): {string}?
  if not ((m.tag == "named")) or m.value or (m.decl.kind ~= "record" and m.decl.kind ~= "class") then
    return nil
  end
  local field = plain_field(ctx, m, name)
  if field ~= nil and field.mut == true then
    return nil
  end
  local t = field ~= nil and field.type or nil
  local body = t ~= nil and (t.tag == "named") and t.decl.kind == "enum" and t.decl.body or nil
  return body ~= nil and body.values or nil
end

--- The strings a value of type `t` may be when `t` says no more of a string than the values of its enums, else nil.
function Tests.enum_strings(ctx: Ctx, t: Type): {string}?
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, m in ipairs(members_of(ctx.store, t)) do
    if Tests.lua_kind(m) == "string" then
      local body: Types.Body? = nil
      if (m.tag == "named") and m.decl.kind == "enum" then
        body = m.decl.body
      end
      if body == nil then
        return nil
      end
      for _, v in ipairs(body.values) do
        if not seen[v] then
          seen[v] = true
          out[#out + 1] = v
        end
      end
    end
  end
  table.sort(out)
  return #out > 0 and out or nil
end

--- The members of `t` that are tables, or nil where `t` may be a table of any kind (`any`, a type variable).
function Tests.table_members(ctx: Ctx, t: Type): {Type}?
  local out: mut {Type} = {}
  for _, m in ipairs(members_of(ctx.store, t)) do
    local kind = Tests.lua_kind(m)
    if kind == "" and m.tag ~= "never" then
      return nil
    elseif kind == "table" then
      out[#out + 1] = m
    end
  end
  return out
end

--- The field that tells the types of `list` apart: one every one declares with an enum, no value of which is in two of
--- them, and the values of the enums.
function Tests.tag_field(ctx: Ctx, list: {Type}): string?, {string}?
  local first = list[1]
  local body: Types.Body? = nil
  if first ~= nil and (first.tag == "named") then
    body = first.decl.body
  end
  if body == nil then
    return nil, nil
  end
  for _, f in ipairs(body.fields) do
    local values: mut {string} = {}
    local seen: mut {string: boolean} = {}
    local apart = true
    for _, m in ipairs(list) do
      local v = Tests.tag_values(ctx, m, f.name)
      if v == nil then
        apart = false
        break
      end
      for _, value in ipairs(v) do
        if seen[value] == true then
          apart = false
        end
        seen[value] = true
        values[#values + 1] = value
      end
    end
    if apart and #values > 0 then
      return f.name, values
    end
  end
  return nil, nil
end

--- Notes that the read `node` of a place declared `declared` has the type `narrowed`, for a run that checks it.
local function note_narrowed(ctx: Ctx, node: Ast.Node, declared: Type, narrowed: Type)
  if ctx.quiet > 0 then
    return
  end
  local after = Tests.kinds_of(ctx, narrowed)
  if after == nil then
    return
  end
  local before = Tests.kinds_of(ctx, declared)
  local taken: mut {string} = {}
  for _, kind in ipairs(LUA_KINDS) do
    if not after[kind] and (before == nil or before[kind]) then
      taken[#taken + 1] = kind
    end
  end
  -- An enum, a class or a tag the test narrowed to: what the declared type left a string or a table to be.
  local strings = Tests.enum_strings(ctx, narrowed)
  local was = Tests.enum_strings(ctx, declared)
  if strings ~= nil and was ~= nil and table.concat(strings, "\0") == table.concat(was, "\0") then
    strings = nil
  end
  local classes: {string}? = nil
  local tag: string? = nil
  local tags: {string}? = nil
  local now = Tests.table_members(ctx, narrowed)
  local old = Tests.table_members(ctx, declared)
  if now ~= nil and #now > 0 and (old == nil or #old > #now) then
    local names: mut {string} = {}
    for _, m in ipairs(now) do
      if (m.tag == "named") and m.decl.kind == "class" and #m.decl.names == 1 and m.decl.module == ctx.input.module and not m.value then
        names[#names + 1] = m.decl.name
      end
    end
    if #names == #now then
      classes = names
    end
    if old ~= nil then
      tag, tags = Tests.tag_field(ctx, now)
      if tag ~= nil then
        local field = tag
        for _, m in ipairs(old) do
          if Tests.tag_values(ctx, m, field) == nil then
            tag, tags = nil, nil
          end
        end
      end
    end
  end
  if #taken == 0 and strings == nil and classes == nil and tag == nil then
    return
  end
  local b = base_of(node)
  local tokens = ctx.tokens
  local first, last = b.first, math.max(b.first, b.last)
  local start = Lexer.offset(tokens, first)
  ctx.narrowed[start] = {
    id = b.id, offset = start, length = math.max(0, Lexer.stop(tokens, last) - start), text = text_of(ctx, node),
    taken = taken, strings = strings, classes = classes, tag = tag, tags = tags,
  }
end

--- `f` where the place is known to have the type `t`. A type no value has makes the edge unreachable, with the place
--- kept at it so that the code there reads it as `never` and reports nothing of it.
local function narrowed_flow(f: Flow.State, place: Place, t: Type): Flow.State
  if t.tag == "never" then
    return Flow.dead(Flow.narrow(f, place.key, t, place.declared))
  end
  return Flow.narrow(f, place.key, t, place.declared)
end

--- `f` where a test that the place is of type `t` holds. A test no value of the place can pass has been refused for
--- that (`compare_disjoint`, `is_disjoint`), so what follows it keeps what was known and reports nothing more.
local function when_true(f: Flow.State, place: Place, t: Type): Flow.State
  if t.tag == "never" then
    return f
  end
  return Flow.narrow(f, place.key, t, place.declared)
end

--- What a value of type `cur` is where a test says it is a `tested`: the members that are one, the tested type for a
--- member it is more specific than (`any` and an interface become the class tested), and nothing else.
function Tests.keep_is(ctx: Ctx, cur: Type, tested: Type): Type
  if cur.tag == "invalid" or tested.tag == "invalid" then
    return cur
  end
  local store = ctx.store
  local out: mut {Type} = {}
  local tested_members = members_of(store, tested)
  for _, m in ipairs(members_of(store, cur)) do
    if m.tag == "invalid" then
      out[#out + 1] = m
    elseif m.tag == "any" or (m.tag == "var") then
      for _, tm in ipairs(tested_members) do
        out[#out + 1] = tm
      end
    elseif below(ctx, m, tested) then
      out[#out + 1] = m
    else
      for _, tm in ipairs(tested_members) do
        if below(ctx, tm, m) then
          out[#out + 1] = tm
        end
      end
    end
  end
  return store:union(out)
end

--- What a value of type `cur` is where a test says it is no `tested`: the members that are not below it. `any`, an
--- interface and a type variable stay, since none is below a class.
function Tests.drop_is(ctx: Ctx, cur: Type, tested: Type): Type
  if cur.tag == "invalid" or tested.tag == "invalid" then
    return cur
  end
  local store = ctx.store
  local out: mut {Type} = {}
  for _, m in ipairs(members_of(store, cur)) do
    if m.tag == "invalid" or not below(ctx, m, tested) then
      out[#out + 1] = m
    end
  end
  return store:union(out)
end

--- What a value of type `cur` is where a test says it is nil.
function Tests.nil_of(ctx: Ctx, cur: Type): Type
  if cur.tag == "invalid" then
    return cur
  elseif nilable(cur) or cur.tag == "any" or (cur.tag == "var") then
    return ctx.nil_type
  end
  return ctx.store.never
end

--- What a value of type `cur` is where a test says it is not nil.
function Tests.not_nil_of(ctx: Ctx, cur: Type): Type
  if cur.tag == "invalid" or cur.tag == "any" then
    return cur
  end
  return ctx.store:non_nil(cur)
end

--- The members of `cur` that are of the Lua type `kind` (`type(x) == "string"`), or none of them where `keep` is false.
--- `any` becomes the type the name says, where there is one.
function Tests.by_kind(ctx: Ctx, cur: Type, kind: string, keep: boolean): Type
  local store = ctx.store
  local out: mut {Type} = {}
  for _, m in ipairs(members_of(store, cur)) do
    local k = Tests.lua_kind(m)
    if m.tag == "any" and keep then
      if kind == "string" then
        out[#out + 1] = store.string
      elseif kind == "number" then
        out[#out + 1] = store.number
      elseif kind == "boolean" then
        out[#out + 1] = store.boolean
      elseif kind == "nil" then
        out[#out + 1] = ctx.nil_type
      else
        out[#out + 1] = m
      end
    elseif k == "" then
      out[#out + 1] = m
    elseif (k == kind) == keep then
      out[#out + 1] = m
    end
  end
  return store:union(out)
end

--- The edges of `field == "lit"` for a field that tells the members of a union of records apart. The true edge keeps
--- the members whose tag enum still has the value, each with all its values. The false edge notes that the tag is not
--- the value, and drops a member once every value of its enum has been noted on the path, so that a chain of tests
--- over the values of a member leaves the rest.
local function tag_edges(ctx: Ctx, f: Flow.State, field: Ast.Field, lit: string): Flow.State, Flow.State
  local p = place_of(ctx, f, field.object)
  if p == nil then
    return f, f
  end
  local store = ctx.store
  -- The key of the fact that a test showed the tag of the place is not `value` in the field being tested while it is the
  -- member `m`, told by its place among the members of the declared type. The fact is a path from the place, so an
  -- assignment to the place or to what it is read from takes it away, and a join keeps it only where both paths have it.
  -- A member that is not one of the declared type's (a narrowing is a union of the declared members, so none is believed
  -- to be) has no key, "": nothing is noted of it and nothing is read, so it stays in both branches and keeps every value.
  local whole = members_of(store, store:non_nil(p.declared))
  -- The place of each by its id (a map is not keyed by a type), made once for the walks over the members below.
  local placed: mut {integer: integer} = {}
  for i, member in ipairs(whole) do
    if placed[member.id] == nil then
      placed[member.id] = i
    end
  end
  local function tag_key(m: Type, value: string): string
    local i = placed[m.id]
    if i == nil or whole[i] ~= m then
      return ""
    end
    return p.key .. ".#" .. tostring(i) .. "." .. field.name .. "=" .. value
  end
  local members = members_of(store, store:non_nil(current(f, p)))
  local yes: mut {Type} = {}
  local no: mut {Type} = {}
  local noted: mut {Type} = {}
  for _, m in ipairs(members) do
    local values = Tests.tag_values(ctx, m, field.name)
    if values == nil then
      yes[#yes + 1] = m
      no[#no + 1] = m
    else
      local left = 0
      local has = false
      for _, v in ipairs(values) do
        local key = tag_key(m, v)
        if key == "" or f.facts[key] == nil then
          left = left + 1
          has = has or v == lit
        end
      end
      if has then
        yes[#yes + 1] = m
      end
      if not has or left > 1 then
        no[#no + 1] = m
      end
      if has and left > 1 and tag_key(m, lit) ~= "" then
        noted[#noted + 1] = m
      end
    end
  end
  local after = narrowed_flow(f, p, store:union(no))
  for _, m in ipairs(noted) do
    after = Flow.narrow(after, tag_key(m, lit), store.boolean, store.integer)
  end
  return when_true(f, p, store:union(yes)), after
end

--- The edges of `type(x) == "kind"`.
local function type_edges(ctx: Ctx, f: Flow.State, call: Ast.Call, kind: string): Flow.State, Flow.State
  local callee = call.callee
  local subject_arg = call.args[1]
  if not ((callee.kind == "Name")) or callee.binding ~= nil or callee.text ~= "type" or #call.args ~= 1 or subject_arg == nil then
    return f, f
  end
  local p = place_of(ctx, f, subject_arg)
  if p == nil then
    return f, f
  end
  local cur = current(f, p)
  return narrowed_flow(f, p, Tests.by_kind(ctx, cur, kind, true)), narrowed_flow(f, p, Tests.by_kind(ctx, cur, kind, false))
end

--- The edges of `a == b`.
local function compare_edges(ctx: Ctx, f: Flow.State, node: Ast.Binary): Flow.State, Flow.State
  local l, r = peel(node.left), peel(node.right)
  local yes, no = f, f
  if (r.kind == "Nil") or (l.kind == "Nil") then
    local p = place_of(ctx, f, (r.kind == "Nil") and l or r)
    if p ~= nil then
      local cur = current(f, p)
      yes, no = when_true(f, p, Tests.nil_of(ctx, cur)), narrowed_flow(f, p, Tests.not_nil_of(ctx, cur))
    end
  elseif (r.kind == "String") and (l.kind == "Call") then
    yes, no = type_edges(ctx, f, l, r.value)
  elseif (l.kind == "String") and (r.kind == "Call") then
    yes, no = type_edges(ctx, f, r, l.value)
  elseif (r.kind == "String") and (l.kind == "Field") then
    yes, no = tag_edges(ctx, f, l, r.value)
  elseif (l.kind == "String") and (r.kind == "Field") then
    yes, no = tag_edges(ctx, f, r, l.value)
  end
  if node.op == "==" then
    return yes, no
  end
  return no, yes
end

--- The edges of a name or a field used as a condition: an optional is not nil when true, and nil when false unless
--- what it holds may be false.
local function truthy_edges(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State, Flow.State
  local p = place_of(ctx, f, e)
  if p == nil then
    return f, f
  end
  local cur = current(f, p)
  if not nilable(cur) then
    return f, f
  end
  local store = ctx.store
  local kept = store:non_nil(cur)
  local falsy = ctx.nil_type
  for _, m in ipairs(members_of(store, kept)) do
    if is_bool(m) then
      falsy = cur
    end
  end
  return narrowed_flow(f, p, kept), narrowed_flow(f, p, falsy)
end

--- The edges of a test that the place `p` is a `tested`. `is table` tests that it is a table of any shape, the standard
--- library's record `table` being the type of its functions and no type of a value: it narrows as `type(v) == "table"`.
local function is_edges(ctx: Ctx, f: Flow.State, p: Place, tested: Type): Flow.State, Flow.State
  local cur = current(f, p)
  local library = ctx.program.globals["table"]
  if (tested.tag == "named") and library ~= nil and tested.decl == library.decl then
    return when_true(f, p, Tests.by_kind(ctx, cur, "table", true)), narrowed_flow(f, p, Tests.by_kind(ctx, cur, "table", false))
  end
  return when_true(f, p, Tests.keep_is(ctx, cur, tested)), narrowed_flow(f, p, Tests.drop_is(ctx, cur, tested))
end

--- The edges of the condition `e` in the state `f`: the states where it is true and where it is false. The test of a
--- place narrows it; `not`, `and` and `or` combine what their operands say, the right operand under the left's edge;
--- a call that narrows an argument says it, and a literal `true` or `false` leaves one edge unreachable.
edges = function(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State, Flow.State
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
      return compare_edges(ctx, f, at)
    end
  elseif (at.kind == "IsTest") then
    local p = place_of(ctx, f, at.value)
    local tested = ctx.lowered.types[at.type.id]
    if p ~= nil and tested ~= nil then
      return is_edges(ctx, f, p, tested)
    end
  elseif (at.kind == "Name") or (at.kind == "Field") then
    return truthy_edges(ctx, f, at)
  elseif (at.kind == "Call") or (at.kind == "MethodCall") then
    local g = ctx.guards[at.id]
    local p = g ~= nil and place_of(ctx, f, g.arg) or nil
    if g ~= nil and p ~= nil then
      return is_edges(ctx, f, p, g.to)
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

local ARITHMETIC <const>: {string: boolean} = { ["+"] = true, ["-"] = true, ["*"] = true, ["%"] = true, ["//"] = true }
local DIVISION <const>: {string: boolean} = { ["/"] = true, ["^"] = true }
local BITWISE <const>: {string: boolean} = { ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true }
local ORDERED <const>: {string: boolean} = { ["<"] = true, [">"] = true, ["<="] = true, [">="] = true }

--- `a == b` and `a ~= b`: both sides overlap, else the test is dead.
local function equality(ctx: Ctx, node: Ast.Binary, left: Type, right: Type)
  Tests.type_name(ctx, node)
  if not overlaps(ctx, left, right) then
    report(ctx, "compare_disjoint", node, subject(ctx, node.left) .. " is " .. tq(ctx, left) .. " and " ..
        subject(ctx, node.right) .. " is " .. tq(ctx, right) .. ", which share no value: the test is never " ..
        (if node.op == "==" then "true" else "false" end),
      "compare values of one type, or remove the test", { show(ctx, left), show(ctx, right) })
  end
end

--- `a < b` and the rest: two numbers or two strings.
local function ordered(ctx: Ctx, node: Ast.Binary, left: Type, right: Type)
  local l, r = left, right
  local function number(t: Type): boolean
    return t.tag == "integer" or t.tag == "number"
  end
  if l.tag == "invalid" or r.tag == "invalid" or l.tag == "never" or r.tag == "never" then
    return
  end
  if number(l) and number(r) or is_text(l) and is_text(r) then
    return
  end
  local fix = "compare two numbers or two strings: " .. quoted(node.op) .. " converts nothing"
  if number(l) or is_text(l) then
    local wanted = if number(l) then "a number" else "a string" end
    if nilable(r) or r.tag == "any" or (r.tag == "var") then
      bad_operand(ctx, node.right, r, node.op, wanted .. ", as its left operand is", fix)
    else
      bad_operand(ctx, node.right, r, node.op, wanted .. ", as its left operand is", fix)
    end
  elseif number(r) or is_text(r) then
    bad_operand(ctx, node.left, l, node.op, (if number(r) then "a number" else "a string" end) .. ", as its right operand is", fix)
  else
    bad_operand(ctx, node.left, l, node.op, "numbers or strings", fix)
  end
end

--- `a or b`: both booleans, or a `T?` replaced by a default of its own type.
local function disjunction(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local store = ctx.store
  local left_kind = if left.tag == "invalid" then "bad" else condition_kind(ctx, node.left, left) end
  if left_kind == "bad" then
    local _ = expr(ctx, node.right, nil)
    return ctx.invalid
  end
  if left_kind == "bool" then
    local right = expr(ctx, node.right, expected)
    if is_bool(right) or right.tag == "never" or right.tag == "invalid" then
      return store.boolean
    end
    report(ctx, "or_mix", node, subject(ctx, node.left) .. " is a boolean and " .. subject(ctx, node.right) .. " is " ..
        tq(ctx, right) .. ": `or` of a boolean and another type answers either",
      "write the test: `if " .. text_of(ctx, node.left) .. " then ... else ... end`, or make both operands booleans",
      { show(ctx, left), show(ctx, right) })
    return ctx.invalid
  end
  local kept = store:non_nil(left)
  -- An enum is not the position of a string: `x or "lit"` joins to `string`.
  local right: Type
  if kept.tag == "never" or has_enum(ctx, kept) then
    right = expr(ctx, node.right, expected)
  else
    right = expr(ctx, node.right, kept)
  end
  if right.tag == "invalid" then
    return right
  end
  local both = join(ctx, { kept, right })
  if both == nil then
    report(ctx, "or_mix", node, subject(ctx, node.left) .. " is " .. tq(ctx, left) .. " and " .. subject(ctx, node.right) ..
        " is " .. tq(ctx, right) .. ", which have no common type for the default",
      "give a default of " .. tq(ctx, kept) .. ", or write the test: `if " .. text_of(ctx, node.left) .. " == nil then " ..
        "... end`", { show(ctx, left), show(ctx, right) })
    return ctx.invalid
  end
  return both
end

--- `a and b`: both booleans, or a `T?` guarding a value, which is optional.
local function conjunction(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local store = ctx.store
  local left_kind = if left.tag == "invalid" then "bad" else condition_kind(ctx, node.left, left) end
  if left_kind == "bad" then
    local _ = expr(ctx, node.right, nil)
    return ctx.invalid
  end
  local right = expr(ctx, node.right, left_kind == "bool" and expected or nil)
  if right.tag == "invalid" then
    return right
  end
  if left_kind == "bool" then
    if is_bool(right) or right.tag == "never" then
      return store.boolean
    end
    local parent = ctx.ternaries[node.id]
    if parent ~= nil then
      report(ctx, "and_ternary", parent, subject(ctx, parent) .. " is a ternary: it answers " .. subject(ctx, parent.right) ..
          " when " .. subject(ctx, node.right) .. " is false or nil",
        "use the `if` expression: `if " .. text_of(ctx, node.left) .. " then " .. text_of(ctx, node.right) .. " else " ..
          text_of(ctx, parent.right) .. " end`")
      return ctx.invalid
    end
    report(ctx, "or_mix", node, subject(ctx, node.left) .. " is a boolean and " .. subject(ctx, node.right) .. " is " ..
        tq(ctx, right) .. ": `and` answers the left operand when it is false",
      "write the test: `if " .. text_of(ctx, node.left) .. " then ... end`, or make both operands booleans",
      { show(ctx, left), show(ctx, right) })
    return ctx.invalid
  end
  return store:optional(right)
end

--- `a and b` and `a or b` whose left operand has type `left`: the right operand is evaluated under the state where the
--- left is true (`and`) or false (`or`), and what follows has the states of both ways out met: the left's short cut and
--- the right operand's end, which a call that never returns does not reach.
local function logical(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local is_and = node.op == "and"
  local ly, ln = edges(ctx, ctx.flow, node.left)
  local into, short = ly, ln
  if not is_and then
    into, short = ln, ly
  end
  ctx.flow = into
  local result: Type
  if is_and then
    result = conjunction(ctx, node, left, expected)
  else
    result = disjunction(ctx, node, left, expected)
  end
  local after = ctx.flow
  local ry, rn = edges(ctx, after, node.right)
  local yes, no = ry, merge(ctx, ln, rn)
  if not is_and then
    yes, no = merge(ctx, ly, ry), rn
  end
  local met = merge(ctx, short, after)
  ctx.edges[node.id] = { post = met, yes = yes, no = no }
  ctx.flow = met
  return result
end

--- A binary expression whose left operand has type `left`.
local function binary(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local store = ctx.store
  local op = node.op
  if op == "or" or op == "and" then
    return logical(ctx, node, left, expected)
  end
  local right = expr(ctx, node.right, (op == "==" or op == "~=") and left or nil)
  if op == ".." then
    local l, r = string_operand(ctx, node.left, left), string_operand(ctx, node.right, right)
    return (l and r) and store.string or ctx.invalid
  elseif ARITHMETIC[op] or DIVISION[op] then
    local l, r = arithmetic_operand(ctx, node.left, left, op), arithmetic_operand(ctx, node.right, right, op)
    if l == 0 or r == 0 then
      return ctx.invalid
    end
    return (l == 1 and r == 1 and ARITHMETIC[op]) and store.integer or store.number
  elseif BITWISE[op] then
    local l, r = integer_operand(ctx, node.left, left, op), integer_operand(ctx, node.right, right, op)
    return (l and r) and store.integer or ctx.invalid
  elseif ORDERED[op] then
    ordered(ctx, node, left, right)
    return store.boolean
  end
  local left_node = node.left
  if (left_node.kind == "String") and has_enum(ctx, right) then
    local _ = string_literal(ctx, left_node, right)
  end
  equality(ctx, node, left, right)
  return store.boolean
end

--- A unary expression whose operand has type `operand`.
local function unary(ctx: Ctx, node: Ast.Unary, operand: Type): Type
  local op = node.op
  if op == "not" then
    local _ = condition_kind(ctx, node.operand, operand)
    return ctx.store.boolean
  elseif op == "#" then
    return length_operand(ctx, node.operand, operand) and ctx.store.integer or ctx.invalid
  elseif op == "-" then
    local c = arithmetic_operand(ctx, node.operand, operand, "-")
    return c == 1 and ctx.store.integer or c == 2 and ctx.store.number or ctx.invalid
  end
  return integer_operand(ctx, node.operand, operand, "~") and ctx.store.integer or ctx.invalid
end

--- Whether a value of type `value` may be a `tested`: some member of one is below some member of the other (a class
--- below the interface the value is of, a number below `number`), as for `==`. `any`, `invalid` and a type variable,
--- which the code around may instantiate as the type, overlap everything.
local function testable(ctx: Ctx, value: Type, tested: Type): boolean
  if value == tested or value.tag == "any" or tested.tag == "any" or value.tag == "invalid" or tested.tag == "invalid" or
      value.tag == "never" or tested.tag == "never" then
    return true
  end
  local store = ctx.store
  for _, x in ipairs(members_of(store, value)) do
    for _, y in ipairs(members_of(store, tested)) do
      if x == y or (x.tag == "var") or (y.tag == "var") or below(ctx, x, y) or below(ctx, y, x) then
        return true
      end
    end
  end
  return false
end

--- `e is T`: a test of a run-time tag.
local function is_test(ctx: Ctx, node: Ast.IsTest, value: Type): Type
  local store = ctx.store
  local tested = ctx.lowered.types[node.type.id] or ctx.invalid
  if tested.tag == "invalid" or value.tag == "invalid" then
    return store.boolean
  end
  Tests.parenthesized(ctx, node)
  local function refuse(why: string)
    report(ctx, "is_on_record", node, "`is " .. show(ctx, tested) .. "` cannot be told by a run-time tag: " .. why,
      "test a tag (`x.kind == \"...\"`), declare a class, or validate the data with a [`cosmic.shape`] validator",
      { show(ctx, tested) })
  end
  local library = ctx.program.globals["table"]
  if (tested.tag == "named") and library ~= nil and tested.decl == library.decl then
    return store.boolean
  end
  local before = #ctx.errors
  if (tested.tag == "named") and tested.decl.kind ~= "enum" and tested.decl.kind ~= "class" then
    local word = KIND_WORDS[tested.decl.kind] or "type"
    refuse((if word == "interface" then "an " else "a " end) .. word .. " leaves nothing to test")
  elseif (tested.tag == "named") and tested.decl.kind == "class" and out_of_reach(ctx, tested.decl) ~= "" then
    report(ctx, "class_scope", node, "`is " .. show(ctx, tested) .. "` tests the metatable of " ..
        out_of_reach(ctx, tested.decl),
      reach_fix(ctx, tested.decl, "test in " .. quoted(tested.decl.module) .. " with a function of the class (`function " ..
          tested.decl.name .. ".owns(v: any): boolean`), and call it here"), { show(ctx, tested) })
  elseif (tested.tag == "named") and tested.decl.kind == "class" and #tested.args > 0 then
    refuse("the metatable tells the class and not its type arguments")
  elseif (tested.tag == "fn") then
    refuse("a function type is tested as `function` and its parameters go unchecked")
  elseif value.tag == "any" and ((tested.tag == "array") or (tested.tag == "map") or (tested.tag == "union")) then
    refuse("the tag says `table` and the contents of untrusted data go unchecked")
  elseif (tested.tag == "array") or (tested.tag == "map") then
    refuse("the tag says `table` and the elements go unchecked")
  end
  -- A test the rules refuse is reported once, for that.
  if #ctx.errors == before and not testable(ctx, value, tested) then
    report(ctx, "is_disjoint", node, subject(ctx, node) .. " is always false: " .. subject(ctx, node.value) .. " is " ..
        tq(ctx, value) .. ", and no value of it is " .. tq(ctx, tested),
      "this test is always false: remove it and the branch it guards, or test a type that " .. subject(ctx, node.value) ..
        " can have (" .. tq(ctx, value) .. ")", { show(ctx, value), show(ctx, tested) })
  end
  return store.boolean
end

--- An `if` expression: conditions, and arms with a common type. Each arm is evaluated under the state where its
--- condition holds and those before it do not.
local function if_expression(ctx: Ctx, node: Ast.IfExp, expected: Type?): Type
  local types: mut {Type} = {}
  local ends: mut {Flow.State} = {}
  for _, arm in ipairs(node.arms) do
    local _ = condition(ctx, arm.cond)
    local yes, no = edges(ctx, ctx.flow, arm.cond)
    ctx.flow = yes
    types[#types + 1] = expr(ctx, arm.value, expected)
    ends[#ends + 1] = ctx.flow
    ctx.flow = no
  end
  types[#types + 1] = expr(ctx, node.else_value, expected)
  ends[#ends + 1] = ctx.flow
  ctx.flow = merge_all(ctx, ends)
  local both = join(ctx, types)
  if both == nil then
    if expected ~= nil and expected.tag ~= "any" then
      -- No common type, but each arm may be what the position wants.
      local ok = true
      for i, arm in ipairs(node.arms) do
        ok = expect(ctx, arm.value, types[i], expected, " as an arm of this `if`") and ok
      end
      local _ = expect(ctx, node.else_value, types[#types], expected, " as an arm of this `if`")
      return expected
    end
    report(ctx, "arms_differ", node, "the arms of this `if` have no common type: " .. listed(type_names(ctx, types)),
      "type the result: `local name: " .. show(ctx, types[1]) .. " = if ... end`, or make the arms one type")
    return ctx.invalid
  end
  return both
end

-- Functions ------------------------------------------------------------------------------------

local block: function(ctx: Ctx, b: Ast.Block)
local stats: function(ctx: Ctx, b: Ast.Block)

local function rtype_base(item: Ast.RType): Ast.Base
  return item
end

--- The return alternatives a written return list stands for, from the types the lowering gave its items.
local function alts_of_rets(ctx: Ctx, rets: Ast.Rets): {Alt}
  local alts: mut {Alt} = {}
  for _, list in ipairs(rets.lists) do
    local alt: Alt = { items = {} }
    local never = false
    for i, item in ipairs(list) do
      local t = ctx.store.boolean
      if not ((item.kind == "Narrows")) then
        t = ctx.lowered.types[rtype_base(item).id] or ctx.invalid
      end
      if t.tag == "never" then
        never = true
      elseif rets.variadic and i == #list then
        alt.tail = t
      else
        alt.items[#alt.items + 1] = t
      end
    end
    if not never then
      alts[#alts + 1] = alt
    end
  end
  return alts
end

--- The one function type of `expected`, or nil: the type itself, or the function of an optional.
local function expected_function(ctx: Ctx, expected: Type?): Fn?
  if expected == nil then
    return nil
  end
  local t = ctx.store:non_nil(expected)
  if (t.tag == "fn") and #t.tparams == 0 then
    return t
  end
  return nil
end

--- The type of the function written as `fn`. Its parameters are typed by its annotations, and by `expected` where a
--- literal leaves one out; a return list it leaves out is the one `expected` has. A parameter with neither is
--- `invalid` and reported.
local function function_type(ctx: Ctx, fn: Ast.Fn, expected: Type?, name: string): Type
  local ex = expected_function(ctx, expected)
  local lowered = ctx.lowered.types[fn.id]
  if lowered ~= nil and (fn.rets ~= nil or ex == nil) then
    return lowered
  end
  local params: mut {Types.Param} = {}
  local rest: Type? = nil
  local ex_rest = ex ~= nil and ex.rest or nil
  for _, p in ipairs(fn.params) do
    local given = p.type
    local written = given ~= nil and ctx.lowered.types[given.id] or nil
    local j = #params + 1
    local t = ctx.invalid
    local omittable = p.optional
    if written ~= nil then
      t = written
    elseif not p.variadic and ex ~= nil and ex.params[j] ~= nil then
      t = ex.params[j].type
      omittable = omittable or ex.params[j].omittable == true
    elseif p.variadic and ex_rest ~= nil then
      t = ex_rest
    else
      if ctx.lenient == 0 then
        local binding = p.name
        report(ctx, "param_untyped", p, "the parameter " .. quoted(binding ~= nil and binding.name or "...") .. " of " ..
            name .. " has no type, and no function type is expected here to give it one",
          "write the type: `" .. (binding ~= nil and binding.name or "...") .. ": T`; a function literal passed " ..
            "where a function type is expected takes its parameter types from it")
      end
    end
    if p.variadic then
      rest = t
    else
      params[j] = { type = t, omittable = omittable }
    end
  end
  local alts: {Alt}? = nil
  local written_rets = fn.rets
  if written_rets ~= nil then
    alts = alts_of_rets(ctx, written_rets)
  elseif ex ~= nil then
    alts = ex.rets
  end
  return ctx.store:fn({ params = params, rest = rest, rets = alts })
end

--- The lists of values `alts` answers, as a program writes them.
local function lists_text(ctx: Ctx, alts: {Alt}): string
  local lists: mut {string} = {}
  for i, alt in ipairs(alts) do
    local items: mut {string} = {}
    for j, t in ipairs(alt.items) do
      items[j] = show(ctx, t)
    end
    local tail = alt.tail
    if tail ~= nil then
      items[#items + 1] = show(ctx, tail) .. "..."
    end
    lists[i] = "(" .. table.concat(items, ", ") .. ")"
  end
  return table.concat(lists, " | ")
end

--- Whether a function that answers `alts` may return no value: one of its lists is empty.
local function may_end(alts: {Alt}): boolean
  for _, alt in ipairs(alts) do
    if #alt.items == 0 then
      return true
    end
  end
  return false
end

--- The type of the place `key` in `f`: what it was narrowed to, else `declared`.
local function fact_type(f: Flow.State, key: string, declared: Type): Type
  local fact = f.facts[key]
  if fact ~= nil then
    return fact.type
  end
  return declared
end

--- Checks that the function being checked makes good the narrowing it declares at `node`, a `return` or its end. A
--- function declared `v is T` answers true only where `v` is a `T` and false only where it is not: the edges of the
--- value returned say so. One declared `asserts v is T` returns only where `v` is a `T`.
local function narrows_proved(ctx: Ctx, node: Ast.Node, value: Ast.Exp?)
  local frame = ctx.frames[#ctx.frames]
  local nr = frame.narrows
  local declared = frame.narrowed_type
  if nr == nil or declared == nil or ctx.quiet > 0 or not ctx.flow.live then
    return
  end
  local key = id_key(ctx, frame.narrowed_id)
  local want = nr.to
  local name = frame.narrowed_name
  if nr.asserts then
    local got = fact_type(ctx.flow, key, declared)
    if not below(ctx, got, want) then
      report(ctx, "narrows_unproved", node, "this function is declared `asserts " .. name .. " is " .. show(ctx, want) ..
          "`, and here it returns with " .. quoted(name) .. " still " .. tq(ctx, got),
        "test the parameter and stop where it is not " .. tq(ctx, want) .. " (`if not (v is T) then error(...) end`), or " ..
          "declare the narrowing the test proves", { show(ctx, got), show(ctx, want) })
    end
    return
  end
  if value == nil then
    return
  end
  local yes, no = edges(ctx, ctx.flow, value)
  local got = fact_type(yes, key, declared)
  if yes.live and not below(ctx, got, want) then
    report(ctx, "narrows_unproved", node, "this function is declared `" .. name .. " is " .. show(ctx, want) ..
        "`, and " .. subject(ctx, value) .. " does not show it when true: " .. quoted(name) .. " is then " .. tq(ctx, got),
      "return a test that decides " .. tq(ctx, want) .. " (`return v is T`, `return v.kind == \"...\"`), or declare the " ..
        "function `boolean`", { show(ctx, got), show(ctx, want) })
    return
  end
  local rest = Tests.drop_is(ctx, declared, want)
  local left = fact_type(no, key, declared)
  if no.live and not below(ctx, left, rest) then
    report(ctx, "narrows_unproved", node, "this function is declared `" .. name .. " is " .. show(ctx, want) ..
        "`, and " .. subject(ctx, value) .. " does not show it is not " .. tq(ctx, want) .. " when false: " ..
        quoted(name) .. " is then " .. tq(ctx, left),
      "return a test that decides " .. tq(ctx, want) .. " both ways (`return v is T`), or declare the function " ..
        "`boolean`", { show(ctx, left), show(ctx, rest) })
  end
end

--- The fix for the local `name` of type `t` that is read before it is assigned. A function declared ahead for a
--- function that calls it before it is defined is the functions of a record, which one body may call before another is
--- defined.
local function assign_fix(ctx: Ctx, name: string, t: Type, own: boolean): string
  if (t.tag == "fn") and own then
    return "declare " .. quoted(name) .. " where it is defined, `local function " .. name .. "(...)`, which a function " ..
      "may call itself in"
  elseif (t.tag == "fn") then
    return "define " .. quoted(name) .. " before the function that names it is made, or make the functions that call " ..
      "each other the functions of a record declared first (`local record Walk end`, `function Walk.visit(...)`)"
  end
  return "assign " .. quoted(name) .. " on every path before this read, give it a value where it is declared (`local " ..
    name .. ": " .. show(ctx, t) .. " = ...`), or declare it `" .. show(ctx, ctx.store:optional(t)) .. "`, which is nil " ..
    "until assigned and is checked where it is used"
end

--- Notes that making the function `fn_id` reads each local of the code around it that it names, and reports one that no
--- path has assigned yet.
local function read_at_creation(ctx: Ctx, fn_id: integer, whole: Ast.Node)
  local list = ctx.reads[fn_id]
  if list == nil or ctx.flow.unsets == 0 then
    return
  end
  local tokens = ctx.tokens
  for _, v in ipairs(list) do
    if ctx.flow.unset[v.id] then
      local t = ctx.vars[v.id]
      report(ctx, "not_assigned", whole, "this function names " .. quoted(v.name) .. ", which no path has assigned yet, and " ..
          "making a function reads what it names",
        t ~= nil and assign_fix(ctx, v.name, t, ctx.assigning[v.id] == true) or "assign " .. quoted(v.name) .. " before this function is made",
        { t ~= nil and show(ctx, t) or "" },
        { y = Lexer.y(tokens, v.declared), x = Lexer.x(tokens, v.declared), offset = Lexer.offset(tokens, v.declared),
          length = Lexer.length(tokens, v.declared) })
      ctx.flow = Flow.assigned(ctx.flow, v.id)
    end
  end
end

--- Checks a function body: its parameters are the variables of the types in `ft`, its `return`s are checked against
--- `ft`'s return list. `names` are the type parameters of a generic function, for display. The body starts from the
--- facts of the code around it that hold inside it ([`Flow.State`]'s `enter`), and a function that answers values
--- reaches its end only where the flow does not.
local function function_body(ctx: Ctx, params: {Ast.Param}, body: Ast.Block, ft: Type, names: {string}, whole: Ast.Node,
                             declared: boolean, fn_id: integer, owner: string)
  read_at_creation(ctx, fn_id, whole)
  if ctx.quiet > 0 then
    -- A pass that is settling a loop reports nothing, and a function's body changes nothing of the code around it.
    return
  end
  local f: Fn? = (ft.tag == "fn") and ft or nil
  local generic = f ~= nil and #f.tparams > 0
  if generic and f ~= nil then
    ctx.judge:enter(f.tparams)
    ctx.binders[#ctx.binders + 1] = names
    ctx.bounds[#ctx.bounds + 1] = f.tparams
  end
  local j = 0
  local narrows: Types.Narrows? = nil
  local alts: {Alt} = f ~= nil and f.rets or unknown_lists(ctx)
  if #alts == 1 and alts[1].narrows ~= nil then
    narrows = alts[1].narrows
  end
  local narrowed_id = 0
  local narrowed_name = ""
  local narrowed_type: Type? = nil
  for _, p in ipairs(params) do
    if not p.variadic then
      j = j + 1
      local binding = p.name
      if binding ~= nil then
        ctx.vars[binding.id] = f ~= nil and f.params[j] ~= nil and f.params[j].type or ctx.invalid
        local given: Types.Param? = nil
        if f ~= nil then
          given = f.params[j]
        end
        -- Only a type the program writes is a declaration to hold a value to: a function literal's parameter that takes
        -- its type from the context (`table.sort(t, function(a, b) ... end)`) declares none.
        if given ~= nil and p.type ~= nil and given.type.tag ~= "any" and binding.name ~= "self" then
          ctx.boundaries[binding.id] = {
            id = fn_id, role = "parameter", name = binding.name, param = j, owner = owner, type = given.type,
            optional = p.optional or given.omittable == true, at = Lexer.offset(ctx.tokens, whole.first),
          }
        end
        if narrows ~= nil and narrows.param == j then
          narrowed_id, narrowed_name, narrowed_type = binding.id, binding.name, ctx.vars[binding.id]
          local assigned = ctx.scoped.vars[binding.id]
          if assigned ~= nil and assigned.assigned then
            report(ctx, "narrows_unproved", whole, "this function assigns " .. quoted(binding.name) .. ", the parameter it narrows, so " ..
                "what its body shows is about the new value and not the argument",
              "do not assign the parameter: copy it to a local and assign that")
          end
        end
      end
    end
  end
  local rest: Type? = ctx.invalid
  if f ~= nil then
    rest = f.rest
  end
  ctx.frames[#ctx.frames + 1] = {
    alts = alts, rest = rest, chunk = false, declared = declared, narrows = narrows, narrowed_id = narrowed_id,
    narrowed_name = narrowed_name, narrowed_type = narrowed_type,
  }
  local saved = ctx.lenient
  ctx.lenient = 0
  local outer_within = ctx.within
  ctx.within = fn_id
  local outer, outer_loops = ctx.flow, ctx.loops
  ctx.flow, ctx.loops = Flow.enter(outer, ctx.unfixed[fn_id]), {}
  local outer_unfixed = ctx.unfixed_now
  local unfixed_now: mut {integer: boolean} = {}
  for id in pairs(outer_unfixed) do
    unfixed_now[id] = true
  end
  for id in pairs(ctx.unfixed[fn_id] or {}) do
    unfixed_now[id] = true
  end
  ctx.unfixed_now = unfixed_now
  block(ctx, body)
  ctx.unfixed_now = outer_unfixed
  if ctx.flow.live then
    local last = body.stats[#body.stats]
    local at: Ast.Node = last ~= nil and last or whole
    if f ~= nil and not may_end(alts) then
      if #alts == 0 then
        report(ctx, "missing_return", at, "this function is declared `never`, and control can reach its end",
          "end every path with `error(...)` or a call of a function that never returns, or declare the return list the " ..
            "function answers")
      else
        local lists = lists_text(ctx, alts)
        report(ctx, "missing_return", at, "control can reach the end of this function, which answers " .. lists .. ", with no " ..
            "`return`",
          "end every path with a `return` of " .. lists .. " (or `error(...)`), or declare the function without a return list",
          { lists })
      end
    elseif narrows ~= nil then
      narrows_proved(ctx, at, nil)
    end
  end
  ctx.flow, ctx.loops = outer, outer_loops
  ctx.lenient = saved
  ctx.within = outer_within
  ctx.frames[#ctx.frames] = nil
  if generic then
    ctx.judge:leave()
    ctx.binders[#ctx.binders] = nil
    ctx.bounds[#ctx.bounds] = nil
  end
end

--- A function literal: its type, and its body checked.
local function function_literal(ctx: Ctx, e: Ast.FunctionLit, expected: Type?): Type
  local ft = function_type(ctx, e.fn, expected, "this function")
  function_body(ctx, e.fn.params, e.fn.body, ft, {}, e, e.fn.rets ~= nil, e.fn.id, "function")
  if ctx.load.waiting > 0 and ctx.load.given[e.id] ~= true then
    LoadOrder.mention(ctx.load, ctx.within, e, LoadOrder.of_function(e.fn.id, "the function written here"))
  end
  return ft
end

-- Calls --------------------------------------------------------------------------------------------

--- Whether an argument is a literal, whose type depends on the position it stands in.
local function is_literal(e: Ast.Exp): boolean
  local at = peel(e)
  if (at.kind == "IfExp") then
    -- Its type is its arms': a literal where one of them is.
    for _, arm in ipairs(at.arms) do
      if is_literal(arm.value) then
        return true
      end
    end
    return is_literal(at.else_value)
  end
  return (at.kind == "Table") or (at.kind == "FunctionLit") or (at.kind == "String") or (at.kind == "Boolean")
end

local function plural(n: integer, word: string): string
  return n .. " " .. word .. (if n == 1 then "" else "s" end)
end

--- Whether a function literal takes the arguments a call of `g` passes: every count from the required parameters of
--- `g` to all of them (and any more where it has a rest parameter), as the relation meets a call's argument list
--- exactly. A parameter the literal leaves untyped takes its type and whether it may be omitted from the position, so
--- the position has to have it, and it is never the one that requires an argument.
local function arguments_fit(lit: Ast.FunctionLit, g: Fn): boolean
  local total, last_required, last_untyped, rest, rest_untyped = 0, 0, 0, false, false
  for _, p in ipairs(lit.fn.params) do
    if p.variadic then
      rest = true
      rest_untyped = p.type == nil
    else
      total = total + 1
      if p.type == nil then
        last_untyped = total
      elseif not p.optional then
        last_required = total
      end
    end
  end
  if last_untyped > #g.params or (rest_untyped and g.rest == nil) then
    return false
  end
  local needed = 0
  for pos, p in ipairs(g.params) do
    if not p.omittable then
      needed = pos
    end
  end
  return last_required <= needed and (#g.params <= total or rest) and (g.rest == nil or rest)
end

--- Whether the enum `m` has the member `value`, or has no body to say.
local function enum_holds(m: Named, value: string): boolean
  local body = m.decl.body
  if body == nil then
    return true
  end
  for _, v in ipairs(body.values) do
    if v == value then
      return true
    end
  end
  return false
end

--- Whether the return lists a function literal writes have as many values as some list of `g` answers (the relation meets
--- the returns of a function by the number of values), or the literal writes none and takes `g`'s.
local function returns_fit(ctx: Ctx, lit: Ast.FunctionLit, g: Fn): boolean
  local written = lit.fn.rets
  if written == nil then
    return true
  end
  for _, list in ipairs(written.lists) do
    local never = false
    for _, item in ipairs(list) do
      if not ((item.kind == "Narrows")) then
        local t = ctx.lowered.types[rtype_base(item).id]
        never = never or (t ~= nil and t.tag == "never")
      end
    end
    if not never then
      local values = #list - (if written.variadic then 1 else 0 end)
      local fits = false
      for _, alt in ipairs(g.rets) do
        fits = fits or (#alt.items == values and (alt.tail ~= nil) == written.variadic)
      end
      if not fits then
        return false
      end
    end
  end
  return true
end

--- Whether the literal `e` could be a value of `want`: its form fits, which is all a position can tell of a literal
--- before it is checked against the overload. A function literal fits a function type whose calls it takes, and a
--- string literal a `string` or an enum that has it, which tells overloads of enums apart.
local function literal_fits(ctx: Ctx, written: Ast.Exp, want: Type): boolean
  if want.tag == "any" or want.tag == "invalid" then
    return true
  end
  local e = peel(written)
  if (e.kind == "IfExp") then
    -- Each arm that is a literal fits; an arm that is not says nothing yet.
    for _, arm in ipairs(e.arms) do
      if is_literal(arm.value) and not literal_fits(ctx, arm.value, want) then
        return false
      end
    end
    return not is_literal(e.else_value) or literal_fits(ctx, e.else_value, want)
  end
  for _, m in ipairs(members_of(ctx.store, want)) do
    if (e.kind == "FunctionLit") then
      if (m.tag == "fn") and (#m.tparams > 0 or arguments_fit(e, m)) and returns_fit(ctx, e, m) then
        return true
      end
    elseif (e.kind == "Table") then
      if (m.tag == "array") or (m.tag == "map") or (m.tag == "named") or (m.tag == "var") then
        return true
      end
    elseif (e.kind == "String") then
      if m.tag == "string" or ((m.tag == "named") and m.decl.kind == "enum" and enum_holds(m, e.value)) then
        return true
      end
    elseif (e.kind == "Boolean") then
      if is_bool(m) then
        return true
      end
    else
      return true
    end
  end
  return false
end

--- Why `f` cannot be called with `n` known arguments (and a receiver where `off` is 1), or nil. `open` says the last
--- argument may add values: those it is known to give are in `n`, so a surplus among them is certain, and a missing one
--- is not (the tail fills it, [`tail_problem`] checks that).
local function arity_problem(f: Fn, off: integer, n: integer, open: boolean): string?
  local np = #f.params
  if n + off > np and f.rest == nil then
    return "too many"
  end
  if not open then
    for pos = n + off + 1, np do
      if not f.params[pos].omittable then
        return "too few"
      end
    end
  end
  return nil
end

--- Where the `tail` (`T...`) that the last argument of a call ends in does not fit what it fills, or nil: the call
--- passes `n` values (a receiver where `off` is 1) before it, so the tail gives the parameters from `n + 1` and then the
--- rest parameter. A parameter it may leave empty takes `T?`, and the rest parameter takes `T`. Answers the position of
--- the argument (from 1, after the receiver), the type wanted there, and whether the tail fits that type and only the
--- missing value is the fault.
local function tail_problem(ctx: Ctx, f: Fn, off: integer, n: integer, tail: Type, strict?: boolean): integer?, Type?, boolean
  if tail.tag == "invalid" then
    return nil, nil, false
  end
  local maybe = ctx.store:optional(tail)
  local np = #f.params - off
  for pos = n + 1, np do
    local want = f.params[pos + off].type
    if strict == true then
      -- a function that raises where a value is missing, nil or not: the tail may be empty
      return pos, want, true
    elseif want.tag ~= "any" then
      if not below(ctx, tail, want) then
        return pos, want, false
      elseif not below(ctx, maybe, want) then
        return pos, want, true
      end
    end
  end
  local rest = f.rest
  if rest ~= nil and rest.tag ~= "any" and not below(ctx, tail, rest) then
    return math.max(n + 1, np + 1), rest, false
  end
  return nil, nil, false
end

--- Reports a call with the wrong number of arguments.
local function arity_error(ctx: Ctx, node: Ast.Node, callee: string, f: Fn, off: integer, n: integer, why: string)
  local np = #f.params - off
  local required = 0
  for pos = 1 + off, #f.params do
    if not f.params[pos].omittable then
      required = pos - off
    end
  end
  if why == "too many" then
    report(ctx, "arity", node, callee .. " takes " .. plural(np, "argument") .. ", but " .. n .. " " ..
        (if n == 1 then "is" else "are" end) .. " given",
      "remove the extra " .. (if n - np == 1 then "argument" else "arguments" end) .. ", or declare the parameter in the function " ..
        "type", { Types.display(f, ctx.binders) })
  else
    local missing = f.params[n + off + 1]
    report(ctx, "arity", node, callee .. " takes " .. (if required < np then required .. " to " .. plural(np, "argument") else
      plural(required, "argument") end) .. ", but " .. n .. " " .. (if n == 1 then "is" else "are" end) .. " given",
      "pass the missing argument " .. (n + 1) .. (if missing ~= nil then ", " .. tq(ctx, missing.type) else "" end) ..
        ", or declare the parameter `name?: T`", { Types.display(f, ctx.binders) })
  end
end

--- The type the call's position `i` (from 1, after the receiver) wants of `f`.
local function parameter_at(f: Fn, off: integer, i: integer): Type?
  local p = f.params[i + off]
  if p ~= nil then
    return p.type
  end
  return f.rest
end

--- Checks the receiver of a method call against the first parameter of `f`.
local function check_receiver(ctx: Ctx, f: Fn, callee: string, recv: Type, recv_node: Ast.Node)
  local p1 = f.params[1]
  if p1 == nil then
    report(ctx, "arity", recv_node, callee .. " takes no receiver, so it cannot be called with `:`",
      "call it with `.`: it is a function of its module, not a method")
  else
    local _ = expect(ctx, recv_node, recv, p1.type, " as the receiver of " .. quoted(callee))
  end
end

--- What the arguments of a call are before the function it calls is taken.
local record Prepared
  --- The type of each argument that is not a literal, by position; the values the last argument expands to follow the
  --- others.
  known: mut {integer: Type}
  --- The literal arguments, by position: their type depends on the position they stand in, so they are typed once the
  --- function is taken.
  pending: mut {integer: boolean}
  --- How many positions the arguments fill, the last one's values included.
  mut count: integer
  --- Set when the last argument is a call or `...` that ends in `T...`.
  mut tail: Type?
  --- Whether the last argument may add values (a call or `...`).
  open: boolean
  --- The lists of a last argument that answers several, which are no values.
  mut lists: {Alt}?
  --- The last argument, when it was expanded.
  mut last: Ast.Exp?
end

--- What instantiating a generic function for a call gave: the instance, or nil and why not.
local record Instance
  fn: Fn?
  why: string
  --- The type parameters that a shape the arguments lack left with no type, and nothing else reported (the instance
  --- holds `invalid` for them).
  holes: {integer}?
end

--- The steps of a generic call.
local record Calls
  prepare: function(ctx: Ctx, args: {Ast.Exp}, wants: {Type}?): Prepared
  hooks: function(ctx: Ctx): Generics.Hooks
  source: function(at: integer): string
  typed_literal: function(e: Ast.Exp): boolean
  shown: function(ctx: Ctx, declared: Fn, t: Type): string
  sparse: function(t: Type): Type?
  holes: function(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, solved: Instance, before: integer)
  --- What to do where no overload of a function takes the arguments, for a function whose overloads cannot say.
  fixes: {string: string}
  solve: function(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, prep: Prepared, off: integer,
                  recv: Type?, expected: Type?, loud: boolean): Instance
  generic: function(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, recv: Type?,
                    recv_node: Ast.Node?, expected: Type?): {Alt}
  plain_place: function(e: Ast.Exp): boolean
  library_call: function(ctx: Ctx, callee_node: Ast.Node, node: Ast.Node, args: {Ast.Exp}, recv: Type?, recv_node: Ast.Node?):
    Literals.Call?
  literal_text: function(ctx: Ctx, e: Ast.Node): string?
  library_value: function(ctx: Ctx, e: Ast.Node): string?
  kind_type: function(ctx: Ctx, kind: string): Type
  refine: function(ctx: Ctx, call: Literals.Call, f: Fn): Fn
  refine_overloads: function(ctx: Ctx, call: Literals.Call, list: {Type}): {Type}
  literal_arguments: function(ctx: Ctx, call: Literals.Call, node: Ast.Node, args: {Ast.Exp}, recv_node: Ast.Node?)
  gsub_key: function(ctx: Ctx, c: Fn, args: {Ast.Exp}, off: integer, key: string)
  method_dot: function(ctx: Ctx, n: Ast.Call, callee: Type, object: Type)
  expect_argument: function(ctx: Ctx, node: Ast.Node, got: Type, want: Type, callee: string, position: integer, named?: string):
    boolean
  dispatch: function(ctx: Ctx, node: Ast.Node, callee_node: Ast.Node, callee: string, ft: Type, cands: {Type}?,
                     args: {Ast.Exp}, recv: Type?, recv_node: Ast.Node?, expected: Type?): {Alt}
end

--- [`expect_argument`] for argument `position` of a call of `callee`: an error it reports says so ([`Codes.Argument`]).
function Calls.expect_argument(ctx: Ctx, node: Ast.Node, got: Type, want: Type, callee: string, position: integer,
                               named?: string): boolean
  ctx.argument = { callee = callee, module = ctx.callee_module, position = position }
  local ok = expect_argument(ctx, node, got, want, " as argument " .. position .. " of " .. quoted(callee), named)
  ctx.argument = nil
  return ok
end

--- Types the arguments of a call that are not literals, and notes the literals. `wants` are the types a position expects
--- where the callee is known to expect one.
function Calls.prepare(ctx: Ctx, args: {Ast.Exp}, wants: {Type}?): Prepared
  local n = #args
  local last = args[n]
  local open = last ~= nil and ((last.kind == "Call") or (last.kind == "MethodCall") or (last.kind == "Vararg"))
  local prep: Prepared = { known = {}, pending = {}, count = n, open = open }
  -- The arguments before an expanding last one are typed as the others; the last one gives the values it is known to
  -- give, and the tail.
  local written = if open then n - 1 else n end
  for i = 1, written do
    local a = args[i]
    if is_literal(a) then
      prep.pending[i] = true
    else
      prep.known[i] = expr(ctx, a, wants ~= nil and wants[i] or nil)
    end
  end
  if open and last ~= nil then
    local vals = values_of(ctx, { last }, if wants ~= nil then { wants[n] } else nil end, nil)
    for j, t in ipairs(vals.types) do
      prep.known[written + j] = t
    end
    prep.count = written + #vals.types
    prep.tail = vals.tail
    prep.last = vals.last
    local several = vals.lists
    if several ~= nil then
      prep.lists = several
      local _ = first_value(ctx, last, several)
    end
  end
  return prep
end

--- `t`, a type written in the generic function `declared` (a parameter of it), as a program writes it: the type
--- parameters of the function have their letters.
function Calls.shown(ctx: Ctx, declared: Fn, t: Type): string
  if #declared.tparams == 0 then
    return show(ctx, t)
  end
  local names: mut {string} = {}
  for i = 1, #declared.tparams do
    names[i] = Types.letter(i - 1)
  end
  local binders: mut {{string}} = {}
  for i, b in ipairs(ctx.binders) do
    binders[i] = b
  end
  binders[#binders + 1] = names
  return Types.display(t, binders)
end

--- A call of the function `f`, with the arguments checked against its parameters. Answers its return lists. `given`
--- holds the values of the arguments when the caller typed them already (a generic call types its arguments to solve the
--- function's type parameters).
local function apply_function(ctx: Ctx, node: Ast.Node, callee: string, f: Fn, args: {Ast.Exp}, recv: Type?,
                              recv_node: Ast.Node?, given?: Values, declared?: Fn, strict?: boolean): {Alt}
  local off = if recv ~= nil then 1 else 0 end
  if recv ~= nil and recv_node ~= nil then
    check_receiver(ctx, f, callee, recv, recv_node)
  end
  local vals: Values
  if given ~= nil then
    vals = given
  else
    local wants: mut {Type} = {}
    for i = 1, #args do
      local w = parameter_at(f, off, i)
      if w ~= nil then
        wants[i] = w
      end
    end
    vals = values_of(ctx, args, wants, f.rest)
  end
  local several, last = vals.lists, vals.last
  if several ~= nil and last ~= nil and given == nil then
    local _ = first_value(ctx, last, several)
  end
  local open = vals.tail ~= nil or vals.lists ~= nil
  local n = #vals.types
  local why = arity_problem(f, off, n, open)
  local reported = false
  for i, t in ipairs(vals.types) do
    local want = parameter_at(f, off, i)
    local at = args[math.min(i, #args)] or node
    if want == nil then
      if not reported and why == "too many" then
        reported = true
        arity_error(ctx, node, quoted(callee), f, off, n, why)
      end
    else
      local named: string? = nil
      local original = declared ~= nil and parameter_at(declared, off, i) or nil
      if original ~= nil and declared ~= nil and names_invalid(want) then
        named = Calls.shown(ctx, declared, original)
      end
      local _ = Calls.expect_argument(ctx, at, t, want, callee, i, named)
    end
  end
  if why == "too few" or (why == "too many" and not reported) then
    arity_error(ctx, node, quoted(callee), f, off, n, why)
  end
  local tail = vals.tail
  if tail ~= nil and last ~= nil and why == nil then
    local pos, want, missing = tail_problem(ctx, f, off, n, tail, strict)
    if pos ~= nil and want ~= nil then
      if missing then
        local fix = "varargs end in nil: take the values into locals and test them (`local a, b = " .. text_of(ctx, last) ..
          " if b == nil then ... end`), or declare the parameter `name?: T`"
        if strict == true then
          fix = "pass the values explicitly (`" .. callee .. "(..., a, b)`), or count them first (`select(\"#\", ...)` or " ..
            "`#t`) and index each value, since " .. quoted(callee) .. " raises on a conversion that has no value, nil or not"
        end
        report(ctx, "nil_not_allowed", last, subject(ctx, last) .. " ends in " .. quoted(show(ctx, tail) .. "...") ..
            ", so argument " .. pos .. " of " .. quoted(callee) .. " may be missing, where " .. tq(ctx, want) .. " is wanted",
          fix, { show(ctx, ctx.store:optional(tail)), show(ctx, want) })
      else
        ctx.argument = { callee = callee, module = ctx.callee_module, position = pos }
        local _ = expect(ctx, last, tail, want, " as argument " .. pos .. " of " .. quoted(callee))
        ctx.argument = nil
      end
    end
  end
  return f.rets
end

--- The Teal the overloads are written in, for `overload_none`.
local function overload_line(ctx: Ctx, f: Type, why: string): string
  return Types.display(f, ctx.binders) .. (if why ~= "" then ": " .. why else "" end)
end

-- Generic calls ----------------------------------------------------------------------------------

--- What [`lang.generics`] reads types through: the judge, and the array part of a record.
function Calls.hooks(ctx: Ctx): Generics.Hooks
  local held = ctx.hooks
  if held ~= nil then
    return held
  end
  local made: Generics.Hooks = {
    below = function(a: Type, b: Type): boolean
      return below(ctx, a, b)
    end,
    listed = function(n: Named): {Type}
      return ctx.judge:listed(n).types
    end,
    array_part = function(n: Named): Type?
      local index = members_index(ctx, n.decl, false)
      local part = index ~= nil and index.array or nil
      return part ~= nil and put_in(ctx, n, part) or nil
    end,
  }
  ctx.hooks = made
  return made
end

Calls.fixes = {
  pcall = "`pcall` passes on at most 6 values, takes a function that answers at most 3 values and none that answers `T...`, " ..
    "and takes no function that may be nil: pass arguments one overload accepts, in its order",
  xpcall = "`xpcall` passes on at most 3 values, takes a function that answers at most 3 values and none that answers " ..
    "`T...`, and takes no function that may be nil: pass arguments one overload accepts, in its order",
  ["table.sort"] = "pass a comparator (`table.sort(xs, function(a, b) return a.key < b.key end)`), because `<` orders only " ..
    "numbers and strings of one type; or pass arguments one overload accepts, in its order",
}

--- Where a type came from, in the words of a message: the receiver, or an argument.
function Calls.source(at: integer): string
  if at == 0 then
    return "the receiver"
  end
  return "argument " .. at
end

--- Whether a function literal gives every parameter a type, so that its type does not depend on the position it stands in.
function Calls.typed_literal(e: Ast.Exp): boolean
  local at = peel(e)
  if not ((at.kind == "FunctionLit")) then
    return false
  end
  for _, p in ipairs(at.fn.params) do
    if p.type == nil then
      return false
    end
  end
  return true
end

--- The function type `c`, which is generic, as a call with these arguments instantiates it: each type parameter solved
--- from the receiver and the arguments, then from what the call is `expected` to answer, then from a literal whose position
--- names a parameter nothing else solved (typed on its own), and each checked against its bound ([`lang.generics`]). Where it cannot
--- be, a `loud` call reports it (`infer_conflict`, `cannot_infer`, `bound_unmet`) and goes on with `invalid` for the
--- parameter, so the arguments are checked and one mistake is one error; a call that is not loud (a candidate among
--- overloads) answers nil and why.
function Calls.solve(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, prep: Prepared, off: integer,
                     recv: Type?, expected: Type?, loud: boolean): Instance
  local store = ctx.store
  local solver = Generics.new(store, c, Calls.hooks(ctx))
  if recv ~= nil and c.params[1] ~= nil then
    Generics.match(solver, c.params[1].type, recv, "into", 0)
  end
  for i = 1, prep.count do
    local t = prep.known[i]
    local want = parameter_at(c, off, i)
    if t ~= nil and want ~= nil then
      Generics.match(solver, want, t, "into", i)
    end
  end
  local tail = prep.tail
  if tail ~= nil then
    for pos = prep.count + 1, #c.params - off do
      Generics.match(solver, c.params[pos + off].type, tail, "into", prep.count + 1)
    end
    local rest = c.rest
    if rest ~= nil then
      Generics.match(solver, rest, tail, "into", prep.count + 1)
    end
  end
  -- What the call is expected to answer solves a parameter before a literal is held to the instance.
  if expected ~= nil then
    local alt = c.rets[1]
    local item = alt ~= nil and (alt.items[1] or alt.tail) or nil
    if item ~= nil then
      Generics.expect(solver, item, expected)
    end
  end
  local failure = ""
  for i = 1, #args do
    local want = parameter_at(c, off, i)
    if prep.pending[i] and want ~= nil and Generics.unsolved(solver, want) then
      local a = args[i]
      local e = peel(a)
      if (e.kind == "Table") or (e.kind == "String") or (e.kind == "Boolean") or (e.kind == "IfExp") or Calls.typed_literal(a) then
        local t = expr(ctx, a, nil)
        prep.pending[i] = nil
        prep.known[i] = t
        Generics.match(solver, want, t, "into", i)
      elseif failure == "" then
        failure = "argument " .. i .. " is a literal whose type depends on a type parameter nothing else gives"
      end
    end
  end
  local given: mut {Type} = {}
  local unbound: mut {integer} = {}
  local holes: mut {integer} = {}
  for i = 1, #c.tparams do
    local held = Generics.value(solver, i)
    if held ~= nil then
      given[i] = held
    else
      given[i] = ctx.invalid
      if not solver.tainted[i] and not solver.invalid then
        unbound[#unbound + 1] = i
      elseif solver.tainted[i] and not solver.invalid then
        holes[#holes + 1] = i
      end
    end
  end
  local name = quoted(callee)
  local problems: mut {string} = {}
  if failure ~= "" then
    problems[#problems + 1] = failure
  end
  for _, k in ipairs(solver.conflicts) do
    local letter = quoted(Types.letter(k.index - 1))
    local same = k.first_at == k.second_at
    local msg = letter .. " of " .. name .. " is " .. tq(ctx, k.first) .. " from " .. Calls.source(k.first_at) .. " and " ..
      tq(ctx, k.second) .. " from " .. (if same then "another type in it" else Calls.source(k.second_at) end) .. ", which " ..
      (if k.exact then "must be one type here: a `mut` collection and the arguments of a generic are invariant" else
        "have no common type" end)
    problems[#problems + 1] = msg
    -- The parameter is none: the arguments are not held to a type they disagree on, so the mistake is the one error.
    given[k.index] = ctx.invalid
    if loud then
      report(ctx, "infer_conflict", args[k.second_at] or node, msg,
        if same then "narrow " .. Calls.source(k.first_at) .. " to one of its types first (`if v is ... then`), or declare the " ..
            "parameter as the union" else
          "pass values of one type to " .. name .. ", or convert " .. Calls.source(k.second_at) .. " to " .. tq(ctx, k.first) end,
        { show(ctx, k.first), show(ctx, k.second) })
    end
  end
  for _, i in ipairs(unbound) do
    local letter = quoted(Types.letter(i - 1))
    local msg = name .. " is generic, and nothing fixes its type parameter " .. letter .. ": no argument has it, and the " ..
      "call is not expected to answer it"
    problems[#problems + 1] = msg
    if loud then
      report(ctx, "cannot_infer", node, msg,
        "type the result, so the call is expected to have the type (`local v: T = " .. callee .. "(...)`), or pass an " ..
          "argument that has it", { Types.display(c, ctx.binders) })
    end
  end
  for i, tp in ipairs(c.tparams) do
    local bound = tp.bound
    local held = given[i]
    if bound ~= nil and held.tag ~= "invalid" and not below(ctx, held, bound) then
      local msg = tq(ctx, held) .. " is the type parameter " .. quoted(Types.letter(i - 1)) .. " of " .. name ..
        ", which is bounded by " .. tq(ctx, bound) .. ", and " .. tq(ctx, held) .. " does not list it"
      problems[#problems + 1] = msg
      if loud then
        report(ctx, "bound_unmet", node, msg,
          "list the interface in the declaration of " .. tq(ctx, held) .. " (`is " .. show(ctx, bound) .. "`), or pass a " ..
            "type that does", { show(ctx, held), show(ctx, bound) })
      end
      given[i] = ctx.invalid
    end
  end
  if #problems > 0 and not loud then
    return { why = problems[1] }
  end
  local made = Relation.specialize(store, c, given)
  local sparse: Type? = nil
  for i = 1, #c.tparams do
    local held = given[i]
    if made ~= nil and sparse == nil and (held.tag == "nil" or (held.tag == "union") and held.nilable) then
      sparse = Calls.sparse(made)
    end
  end
  if sparse ~= nil then
    local msg = name .. " with these type arguments has " .. tq(ctx, sparse) .. ", whose elements may be nil, and an array is dense"
    if loud then
      report(ctx, "array_of_optional", node, msg, "use a map `{integer: T}` for sparse data, or pass a value that is not " ..
          "optional: test it for nil first", { show(ctx, sparse) })
    end
    return { why = msg }
  end
  if made == nil then
    if loud then
      report(ctx, "not_assignable", node, name .. " with these type arguments nests more than " .. Types.max_depth ..
          " types deep", "name a part of the arguments with a record, which a type does not unfold")
    end
    return { why = "its instance nests too deep" }
  end
  return { fn = made, why = "", holes = holes }
end

--- An array or map type that `t` holds whose elements or values may be nil, or nil: what an instance makes of a type
--- parameter that an argument gave as optional.
function Calls.sparse(t: Type): Type?
  local function maybe(x: Type): boolean
    return x.tag == "nil" or (x.tag == "union") and x.nilable
  end
  if (t.tag == "array") and maybe(t.element) then
    return t
  elseif (t.tag == "map") and maybe(t.value) then
    return t
  end
  for _, part in ipairs(Types.parts(t)) do
    local found = Calls.sparse(part)
    if found ~= nil then
      return found
    end
  end
  return nil
end

--- Reports the type parameters of a call of the generic `c` that the shapes of the arguments left with no type, if
--- nothing else was reported for the call since `before` errors: the instance holds `invalid` for them, which the
--- argument check does not refuse, and a hole needs its error.
function Calls.holes(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, solved: Instance, before: integer)
  local holes = solved.holes
  if holes == nil or #holes == 0 or #ctx.errors ~= before then
    return
  end
  local letters: mut {string} = {}
  for _, i in ipairs(holes) do
    letters[#letters + 1] = quoted(Types.letter(i - 1))
  end
  report(ctx, "cannot_infer", node, quoted(callee) .. " is generic, and its type " .. (if #holes == 1 then "parameter " else "parameters " end) ..
      table.concat(letters, ", ") .. " get no type from the arguments: a parameter that is a union of shapes with " ..
      "a type parameter in each (`{T} | {U}`) says no more of an argument than that it is one of them",
    "give the parameter one shape, or one type parameter for the whole union (`x: T`)",
    { Types.display(c, ctx.binders) })
end

--- A call of the generic function `c`: its type parameters solved from the arguments and the type expected, then the
--- instance applied as any function is.
function Calls.generic(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, recv: Type?,
                       recv_node: Ast.Node?, expected: Type?): {Alt}
  local off = if recv ~= nil then 1 else 0 end
  -- A position that names no type parameter of the function expects its type of the argument there.
  local wants: mut {Type} = {}
  for i = 1, #args do
    local w = parameter_at(c, off, i)
    if w ~= nil and w.open == 0 then
      wants[i] = w
    end
  end
  local prep = Calls.prepare(ctx, args, wants)
  local before = #ctx.errors
  local solved = Calls.solve(ctx, node, callee, c, args, prep, off, recv, expected, true)
  local made = solved.fn
  if made == nil then
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  end
  for i = 1, #args do
    if prep.pending[i] then
      prep.known[i] = expr(ctx, args[i], parameter_at(made, off, i))
    end
  end
  local vals: Values = { types = {}, tail = prep.tail, lists = prep.lists, last = prep.last }
  for i = 1, prep.count do
    vals.types[i] = prep.known[i] or ctx.invalid
  end
  local alts = apply_function(ctx, node, callee, made, args, recv, recv_node, vals, c)
  Calls.holes(ctx, node, callee, c, solved, before)
  return alts
end

--- A call of the first of `cands`, in declared order, whose parameters accept the arguments; the literal arguments are
--- checked last, against it. A generic candidate is instantiated by the arguments first.
--- Reports a table that `gsub` looks matches up in when its keys are not what the literal pattern captures: `key` is
--- `string` for a captured text (or the whole match) and `integer` for a position `()`. `c` is the overload taken.
function Calls.gsub_key(ctx: Ctx, c: Fn, args: {Ast.Exp}, off: integer, key: string)
  local table_arg = args[3 - off]
  local declared = parameter_at(c, off, 3 - off)
  if table_arg == nil or declared == nil or not ((declared.tag == "map")) then
    return
  end
  local held = declared.key.tag
  if (key == "string" and held == "string") or (key == "integer" and held == "integer") then
    return
  end
  local wants = if key == "string" then "the captured text, a `string`" else "the position of a `()` capture, an `integer`" end
  report(ctx, "gsub_key", table_arg, "the table of `gsub` is looked up with " .. wants .. " as the key, and its keys are " ..
      tq(ctx, declared.key),
    "declare the table `{" .. key .. ": string}`" .. (if key == "string" then ", or capture a position with `()` for " ..
        "integer keys" else ", or capture text with `( ... )` for string keys" end), { show(ctx, declared) })
end

local function apply_overloads(ctx: Ctx, node: Ast.Node, callee: string, cands: {Type}, args: {Ast.Exp}, recv: Type?,
                               expected: Type?, key?: string): {Alt}
  local off = if recv ~= nil then 1 else 0 end
  local prep = Calls.prepare(ctx, args, nil)
  local known, pending, tail, count = prep.known, prep.pending, prep.tail, prep.count
  local reasons: mut {string} = {}
  for _, declared in ipairs(cands) do
    if (declared.tag == "fn") then
      local c: Fn = declared
      local failure = ""
      -- The number of arguments does not depend on the type parameters, so a candidate that takes another is not solved.
      local wrong_count = arity_problem(declared, off, count, prep.open and tail ~= nil)
      if wrong_count == nil and #declared.tparams > 0 then
        local solved = Calls.solve(ctx, node, callee, declared, args, prep, off, recv, expected, false)
        local made = solved.fn
        if made == nil then
          failure = solved.why
        else
          c = made
        end
      end
      if failure ~= "" then
        -- The candidate could not be instantiated.
      elseif wrong_count ~= nil then
        failure = wrong_count .. " arguments"
      elseif recv ~= nil and c.params[1] ~= nil and not accepts(ctx, recv, c.params[1].type) then
        local declared_receiver = declared.params[1]
        local wanted_receiver = c.params[1].type
        if declared_receiver ~= nil then
          wanted_receiver = declared_receiver.type
        end
        failure = "the receiver is " .. tq(ctx, recv) .. ", where " .. quoted(Calls.shown(ctx, declared, wanted_receiver)) ..
          " is wanted"
      else
        for i = 1, count do
          local want = parameter_at(c, off, i)
          local t = known[i]
          local wanted = ""
          if want ~= nil then
            local original = parameter_at(declared, off, i)
            wanted = quoted(Calls.shown(ctx, declared, original ~= nil and original or want))
          end
          if t ~= nil and (want == nil or not accepts(ctx, t, want)) then
            failure = "argument " .. i .. " is " .. tq(ctx, t) .. (if want ~= nil then ", where " .. wanted ..
                " is wanted" else ", which it does not take" end)
            break
          elseif pending[i] and (want == nil or not literal_fits(ctx, args[i], want)) then
            failure = "argument " .. i .. " is a literal that is not " .. (if want ~= nil then "a " .. wanted else "taken" end)
            break
          end
        end
      end
      if failure == "" and tail ~= nil then
        local pos, want, missing = tail_problem(ctx, c, off, count, tail)
        if pos ~= nil and want ~= nil then
          failure = "argument " .. pos .. " is filled by " .. quoted(show(ctx, tail) .. "...") .. (if missing then
            ", which may leave it missing, where " else ", where " end) .. tq(ctx, want) .. " is wanted"
        end
      end
      if failure == "" then
        for i, a in ipairs(args) do
          if pending[i] then
            local want = parameter_at(c, off, i)
            local t = expr(ctx, a, want)
            if want ~= nil then
              local _ = Calls.expect_argument(ctx, a, t, want, callee, i)
            end
          end
        end
        if key ~= nil then
          Calls.gsub_key(ctx, c, args, off, key)
        end
        if ctx.typed and (node.kind == "Call") then
          -- The callee is the overload taken (instantiated, for a generic one), not the first the name has.
          ctx.types[base_of(node.callee).id] = c
        end
        if ctx.typed then
          ctx.callees[base_of(node).id] = c
        end
        return c.rets
      end
      reasons[#reasons + 1] = overload_line(ctx, declared, failure)
    end
  end
  for i, a in ipairs(args) do
    if pending[i] then
      ctx.lenient = ctx.lenient + 1
      local _ = expr(ctx, a, nil)
      ctx.lenient = ctx.lenient - 1
    end
  end
  local shown: mut {string} = {}
  for i = 1, count do
    local t = known[i]
    if t ~= nil then
      shown[i] = show(ctx, t)
    else
      local literal = args[i]
      shown[i] = if (literal.kind == "String") then "string" elseif (literal.kind == "Boolean") then "boolean" elseif
        (literal.kind == "FunctionLit") then "function" else "table" end
    end
  end
  -- A module given beside a collection of its values (`table.insert(list, Queues)`): the argument is what is wrong.
  local function holds_values_of(t: Type, decl: Decl): boolean
    if (t.tag == "named") and not t.value and t.decl == decl then
      return true
    end
    for _, part in ipairs(Types.parts(t)) do
      if holds_values_of(part, decl) then
        return true
      end
    end
    return false
  end
  for i = 1, count do
    local held = known[i]
    local given = args[i]
    if given ~= nil and held ~= nil and (held.tag == "named") and held.value and (held.decl.kind == "record" or held.decl.kind == "class") then
      for j = 1, count do
        local other = known[j]
        if j ~= i and other ~= nil and holds_values_of(other, held.decl) then
          local why: Relation.Refusal = { code = "declaration_value", path = {}, sub = held, super = other }
          ctx.argument = { callee = callee, module = ctx.callee_module, position = i }
          refused(ctx, given, held, other, why, " as argument " .. tostring(i) .. " of " .. quoted(callee), held.decl.name)
          ctx.argument = nil
          return unknown_lists(ctx)
        end
      end
    end
  end
  local first = reasons[1]
  report(ctx, "overload_none", node, "no overload of " .. quoted(callee) .. " takes the arguments (" ..
      table.concat(shown, ", ") .. ")",
    (Calls.fixes[callee] or "pass arguments one overload accepts, in its order") .. ": " .. table.concat(reasons, "; "),
    { first or "" })
  return unknown_lists(ctx)
end

--- The function of the string library `e` denotes, by what it is and not by how it is spelled: `string.f`, `string["f"]`, the
--- same through a local that holds the library table (`local str = string`) or through a text (`("x").format`, `s.find` of a
--- text `s`), and a local that was given one of these and is never assigned (`local f = string.f`, `local g = f`). Nil for
--- anything else, a function of a record that is called alike among them.
function Calls.library_value(ctx: Ctx, e: Ast.Node): string?
  local at = peel(e)
  local name: string? = nil
  local object: Ast.Node? = nil
  local bound: integer? = nil
  if (at.kind == "Name") then
    bound = at.binding
  end
  if bound ~= nil then
    return ctx.library[bound]
  elseif (at.kind == "Field") then
    name, object = at.name, peel(at.object)
  elseif (at.kind == "Index") then
    local key = peel(at.key)
    if (key.kind == "String") then
      name, object = key.value, peel(at.object)
    end
  end
  if name == nil or object == nil or not Literals.functions[name] then
    return nil
  end
  if (object.kind == "String") then
    return name
  elseif (object.kind == "Name") then
    local object_binding = object.binding
    if object_binding == nil then
      return object.text == "string" and name or nil
    end
    local held = ctx.vars[object_binding]
    local library = ctx.program.globals["string"]
    if held ~= nil and (is_text(held) or ((held.tag == "named") and library ~= nil and held.decl == library.decl)) then
      return name
    end
  end
  return nil
end

--- The text `e` is: a string literal, or a name that was given one and is never assigned.
function Calls.literal_text(ctx: Ctx, e: Ast.Node): string?
  if (e.kind == "String") then
    return e.value
  elseif (e.kind == "Name") then
    local bound = e.binding
    if bound ~= nil then
      return ctx.consts[bound]
    end
  end
  return nil
end

--- The type an argument or a result has for a `kind` of [`lang.literals`]: a type of a conversion, an option or a capture.
function Calls.kind_type(ctx: Ctx, kind: string): Type
  local store = ctx.store
  if kind == "integer" or kind == "position" then
    return store.integer
  elseif kind == "number" then
    return store.number
  elseif kind == "string" then
    return store.string
  elseif kind == "quoted" then
    return store:union({ store.string, store.number, store.boolean, ctx.nil_type })
  end
  return store:atom("any")
end

--- The function `f`, a function of the string library called with the literals `call` gives, with the types they say: the
--- arguments of `format` and `pack` are those their conversions and options take, and the captures of `find`, `match` and
--- `gmatch` and the results of `unpack` are those of the pattern and the format (a position `()` is an integer). `f` itself
--- where a literal is not read or is wrong, which is reported by [`Calls.literal_arguments`].
function Calls.refine(ctx: Ctx, call: Literals.Call, f: Fn): Fn
  local store = ctx.store
  local fn = call.fn
  local format = call.literals[1]
  local pattern = call.literals[2]
  local first = f.rets[1]
  local function made(params: {Types.Param}, rest: Type?, rets: {Alt}): Fn
    local built = store:fn({ tparams = f.tparams, params = params, rest = rest, rets = rets })
    if (built.tag == "fn") then
      return built
    end
    return f
  end
  if (fn == "format" or fn == "pack") and format ~= nil and f.params[1] ~= nil then
    local kinds: {string} = {}
    local trouble: Literals.Problem? = nil
    if fn == "format" then
      local read = Literals.format(format)
      kinds, trouble = read.kinds, read.problem
    else
      local read = Literals.pack(format)
      kinds, trouble = read.kinds, read.problem
    end
    if trouble ~= nil then
      return f
    end
    local params: mut {Types.Param} = { f.params[1] }
    for _, kind in ipairs(kinds) do
      params[#params + 1] = { type = Calls.kind_type(ctx, kind) }
    end
    return made(params, nil, f.rets)
  elseif fn == "unpack" and format ~= nil then
    local read = Literals.pack(format)
    if read.problem ~= nil then
      return f
    end
    local items: mut {Type} = {}
    for _, kind in ipairs(read.kinds) do
      items[#items + 1] = Calls.kind_type(ctx, kind)
    end
    items[#items + 1] = store.integer
    return made(f.params, f.rest, { { items = items } })
  elseif pattern ~= nil and (fn == "match" or fn == "gmatch" or fn == "find") then
    local read = Literals.pattern(pattern)
    local reads = fn ~= "find" or call.plain == "none" or call.plain == "false"
    if read.problem ~= nil or not reads or first == nil or #f.rets ~= 1 then
      return f
    end
    local captures: mut {Type} = {}
    for _, kind in ipairs(read.captures) do
      captures[#captures + 1] = Calls.kind_type(ctx, kind)
    end
    if #captures == 0 and fn ~= "find" then
      captures[1] = store.string
    end
    if fn == "gmatch" then
      local iterator = first.items[1]
      if iterator ~= nil and (iterator.tag == "fn") then
        local each = store:fn({ tparams = iterator.tparams, params = iterator.params, rest = iterator.rest,
          rets = { { items = captures } } })
        return made(f.params, f.rest, { { items = { each } } })
      end
      return f
    end
    local items: mut {Type} = {}
    for _, item in ipairs(first.items) do
      items[#items + 1] = item
    end
    for _, captured in ipairs(captures) do
      items[#items + 1] = store:optional(captured)
    end
    return made(f.params, f.rest, { { items = items } })
  end
  return f
end

--- The overloads `list` of `gsub` called with a literal pattern, where a callback takes the captures the pattern gives: the
--- type of each capture, so that a `()` is an integer, and no more parameters than there are captures (a pattern with none
--- passes the whole match). A callback that takes more is no overload.
function Calls.refine_overloads(ctx: Ctx, call: Literals.Call, list: {Type}): {Type}
  local pattern = call.literals[2]
  if call.fn ~= "gsub" or pattern == nil then
    return list
  end
  local read = Literals.pattern(pattern)
  if read.problem ~= nil then
    return list
  end
  local given: mut {Type} = {}
  for _, kind in ipairs(read.captures) do
    given[#given + 1] = Calls.kind_type(ctx, kind)
  end
  if #given == 0 then
    given[1] = ctx.store.string
  end
  local out: mut {Type} = {}
  for _, each in ipairs(list) do
    local callback: Type? = nil
    if each.tag == "fn" then
      local third = each.params[3]
      if third ~= nil then
        callback = third.type
      end
    end
    if (each.tag == "fn") and callback ~= nil and (callback.tag == "fn") then
      if #callback.params <= #given then
        local params: mut {Types.Param} = {}
        for i = 1, #callback.params do
          params[i] = { type = given[i] }
        end
        local made = ctx.store:fn({ tparams = callback.tparams, params = params, rest = nil, rets = callback.rets })
        local rebuilt: mut {Types.Param} = {}
        for i, p in ipairs(each.params) do
          rebuilt[i] = if i == 3 then { type = made, omittable = p.omittable } else p end
        end
        out[#out + 1] = ctx.store:fn({ tparams = each.tparams, params = rebuilt, rest = each.rest, rets = each.rets })
      end
    else
      out[#out + 1] = each
    end
  end
  return out
end

--- The literal arguments of a call of the string library, written `string.f(...)`, `s:f(...)` on text, or `f(...)` of a local
--- that was given `string.f` and is never assigned, or nil. A string literal is an argument that is one, or a name given one
--- and never assigned (`local P <const> = "%b("`). A library function that is passed on or stored in a field is not read.
function Calls.library_call(ctx: Ctx, callee_node: Ast.Node, node: Ast.Node, args: {Ast.Exp}, recv: Type?,
                            recv_node: Ast.Node?): Literals.Call?
  local fn: string? = nil
  local method = false
  if (node.kind == "MethodCall") then
    method = recv ~= nil and is_text(recv)
    if method then
      fn = node.name
    end
  else
    fn = Calls.library_value(ctx, callee_node)
  end
  if fn == nil or not Literals.functions[fn] then
    return nil
  end
  local off = if method then 1 else 0 end
  local literals: mut {integer: string} = {}
  local receiver = recv_node ~= nil and peel(recv_node) or nil
  local held = receiver ~= nil and Calls.literal_text(ctx, receiver) or nil
  if method and held ~= nil then
    literals[1] = held
  end
  for i, a in ipairs(args) do
    local text = Calls.literal_text(ctx, peel(a))
    if text ~= nil then
      literals[i + off] = text
    end
  end
  local plain = "none"
  local fourth = args[4 - off]
  if fourth ~= nil then
    local written = peel(fourth)
    plain = (written.kind == "Boolean") and tostring(written.value) or "other"
  end
  return { fn = fn, literals = literals, plain = plain }
end

--- Reports what Lua raises on in the literal arguments of `call`, a call of the string library.
function Calls.literal_arguments(ctx: Ctx, call: Literals.Call, node: Ast.Node, args: {Ast.Exp}, recv_node: Ast.Node?)
  local off = if recv_node ~= nil then 1 else 0 end
  for _, found in ipairs(Literals.check(call)) do
    local place = recv_node ~= nil and found.place == 1 and recv_node or args[found.place - off] or node
    report(ctx, found.code, place, found.msg, found.fix)
  end
end

--- The lists a call answers, where the callee has type `ft` (and the overloads `cands`, if it has several). `expected`
--- is the type the call is expected to answer, which solves a type parameter no argument does.
function Calls.dispatch(ctx: Ctx, node: Ast.Node, callee_node: Ast.Node, callee: string, ft: Type, cands: {Type}?,
                        args: {Ast.Exp}, recv: Type?, recv_node: Ast.Node?, expected: Type?): {Alt}
  local list = cands or { ft }
  local first = list[1]
  if first.tag == "invalid" then
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  elseif first.tag == "any" then
    report(ctx, "any_use", callee_node, quoted(callee) .. " is untrusted data (`any`) and is called",
      "validate it with a [`cosmic.shape`] validator, and call the checked function", { "any" })
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  end
  if cands == nil and nilable(first) and first.tag ~= "nil" then
    report(ctx, "nil_not_allowed", callee_node, quoted(callee) .. " is " .. tq(ctx, first) .. ", so it may be nil, and it is called",
      "test it first (`if " .. callee .. " ~= nil then ... end`), or copy it to a local and test that", { show(ctx, first) })
    first = ctx.store:non_nil(first)
    list = { first }
  end
  local library = Calls.library_call(ctx, callee_node, node, args, recv, recv_node)
  local key: string? = nil
  local refined: Fn? = nil
  if library ~= nil then
    Calls.literal_arguments(ctx, library, node, args, recv_node)
    local pattern = library.fn == "gsub" and library.literals[2] or nil
    key = pattern ~= nil and Literals.key(pattern) or nil
    if #list == 1 and (first.tag == "fn") then
      refined = Calls.refine(ctx, library, first)
    else
      list = Calls.refine_overloads(ctx, library, list)
    end
  end
  if #list == 1 then
    if (first.tag == "fn") then
      if ctx.typed then
        ctx.callees[base_of(node).id] = first
      end
      if #first.tparams > 0 then
        return Calls.generic(ctx, node, callee, first, args, recv, recv_node, expected)
      end
      local strict = refined ~= nil and library ~= nil and library.fn == "format"
      return apply_function(ctx, node, callee, refined or first, args, recv, recv_node, nil, nil, strict)
    end
    report(ctx, "not_callable", callee_node, quoted(callee) .. " is " .. tq(ctx, first) .. ", which is not a function",
      if (first.tag == "union") then "narrow it to one function first" else "call a function" end, { show(ctx, first) })
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  end
  return apply_overloads(ctx, node, callee, list, args, recv, expected, key)
end

--- What a call that has returned shows. A function declared `never` does not return, so the state after it is
--- unreachable. `assert(c)` returns only where `c` holds, and a function declared `asserts v is T` only where `v` is a
--- `T`: the state after is the one where the argument is. A function declared `v is T` is a test of its argument, which
--- [`edges`] reads from `ctx.guards`.
--
-- TODO: drop the special case of `assert` here, once a narrowing declaration can say that a function returns only where
-- its argument holds and answers it (`asserts v` without a type, which the grammar leaves out): `asserts v is T`
-- narrows a place to a type and answers nothing, while `assert(x ~= nil)` and `local s = assert(find())` narrow by the
-- condition and answer the value. The type of the call is the declaration's (a generic function, solved as any is); only
-- what follows it is this.
local function after_call(ctx: Ctx, node: Ast.Node, callee: Ast.Exp?, alts: {Alt}, args: {Ast.Exp},
                          receiver: Ast.Exp?)
  ctx.guards[base_of(node).id] = nil
  if #alts == 0 then
    ctx.flow = Flow.dead(ctx.flow)
    return
  end
  local first = args[1]
  if callee ~= nil and (callee.kind == "Name") and callee.binding == nil and callee.text == "assert" and first ~= nil then
    local yes, _ = edges(ctx, ctx.flow, first)
    ctx.flow = yes
    return
  end
  local alt = alts[1]
  local narrows = #alts == 1 and alt.narrows or nil
  if narrows == nil then
    return
  end
  local target: Ast.Exp? = args[narrows.param]
  if receiver ~= nil then
    target = narrows.param == 1 and receiver or args[narrows.param - 1]
  end
  if target == nil then
    return
  end
  if narrows.asserts then
    local p = place_of(ctx, ctx.flow, target)
    if p ~= nil then
      local yes, _ = is_edges(ctx, ctx.flow, p, narrows.to)
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
    if callee.text == "setmetatable" then
      report(ctx, "setmetatable_call", node, "a program has no `setmetatable`: the metatable of a value is the compiler's, " ..
          "attached to the literal that makes the value of a class",
        "declare a `class` with the methods and write the value as a table literal typed as the class " ..
          "(`local v: C = { field = value }`)")
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
  if ctx.flow.unsets > 0 and ctx.flow.unset[id] then
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
    local fact = key ~= nil and ctx.flow.facts[key] or nil
    if fact ~= nil then
      note_narrowed(ctx, e, fact.declared, fact.type)
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
    return expr(ctx, e.inner, expected)
  elseif (e.kind == "Table") then
    return table_literal(ctx, e, expected)
  elseif (e.kind == "FunctionLit") then
    return function_literal(ctx, e, expected)
  elseif (e.kind == "Unary") then
    return unary(ctx, e, expr(ctx, e.operand, nil))
  elseif (e.kind == "IfExp") then
    return if_expression(ctx, e, expected)
  elseif (e.kind == "Vararg") then
    local rest = vararg_rest(ctx, e)
    return rest.tag == "invalid" and rest or store:optional(rest)
  end
  return ctx.invalid
end

--- The hint for `r.m(r, ...)`, a call of a method with `.` and its receiver as the first argument. `callee` is the type of the
--- function: a method is a function whose first parameter is the declaration of the object it is read from, and the call
--- passes a value of that declaration first.
--- Whether `e` is a name, or a chain of fields of a name: a place that reads the same each time, with no call, method call or
--- index to run between.
function Calls.plain_place(e: Ast.Exp): boolean
  local node = e
  while (node.kind == "Field") do
    node = node.object
  end
  return (node.kind == "Name")
end

function Calls.method_dot(ctx: Ctx, n: Ast.Call, callee: Type, object: Type)
  local field = n.callee
  if not ((field.kind == "Field")) or not ((callee.tag == "fn")) or not ((object.tag == "named")) or object.value then
    return
  end
  local first = callee.params[1]
  local given = n.args[1]
  if first == nil or given == nil then
    return
  end
  local receiver = first.type
  if not ((receiver.tag == "named")) or receiver.value or receiver.decl ~= object.decl then
    return
  end
  -- The receiver named twice: the first argument is the object the method was read from. Only a place that reads the same
  -- twice (a name, or fields of one) is: `mk().get(mk())` makes two objects, and `mk():get()` would make one.
  if not Calls.plain_place(field.object) then
    return
  end
  local who = text_of(ctx, field.object)
  if text_of(ctx, given) ~= who then
    return
  end
  local rest: mut {string} = {}
  for i = 2, #n.args do
    local item = n.args[i]
    if item ~= nil then
      rest[#rest + 1] = text_of(ctx, item)
    end
  end
  local call = who .. ":" .. field.name .. "(" .. table.concat(rest, ", ") .. ")"
  Tests.warn(ctx, "method_dot", n, quoted(field.name) .. " is a method of " .. tq(ctx, object) .. ", called with `.` and its " ..
      "receiver as the first argument", "write " .. quoted(call) .. " and pass the receiver once")
end

--- Applies the chain node `n` to the type `t` of its first operand.
local function apply(ctx: Ctx, n: Ast.Exp, t: Type, expected: Type?, wants_lists: boolean): Type, {Alt}?
  if (n.kind == "Binary") then
    return binary(ctx, n, t, expected), nil
  elseif (n.kind == "Field") then
    ctx.field_node, ctx.field_base = n, t
    local base = readable(ctx, n.object, t, "it has no field " .. quoted(n.name) .. " to read")
    if base == nil then
      return ctx.invalid, nil
    end
    local read = member_read(ctx, n, base, n.name)
    if ctx.flow.paths > 0 and read.tag ~= "invalid" then
      local key = path_key(ctx, n)
      local fact = key ~= nil and ctx.flow.facts[key] or nil
      if fact ~= nil then
        note_narrowed(ctx, n, fact.declared, fact.type)
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
    local alts = apply_call(ctx, n, t, expected)
    ctx.lenient = saved
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
    local alts = apply_method(ctx, n, t, expected)
    ctx.lenient = saved
    after_call(ctx, n, nil, alts, n.args, n.object)
    if wants_lists then
      return ctx.invalid, alts
    end
    return first_value(ctx, n, alts), nil
  elseif (n.kind == "IsTest") then
    return is_test(ctx, n, t), nil
  elseif (n.kind == "Cast") then
    report(ctx, "cast_refused", n, "`as` is not in the language: " .. subject(ctx, n) .. " changes a type by no check",
      "validate the value with a [`cosmic.shape`] validator, test it with `is` or a guard, or delete the cast")
    return ctx.invalid, nil
  end
  return ctx.invalid, nil
end

--- The type of `e`, and the lists it answers where `wants_lists` and it is a call.
local function evaluate(ctx: Ctx, e: Ast.Exp, expected: Type?, wants_lists: boolean): Type, {Alt}?
  local base = ctx.top
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
    ctx.top = ctx.top + 1
    ctx.spine[ctx.top] = node
    node = nxt
  end
  local t = leaf(ctx, node, ctx.top == base and expected or nil)
  local types = ctx.types
  local typed = ctx.typed
  if typed then
    types[base_of(node).id] = t
  end
  local alts: {Alt}? = nil
  for i = ctx.top, base + 1, -1 do
    local n = ctx.spine[i]
    ctx.top = i - 1
    t, alts = apply(ctx, n, t, i == base + 1 and expected or nil, wants_lists and i == base + 1)
    if typed then
      types[base_of(n).id] = t
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

expr = function(ctx: Ctx, e: Ast.Exp, expected: Type?): Type
  local t, _ = evaluate(ctx, e, expected, false)
  return t
end

lists_of = function(ctx: Ctx, e: Ast.Exp, expected: Type?): {Alt}
  local t, alts = evaluate(ctx, e, expected, true)
  if alts ~= nil then
    if ctx.typed then
      -- A call that answers lists has the type of the first value of its lists, for the type report.
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

--- The type column `i` of the lists `alts` gives a name: the union of what each has there, `T?` where one has a tail
--- and nil where one lacks the position.
local function column(ctx: Ctx, alts: {Alt}, i: integer): Type
  local types: mut {Type} = {}
  for _, alt in ipairs(alts) do
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
  return ctx.store:union(types)
end

--- The type value `i` of `vals` gives a name, or nil where there is none.
local function value_at(ctx: Ctx, vals: Values, i: integer): Type?
  local held = vals.types[i]
  local several, tail = vals.lists, vals.tail
  if held ~= nil then
    return held
  elseif several ~= nil then
    return column(ctx, several, i)
  elseif tail ~= nil then
    if tail.tag == "invalid" then
      return tail
    end
    return ctx.store:optional(tail)
  end
  return nil
end

--- Checks that `n` names or targets are given `vals`, reporting the names left without a value and the values no name
--- takes. `count_nodes` is how many expressions were written.
local function check_counts(ctx: Ctx, node: Ast.Node, n: integer, vals: Values, written: integer, what: string): boolean
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
      "give " .. plural(n, "value") .. ", or remove the " .. what .. "s that have none")
    return false
  end
  return true
end

--- Whether a value of type `t` is nil or a value of a class that declares `__close`, which is what a `<close>` local
--- holds ("compiler-written classes" in doc/plans/strict-teal.md). `invalid` and `never` stand for a mistake already
--- reported.
local function closable(t: Type): boolean
  local tag = t.tag
  if tag == "nil" or tag == "invalid" or tag == "never" then
    return true
  elseif (t.tag == "named") then
    local body = t.decl.body
    if t.value or t.decl.kind ~= "class" then
      return false
    elseif body == nil then
      return true
    end
    for _, m in ipairs(body.methods) do
      if m.name == "__close" then
        return true
      end
    end
    return false
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

--- Reports the `<close>` local `b`, of type `t`, unless it holds nil or a class that declares `__close`.
local function check_closable(ctx: Ctx, b: Ast.Binding, t: Type)
  if closable(t) then
    return
  end
  local what = if (t.tag == "named") and not t.value and t.decl.kind == "class" then "the class " .. tq(ctx, t) .. " declares no `__close`" else
    tq(ctx, t) .. " is not a class" end
  report(ctx, "close_not_closable", b, quoted(b.name) .. " is a `<close>` local of " .. tq(ctx, t) .. ", and " .. what ..
      ": Lua would raise at the declaration, since the value has no `__close` to call at the end of the block",
    "hold a class that declares `function __close(self)` (or nil) in " .. quoted(b.name) .. ", or release the value by " ..
      "hand and make " .. quoted(b.name) .. " an ordinary local", { show(ctx, t) })
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

--- `local a, b: T, U = f(), g()`.
local function local_statement(ctx: Ctx, s: Ast.Local)
  local n = #s.bindings
  local wants: mut {Type} = {}
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
        check_closable(ctx, b, wants[i])
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
  local vals = values_of(ctx, s.values, wants, nil)
  local counted = check_counts(ctx, s, n, vals, #s.values, "name")
  for i, b in ipairs(s.bindings) do
    local t = value_at(ctx, vals, i)
    local want = wants[i]
    local written = s.values[i]
    local held = ctx.scoped.vars[b.id]
    if written ~= nil and held ~= nil and not held.assigned then
      local literal = peel(written)
      if (literal.kind == "String") then
        ctx.consts[b.id] = literal.value
      else
        ctx.library[b.id] = Calls.library_value(ctx, literal)
      end
    end
    if want ~= nil then
      if t ~= nil and counted then
        local at = s.values[math.min(i, #s.values)]
        local _ = expect(ctx, at, t, want, " as the value of " .. quoted(b.name))
      end
      ctx.vars[b.id] = want
    elseif t ~= nil and counted then
      ctx.vars[b.id] = t
    else
      ctx.vars[b.id] = ctx.invalid
    end
    declare_local(ctx, b.id, false)
    local given = want ~= nil and t ~= nil and counted and value_narrowing(ctx, t, want) or nil
    if given ~= nil and want ~= nil then
      ctx.flow = Flow.narrow(ctx.flow, id_key(ctx, b.id), given, want)
    end
    if b.attr == "close" then
      check_closable(ctx, b, ctx.vars[b.id])
    end
  end
end

--- The rules by which an index write to a `mut` array is no hole ([`Writes.leaves_no_hole`]).
local record Writes
end

--- Whether `a` and `b` name the same place: a name, or fields of one.
function Writes.same_place(a: Ast.Exp, b: Ast.Exp): boolean
  local x, y = peel(a), peel(b)
  if (x.kind == "Name") and (y.kind == "Name") then
    return x.binding ~= nil and x.binding == y.binding
  elseif (x.kind == "Field") and (y.kind == "Field") then
    return x.name == y.name and Writes.same_place(x.object, y.object)
  end
  return false
end

--- Whether `key` is `#object`: the key of the last element of the array `object`.
function Writes.is_length_of(key: Ast.Exp, object: Ast.Exp): boolean
  local len = peel(key)
  return (len.kind == "Unary") and len.op == "#" and Writes.same_place(len.operand, object)
end

--- Whether the key of `target` is `#object + 1`, which appends.
function Writes.is_append(target: Ast.Index): boolean
  local key = peel(target.key)
  if (key.kind == "Binary") and key.op == "+" then
    local one = key.right
    return Writes.is_length_of(key.left, target.object) and (one.kind == "Integer") and one.value == 1
  end
  return false
end

--- Whether a value of type `t` is known not to be nil: an optional is not, nor is `any`, nor a type with no value.
function Writes.present(t: Type): boolean
  local tag = t.tag
  return not nilable(t) and tag ~= "any" and tag ~= "invalid" and tag ~= "never"
end

--- An index write to a `mut` array that is not an append, whose verdict waits for the values of its statement, which say
--- whether the value written is nil.
local record Pending
  target: Ast.Index
  --- Its place among the targets of the statement.
  at: integer
  owner: string
  base: Type
end

--- Whether the statements `body` of a loop leave the number of elements of the array held by the local `array` from falling
--- below what it was before them, and never assign the local `var`, the index of the loop. The code that may shorten the
--- array is a call, an iterator of a generic `for` (a call of its own) and the `__close` of a `<close>` local, and a
--- write of a nil or of the array's name. No other code runs in the body, because no metamethod can: `class_metamethod` lets
--- a class declare only `__close` and `__tostring` (both reached by the forms above), `setmetatable_call` refuses
--- `setmetatable`, and `operand_type` refuses an operator on a record. The loop rule must be revisited if any of the three is
--- relaxed; lang/check_test.tl pins them beside the loop tests.
function Writes.keeps_length(body: Ast.Node, array: integer, var: integer): boolean
  -- A closure may not assign a local of its function, so a way the body may change the length is a mark in a list. The
  -- statements wait in a list too, so that a body of any depth is read without recursion.
  local marks: mut {boolean} = {}
  local waiting: mut {Ast.Node} = { body }
  local function wait(child: Ast.Node)
    waiting[#waiting + 1] = child
  end
  while #waiting > 0 and #marks == 0 do
    local node = assert(waiting[#waiting])
    waiting[#waiting] = nil
    if (node.kind == "Call") or (node.kind == "MethodCall") or (node.kind == "ForIn") then
      -- TODO: let a call that cannot change the length of an array (a function of the standard library that is passed
      -- no function, `string.format`, `math.max`) stand in the body, once the checker says which calls those are.
      marks[#marks + 1] = true
    elseif (node.kind == "Local") then
      for _, binding in ipairs(node.bindings) do
        if binding.attr == "close" then
          marks[#marks + 1] = true
        end
      end
    elseif (node.kind == "Assign") then
      for i, target in ipairs(node.targets) do
        local value = node.values[i]
        if (target.kind == "Name") then
          -- `t = {}` is another table, and the index of the loop is not assigned.
          if target.binding == array or target.binding == var then
            marks[#marks + 1] = true
          end
        elseif (target.kind == "Index") then
          local object = peel(target.object)
          if value ~= nil and peel(value).kind == "Nil" then
            -- Any table may be the array under another name.
            marks[#marks + 1] = true
          elseif (object.kind == "Name") and object.binding == array then
            -- The write at the index of the loop overwrites; any other write may append or leave a hole.
            local key = peel(target.key)
            if not ((key.kind == "Name") and key.binding == var) then
              marks[#marks + 1] = true
            end
          end
        end
      end
    end
    Ast.children(node, wait)
  end
  return #marks == 0
end

--- What the numeric loop `s` knows of its index, if it counts the keys of an array: `for i = 1, #t do`, from a literal
--- of 1 or more by a literal step of 1 or more, over a local `t` that the body does not assign, append to, shorten or
--- pass to a call, and whose index nothing assigns. `t` has at least as many elements at each pass as it had when the
--- loop began, so `i` is a key it has.
function Writes.fill_of(s: Ast.ForNum): Fill?
  local from = peel(s.from)
  local to = peel(s.to)
  local step = s.step
  if not ((from.kind == "Integer") and from.value >= 1) then
    return nil
  elseif step ~= nil then
    local given = peel(step)
    if not ((given.kind == "Integer") and given.value >= 1) then
      return nil
    end
  end
  if not ((to.kind == "Unary") and to.op == "#") then
    return nil
  end
  local object = peel(to.operand)
  if not (object.kind == "Name") then
    return nil
  end
  local held = object.binding
  if held == nil or not Writes.keeps_length(s.body, held, s.var.id) then
    return nil
  end
  return { var = s.var.id, object = object }
end

--- The type of `object` to write a member of, after reporting what it may not be.
local function writable_base(ctx: Ctx, object: Ast.Exp): Type?
  local t = expr(ctx, object, nil)
  return readable(ctx, object, t, "it has no member to write")
end

--- The place `target` writes, reporting what may not be written. It is the `at`th target of its statement, which `removes`
--- if it is the only one and gives it a literal nil. A write to an array that is no append is left in `pending`.
local function place_of_target(ctx: Ctx, target: Ast.Exp, at: integer, removes: boolean, pending: mut {Pending}): Type?, boolean
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
      if list == nil or list[1].method then
        field_unknown(ctx, target, base, target.name)
        return nil, false
      end
      local field = list[1]
      if not field.mut then
        report(ctx, "field_fixed", target, quoted(base.decl.name .. "." .. target.name) .. " is fixed: it is not declared `mut`",
          "declare `mut " .. target.name .. ": " .. show(ctx, field.type) .. "` in " .. quoted(base.decl.name) ..
            ", or make a new " .. quoted(base.decl.name), { show(ctx, base) })
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
      if not base.mut then
        report(ctx, "view_written", target, owner .. " is a view " .. tq(ctx, base) .. ", so " .. subject(ctx, target) ..
            " cannot be assigned",
          "declare " .. owner .. " `mut " .. show(ctx, base) .. "` where it is made or received", { show(ctx, base) })
      elseif removes and Writes.is_length_of(target.key, target.object) then
        -- The last element goes, so the elements left are the first ones. Of several targets, another may write the key
        -- the length names after this one is gone (`t[#t], t[#t + 1] = nil, v`).
        return base.element, true
      elseif not Writes.is_append(target) then
        pending[#pending + 1] = { target = target, at = at, owner = owner, base = base }
      end
      return base.element, false
    elseif (base.tag == "map") then
      local k = expr(ctx, target.key, base.key)
      local _ = key_ok(ctx, target.key, k, base.key, owner)
      if not base.mut then
        report(ctx, "view_written", target, owner .. " is a view " .. tq(ctx, base) .. ", so " .. subject(ctx, target) ..
            " cannot be assigned",
          "declare " .. owner .. " `mut " .. show(ctx, base) .. "` where it is made or received", { show(ctx, base) })
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
      if names ~= nil and #names == 1 then
        local list = member_types(ctx, base, names[1])
        if list ~= nil and not list[1].method then
          if not list[1].mut then
            report(ctx, "field_fixed", target, quoted(base.decl.name .. "." .. names[1]) .. " is fixed: it is not declared `mut`",
              "declare `mut " .. names[1] .. ": " .. show(ctx, list[1].type) .. "` in " .. quoted(base.decl.name) ..
                ", or make a new " .. quoted(base.decl.name), { show(ctx, base) })
          end
          return put_in(ctx, base, list[1].type), false
        end
        field_unknown(ctx, target.key, base, names[1])
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

--- Whether the write `p` leaves the array it writes with no hole: the statement has the values `vals`. The array has its
--- elements from 1 to its length, so a write that puts a value that is not nil
---   - at 1 appends (the array is empty) or overwrites (it is not),
---   - at the index of a loop over `1` to the length of the array ([`Writes.fill_of`]), which has that element,
--- overwrites an element and leaves the others where they are. A nil would take an element out of the middle, and a write at
--- the length (`t[#t] = v`) is at 0 where the array is empty, which is no key of an array.
---
--- A write in a function made inside the loop (`saved = function() u[i] = 1 end`) is refused only because the body of a
--- function does not inherit `ctx.loops` (([`function_body`])), which holds the loop's fill; [`Writes.keeps_length`] does not
--- decide it. Keep the two apart: a closure may run when the array is shorter.
function Writes.leaves_no_hole(ctx: Ctx, vals: Values, p: Pending): boolean
  local written = value_at(ctx, vals, p.at)
  if written == nil or not Writes.present(written) then
    return false
  end
  local target = p.target
  local key = peel(target.key)
  if (key.kind == "Integer") and key.value == 1 then
    return true
  end
  if (key.kind == "Name") then
    for _, loop in ipairs(ctx.loops) do
      local fill = loop.fill
      if fill ~= nil and key.binding == fill.var and Writes.same_place(fill.object, target.object) then
        return true
      end
    end
  end
  -- TODO: let the swap `t[i], t[j] = t[j], t[i]` stand, whose values are elements that are there, once the checker narrows a
  -- read of an index (`if t[i] ~= nil`) to the element type: `t[i]` is `T?` after any test now, so the swap is refused.
  return false
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
    if id ~= nil and named[id] then
      report(ctx, "assign_repeated", target, subject(ctx, target) .. " is assigned twice by one statement, and Lua leaves " ..
          "the order of the two open",
        "assign " .. subject(ctx, target) .. " once, or in two statements in the order you mean")
    elseif id ~= nil then
      named[id] = true
    end
  end
  local outer_assigning = ctx.assigning
  ctx.assigning = named
  local wants: mut {Type} = {}
  local deletes: mut {boolean} = {}
  local pending: mut {Pending} = {}
  local first = s.values[1]
  local removes = #s.targets == 1 and #s.values == 1 and first ~= nil and peel(first).kind == "Nil"
  for i, target in ipairs(s.targets) do
    local want, deleting = place_of_target(ctx, target, i, removes, pending)
    if want ~= nil then
      wants[i] = want
      deletes[i] = deleting
    end
  end
  local vals = values_of(ctx, s.values, wants, nil)
  ctx.assigning = outer_assigning
  for _, p in ipairs(pending) do
    if not Writes.leaves_no_hole(ctx, vals, p) then
      local target = p.target
      report(ctx, "array_hole", target, subject(ctx, target) .. " may leave a hole in the array " .. p.owner,
        "append with `" .. text_of(ctx, target.object) .. "[#" .. text_of(ctx, target.object) .. " + 1] = v` or " ..
          "`table.insert`, remove with `table.remove`, or key a map `{integer: T}` for sparse data", { show(ctx, p.base) })
    end
  end
  local counted = check_counts(ctx, s, #s.targets, vals, #s.values, "target")
  if not counted then
    return nil
  end
  for i, target in ipairs(s.targets) do
    local t = value_at(ctx, vals, i)
    local want = wants[i]
    if t ~= nil and want ~= nil then
      local at = s.values[math.min(i, #s.values)]
      -- Only a literal nil deletes the key of a map; any other value is one of its value type.
      local written = peel(at)
      if not (deletes[i] and (written.kind == "Nil")) then
        local _ = expect(ctx, at, t, want, " in the assignment to " .. subject(ctx, target))
      end
    end
  end
  return vals
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
  for i, target in ipairs(s.targets) do
    local id: integer? = nil
    if (target.kind == "Name") then
      id = target.binding
    end
    if id ~= nil then
      -- The drop is told to a later use only where it took away a test that showed the value was not nil.
      local fact = ctx.flow.facts[id_key(ctx, id)]
      local told = (fact ~= nil and not nilable(fact.type)) or ctx.flow.paths > 0
      local tokens, at = ctx.tokens, base_of(target).first
      ctx.flow = Flow.assign(ctx.flow, id, if told then
        { y = Lexer.y(tokens, at), x = Lexer.x(tokens, at), offset = Lexer.offset(tokens, at),
          length = Lexer.length(tokens, at) } else nil end)
      local v = ctx.scoped.vars[id]
      local declared = ctx.vars[id]
      local t = vals ~= nil and value_at(ctx, vals, i) or nil
      local given = t ~= nil and declared ~= nil and v ~= nil and PLACE_KINDS[v.kind] and value_narrowing(ctx, t, declared) or nil
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
      if not below(ctx, rest, alt.items[i]) then
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
  if frame.chunk then
    local _ = values_of(ctx, s.values, nil, nil)
    local info = ctx.program.modules[ctx.input.module]
    local ok = #s.values == 0 or (info ~= nil and (info.export ~= nil or info.value ~= nil))
    if not ok then
      report(ctx, "export_not_declared", s, "this module returns " .. subject(ctx, s.values[1]) .. ", which no declaration describes",
        "return a record, class, interface or enum of the module, or a local declared with its type")
    end
    return
  end
  local alts = frame.alts
  local n = #s.values
  if #alts == 0 then
    local _ = values_of(ctx, s.values, nil, nil)
    report(ctx, "return_unexpected", s, "this function is declared `never` and cannot return",
      "end it with `error(...)`, or declare the return list")
    return
  end
  -- What each position wants: the item of the one list that has the length, else the union of those that have it.
  local wants: mut {Type} = {}
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
      wants[i] = #types == 1 and types[1] or ctx.store:union(types)
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
        vals.types[i] = ctx.store:atom(if literal.value then "true" else "false" end)
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
        report(ctx, "not_assignable", last, subject(ctx, last) .. " answers a list of values this function does not",
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
          if frame.declared then "remove the value" else "declare the return list: `function f(): T`" end)
      end
      return
    end
    local count = #vals.types
    if vals.tail == nil and (count < #alt.items or (count > #alt.items and alt.tail == nil)) then
      report(ctx, "return_arity", s, "this returns " .. plural(count, "value") .. ", where the function answers " ..
          plural(#alt.items, "value") .. (if alt.tail ~= nil then " or more" else "" end),
        "return " .. plural(#alt.items, "value") .. (if alt.tail ~= nil then " or more" else "" end) ..
          ", or change the declared return list")
      return
    end
    for i, t in ipairs(vals.types) do
      local want = alt.items[i] or alt.tail
      local at = s.values[math.min(i, n)]
      if want ~= nil then
        local _ = expect(ctx, at, t, want, " as return value " .. i)
      end
    end
    local tail = vals.tail
    if tail ~= nil and tail.tag ~= "invalid" and last ~= nil then
      -- The `T...` the last value ends in: the values it gives are what follows, and any of them may be missing.
      local maybe = ctx.store:optional(tail)
      local fix = "varargs end in nil: test the first value (`local v = ... if v == nil then ... end`) and return it"
      for i = count + 1, #alt.items do
        if not below(ctx, tail, alt.items[i]) then
          local _ = expect(ctx, last, tail, alt.items[i], " as return value " .. i)
          return
        elseif not below(ctx, maybe, alt.items[i]) then
          report(ctx, "nil_not_allowed", last, subject(ctx, last) .. " ends in `" .. show(ctx, tail) .. "...`, so return value " ..
              i .. " may be missing, where " .. tq(ctx, alt.items[i]) .. " is wanted",
            fix, { show(ctx, maybe), show(ctx, alt.items[i]) })
          return
        end
      end
      local at = alt.tail
      if at ~= nil then
        local _ = expect(ctx, last, tail, at, " as the values after return value " .. #alt.items)
      elseif count + 1 > #alt.items then
        report(ctx, "return_arity", last, subject(ctx, last) .. " ends in `" .. show(ctx, tail) ..
            "...`, so this may return more values than the function answers (" .. #alt.items .. ")",
          "return the values the function answers, one by one")
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
  narrows_proved(ctx, s, s.values[1])
  ctx.flow = Flow.dead(ctx.flow)
end

--- The most rounds a loop is walked quietly before it gives up what it knows of its places.
local ROUNDS <const> = 6

--- Walks a loop to a fixed point. `walk` takes the state at the head of the loop and answers the state its pass ends in,
--- which goes back to the head, and the state the loop leaves in. The head is where the entry and the back edge meet,
--- so a place keeps a fact only if the back edge keeps it too, and a local is unset if it may be; the passes that
--- settle it report nothing (`ctx.quiet`), and one more that reports is made from the head they settle on. A loop whose
--- entry knows nothing has no head to settle.
local function run_loop(ctx: Ctx, entry: Flow.State, walk: function(head: Flow.State): Flow.State, Flow.State): Flow.State
  local head = entry
  if next(entry.facts) ~= nil or entry.unsets > 0 then
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
local function open_loop(ctx: Ctx, fill?: Fill): Loop
  local loop: Loop = { fill = fill }
  ctx.loops[#ctx.loops + 1] = loop
  return loop
end

--- Closes the loop `loop`. Answers the state its pass ends in (the end of the body, with the `continue`s) and the
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
  return arithmetic_operand(ctx, e, t, "for " .. what)
end

local function for_numeric(ctx: Ctx, s: Ast.ForNum)
  local from = numeric_bound(ctx, s.from, "start")
  local _ = numeric_bound(ctx, s.to, "limit")
  local step_node = s.step
  local step = 1
  if step_node ~= nil then
    step = numeric_bound(ctx, step_node, "step")
  end
  ctx.vars[s.var.id] = (from == 1 and step == 1) and ctx.store.integer or ctx.store.number
  local entry = ctx.flow
  local fill = Writes.fill_of(s)
  ctx.flow = run_loop(ctx, entry, function(head: Flow.State): Flow.State, Flow.State
    ctx.flow = head
    local loop = open_loop(ctx, fill)
    declare_local(ctx, s.var.id, false)
    block(ctx, s.body)
    local back, breaks = close_loop(ctx, loop, ctx.flow)
    return back, merge_maybe(ctx, head, breaks)
  end)
end

local function for_generic(ctx: Ctx, s: Ast.ForIn)
  local store = ctx.store
  local vals = values_of(ctx, s.iterators, nil, nil)
  local iterator = vals.types[1] or vals.tail
  local types: mut {Type} = {}
  local fourth = s.iterators[4]
  if fourth ~= nil then
    report(ctx, "iterator_extra", fourth, "a generic `for` takes an iterator, a state and a first control value, and " ..
        subject(ctx, fourth) .. " is a fourth: Lua takes it as the value to close, and raises when it has no `__close`",
      "write at most three expressions after `in`")
  else
    -- a call that answers a fourth value in the last place gives the same closing value
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
    report(ctx, "no_value", first, subject(ctx, first) .. " answers nothing, so there is no iterator to loop over",
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
    local given: Prepared = { known = known, pending = {}, count = math.max(0, math.min(2, #vals.types - 1)), open = false }
    before = #ctx.errors
    generic_iterator = iterator
    solved = Calls.solve(ctx, s.iterators[1], text_of(ctx, s.iterators[1]), iterator, s.iterators, given, 0, nil, nil, true)
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
      local _ = expect_argument(ctx, s.iterators[math.min(2, #s.iterators)], state, iterator_state.type,
        " as the state of the iterator")
    end
    if control ~= nil and iterator_control ~= nil then
      local _ = expect_argument(ctx, s.iterators[math.min(3, #s.iterators)] or final, control, iterator_control.type,
        " as the first value of the iterator")
    end
  else
    report(ctx, "not_callable", s.iterators[1], subject(ctx, s.iterators[1]) .. " is " .. tq(ctx, iterator) ..
        ", which is no iterator function",
      "iterate a collection with `ipairs(...)` or `pairs(...)`, or pass an iterator function", { show(ctx, iterator) })
    for i = 1, #s.vars do
      types[i] = ctx.invalid
    end
  end
  if solved ~= nil and generic_iterator ~= nil then
    Calls.holes(ctx, s.iterators[1], text_of(ctx, s.iterators[1]), generic_iterator, solved, before)
  end
  for i, v in ipairs(s.vars) do
    ctx.vars[v.id] = types[i]
  end
  local entry = ctx.flow
  ctx.flow = run_loop(ctx, entry, function(head: Flow.State): Flow.State, Flow.State
    ctx.flow = head
    local loop = open_loop(ctx)
    for _, v in ipairs(s.vars) do
      declare_local(ctx, v.id, false)
    end
    block(ctx, s.body)
    local back, breaks = close_loop(ctx, loop, ctx.flow)
    return back, merge_maybe(ctx, head, breaks)
  end)
end

--- The bodies of the methods of a class, and of the declarations nested in a record, interface or class.
local function declaration_bodies(ctx: Ctx, node: Ast.Node, decl: Decl?)
  local members: {Ast.Member} = {}
  if (node.kind == "Record") or (node.kind == "Interface") or (node.kind == "Class") then
    members = node.members
  end
  local body = decl ~= nil and decl.body or nil
  local binder = decl ~= nil and body ~= nil and #body.tparams > 0
  if binder and decl ~= nil and body ~= nil then
    local names: mut {string} = {}
    for i, p in ipairs(body.tparams) do
      names[i] = p.name
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
      if (super.tag == "named") and not seen[super.decl] then
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
      function_body(ctx, m.params, m.body, ft, {}, m, m.rets ~= nil, m.id,
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

local function names_of_params(list: {Ast.TypeParam}): {string}
  local out: mut {string} = {}
  for i, p in ipairs(list) do
    out[i] = p.name.name
  end
  return out
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
  local waiting = (owner.tag == "named") and ctx.pending[owner.decl] or nil
  if waiting ~= nil and #s.path == 2 then
    if waiting[s.path[2].text] == true then
      ctx.load.waiting = ctx.load.waiting - 1
    end
    waiting[s.path[2].text] = nil
  end
  local text = head.text
  for i = 2, #s.path do
    text = text .. "." .. s.path[i].text
  end
  local ft = function_type(ctx, s.fn, nil, quoted(text))
  if owner.tag ~= "invalid" then
    local field_type: Type = owner
    for i = 2, #s.path do
      local part = s.path[i]
      local base = readable(ctx, s.path[i - 1], field_type, "it has no member to define")
      if base == nil then
        field_type = ctx.invalid
        break
      end
      field_type = member_read(ctx, part, base, part.text)
      ctx.cands, ctx.cand_node = nil, nil
    end
    if field_type.tag ~= "invalid" then
      local _ = expect(ctx, s, ft, field_type, " as the declaration of " .. quoted(text))
    end
  end
  if (owner.tag == "named") and #s.path == 2 then
    LoadOrder.define(ctx.load, owner.decl, s.path[2].text, s.fn.id)
  end
  function_body(ctx, s.fn.params, s.fn.body, ft, names_of_params(s.typeparams), s, s.fn.rets ~= nil, s.fn.id, text)
end

--- `if`: each arm is walked under the state where its condition holds and those before it do not, and what follows is
--- where the ends of the arms, and of the path that took none, meet.
local function if_statement(ctx: Ctx, s: Ast.If)
  local ends: mut {Flow.State} = {}
  for _, arm in ipairs(s.arms) do
    local _ = condition(ctx, arm.cond)
    local yes, no = edges(ctx, ctx.flow, arm.cond)
    ctx.flow = yes
    block(ctx, arm.body)
    ends[#ends + 1] = ctx.flow
    ctx.flow = no
  end
  local else_body = s.else_body
  if else_body ~= nil then
    block(ctx, else_body)
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
    block(ctx, s.body)
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
    stats(ctx, s.body)
    local continues = loop.continues
    if continues ~= nil then
      ctx.flow = merge(ctx, ctx.flow, continues)
    end
    local _ = condition(ctx, s.cond)
    local yes, no = edges(ctx, ctx.flow, s.cond)
    ctx.loops[#ctx.loops] = nil
    return no, merge_maybe(ctx, yes, loop.breaks)
  end)
end

--- `break` (`leaves`) and `continue`: the state goes to the innermost loop, and the path ends.
local function jump_statement(ctx: Ctx, leaves: boolean)
  local loop = ctx.loops[#ctx.loops]
  if loop ~= nil then
    local f = ctx.flow
    if leaves then
      loop.breaks = merge_maybe(ctx, f, loop.breaks)
    else
      loop.continues = merge_maybe(ctx, f, loop.continues)
    end
  end
  ctx.flow = Flow.dead(ctx.flow)
end

--- How the tests of `arm` stand against the list `alt` the call may answer: "yes" when each `true` and `false` is the
--- value the list has at its position, "no" when one is the other, and "unclear" when the list has no `true` or `false`
--- at a position the arm tests (the position it is, or 0, for the message).
local function arm_against(arm: Ast.MatchArm, alt: Alt): string, integer
  local unclear = 0
  for i, p in ipairs(arm.pats) do
    if (p.kind == "PatBool") then
      local item = alt.items[i]
      local tag = ""
      if item ~= nil then
        tag = item.tag
      end
      if tag == "true" or tag == "false" then
        if (tag == "true") ~= p.value then
          return "no", i
        end
      elseif unclear == 0 then
        unclear = i
      end
    end
  end
  if unclear > 0 then
    return "unclear", unclear
  end
  return "yes", 0
end

--- The arm that takes the list `alt`: `true` and `false` where the list has them, and a name for each other value.
local function arm_for(alt: Alt): string
  local pats: mut {string} = {}
  for i, item in ipairs(alt.items) do
    local pat = "v" .. i
    if item.tag == "true" or item.tag == "false" then
      pat = item.tag
    end
    pats[i] = pat
  end
  if #pats == 0 and alt.tail ~= nil then
    pats[1] = "v1"
  end
  return "| (" .. table.concat(pats, ", ") .. ") then ..."
end

--- `match`: the arms cover the lists the call may answer exactly ([`doc/plans/new-checker-types.md`], "`match` and
--- tagged unions"). An arm takes the lists whose value at each position it tests with `true` or `false` is that one,
--- and a list some earlier arm takes is not its: the names of the arm are the union of what those lists have where the
--- name stands, and each arm names every value of them. An arm that takes no list, or only lists the arms before it took,
--- is `match_redundant`; a list no arm takes is `match_missing`. Each arm is walked from the state after the call, and what
--- follows is where their ends meet.
local function match_statement(ctx: Ctx, s: Ast.Match)
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
  local taken: mut {boolean} = {}
  for _, arm in ipairs(s.arms) do
    ctx.flow = start
    local mine: mut {Alt} = {}
    local explained = false
    if not unknown then
      local selected = 0
      for k, alt in ipairs(alts) do
        local verdict, at = arm_against(arm, alt)
        if verdict == "unclear" then
          explained = true
          taken[k] = true
          local pat = assert(arm.pats[at])
          local item = alt.items[at]
          report(ctx, "match_pattern", pat, "this pattern tests position " .. at .. " with `" ..
              (if (pat.kind == "PatBool") and pat.value then "true" else "" end) .. "`, and the list " .. quoted(lists_text(ctx, { alt })) .. " has " ..
              (item ~= nil and tq(ctx, item) or "no value") .. " there, which `true` and `false` do not tell",
            "test only the positions that are `true` or `false` in the lists the call answers, and name the others",
            { lists_text(ctx, { alt }) })
        elseif verdict == "yes" then
          selected = selected + 1
          local have, n = #alt.items, #arm.pats
          if n < have or (alt.tail == nil and n > have) then
            explained = true
            report(ctx, "match_pattern", arm, "this arm names " .. plural(n, "value") .. ", and the list " ..
                quoted(lists_text(ctx, { alt })) .. " it takes has " .. (if alt.tail ~= nil then "at least " else "" end) ..
                plural(have, "value"),
              "write " .. (if alt.tail ~= nil then "at least " else "" end) .. plural(have, "pattern") .. ", `_` for a value the arm " ..
                "does not use: " .. quoted(arm_for(alt)), { lists_text(ctx, { alt }) })
          end
          if not taken[k] then
            mine[#mine + 1] = alt
            taken[k] = true
          end
        end
      end
      if #mine == 0 and not explained then
        report(ctx, "match_redundant", arm, if selected == 0 then "this arm takes no list the call answers: no list has the " ..
            "values its `true` and `false` test" else "this arm takes only lists the arms before it take, so it never runs" end,
          "delete the arm, or change its `true` and `false` to take a list no arm before it takes")
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
        ctx.vars[p.name.id] = #types > 0 and ctx.store:union(types) or ctx.invalid
        declare_local(ctx, p.name.id, false)
      end
    end
    block(ctx, arm.body)
    ends[#ends + 1] = ctx.flow
  end
  if not unknown then
    for k, alt in ipairs(alts) do
      if not taken[k] then
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
      local _ = lists_of(ctx, c, nil)
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
    function_body(ctx, s.fn.params, s.fn.body, ft, names_of_params(s.typeparams), s, s.fn.rets ~= nil, s.fn.id,
      s.name.name)
  elseif (s.kind == "Function") then
    function_statement(ctx, s)
  elseif (s.kind == "While") then
    while_statement(ctx, s)
  elseif (s.kind == "Repeat") then
    repeat_statement(ctx, s)
  elseif (s.kind == "Do") then
    block(ctx, s.body)
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
stats = function(ctx: Ctx, b: Ast.Block)
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

block = function(ctx: Ctx, b: Ast.Block)
  stats(ctx, b)
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

function Check.check(program: Declarations.Program, input: Declarations.Input, lowered: Declarations.Lowered,
                     typed?: boolean): Check.Checked
  local store = program.store
  local ctx: Ctx = {
    program = program, store = store, judge = program.judge, input = input, lowered = lowered, scoped = input.scoped,
    tokens = input.chunk.tokens, filename = input.filename, errors = {}, vars = {}, frames = {}, binders = {},
    bounds = {}, lenient = 0, members = {}, value_members = {}, pending = {}, within = 0, probes = {},
    load = LoadOrder.new(0, function(_decl: Decl, _name: string): boolean
      return false
    end, function(_node: Ast.Node, _spelled: string, _found: LoadOrder.Found) end),
    literals = {}, declared = {}, union_fields = {}, spine = {},
    top = 0, ternaries = {}, invalid = store.invalid, nil_type = store:atom("nil"), flow = Flow.start(), unfixed_now = {}, assigning = {}, quiet = 0, callee_module = "", member_module = "",
    loops = {}, keys = {}, edges = {}, guards = {}, reads = {}, unfixed = {}, narrowed = {}, boundaries = {}, types = {}, callees = {}, consts = {}, library = {}, typed = typed ~= false, warnings = {},
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
    local owner = read.decl.name .. "." .. read.name
    local through = ""
    if #found.via > 0 then
      local names: mut {string} = {}
      for i, via in ipairs(found.via) do
        names[i] = via
      end
      through = " through " .. table.concat(names, ", ")
    end
    report(ctx, "static_before_definition", node, spelled .. " is called, or handed to code that may call it, as " ..
        "the module loads, and" .. through .. " it reads the function " .. quoted(owner) .. " (line " ..
        tostring(Lexer.y(ctx.tokens, read.first)) .. ") before the statement that defines it has run",
      "move the statement `function " .. owner .. "(...)` above this use of " .. spelled .. ", or use " ..
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
      reads[#reads + 1] = v
      if c.after then
        local unfixed = ctx.unfixed[c.fn]
        if unfixed == nil then
          unfixed = {}
          ctx.unfixed[c.fn] = unfixed
        end
        unfixed[v.id] = true
      end
    end
  end
  for _, top in ipairs(input.chunk.body.stats) do
    if (top.kind == "Function") and #top.path == 2 then
      local binding = assert(top.path[1]).binding
      local entry = binding ~= nil and lowered.entries[binding] or nil
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
  ctx.frames[1] = {
    alts = {}, rest = store.string, chunk = true, declared = false, narrows = nil, narrowed_id = 0, narrowed_name = "",
    narrowed_type = nil,
  }
  block(ctx, input.chunk.body)
  -- Source order; errors at one place stay in the order they were found.
  local position: mut {Codes.Error: integer} = {}
  for i, e in ipairs(ctx.errors) do
    position[e] = i
  end
  table.sort(ctx.errors, function(a: Codes.Error, b: Codes.Error): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return position[a] < position[b]
  end)
  local narrowed: mut {Check.Narrowed} = {}
  for _, n in pairs(ctx.narrowed) do
    narrowed[#narrowed + 1] = n
  end
  table.sort(narrowed, function(a: Check.Narrowed, b: Check.Narrowed): boolean
    return a.offset < b.offset
  end)
  local warnings = ctx.warnings
  for _, w in ipairs(Warnings.usage(ctx.filename, ctx.tokens, ctx.scoped, ctx.vars, function(t: Type): string
    return Types.display(t, {})
  end)) do
    warnings[#warnings + 1] = w
  end
  table.sort(warnings, function(a: Warnings.Warning, b: Warnings.Warning): boolean
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
    errors = ctx.errors, vars = ctx.vars, literals = ctx.literals, narrowed = narrowed, boundaries = boundaries,
    types = ctx.types, callees = ctx.callees, warnings = warnings,
  }
end

return Check
