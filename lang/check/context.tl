--- What one check of a module holds ([`Context.Ctx`]) and the helpers every part of the checker ([`lang.check`]) reads it
--- with: how a type and a node are shown, the keys of places, and the relations of types the parts ask most.

local Ast = require("lang.ast")
local Codes = require("lang.check_codes")
local Declarations = require("lang.declarations")
local Flow = require("lang.flow")
local Generics = require("lang.generics")
local Lexer = require("lang.lexer")
local LoadOrder = require("lang.load_order")
local Relation = require("lang.relation")
local Scopes = require("lang.scopes")
local Types = require("lang.types")
local Warnings = require("lang.warnings")
local type Sql = require("lang.sql")
local type Type = Types.Type
local type Alt = Types.Alt
local type Decl = Types.Decl
local type Store = Types.Store

--
-- TODO: record in [`Narrowed`] the facts it leaves out, and have [`lang.fact_wraps`] pass them: a number that a test took
-- to be an integer or a float ([`Tests.lua_kind`] maps both to `"number"`), a `thread` (`LUA_KINDS` has none), an enum or
-- a string that an `==` test narrowed (no read is wrapped), and `true` against `false` of a boolean. A run misses a
-- false conclusion of these and refuses nothing valid. Once a full `cosmic test --check-types` run (CI's two `checked-narrowing`
-- shares together) has a time to compare, so that the cost of a call per read of each decides which are worth it.
--- A read of a local, of a path of fixed fields from one, or of an element a length test proved, whose type a test
--- narrowed. The checker took the value to have none of the kinds of Lua value in `taken`, and the values of the enums,
--- classes and tags the other fields name, which a run can check at the read.
local record Narrowed
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

local enum Role
  "parameter"
end

--- A value that crosses a typed boundary of the program, for a run that checks it at the boundary
--- ([`lang.boundary_checks`]). Only parameters are listed so far: `id` is the id of the node of the function (its [`Types.Fn`],
--- or the `Method` of a class), and a function with several checked parameters has a row for each, by `param`.
local record Boundary
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

-- State ----------------------------------------------------------------------------------

--- The members called one name in a declaration, in the order they are declared.
local record Member
  type: Type
  mut: boolean
  method: boolean
  --- The names its parameters were declared with, where it is a function ([`Types.Field.params`]).
  params?: {string}
end

--- A declaration's members by name, and its array part.
local record Members
  --- The functions of the declaration used as a value that take a value of the declaration first, by name: the shape of a
  --- method, whether or not a value of the declaration can reach it.
  selfish: mut {string: boolean}
  by_name: mut {string: {Member}}
  array: Type?
end

--- Where the program lets a table out of the local that names it, for each local that holds a table literal.
local record Privacy
  record Span
    first: integer
    last: integer
  end
  --- The locals declared with a table literal, by the id of the binding.
  literal: mut {integer: boolean}
  --- The locals declared with a table literal that has no item (`{}`).
  empty: mut {integer: boolean}
  --- The first token of each read of such a local that [`Writes.stays_private`] does not allow, by the id of the binding.
  escapes: mut {integer: mut {integer}}
  --- The first and last token of each loop.
  loops: mut {Privacy.Span}
end

--- What a numeric loop `for i = 1, #t do` whose body leaves the length of `t` alone knows: `i` is a key `t` has for as long
--- as the body runs, so a non-nil value written at it overwrites a slot and leaves no hole ([`Writes.leaves_no_hole`]).
local record Fill
  --- The id of the binding of `i`.
  var: integer
  --- The local `t`, as the loop writes it.
  object: Ast.Exp
  --- Whether the loop steps by 1 (no step, or a literal 1). It need not reach `#t`: a limit of `math.min(n, #t)` stops
  --- short of it.
  unit: boolean
end

--- What a numeric loop `for i = a, #t - b do` by 1 whose body leaves the length of `t` alone knows: `i` is an integer from
--- `from` to the length of `t` less `slack` for as long as the body runs, so `t[i + c]` is an element `t` has where
--- `from + c` is 1 or more and `c` is at most `slack` ([`Writes.counted_read`]).
local record Span
  --- The id of the binding of `i`.
  var: integer
  --- The local `t`, as the loop writes it.
  object: Ast.Exp
  --- The literal `a` the loop starts at, 1 or more.
  from: integer
  --- The literal `b` the loop stops short of `#t` by, 0 where it runs to `#t`.
  slack: integer
end

--- What a loop whose index counts 1, 2, 3 and so on, and writes `a[i]` in every pass before any `continue`, knows of the
--- arrays `a` it fills ([`Writes.grow_in`]): at each write the array has the keys 1 to `i - 1` at least, so a value that is
--- not nil written at `i` overwrites a key or appends ([`Writes.leaves_no_hole`]).
local record Grow
  --- The id of the binding of `i`.
  var: integer
  --- The ids of the bindings of the arrays the loop fills.
  arrays: {integer: boolean}
end

--- A loop being walked: where its `break`s and `continue`s leave from.
local record Loop
  --- The states at the `break`s, met: nil where none.
  breaks: Flow.State?
  --- The states at the `continue`s, met.
  continues: Flow.State?
  --- What the loop knows of the keys it counts, where it counts the keys of an array.
  fill: Fill?
  --- What the loop knows of the arrays it fills in order, where it counts from 1 by 1.
  grow: Grow?
  --- What the loop knows of the keys around its index, where it counts keys of an array by 1.
  span: Span?
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

--- A local tied to the first of its statement: the type it has in the lists that begin with `true`, and in those that
--- begin with `false`.
local record TieSlot
  id: integer
  yes: Type
  no: Type
end

--- The locals a `local` statement bound to the values of one call whose lists are told apart by a first value of `true` or
--- `false` (`local ok, r = pcall(f)`), or by a first value that is `nil` or is not (`local v, why = f()` of a call that
--- returns `(T) | (nil, E)`): the test of the first narrows the others to the lists that first value selects.
local record Tie
  --- The id of the first local, which holds the tag.
  first: integer
  --- Whether the lists are told apart by a first value of `nil`, where the selected lists have one that is never nil,
  --- rather than by `true` and `false`.
  by_nil: boolean
  --- Whether a test of the truth of the first value tells the lists apart: they are told by `true` and `false`, or by
  --- `nil` and a value that is never `false` either. `v == nil` tells lists told by `nil` where `if v` does not.
  truth: boolean
  --- The others, in order.
  rest: {TieSlot}
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
  --- Whether it is the module's own chunk, whose `return` is what `require` returns.
  chunk: boolean
  --- Whether the return list was written, for the message.
  declared: boolean
end

--- What one `check` holds.
local record Ctx
  --- The walk's own functions, which lang/check/init.tl defines, for the modules of lang/check/ it requires to call:
  --- an expression's type and its lists of values, the edges out of a condition, and the walk of statements.
  record Walk
    expr: function(ctx: Ctx, e: Ast.Exp, expected: Type?): Type
    lists_of: function(ctx: Ctx, e: Ast.Exp, expected: Type?): {Alt}
    leaf: function(ctx: Ctx, e: Ast.Exp, expected: Type?): Type
    evaluate: function(ctx: Ctx, e: Ast.Exp, expected: Type?, wants_lists: boolean): Type, {Alt}?
    edges: function(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State, Flow.State
    block: function(ctx: Ctx, b: Ast.Block)
    stats: function(ctx: Ctx, b: Ast.Block)
    stat: function(ctx: Ctx, s: Ast.Stat)
  end
  walk: Walk
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
  --- The names of the type parameters of the generic functions this module declares, by the id of each one's type, so
  --- an error shows a function with its author's names (`function<Item>(Item): Item`), not letters.
  fn_names: mut {integer: {string}}
  --- How many generic-call arguments are being checked: a literal there has no type to be checked against.
  mut lenient: integer
  --- The `==` or `~=` an operand of which is being checked against the other's type: a string literal there that is no
  --- member of an enum makes a test that is always false (or true).
  mut comparing?: Ast.Binary
  --- Set while the arguments of a generic call are checked: a function there is held to the parameters of the type it is
  --- instantiated to, which no declaration spells, so it never drops a trailing parameter.
  mut no_drop: boolean
  members: {Decl: Members}
  --- The same for a declaration used as a value, which also has its statics.
  value_members: {Decl: Members}
  --- The `function R.m(...)` statements at the top of the module that the walk has not passed, by declaration and name.
  pending: mut {Decl: mut {string: boolean}}
  --- What the functions read of those statics, for the functions the module runs as it loads ([`lang.load_order`]).
  mut load: LoadOrder.State
  --- The local the module's last statement returns where it is a record of the module's own, the module's table, and nil
  --- where it is not; the statements of the chunk itself, not of a block or function within it, by id; and the fields of
  --- the table a statement has given (`inits_module` in [`lang.check`]).
  module_table: integer?
  top: {integer: boolean}
  initialized: mut {string: boolean}
  --- The fields of the module's table that a statement `M.f = v` of the chunk gives, which `pending` names as a function
  --- statement's are named; and whether a `return` of the chunk outside any function has been passed, which may have handed
  --- the table out before the last statement.
  given: mut {string: boolean}
  mut handed: boolean
  --- The id of the function being walked, 0 in the chunk.
  mut within: integer
  --- The class each table literal of a class is a literal of, by the id of its node.
  literals: mut {integer: Decl}
  --- The fields each table literal with a spread copies, by the id of its node.
  spreads: mut {integer: {string}}
  --- The tests of a record by its tag, by the id of the tested type's node ([`Check.Checked`]'s `tags`).
  tags: mut {integer: {string}}
  --- The classes whose declaration the walk has passed: a literal or a test of a class before that reads a name that
  --- is not yet its table.
  declared: mut {Decl: boolean}
  --- The type of a field read through a union, by the union and the field.
  union_fields: mut {string: Type}
  --- The field reads that only ask whether a method is there (`a.cb ~= nil`, `if a.cb then`): nothing of the method
  --- escapes through them, so they are no use of it as a value.
  probes: mut {integer: boolean}
  --- The nodes a left-leaning chain visits and has not yet applied, the innermost last.
  spine: mut {Ast.Exp}
  --- The overloads the callee last found, and the node that found them.
  mut cands: {Type}?
  mut cand_node: Ast.Node?
  --- The `or` that has an `and` for its left operand, by the id of the `and`.
  ternaries: mut {integer: Ast.Binary}
  --- The type of the right operand of each `and` and `or`, by the id of the operator: as a condition, the right operand
  --- is the one whose value is asked (the left is checked where it is walked).
  right_types: mut {integer: Type}
  --- The calls whose one value was taken where they may return more, by id: `or` after one cuts the rest.
  spare: mut {integer: boolean}
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
  --- How many quiet walks that test a proof of keys ([`Writes.keeps_length`] with calls pending) the walk is inside: a
  --- loop or a range test within one takes its proof on trust, and the walk after tests it, so the cost of nested proofs
  --- stays linear in their depth.
  mut proving: integer
  --- How many `<close>` locals the walk is inside the scope of: a handler runs when the scope ends, so no test of the
  --- length of an array is believed there ([`Tests.length_edges`]).
  mut closers: integer
  --- The module that declares the callee of the call being dispatched, "" where the walk does not know it.
  mut callee_module: string
  --- The module of the declaration the last member read took its member from, "" where it had none.
  mut member_module: string
  --- The expression that read it.
  mut member_node: Ast.Node?
  --- The call argument being checked: [`Naming.report`] gives it to the error it files.
  mut argument: Codes.Argument?
  --- Added to the fix of an error reported now: what a call spilling values into later parameters did ([`Calls.spill_note`]).
  mut spill: string?
  --- The loops being walked, innermost last.
  mut loops: mut {Loop}
  --- The reads of a map, by the id of the node: an index read that may be nil there is a missing key, not a key past
  --- the end (`index_fix` in [`lang.check`]).
  map_reads: mut {integer: boolean}
  --- The range tests of the arms of `if` being walked ([`Writes.ranges_of`]), innermost last: what a write
  --- ([`Writes.leaves_no_hole`]) and a read ([`Writes.counted_read`]) at the index tested stand on.
  mut ranges: mut {Fill}
  --- The key of each local's place, by id.
  keys: mut {integer: string}
  --- The edges of the `and`s and `or`s evaluated, by the id of the node.
  edges: mut {integer: Edges}
  --- The calls that narrow an argument, by the id of the node.
  guards: mut {integer: Guarded}
  --- The ties of the locals of a `local` statement, by the id of its first local ([`Tie`]).
  ties: mut {integer: Tie}
  --- The member reads, by the id of the node, of a member of the standard library's `coroutine` record.
  coroutine_reads: mut {integer: boolean}
  --- By the id of a function: the locals it reads from outside (named where it is made), and those an assignment may
  --- change after it is made ([`Scopes.Capture.after`]), which no fact of the code around it holds inside it.
  reads: mut {integer: {Scopes.Var}}
  unfixed: mut {integer: {integer: boolean}}
  --- What the program does with the locals that hold a table literal ([`Writes.privacy`]), worked out the first time a write
  --- asks.
  mut privacy: Privacy?
  --- The names of the fields the program writes of each table literal it gives a local, by the id of the literal's node
  --- ([`TableLiterals.writes`]), worked out the first time a literal asks.
  mut literal_writes: {integer: {string: boolean}}?
  --- The records inferred for literals with named items, by the text of their fields ([`TableLiterals.inferred`]).
  inferred: mut {string: Decl}
  --- The reads of narrowed places, by the id of the node of the read.
  narrowed: mut {integer: Narrowed}
  --- The calls, by the id of the node, that run no code of the program ([`Tests.inert_callee`]): the facts about the length of
  --- an array stand through them.
  inert: mut {integer: boolean}
  --- The comparisons, by the id of the node, that run code of the program, as a call does: of two values of a class,
  --- which call its `__lt` or `__le`, and of two of a type parameter bounded by `Ordered`, which a class may meet.
  runs: mut {integer: boolean}
  --- The parameters of the functions checked, by the id of the binding of the parameter.
  boundaries: mut {integer: Boundary}
  --- The type of each expression typed, by the id of its node, and the warnings found.
  types: mut {integer: Type}
  --- The function each call took, by the id of the call node ([`Check.Checked.callees`]).
  callees: mut {integer: Type}
  --- The text of each local that is given a string literal and never assigned, by id: what a literal pattern or format
  --- held in a local says.
  consts: mut {integer: string}
  --- The schemas whose handles' SQL the rest of the module no longer reads: a handle of one was sent SQL that may
  --- make a table or attach a database, or was migrated ([`Calls.sql_arguments`]).
  unread_schemas: mut {Decl: boolean}
  --- The locals made from an empty literal with no type, by id, until the first store in each gives it one ([`lang.check.unfilled`]).
  unfilled: mut {integer: Ast.Table}
  mut unfilled_n: integer
  --- The result columns of each call of `rows` or `one` on a handle of a `local schema` with literal SQL
  --- that SQLite prepares against it, by the id of the call.
  call_columns: mut {integer: {Sql.Column}}
  --- The result columns of the rows each local holds, by id: a local given `db:rows(sql)` of a handle
  --- of a `local schema` ([`Calls.result_columns`]).
  row_lists: mut {integer: {Sql.Column}}
  --- The result columns of the row each local holds, by id: one given `db:one(sql)`, a `for` variable
  --- over a list [`Ctx.row_lists`] holds, or the parameter of the function given `db:map`.
  row_columns: mut {integer: {Sql.Column}}
  --- The integer literal as written (`0`) that starts each local declared without a type, by binding: an `integer` the
  --- program may mean as a `number`.
  starts: mut {integer: string}
  --- The name the assignment being checked writes, which `refused` in [`lang.check`] reads for the fix of a `number` it refuses.
  mut written: Ast.Name?
  --- The name of the function of the string library each local that is given one and never assigned holds, by id.
  library: mut {integer: string}
  --- The type each local declares in its statement, by the id of the local's binding: where a view that is written is
  --- declared ([`Writes.view_rewrite`]).
  annotated: mut {integer: Ast.Type}
  --- Each `s:sub(...)` whose `s` is a string, by the call's id: its bounds bound what it answers ([`Operators.short_range`]).
  string_subs: mut {integer: boolean}
  --- The reads of `table.move` not yet taken as the callee of a call, by the id of the node ([`Writes.move_stray`]).
  moves: mut {integer: Ast.Node}
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

local record Context
  type Narrowed = Narrowed
  type Role = Role
  type Boundary = Boundary
  type Member = Member
  type Members = Members
  type Privacy = Privacy
  type Fill = Fill
  type Span = Span
  type Grow = Grow
  type Loop = Loop
  type Guarded = Guarded
  type Edges = Edges
  type TieSlot = TieSlot
  type Tie = Tie
  type Frame = Frame
  type Ctx = Ctx
end

function Context.base_of(node: Ast.Node): Ast.Base
  return node
end
local base_of = Context.base_of

function Context.quoted(s: string): string
  return "`" .. s .. "`"
end
local quoted = Context.quoted

function Context.show(ctx: Ctx, t: Type): string
  return Types.display(t, ctx.binders, ctx.fn_names)
end
local show = Context.show

function Context.tq(ctx: Ctx, t: Type): string
  return quoted(show(ctx, t))
end

--- The text of the tokens of `node`, cut at a length a message can hold.
function Context.text_of(ctx: Ctx, node: Ast.Node): string
  local b = base_of(node)
  -- The `must` of `e!` is written nowhere: its name is its text.
  if b.last < b.first and node.kind == "Name" then
    return node.text
  end
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
local text_of = Context.text_of

--- The text of the tokens of `node`, whole: spaces between tokens as one, and no comment. For a rewrite that writes the
--- node again.
function Context.full_text(ctx: Ctx, node: Ast.Node): string
  local b = base_of(node)
  if b.last < b.first then
    return text_of(ctx, node)
  end
  local tokens = ctx.tokens
  local parts: mut {string} = {}
  for i = b.first, b.last do
    if i > b.first and Lexer.offset(tokens, i) > Lexer.stop(tokens, i - 1) then
      parts[#parts + 1] = " "
    end
    parts[#parts + 1] = Lexer.text(tokens, i)
  end
  return table.concat(parts)
end

function Context.subject(ctx: Ctx, node: Ast.Node): string
  return quoted(text_of(ctx, node))
end

function Context.peel(e: Ast.Node): Ast.Node
  local at = e
  while (at.kind == "Paren") do
    at = at.inner
  end
  return at
end
local peel = Context.peel

--- The key of the place of the local `id`.
function Context.id_key(ctx: Ctx, id: integer): string
  local key = ctx.keys[id]
  if key == nil then
    key = tostring(id)
    ctx.keys[id] = key
  end
  return key
end
local id_key = Context.id_key

--- The key of the place a name or a chain of fields from a name is, whatever the facts hold of it: a local's id, then
--- `.` and each field. Nil for any other expression.
function Context.path_key(ctx: Ctx, e: Ast.Exp): string?
  local at = peel(e)
  if (at.kind == "Name") then
    local id = at.binding
    return id ~= nil and id_key(ctx, id) or nil -- checked: and_ternary
  elseif (at.kind == "Field") then
    local base = Context.path_key(ctx, at.object)
    return if base ~= nil then base .. "." .. at.name else nil end
  end
  return nil
end
local path_key = Context.path_key

--- Where an assignment dropped the fact the place of `node` had, or nil.
function Context.dropped_by(ctx: Ctx, node: Ast.Node): Scopes.Place?
  if next(ctx.flow.gone) == nil then
    return nil
  end
  local at = peel(node)
  if (at.kind == "Name") or (at.kind == "Field") then
    local key = path_key(ctx, at)
    return key ~= nil and ctx.flow.gone[key] or nil -- checked: and_ternary
  end
  return nil
end

--- Whether `t` is `nil` or has the nil flag.
function Context.nilable(t: Type): boolean
  return t.tag == "nil" or ((t.tag == "union") and t.nilable)
end

function Context.is_bool(t: Type): boolean
  local tag = t.tag
  return tag == "boolean" or tag == "true" or tag == "false"
end

function Context.is_text(t: Type): boolean
  return t.tag == "string" or ((t.tag == "named") and t.decl.kind == "enum")
end

function Context.is_enum(t: Type): boolean
  return (t.tag == "named") and t.decl.kind == "enum"
end
local is_enum = Context.is_enum

--- Whether `t` is a value of an integer enum, an `integer` to every operator; the enum's table is not one.
function Context.is_integer_enum(t: Type): boolean
  return (t.tag == "named") and t.decl.kind == "integer_enum" and not t.value
end

--- `t` as a reader of the collection it is through sees it: a `mut` collection in it is a view, through arrays,
--- maps and unions and not through a named type.
function Context.view(store: Store, t: Type): Type
  if not t.has_mut then
    return t
  elseif (t.tag == "array") then
    return store:array(Context.view(store, t.element), false)
  elseif (t.tag == "map") then
    return store:map(t.key, Context.view(store, t.value), false)
  elseif (t.tag == "union") then
    local members: mut {Type} = {}
    for i, m in ipairs(t.members) do
      members[i] = Context.view(store, m)
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
function Context.members_of(store: Store, t: Type): {Type}
  local out: mut {Type} = {}
  local function add(m: Type)
    if (m.tag == "union") then
      for _, inner in ipairs(m.members) do
        out[#out + 1] = inner
      end
      if m.nilable then
        table.insert(out, store:atom("nil"))
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
      table.insert(out, store:atom("nil"))
    end
  else
    add(whole)
  end
  return out
end
local members_of = Context.members_of

--- Whether `t` is an enum, or a union with one.
function Context.has_enum(ctx: Ctx, t: Type): boolean
  for _, m in ipairs(members_of(ctx.store, t)) do
    if is_enum(m) then
      return true
    end
  end
  return false
end

--- Whether `a` is below `b`, as the program's judge says.
function Context.below(ctx: Ctx, a: Type, b: Type): boolean
  if a == b or a.tag == "invalid" or b.tag == "invalid" or a.tag == "never" then
    return true
  end
  return ctx.judge:subtype(a, b)
end
local below = Context.below

--- Whether `a` may be passed to a parameter of type `b`.
function Context.accepts(ctx: Ctx, a: Type, b: Type): boolean
  return b.tag == "any" or below(ctx, a, b)
end

--- A text for the list of `items` joined by ", " and a last `joiner` ("or" by default).
function Context.listed(items: {string}, joiner?: string): string
  if #items <= 1 then
    return items[1] or ""
  end
  local head: mut {string} = {}
  for i = 1, #items - 1 do
    head[i] = assert(items[i])
  end
  return table.concat(head, ", ") .. " " .. (joiner or "or") .. " " .. items[#items]
end

--- The name of `names` nearest to `name`, within an edit or two, or "".
function Context.nearest(name: string, names: {string}): string
  --- How far apart two names are, up to `limit`: `limit + 1` for more.
  local function distance(a: string, b: string, limit: integer): integer
    local la, lb = #a, #b
    if la - lb > limit or lb - la > limit then
      return limit + 1
    end
    local previous: mut {integer: integer} = {}
    for j = 0, lb do
      previous[j] = j
    end
    for i = 1, la do
      local row: mut {integer: integer} = { [0] = i }
      local least = i
      for j = 1, lb do
        local cost = if a:byte(i) == b:byte(j) then 0 else 1 end
        local best = math.min(previous[j - 1] + cost, previous[j] + 1, row[j - 1] + 1) -- checked: nil_not_allowed*3
        row[j] = best
        least = math.min(least, best)
      end
      if least > limit then
        return limit + 1
      end
      previous = row
    end
    return previous[lb] -- checked: index_may_be_nil
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

return Context
