--- The new checker's expressions ([`doc/plans/new-checker-types.md`], "checking" and "errors"): every
--- expression and statement of a module's bodies typed against the declarations [`lang.declarations`] lowered,
--- by the relation of [`lang.relation`], without flow.
---
--- [`Check.check`] walks a lowered module in source order. An expression is inferred ([`expr`]), with the type
--- the position expects where it has one, which only a literal uses: a table, a function, a string for an enum,
--- a boolean for `true`. What is inferred is then required to be below what the position wants, and where it is
--- not the error names the rule, the place and the change that fixes it ([`lang.check_codes`]).
---
--- **What it checks.** Literals, names, fields, indexes, operators and concatenation; calls of functions that
--- are not generic, with the first-match rule of overloads; table literals against the expected type (records
--- included); assignments, writes to fields (fixed unless `mut`) and indexes (views are never written, and an
--- array grows by an append); returns against the declared list; conditions (booleans or optionals) and the
--- honest `or` and `and`; numeric keys, views and `mut` collections, records and maps.
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
--- **What it leaves.** No test narrows a type, and no assignment is tracked: a value that may be nil stays
--- so until the flow piece lands, and a read of a name before its assignment, a function that can reach its
--- end without its return, and the arms of a `match` are that piece's. A call of a generic function, a
--- protected call, a coroutine function and a `match` are typed `invalid` and reported (`unchecked_*`), so
--- that no `invalid` is silent: the one that stands for a mistake already reported, by this checker or by the
--- lowering of the declarations, is the only other.
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
local Lexer = require("lang.lexer")
local Relation = require("lang.relation")
local Scopes = require("lang.scopes")
local Types = require("lang.types")

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

  --- What checking a module answers.
  record Checked
    --- The errors, in source order.
    errors: {Codes.Error}
    --- The type of each local, parameter and loop variable that was given one, by [`Scopes.Var.id`].
    vars: {integer: Type}
    --- The class of each table literal that makes a value of a class, by the id of its node: what the code
    --- generator writes as the class literal, a class of this module.
    literals: {integer: Decl}
  end

  --- Checks `input`, which `program` has lowered into `lowered` ([`Declarations.Program.lower`]), and answers
  --- its errors. The modules it requires must be lowered: a type whose declaration has no body raises
  --- `relation: <declaration> is not defined`.
  check: function(program: Declarations.Program, input: Declarations.Input, lowered: Declarations.Lowered): Checked

  --- Every [`Codes.Code`] an error may have, with its row in [`Check.catalog`] or in [`Declarations.catalog`].
  codes: {Codes.Code}

  --- The rule behind each code of [`lang.check_codes`].
  catalog: {Codes.Row}
end

Check.codes = Codes.codes
Check.catalog = Codes.catalog

-- State ----------------------------------------------------------------------------------

--- The members called one name in a declaration, in the order they are declared.
local record Member
  type: Type
  mut: boolean
  method: boolean
end

--- A declaration's members by name, and its array part.
local record Members
  by_name: {string: {Member}}
  array: Type | nil
end

--- A function being checked.
local record Frame
  --- What it may return: a set of lists. Empty, it never returns.
  alts: {Alt}
  --- The type of each value `...` stands for, or nil where it has no rest parameter.
  rest: Type | nil
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
  tokens: {Lexer.Token}
  filename: string
  errors: {Codes.Error}
  vars: {integer: Type}
  frames: {Frame}
  --- The names of the type parameters of the binders in scope, outermost first, for display, and their bounds.
  binders: {{string}}
  bounds: {{Types.TParam}}
  --- How many generic-call arguments are being checked: a literal there has no type to be checked against.
  lenient: integer
  members: {Decl: Members}
  --- The same for a declaration used as a value, which also has its statics.
  value_members: {Decl: Members}
  --- The class each table literal of a class is a literal of, by the id of its node.
  literals: {integer: Decl}
  --- The classes whose declaration the walk has passed: a literal or a test of a class before that reads a name that
  --- is not yet its table.
  declared: {Decl: boolean}
  --- The type of a field read through a union, by the union and the field.
  union_fields: {string: Type}
  --- The nodes a left-leaning chain visits, and how many are in use.
  spine: {Ast.Exp}
  top: integer
  --- The overloads the callee last found, and the node that found them.
  cands: {Type} | nil
  cand_node: Ast.Node | nil
  --- The `or` that has an `and` for its left operand, by the id of the `and`.
  ternaries: {integer: Ast.Binary}
  --- The offsets of the names the scope builder reported unknown, once asked for.
  unknown: {integer: boolean} | nil
  invalid: Type
  nil_type: Type
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
  local parts: {string} = {}
  local previous: Lexer.Token | nil = nil
  for i = b.first, last do
    local t = tokens[i]
    if previous ~= nil and t.offset > previous.offset + previous.length then
      parts[#parts + 1] = " "
    end
    parts[#parts + 1] = t.text
    previous = t
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

--- Reports `code` on the tokens of `node`.
local function report(ctx: Ctx, code: Code, node: Ast.Node, msg: string, fix: string, shown?: {string},
                      other?: Scopes.Place)
  local b = base_of(node)
  local tokens = ctx.tokens
  local a = tokens[b.first]
  local z = tokens[math.max(b.first, b.last)]
  ctx.errors[#ctx.errors + 1] = {
    filename = ctx.filename, code = code, msg = msg, fix = fix, y = a.y, x = a.x, offset = a.offset,
    length = math.max(0, z.offset + z.length - a.offset), other = other, types = shown or {},
  }
end

--- Whether `t` is `nil` or has the nil flag.
local function nilable(t: Type): boolean
  return t.tag == "nil" or (t is Types.Union and t.nilable)
end

local function is_bool(t: Type): boolean
  local tag = t.tag
  return tag == "boolean" or tag == "true" or tag == "false"
end

local function is_text(t: Type): boolean
  return t.tag == "string" or (t is Named and t.decl.kind == "enum")
end

local function is_enum(t: Type): boolean
  return t is Named and t.decl.kind == "enum"
end

--- `t` as a reader of the collection it is through sees it: a `mut` collection in it is a view, through arrays,
--- maps and unions and not through a named type.
local function view(store: Store, t: Type): Type
  if not t.has_mut then
    return t
  elseif t is Types.Array then
    return store:array(view(store, t.element), false)
  elseif t is Types.Map then
    return store:map(t.key, view(store, t.value), false)
  elseif t is Types.Union then
    local members: {Type} = {}
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

--- The members of a union (the nil flag as `nil`), or the type alone.
local function members_of(store: Store, t: Type): {Type}
  if t is Types.Union then
    local out: {Type} = {}
    for i, m in ipairs(t.members) do
      out[i] = m
    end
    if t.nilable then
      out[#out + 1] = store:atom("nil")
    end
    return out
  end
  return { t }
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
local function join(ctx: Ctx, list: {Type}): Type | nil
  local store = ctx.store
  local best: Type | nil = nil
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
  local head: {string} = {}
  for i = 1, #items - 1 do
    head[i] = items[i]
  end
  return table.concat(head, ", ") .. " " .. (joiner or "or") .. " " .. items[#items]
end

--- How far apart two names are, up to `limit`: `limit + 1` for more.
local function distance(a: string, b: string, limit: integer): integer
  local la, lb = #a, #b
  if la - lb > limit or lb - la > limit then
    return limit + 1
  end
  local previous: {integer} = {}
  for j = 0, lb do
    previous[j] = j
  end
  for i = 1, la do
    local row: {integer} = { [0] = i }
    local least = i
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
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

--- The name of `names` nearest to `name`, within an edit or two, or "".
local function nearest(name: string, names: {string}): string
  local limit = #name <= 2 and 0 or #name <= 5 and 1 or 2
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

local expr: function(ctx: Ctx, e: Ast.Exp, expected: Type | nil): Type

-- Members --------------------------------------------------------------------------------

--- The members of `decl` by name, or nil where it has no body to read. Where `value` they are those of the
--- declaration used as a value: the statics its `function R.m(...)` statements gave it besides, and no array part. The
--- table of a class holds its methods and statics and none of the fields of its values, so a class's value has no
--- field. A record's value keeps the fields it declares, since a module record declares its functions and constants
--- as fields.
local function members_index(ctx: Ctx, decl: Decl, value: boolean): Members | nil
  local cache = value and ctx.value_members or ctx.members
  local held = cache[decl]
  if held ~= nil then
    return held
  end
  local body = decl.body
  if body == nil then
    return nil
  end
  local index: Members = { by_name = {}, array = not value and body.array or nil }
  for _, f in ipairs(body.fields) do
    if not (value and decl.kind == "class") then
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
  if value then
    for name, f in pairs(ctx.program.statics[decl] or {}) do
      local list = index.by_name[name] or {}
      list[#list + 1] = { type = f.type, mut = false, method = false }
      index.by_name[name] = list
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
  local out: {string} = {}
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

local function peel(e: Ast.Node): Ast.Node
  local at = e
  while at is Ast.Paren do
    at = at.inner
  end
  return at
end

-- Refusals -----------------------------------------------------------------------------------

--- The fix for a value that may be nil.
local function nil_fix(ctx: Ctx, node: Ast.Node): string
  local e = peel(node)
  if e is Ast.Call or e is Ast.MethodCall then
    local call = subject(ctx, e)
    return "take the value with `local v = assert(" .. text_of(ctx, e) .. ")`, or test it first (`if v == nil then " ..
      "return nil, why end`); " .. call .. " answers nil when it fails"
  end
  local s = text_of(ctx, e)
  if e is Ast.Field then
    return "copy " .. quoted(s) .. " to a local and test that: `local v = " .. s .. " if v ~= nil then ... end`, or " ..
      "take it with `assert(" .. s .. ")`"
  end
  return "test it first (`if " .. s .. " == nil then return nil, why end`), or take it with `assert(" .. s .. ")`"
end

--- Reports that the value of `node`, of type `got`, is not below `want`, and `r` says why. `where` is a phrase that
--- says what wants it, with a space before it, or "".
local function refused(ctx: Ctx, node: Ast.Node, got: Type, want: Type, r: Relation.Refusal, where: string)
  local s = subject(ctx, node)
  local g, w = show(ctx, got), show(ctx, want)
  local shown = { g, w }
  local code = r.code
  local e = peel(node)
  if code == "nil" then
    if got.tag == "nil" then
      report(ctx, "nil_not_allowed", node, "nil is given" .. where .. ", where " .. quoted(w) .. " is wanted",
        "give a value, or declare what takes it `" .. w .. "?` (a parameter or field `name?: T`)", shown)
    elseif e is Ast.Index then
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
    report(ctx, "view_as_mut", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        ": the view " .. quoted(Types.display(r.sub, ctx.binders)) .. " is not " ..
        quoted(Types.display(r.super, ctx.binders)) .. ", which the receiver may change",
      "declare " .. s .. " `" .. w .. "` where it is made or received, or pass a collection made `mut`", shown)
  elseif code == "invariant_mut" or code == "invariant_key" then
    report(ctx, "invariant_mut", node, quoted(Types.display(r.sub, ctx.binders)) .. " is not " ..
        quoted(Types.display(r.super, ctx.binders)) .. " (" .. s .. " is " .. quoted(g) .. ", where " .. quoted(w) ..
        " is wanted" .. where .. "): a receiver could store another element type through a `mut` collection",
      "pass a view, or declare the receiver's type " .. quoted(g) .. " as the argument has it", shown)
  elseif code == "declaration_value" then
    local sub, super = r.sub, r.super
    local name = sub is Named and sub.decl.name or super is Named and super.decl.name or g
    local kind = sub is Named and sub.decl.kind or super is Named and super.decl.kind or "record"
    if kind ~= "class" then
      -- A module is a record used as a value, and a place that holds one (`Seatbelt: Seatbelt`, `local raw: hash =
      -- require(...)`) is typed with the record, which the grammar cannot spell as the declaration.
      report(ctx, "declaration_value", node, s .. " is " .. quoted(g) .. ", the table of the functions of " .. quoted(name) ..
          ", where " .. quoted(w) .. " is wanted" .. where,
        "no change of this program fixes it: the grammar has no type for " .. quoted(name) .. " used as a value yet " ..
          "(the TODO of `declaration_value` in lang/check.tl), and build/check_pins.tl holds the places that need one", shown)
    elseif sub is Named and sub.value then
      report(ctx, "declaration_value", node, s .. " is " .. quoted(g) .. ", the table of the functions of " .. quoted(name) ..
          ", where a value of " .. quoted(w) .. " is wanted" .. where,
        "make a value with a table literal typed as the type (`local v: " .. name .. " = { ... }`), or call a function " ..
          "of " .. quoted(name) .. " that makes one (`" .. name .. ".new(...)`)", shown)
    else
      report(ctx, "declaration_value", node, s .. " is a value of " .. quoted(name) .. ", where the declaration " ..
          quoted(name) .. " itself is wanted" .. where,
        "pass the declaration " .. quoted(name) .. ", not a value of it", shown)
    end
  elseif code == "record_as_map" or code == "map_as_record" then
    report(ctx, "record_as_map", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        ": " .. (code == "record_as_map" and "a record is not a map" or "a map is not a record"),
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
local function expect(ctx: Ctx, node: Ast.Node, got: Type, want: Type, where: string): boolean
  if below(ctx, got, want) then
    return true
  end
  local r = ctx.judge:refuse(got, want)
  if r ~= nil then
    refused(ctx, node, got, want, r, where)
  end
  return false
end

--- [`expect`] for a position that accepts any value as `any`: an argument to a parameter declared `any`.
local function expect_argument(ctx: Ctx, node: Ast.Node, got: Type, want: Type, where: string): boolean
  if want.tag == "any" then
    return true
  end
  return expect(ctx, node, got, want, where)
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
--- declaration ([`Types.Named`]'s `value`).
--
-- TODO: let a field be typed as a declaration used as a value, once the grammar has a type for one: a record that
-- re-exports a module as a field (`Seatbelt: Seatbelt` in [`cosmic.sandbox`]) types it as the module's record, and a
-- function of the module read through it is [`field_unknown`], since an instance has none of the statics. A record's
-- value still carries the fields its instances have, so the table of a record with a field it never defines is typed
-- as if it did.
local function declaration_value(ctx: Ctx, decl: Decl): Type
  local args: {Type} = {}
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
  if decl ~= nil then
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
  local out: {integer: boolean} = {}
  for _, e in ipairs(ctx.scoped.errors) do
    out[e.offset] = true
  end
  ctx.unknown = out
  return out
end

--- The type of a global the declaration files declare. The standard library's are the fork's, as
--- [`lang.stdlib_corrections`] corrects them: a function that answers nil where Lua does says so (`s:find(p)` is
--- `integer?`), so each use of its result is held to that.
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
  if unknown_offsets(ctx)[ctx.tokens[base_of(node).first].offset] then
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
local function string_value(ctx: Ctx, node: Ast.Node, value: string, expected: Type | nil): Type
  local store = ctx.store
  if expected == nil then
    return store.string
  end
  local enums = 0
  local values: {string} = {}
  for _, m in ipairs(members_of(store, expected)) do
    if m is Named and m.decl.kind == "enum" then
      enums = enums + 1
      local body = m.decl.body
      for _, v in ipairs(body ~= nil and body.values or {}) do
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
  local shown: {string} = {}
  for i, v in ipairs(values) do
    if i > 8 then
      shown[#shown + 1] = "..."
      break
    end
    shown[#shown + 1] = quoted(string.format("%q", v))
  end
  report(ctx, "enum_member", node, quoted(string.format("%q", value)) .. " is not a member of " .. tq(ctx, expected) ..
      (close ~= "" and ", nearest " .. quoted(string.format("%q", close)) or ""),
    "write " .. listed(shown), { show(ctx, expected) })
  return ctx.invalid
end

local function string_literal(ctx: Ctx, e: Ast.String, expected: Type | nil): Type
  return string_value(ctx, e, e.value, expected)
end

--- A boolean literal: `true` or `false` where the position wants that and not `boolean`.
local function boolean_literal(ctx: Ctx, e: Ast.Boolean, expected: Type | nil): Type
  local store = ctx.store
  if expected ~= nil and not below(ctx, store.boolean, expected) then
    local exact = store:atom(e.value and "true" or "false")
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
  types: {Type}
  --- Set when the last expression ends in `T...` or is `...`: any number more values of this type.
  tail: Type | nil
  --- Set when the last expression is a call with several lists, which are no values.
  lists: {Alt} | nil
  --- The last expression, when it was expanded.
  last: Ast.Exp | nil
end

local lists_of: function(ctx: Ctx, e: Ast.Exp, expected: Type | nil): {Alt}

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
local function values_of(ctx: Ctx, list: {Ast.Exp}, wants: {Type} | nil, rest_want: Type | nil): Values
  local out: Values = { types = {} }
  local n = #list
  for i, e in ipairs(list) do
    local want = rest_want
    if wants ~= nil and wants[i] ~= nil then
      want = wants[i]
    end
    if i < n then
      out.types[i] = expr(ctx, e, want)
    elseif e is Ast.Call or e is Ast.MethodCall then
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
    elseif e is Ast.Vararg then
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
  local out: {string} = {}
  local seen: {integer: boolean} = {}
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
    if item is Ast.Keyed then
      local _ = expr(ctx, item.key, nil)
      local _ = expr(ctx, item.value, nil)
    elseif item is Ast.Named then
      local _ = expr(ctx, item.value, nil)
    elseif item is Ast.Positional then
      local _ = expr(ctx, item.value, nil)
    end
  end
  ctx.lenient = ctx.lenient - 1
end

--- The kinds of item a literal holds: "positional", "named", "keyed", "mixed" or "empty".
local function shape_of(items: {Ast.Item}): string
  local shape = "empty"
  for _, item in ipairs(items) do
    local kind = item is Ast.Positional and "positional" or item is Ast.Named and "named" or "keyed"
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
  local out: {Ast.Exp} = {}
  for _, item in ipairs(items) do
    if item is Ast.Positional then
      out[#out + 1] = item.value
    end
  end
  return out
end

--- Whether a map is keyed by `k`: the key types of [`lang.declarations`].
local function valid_key(k: Type): boolean
  local tag = k.tag
  return tag == "integer" or tag == "string" or tag == "boolean" or k.tag == "invalid" or
    (k is Named and k.decl.kind ~= "enum" or is_enum(k))
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
  local keys: {Type} = {}
  local values: {Type} = {}
  for _, item in ipairs(items) do
    if item is Ast.Named then
      keys[#keys + 1] = store.string
      values[#values + 1] = expr(ctx, item.value, nil)
    elseif item is Ast.Keyed then
      keys[#keys + 1] = expr(ctx, item.key, nil)
      values[#values + 1] = expr(ctx, item.value, nil)
    end
  end
  local key = join(ctx, keys)
  local value = join(ctx, values)
  if key == nil or value == nil then
    report(ctx, "arms_differ", e, "the " .. (key == nil and "keys" or "values") .. " of this literal have no common type",
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
    if not (item is Ast.Positional) and not reported then
      reported = true
      wrong_shape(ctx, item, item is Ast.Named and "named" or "keyed", want,
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
    if item is Ast.Positional then
      wrong_shape(ctx, item, "positional", want, "write `[key] = value` or `name = value` items")
      items_unshaped(ctx, e.items)
      return ctx.invalid
    elseif item is Ast.Named then
      local k = string_value(ctx, item, item.name, want.key)
      local _ = expect(ctx, item, k, want.key, " as a key of " .. tq(ctx, want))
      local v = expr(ctx, item.value, want.value)
      local _ = expect(ctx, item.value, v, want.value, " as a value of " .. tq(ctx, want))
    elseif item is Ast.Keyed then
      local k = expr(ctx, item.key, want.key)
      local _ = expect(ctx, item.key, k, want.key, " as a key of " .. tq(ctx, want))
      local v = expr(ctx, item.value, want.value)
      local _ = expect(ctx, item.value, v, want.value, " as a value of " .. tq(ctx, want))
    end
  end
  return store:map(want.key, want.value, true)
end

--- The field of `n` called `name`, not a method.
local function plain_field(ctx: Ctx, n: Named, name: string): Member | nil
  local index = members_index(ctx, n.decl, n.value)
  local list = index ~= nil and index.by_name[name] or nil
  if list ~= nil and not list[1].method then
    return list[1]
  end
  return nil
end

--- The field a literal item names: `name = v`, or `["name"] = v`.
local function item_name(item: Ast.Item): string | nil
  if item is Ast.Named then
    return item.name
  elseif item is Ast.Keyed then
    local key = peel(item.key)
    if key is Ast.String then
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
    else
      report(ctx, "class_scope", e, "this literal makes a value of " .. quoted(n.decl.name) .. ", " .. why,
        reach_fix(ctx, n.decl, "make the value in " .. quoted(n.decl.module) .. " with a function of the class (`function " ..
            n.decl.name .. ".new(...): " .. n.decl.name .. "`), and call it here"), { show(ctx, n) })
    end
  end
  local given: {string: boolean} = {}
  local owner = quoted(n.decl.name)
  local array_part = index.array
  local shaped = true
  for _, item in ipairs(e.items) do
    local name = item_name(item)
    if name ~= nil and not (item is Ast.Positional) then
      local value = item is Ast.Named and item.value or item is Ast.Keyed and item.value or nil
      local field = plain_field(ctx, n, name)
      if field == nil then
        local close = nearest(name, names_of(ctx, n))
        report(ctx, "literal_unknown", item, owner .. " has no field " .. quoted(name) ..
            (close ~= "" and ", nearest " .. quoted(close) or ""),
          (close ~= "" and "write " .. quoted(close) .. ", or declare " or "declare ") .. quoted(name) .. " in " .. owner)
      elseif value ~= nil then
        if given[name] then
          report(ctx, "literal_repeated", item, "the field " .. quoted(name) .. " is written twice",
            "remove the second " .. quoted(name))
        end
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
    elseif item is Ast.Positional and array_part ~= nil then
      -- Checked together below, so that the last item may expand.
    else
      if shaped then
        shaped = false
        wrong_shape(ctx, item, item is Ast.Positional and "positional" or "keyed", n,
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
  local missing: {string} = {}
  for _, f in ipairs(body.fields) do
    if (is_class or not f.omittable) and not given[f.name] then
      missing[#missing + 1] = quoted(f.name)
    end
  end
  if #missing > 0 and shaped then
    report(ctx, "literal_missing", e, "this literal of " .. owner .. " leaves out " .. listed(missing, "and"),
      is_class and "add " .. listed(missing, "and") .. " to the literal: a class literal names every field, a field " ..
        "not yet known as its empty value (`fd = -1`) and a `?` field as `name = nil`" or
        "add " .. listed(missing, "and") .. " to the literal (`name = nil` for a value that may be nil), or declare " ..
        (#missing == 1 and "the field" or "them") .. " `name?: T`")
  end
  return n
end

--- The member of the union `u` that the literal `e` is, or nil with the error reported.
local function literal_member(ctx: Ctx, e: Ast.Table, u: Union): Type | nil
  local candidates: {Type} = {}
  for _, m in ipairs(u.members) do
    if (m is Named and (m.decl.kind == "record" or m.decl.kind == "class")) or m is Types.Array or m is Types.Map then
      candidates[#candidates + 1] = m
    end
  end
  if #candidates == 1 then
    return candidates[1]
  elseif #candidates == 0 then
    report(ctx, "literal_shape", e, "a table literal is checked against " .. tq(ctx, u) .. ", which has no member a " ..
        "table makes",
      "write a value of one of its members", { show(ctx, u) })
    return nil
  end
  -- A tag: a named item whose string value is the one value of an enum a member's field of that name has.
  for _, item in ipairs(e.items) do
    local name = item_name(item)
    local value = item is Ast.Named and peel(item.value) or item is Ast.Keyed and peel(item.value) or nil
    if name ~= nil and value ~= nil and value is Ast.String then
      local tagged: {Type} = {}
      for _, m in ipairs(candidates) do
        local field = m is Named and plain_field(ctx, m, name) or nil
        local t = field ~= nil and field.type or nil
        local body = t ~= nil and t is Named and t.decl.body or nil
        if body ~= nil and #body.values == 1 and body.values[1] == value.value then
          tagged[#tagged + 1] = m
        end
      end
      if #tagged == 1 then
        return tagged[1]
      end
    end
  end
  report(ctx, "literal_ambiguous", e, "this literal could be any of " .. listed(type_names(ctx, candidates)),
    "give the tag field of the member it is (`kind = \"...\"`), or type the literal first: `local v: Member = {...}`")
  return nil
end

--- A table literal. Checked against a type it is a record, a class, an array or a map as that type is; with no type it
--- is an array or a map of the join of its items.
local function table_literal(ctx: Ctx, e: Ast.Table, expected: Type | nil): Type
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
  if want is Union then
    local member = literal_member(ctx, e, want)
    if member == nil then
      items_unshaped(ctx, e.items)
      return ctx.invalid
    end
    want = member
  end
  if want is Named then
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
        (kind == "interface" and "an interface" or kind == "enum" and "an enum" or "a userdata record"),
      kind == "interface" and "make the value with a class that lists " .. quoted(want.decl.name) ..
        " (`class C is " .. want.decl.name .. "`)" or "write a value of " .. quoted(want.decl.name), { show(ctx, want) })
    items_unshaped(ctx, e.items)
    return ctx.invalid
  elseif want is Types.Array then
    return literal_array(ctx, e, want)
  elseif want is Types.Map then
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
local function readable(ctx: Ctx, node: Ast.Node, t: Type, what: string): Type | nil
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
local function member_types(ctx: Ctx, t: Named, name: string): {Member} | nil
  local index = members_index(ctx, t.decl, t.value)
  return index ~= nil and index.by_name[name] or nil
end

local function field_unknown(ctx: Ctx, node: Ast.Node, t: Type, name: string)
  if t is Named and not t.value and (ctx.program.statics[t.decl] or {})[name] ~= nil then
    -- A module re-exported as a field of a record is typed with its record, whose values have none of its functions.
    local owner = quoted(t.decl.name)
    local through_field = false
    if node is Ast.Field then
      local object = node.object
      through_field = object is Ast.Field
    end
    local call = "call it on the declaration: `" .. t.decl.name .. "." .. name .. "(...)`"
    local module = "no change of this program fixes it where this value is a module typed with its record: the grammar " ..
      "has no type for " .. owner .. " used as a value yet (the TODO of `declaration_value` in lang/check.tl), and " ..
      "build/check_pins.tl holds the places that need one"
    -- A class has no module among its values; a record read through a field is a module re-exported by a record.
    local fix = call .. "; " .. module
    if t.decl.kind == "class" then
      fix = call
    elseif through_field then
      fix = module
    end
    report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) .. ": " .. quoted(name) ..
        " is a function of the declaration " .. owner .. " used as a value, and this is typed as a value of it",
      fix, { show(ctx, t) })
    return
  end
  local names: {string} = {}
  if t is Named then
    names = names_of(ctx, t)
  end
  local close = nearest(name, names)
  local owner = t is Named and quoted(t.decl.name) or tq(ctx, t)
  report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) ..
      (close ~= "" and ", nearest " .. quoted(close) or ""),
    close ~= "" and "write " .. quoted(close) .. ", or declare " .. quoted(name) .. " in " .. owner or
      "declare " .. quoted(name) .. " in " .. owner, { show(ctx, t) })
end

--- Whether the field type `ft` of the interface `t` is a method of it: a function whose first parameter is the
--- interface itself.
local function interface_method(t: Named, ft: Type): boolean
  if not (ft is Fn) then
    return false
  end
  local first = ft.params[1]
  local receiver = first ~= nil and first.type or nil
  return receiver ~= nil and receiver is Named and receiver.decl == t.decl
end

--- The type of the field or method `name` of the value of type `t`, reported where it has none. `node` is the
--- expression that reads it; it holds the overloads of the field in `ctx.cands` when it has several.
local function member_read(ctx: Ctx, node: Ast.Node, t: Type, name: string): Type
  local store = ctx.store
  if t is Named then
    local list = member_types(ctx, t, name)
    if list == nil then
      field_unknown(ctx, node, t, name)
      return ctx.invalid
    end
    if t.decl.kind == "interface" and not (node is Ast.MethodCall) and not list[1].method and
        interface_method(t, list[1].type) then
      -- The implementation depends on the receiver, which agreement fixes to the implementing type: read as a value, it
      -- would be called with another implementer.
      local receiver = node is Ast.Field and text_of(ctx, node.object) or "v"
      report(ctx, "interface_method_value", node, subject(ctx, node) .. " reads the method " .. quoted(name) ..
          " of the interface " .. tq(ctx, t) .. " as a value, and its implementation depends on the receiver",
        "call it as `" .. receiver .. ":" .. name .. "(...)`", { show(ctx, t) })
      return ctx.invalid
    end
    if #list > 1 then
      local all: {Type} = {}
      for i, m in ipairs(list) do
        all[i] = put_in(ctx, t, m.type)
      end
      ctx.cands = all
      ctx.cand_node = node
    end
    return put_in(ctx, t, list[1].type)
  elseif t is Union then
    -- Read as a value, the member is the union of their types; a call is typed by [`union_method`] and not by this.
    local key = t.id .. "." .. name
    local held = ctx.union_fields[key]
    if held ~= nil then
      return held
    end
    local types: {Type} = {}
    for _, m in ipairs(t.members) do
      if m is Named and member_types(ctx, m, name) ~= nil then
        types[#types + 1] = member_read(ctx, node, m, name)
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
  elseif t is Types.Map then
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
      report(ctx, "field_unknown", node, "a string has no field " .. quoted(name),
        "call a function of `string` on it: `s:upper()`, `s:sub(i, j)`", { show(ctx, t) })
      return ctx.invalid
    end
    if #list > 1 then
      local all: {Type} = {}
      for i, m in ipairs(list) do
        all[i] = m.type
      end
      ctx.cands = all
      ctx.cand_node = node
    end
    return list[1].type
  elseif t is Types.Var then
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
local function union_method(ctx: Ctx, node: Ast.MethodCall, u: Union): Type | nil, {Type} | nil
  local store = ctx.store
  local common: {Type} | nil = nil
  local first: Type | nil = nil
  for _, m in ipairs(u.members) do
    if not (m is Named) or member_types(ctx, m, node.name) == nil then
      report(ctx, "field_unknown", node, quoted(node.name) .. " is not a field of " .. tq(ctx, m) .. ", a member of " ..
          tq(ctx, u),
        "narrow the value to the member that has it (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(node.name) ..
          " in every member", { show(ctx, u) })
      return nil
    end
    ctx.cands, ctx.cand_node = nil, nil
    local read = member_read(ctx, node, m, node.name)
    local declared: {Type} = { read }
    if ctx.cand_node == node and ctx.cands ~= nil then
      declared = ctx.cands
    end
    ctx.cands, ctx.cand_node = nil, nil
    if read.tag == "invalid" then
      return nil
    end
    local replaced: {Type} = {}
    for i, each in ipairs(declared) do
      local f = each
      if f is Fn and f.params[1] ~= nil and f.params[1].type == m then
        local params: {Types.Param} = {}
        for j, p in ipairs(f.params) do
          params[j] = p
        end
        params[1] = { type = u, omittable = f.params[1].omittable }
        f = store:fn({ tparams = f.tparams, params = params, rest = f.rest, rets = f.rets })
      end
      replaced[i] = f
    end
    local held = common
    if held == nil then
      common = replaced
      first = m
    else
      local agree = #held == #replaced
      for i = 1, agree and #held or 0 do
        agree = agree and held[i] == replaced[i]
      end
      if not agree then
        local other = first
        report(ctx, "not_callable", node, subject(ctx, node) .. " calls the method " .. quoted(node.name) .. " of each member " ..
            "of " .. tq(ctx, u) .. ", and " .. tq(ctx, other ~= nil and other or m) .. " and " .. tq(ctx, m) ..
            " declare it differently: " .. quoted(show(ctx, held[1])) .. " and " .. quoted(show(ctx, replaced[1])),
          "narrow the value to one member first (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(node.name) ..
            " the same in every member", { show(ctx, held[1]), show(ctx, replaced[1]) })
        return nil
      end
    end
  end
  local list = common
  if list == nil or list[1] == nil then
    return nil
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
local function key_names(key: Ast.Exp, kt: Type): {string} | nil
  local literal = peel(key)
  if literal is Ast.String then
    return { literal.value }
  end
  if kt is Named and kt.decl.kind == "enum" then
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
  if t is Types.Array then
    local k = expr(ctx, node.key, store.integer)
    local _ = key_ok(ctx, node.key, k, store.integer, subject(ctx, node.object))
    return store:optional(t.mut and t.element or view(store, t.element))
  elseif t is Types.Map then
    local k = expr(ctx, node.key, t.key)
    local _ = key_ok(ctx, node.key, k, t.key, subject(ctx, node.object))
    return store:optional(t.mut and t.value or view(store, t.value))
  elseif t is Named and (t.decl.kind == "record" or t.decl.kind == "class" or t.decl.kind == "userdata") then
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
    local types: {Type} = {}
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
  elseif t is Types.Var then
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
  local fix = is_text(t) and "convert it with `tonumber(" .. text_of(ctx, node) .. ")`" or
    "use a number: " .. quoted(op) .. " converts nothing"
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
  local fix = t.tag == "number" and "convert it with `math.tointeger(" .. text_of(ctx, node) .. ")` or `math.floor(" ..
    text_of(ctx, node) .. ")`" or "use an integer: " .. quoted(op) .. " converts nothing"
  bad_operand(ctx, node, t, op, "integers", fix)
  return false
end

--- Whether `t` is a string, as an operand of `..`; reports it where not.
local function string_operand(ctx: Ctx, node: Ast.Node, t: Type): boolean
  if is_text(t) or t.tag == "never" then
    return true
  elseif t.tag == "invalid" then
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
  if is_text(t) or t is Types.Array or t.tag == "never" then
    return true
  elseif t.tag == "invalid" then
    return false
  elseif t is Named then
    local index = members_index(ctx, t.decl, t.value)
    if index ~= nil and index.array ~= nil then
      return true
    end
  end
  bad_operand(ctx, node, t, "#", "a string or an array", t is Types.Map and
      "a map has no length: keep a count, or use an array" or "take the length of a string or an array")
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
      if (x is Types.Var and y.tag == "nil") or (y is Types.Var and x.tag == "nil") then
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
  elseif t is Types.Var then
    fix = "a type parameter may be nil or false: test it with `" .. text_of(ctx, node) .. " ~= nil` where it is bounded"
  end
  report(ctx, "condition_type", node, s .. " is " .. tq(ctx, t) .. ", which is no boolean or optional, so it is no condition",
    fix, { show(ctx, t) })
  return "bad"
end

--- Checks the condition `node`.
local function condition(ctx: Ctx, node: Ast.Exp): Type
  local t = expr(ctx, node, nil)
  local _ = condition_kind(ctx, node, t)
  return t
end

-- Binary and unary operators ---------------------------------------------------------------

local ARITHMETIC <const>: {string: boolean} = { ["+"] = true, ["-"] = true, ["*"] = true, ["%"] = true, ["//"] = true }
local DIVISION <const>: {string: boolean} = { ["/"] = true, ["^"] = true }
local BITWISE <const>: {string: boolean} = { ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true }
local ORDERED <const>: {string: boolean} = { ["<"] = true, [">"] = true, ["<="] = true, [">="] = true }

--- `a == b` and `a ~= b`: both sides overlap, else the test is dead.
local function equality(ctx: Ctx, node: Ast.Binary, left: Type, right: Type)
  if not overlaps(ctx, left, right) then
    report(ctx, "compare_disjoint", node, subject(ctx, node.left) .. " is " .. tq(ctx, left) .. " and " ..
        subject(ctx, node.right) .. " is " .. tq(ctx, right) .. ", which share no value: the test is never " ..
        (node.op == "==" and "true" or "false"),
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
    local wanted = number(l) and "a number" or "a string"
    if nilable(r) or r.tag == "any" or r is Types.Var then
      bad_operand(ctx, node.right, r, node.op, wanted .. ", as its left operand is", fix)
    else
      bad_operand(ctx, node.right, r, node.op, wanted .. ", as its left operand is", fix)
    end
  elseif number(r) or is_text(r) then
    bad_operand(ctx, node.left, l, node.op, (number(r) and "a number" or "a string") .. ", as its right operand is", fix)
  else
    bad_operand(ctx, node.left, l, node.op, "numbers or strings", fix)
  end
end

--- `a or b`: both booleans, or a `T?` replaced by a default of its own type.
local function disjunction(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type | nil): Type
  local store = ctx.store
  local left_kind = left.tag == "invalid" and "bad" or condition_kind(ctx, node.left, left)
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
local function conjunction(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type | nil): Type
  local store = ctx.store
  local left_kind = left.tag == "invalid" and "bad" or condition_kind(ctx, node.left, left)
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

--- A binary expression whose left operand has type `left`.
local function binary(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type | nil): Type
  local store = ctx.store
  local op = node.op
  if op == "or" then
    return disjunction(ctx, node, left, expected)
  elseif op == "and" then
    return conjunction(ctx, node, left, expected)
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
  if left_node is Ast.String and has_enum(ctx, right) then
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
      if x == y or x is Types.Var or y is Types.Var or below(ctx, x, y) or below(ctx, y, x) then
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
  local function refuse(why: string)
    report(ctx, "is_on_record", node, "`is " .. show(ctx, tested) .. "` cannot be told by a run-time tag: " .. why,
      "test a tag (`x.kind == \"...\"`), declare a class, or validate the data with a [`cosmic.shape`] validator",
      { show(ctx, tested) })
  end
  local library = ctx.program.globals["table"]
  if tested is Named and library ~= nil and tested.decl == library.decl then
    return store.boolean
  end
  local before = #ctx.errors
  if tested is Named and tested.decl.kind ~= "enum" and tested.decl.kind ~= "class" then
    local word = KIND_WORDS[tested.decl.kind] or "type"
    refuse((word == "interface" and "an " or "a ") .. word .. " leaves nothing to test")
  elseif tested is Named and tested.decl.kind == "class" and out_of_reach(ctx, tested.decl) ~= "" then
    report(ctx, "class_scope", node, "`is " .. show(ctx, tested) .. "` tests the metatable of " ..
        out_of_reach(ctx, tested.decl),
      reach_fix(ctx, tested.decl, "test in " .. quoted(tested.decl.module) .. " with a function of the class (`function " ..
          tested.decl.name .. ".owns(v: any): boolean`), and call it here"), { show(ctx, tested) })
  elseif tested is Named and tested.decl.kind == "class" and #tested.args > 0 then
    refuse("the metatable tells the class and not its type arguments")
  elseif tested is Types.Fn then
    refuse("a function type is tested as `function` and its parameters go unchecked")
  elseif value.tag == "any" and (tested is Types.Array or tested is Types.Map or tested is Union) then
    refuse("the tag says `table` and the contents of untrusted data go unchecked")
  elseif tested is Types.Array or tested is Types.Map then
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

--- An `if` expression: conditions, and arms with a common type.
local function if_expression(ctx: Ctx, node: Ast.IfExp, expected: Type | nil): Type
  local types: {Type} = {}
  for _, arm in ipairs(node.arms) do
    local _ = condition(ctx, arm.cond)
    types[#types + 1] = expr(ctx, arm.value, expected)
  end
  types[#types + 1] = expr(ctx, node.else_value, expected)
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

local function rtype_base(item: Ast.RType): Ast.Base
  return item
end

--- The return alternatives a written return list stands for, from the types the lowering gave its items.
local function alts_of_rets(ctx: Ctx, rets: Ast.Rets): {Alt}
  local alts: {Alt} = {}
  for _, list in ipairs(rets.lists) do
    local alt: Alt = { items = {} }
    local never = false
    for i, item in ipairs(list) do
      local t = ctx.store.boolean
      if not (item is Ast.Narrows) then
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
local function expected_function(ctx: Ctx, expected: Type | nil): Fn | nil
  if expected == nil then
    return nil
  end
  local t = ctx.store:non_nil(expected)
  if t is Fn and #t.tparams == 0 then
    return t
  end
  return nil
end

--- The type of the function written as `fn`. Its parameters are typed by its annotations, and by `expected` where a
--- literal leaves one out; a return list it leaves out is the one `expected` has. A parameter with neither is
--- `invalid` and reported.
local function function_type(ctx: Ctx, fn: Ast.Fn, expected: Type | nil, name: string): Type
  local ex = expected_function(ctx, expected)
  local lowered = ctx.lowered.types[fn.id]
  if lowered ~= nil and (fn.rets ~= nil or ex == nil) then
    return lowered
  end
  local params: {Types.Param} = {}
  local rest: Type | nil = nil
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
  local alts: {Alt} | nil = nil
  local written_rets = fn.rets
  if written_rets ~= nil then
    alts = alts_of_rets(ctx, written_rets)
  elseif ex ~= nil then
    alts = ex.rets
  end
  return ctx.store:fn({ params = params, rest = rest, rets = alts })
end

--- Checks a function body: its parameters are the variables of the types in `ft`, its `return`s are checked against
--- `ft`'s return list. `names` are the type parameters of a generic function, for display.
local function function_body(ctx: Ctx, params: {Ast.Param}, body: Ast.Block, ft: Type, names: {string}, whole: Ast.Node,
                             declared: boolean)
  local f: Fn | nil = ft is Fn and ft or nil
  local generic = f ~= nil and #f.tparams > 0
  if generic and f ~= nil then
    if #ctx.binders > 0 then
      unchecked(ctx, "unchecked_nested", whole, "this generic function is inside the code of another")
      return
    end
    ctx.judge:enter(f.tparams)
    ctx.binders[#ctx.binders + 1] = names
    ctx.bounds[#ctx.bounds + 1] = f.tparams
  end
  local j = 0
  for _, p in ipairs(params) do
    if not p.variadic then
      j = j + 1
      local binding = p.name
      if binding ~= nil then
        ctx.vars[binding.id] = f ~= nil and f.params[j] ~= nil and f.params[j].type or ctx.invalid
      end
    end
  end
  local alts: {Alt} = f ~= nil and f.rets or unknown_lists(ctx)
  local rest: Type | nil = ctx.invalid
  if f ~= nil then
    rest = f.rest
  end
  ctx.frames[#ctx.frames + 1] = { alts = alts, rest = rest, chunk = false, declared = declared }
  local saved = ctx.lenient
  ctx.lenient = 0
  block(ctx, body)
  ctx.lenient = saved
  -- TODO: report `missing_return` for a function with return lists whose end is reachable, and `not_assigned` for a
  -- read before an assignment, once the flow piece lands (doc/plans/new-checker-types.md, "narrowing and
  -- reachability"): both read the facts of the walk, which this walk keeps none of.
  ctx.frames[#ctx.frames] = nil
  if generic then
    ctx.judge:leave()
    ctx.binders[#ctx.binders] = nil
    ctx.bounds[#ctx.bounds] = nil
  end
end

--- A function literal: its type, and its body checked.
local function function_literal(ctx: Ctx, e: Ast.FunctionLit, expected: Type | nil): Type
  local ft = function_type(ctx, e.fn, expected, "this function")
  function_body(ctx, e.fn.params, e.fn.body, ft, {}, e, e.fn.rets ~= nil)
  return ft
end

-- Calls --------------------------------------------------------------------------------------------

--- Whether an argument is a literal, whose type depends on the position it stands in.
local function is_literal(e: Ast.Exp): boolean
  local at = peel(e)
  if at is Ast.IfExp then
    -- Its type is its arms': a literal where one of them is.
    for _, arm in ipairs(at.arms) do
      if is_literal(arm.value) then
        return true
      end
    end
    return is_literal(at.else_value)
  end
  return at is Ast.Table or at is Ast.FunctionLit or at is Ast.String or at is Ast.Boolean
end

local function plural(n: integer, word: string): string
  return n .. " " .. word .. (n == 1 and "" or "s")
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

--- Whether the literal `e` could be a value of `want`: its form fits, which is all a position can tell of a literal
--- before it is checked against the overload. A function literal fits a function type whose calls it takes, and a
--- string literal a `string` or an enum that has it, which tells overloads of enums apart.
local function literal_fits(ctx: Ctx, written: Ast.Exp, want: Type): boolean
  if want.tag == "any" or want.tag == "invalid" then
    return true
  end
  local e = peel(written)
  if e is Ast.IfExp then
    -- Each arm that is a literal fits; an arm that is not says nothing yet.
    for _, arm in ipairs(e.arms) do
      if is_literal(arm.value) and not literal_fits(ctx, arm.value, want) then
        return false
      end
    end
    return not is_literal(e.else_value) or literal_fits(ctx, e.else_value, want)
  end
  for _, m in ipairs(members_of(ctx.store, want)) do
    if e is Ast.FunctionLit then
      if m is Fn and (#m.tparams > 0 or arguments_fit(e, m)) then
        return true
      end
    elseif e is Ast.Table then
      if m is Types.Array or m is Types.Map or m is Named or m is Types.Var then
        return true
      end
    elseif e is Ast.String then
      if m.tag == "string" or (m is Named and m.decl.kind == "enum" and enum_holds(m, e.value)) then
        return true
      end
    elseif e is Ast.Boolean then
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
local function arity_problem(f: Fn, off: integer, n: integer, open: boolean): string | nil
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
local function tail_problem(ctx: Ctx, f: Fn, off: integer, n: integer, tail: Type): integer | nil, Type | nil, boolean
  if tail.tag == "invalid" then
    return nil
  end
  local maybe = ctx.store:optional(tail)
  local np = #f.params - off
  for pos = n + 1, np do
    local want = f.params[pos + off].type
    if want.tag ~= "any" then
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
  return nil
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
        (n == 1 and "is" or "are") .. " given",
      "remove the extra " .. (n - np == 1 and "argument" or "arguments") .. ", or declare the parameter in the function " ..
        "type", { Types.display(f, ctx.binders) })
  else
    local missing = f.params[n + off + 1]
    report(ctx, "arity", node, callee .. " takes " .. (required < np and required .. " to " .. plural(np, "argument") or
      plural(required, "argument")) .. ", but " .. n .. " " .. (n == 1 and "is" or "are") .. " given",
      "pass the missing argument " .. (n + 1) .. (missing ~= nil and ", " .. tq(ctx, missing.type) or "") ..
        ", or declare the parameter `name?: T`", { Types.display(f, ctx.binders) })
  end
end

--- The type the call's position `i` (from 1, after the receiver) wants of `f`.
local function parameter_at(f: Fn, off: integer, i: integer): Type | nil
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

--- A call of the function `f`, with the arguments checked against its parameters. Answers its return lists.
local function apply_function(ctx: Ctx, node: Ast.Node, callee: string, f: Fn, args: {Ast.Exp}, recv: Type | nil,
                              recv_node: Ast.Node | nil): {Alt}
  local off = recv ~= nil and 1 or 0
  if recv ~= nil and recv_node ~= nil then
    check_receiver(ctx, f, callee, recv, recv_node)
  end
  local wants: {Type} = {}
  for i = 1, #args do
    local w = parameter_at(f, off, i)
    if w ~= nil then
      wants[i] = w
    end
  end
  local vals = values_of(ctx, args, wants, f.rest)
  local several, last = vals.lists, vals.last
  if several ~= nil and last ~= nil then
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
      local _ = expect_argument(ctx, at, t, want, " as argument " .. i .. " of " .. quoted(callee))
    end
  end
  if why == "too few" or (why == "too many" and not reported) then
    arity_error(ctx, node, quoted(callee), f, off, n, why)
  end
  local tail = vals.tail
  if tail ~= nil and last ~= nil and why == nil then
    local pos, want, missing = tail_problem(ctx, f, off, n, tail)
    if pos ~= nil and want ~= nil then
      if missing then
        report(ctx, "nil_not_allowed", last, subject(ctx, last) .. " ends in " .. quoted(show(ctx, tail) .. "...") ..
            ", so argument " .. pos .. " of " .. quoted(callee) .. " may be missing, where " .. tq(ctx, want) .. " is wanted",
          "varargs end in nil: take the values into locals and test them (`local a, b = " .. text_of(ctx, last) ..
            " if b == nil then ... end`), or declare the parameter `name?: T`", { show(ctx, ctx.store:optional(tail)), show(ctx, want) })
      else
        local _ = expect(ctx, last, tail, want, " as argument " .. pos .. " of " .. quoted(callee))
      end
    end
  end
  return f.rets
end

--- The Teal the overloads are written in, for `overload_none`.
local function overload_line(ctx: Ctx, f: Type, why: string): string
  return Types.display(f, ctx.binders) .. (why ~= "" and ": " .. why or "")
end

--- A call of the first of `cands`, in declared order, whose parameters accept the arguments; the literal arguments are
--- checked last, against it.
local function apply_overloads(ctx: Ctx, node: Ast.Node, callee: string, cands: {Type}, args: {Ast.Exp}, recv: Type | nil): {Alt}
  local off = recv ~= nil and 1 or 0
  local n = #args
  local last = args[n]
  local open = last ~= nil and (last is Ast.Call or last is Ast.MethodCall or last is Ast.Vararg)
  local known: {Type} = {}
  local pending: {integer: boolean} = {}
  local tail: Type | nil = nil
  -- The arguments before an expanding last one are typed as the others, a literal when the overload is taken; the last
  -- one gives the values it is known to give, and the tail.
  local written = open and n - 1 or n
  for i = 1, written do
    local a = args[i]
    if is_literal(a) then
      pending[i] = true
    else
      known[i] = expr(ctx, a, nil)
    end
  end
  local count = n
  if open and last ~= nil then
    local vals = values_of(ctx, { last }, nil, nil)
    for j, t in ipairs(vals.types) do
      known[written + j] = t
    end
    count = written + #vals.types
    tail = vals.tail
    local several = vals.lists
    if several ~= nil then
      local _ = first_value(ctx, last, several)
    end
  end
  local reasons: {string} = {}
  for _, c in ipairs(cands) do
    if c is Fn and #c.tparams > 0 then
      unchecked(ctx, "unchecked_generic", node, "this call of " .. quoted(callee) .. " may take a generic overload")
      for i, a in ipairs(args) do
        if pending[i] then
          ctx.lenient = ctx.lenient + 1
          local _ = expr(ctx, a, nil)
          ctx.lenient = ctx.lenient - 1
        end
      end
      return unknown_lists(ctx)
    elseif c is Fn then
      local why = arity_problem(c, off, count, open and tail ~= nil)
      local failure = ""
      if why ~= nil then
        failure = why .. " arguments"
      elseif recv ~= nil and c.params[1] ~= nil and not accepts(ctx, recv, c.params[1].type) then
        failure = "the receiver is " .. tq(ctx, recv) .. ", where " .. tq(ctx, c.params[1].type) .. " is wanted"
      else
        for i = 1, count do
          local want = parameter_at(c, off, i)
          local t = known[i]
          if t ~= nil and (want == nil or not accepts(ctx, t, want)) then
            failure = "argument " .. i .. " is " .. tq(ctx, t) .. (want ~= nil and ", where " .. tq(ctx, want) ..
              " is wanted" or ", which it does not take")
            break
          elseif pending[i] and (want == nil or not literal_fits(ctx, args[i], want)) then
            failure = "argument " .. i .. " is a literal that is not " .. (want ~= nil and "a " .. tq(ctx, want) or "taken")
            break
          end
        end
      end
      if failure == "" and tail ~= nil then
        local pos, want, missing = tail_problem(ctx, c, off, count, tail)
        if pos ~= nil and want ~= nil then
          failure = "argument " .. pos .. " is filled by " .. quoted(show(ctx, tail) .. "...") .. (missing and
            ", which may leave it missing, where " or ", where ") .. tq(ctx, want) .. " is wanted"
        end
      end
      if failure == "" then
        for i, a in ipairs(args) do
          if pending[i] then
            local want = parameter_at(c, off, i)
            local t = expr(ctx, a, want)
            if want ~= nil then
              local _ = expect_argument(ctx, a, t, want, " as argument " .. i .. " of " .. quoted(callee))
            end
          end
        end
        return c.rets
      end
      reasons[#reasons + 1] = overload_line(ctx, c, failure)
    end
  end
  for i, a in ipairs(args) do
    if pending[i] then
      ctx.lenient = ctx.lenient + 1
      local _ = expr(ctx, a, nil)
      ctx.lenient = ctx.lenient - 1
    end
  end
  local shown: {string} = {}
  for i = 1, count do
    local t = known[i]
    if t ~= nil then
      shown[i] = show(ctx, t)
    else
      local literal = args[i]
      shown[i] = literal is Ast.String and "string" or literal is Ast.Boolean and "boolean" or
        literal is Ast.FunctionLit and "function" or "table"
    end
  end
  local first = reasons[1]
  report(ctx, "overload_none", node, "no overload of " .. quoted(callee) .. " takes the arguments (" ..
      table.concat(shown, ", ") .. ")",
    "pass arguments one overload accepts, in its order: " .. table.concat(reasons, "; "), { first or "" })
  return unknown_lists(ctx)
end

--- The lists a call answers, where the callee has type `ft` (and the overloads `cands`, if it has several).
local function dispatch_call(ctx: Ctx, node: Ast.Node, callee_node: Ast.Node, callee: string, ft: Type, cands: {Type} | nil,
                             args: {Ast.Exp}, recv: Type | nil, recv_node: Ast.Node | nil): {Alt}
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
    list = { ctx.store:non_nil(first) }
    first = list[1]
  end
  if #list == 1 then
    if first is Fn then
      if #first.tparams > 0 then
        unchecked(ctx, "unchecked_generic", node, "this call of the generic function " .. quoted(callee))
        unchecked_arguments(ctx, args)
        return unknown_lists(ctx)
      end
      return apply_function(ctx, node, callee, first, args, recv, recv_node)
    end
    report(ctx, "not_callable", callee_node, quoted(callee) .. " is " .. tq(ctx, first) .. ", which is not a function",
      first is Union and "narrow it to one function first" or "call a function", { show(ctx, first) })
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  end
  return apply_overloads(ctx, node, callee, list, args, recv)
end

--- The names `pcall` and `xpcall` have as globals the checker types in a later piece.
local PROTECTED <const>: {string: boolean} = { pcall = true, xpcall = true }

--- A call `callee(args)` whose callee has type `ft`.
local function apply_call(ctx: Ctx, node: Ast.Call, ft: Type): {Alt}
  local callee = node.callee
  local cands: {Type} | nil = nil
  if ctx.cand_node == callee then
    cands = ctx.cands
  end
  ctx.cands, ctx.cand_node = nil, nil
  local callee_text = text_of(ctx, callee)
  if callee is Ast.Name and callee.binding == nil then
    if PROTECTED[callee.text] then
      unchecked(ctx, "unchecked_protected", node, "a protected call " .. quoted(callee.text))
      unchecked_arguments(ctx, node.args)
      return unknown_lists(ctx)
    elseif callee.text == "setmetatable" then
      report(ctx, "setmetatable_call", node, "a program has no `setmetatable`: the metatable of a value is the compiler's, " ..
          "attached to the literal that makes the value of a class",
        "declare a `class` with the methods and write the value as a table literal typed as the class " ..
          "(`local v: C = { field = value }`)")
      unchecked_arguments(ctx, node.args)
      return unknown_lists(ctx)
    elseif callee.text == "require" then
      local named = node.args[1]
      if named ~= nil and named is Ast.String and #node.args == 1 then
        return { { items = { module_value(ctx, node, named.value) } } }
      end
    end
  elseif callee is Ast.Field then
    local object = callee.object
    if object is Ast.Name and object.binding == nil and object.text == "coroutine" then
      unchecked(ctx, "unchecked_coroutine", node, "a coroutine function " .. quoted(callee_text))
      unchecked_arguments(ctx, node.args)
      return unknown_lists(ctx)
    end
  end
  return dispatch_call(ctx, node, callee, callee_text, ft, cands, node.args, nil, nil)
end

--- A method call `object:name(args)` whose object has type `object`.
local function apply_method(ctx: Ctx, node: Ast.MethodCall, object: Type): {Alt}
  local text = text_of(ctx, node.object) .. ":" .. node.name
  local t = readable(ctx, node.object, object, "it has no method " .. quoted(node.name) .. " to call")
  if t == nil then
    unchecked_arguments(ctx, node.args)
    return unknown_lists(ctx)
  end
  ctx.cands, ctx.cand_node = nil, nil
  local ft: Type
  local cands: {Type} | nil = nil
  if t is Union then
    local common, overloads = union_method(ctx, node, t)
    if common == nil then
      unchecked_arguments(ctx, node.args)
      return unknown_lists(ctx)
    end
    ft, cands = common, overloads
  else
    ft = member_read(ctx, node, t, node.name)
    if ctx.cand_node == node then
      cands = ctx.cands
    end
    ctx.cands, ctx.cand_node = nil, nil
  end
  return dispatch_call(ctx, node, node, text, ft, cands, node.args, t, node.object)
end

-- Expressions: the spine --------------------------------------------------------------------

--- The expressions whose first operand the walk descends into, in place of recursing.
local function spine_child(node: Ast.Exp): Ast.Exp | nil
  if node is Ast.Binary then
    return node.left
  elseif node is Ast.Field then
    return node.object
  elseif node is Ast.Index then
    return node.object
  elseif node is Ast.Call then
    return node.callee
  elseif node is Ast.MethodCall then
    return node.object
  elseif node is Ast.IsTest then
    return node.value
  elseif node is Ast.Cast then
    return node.value
  end
  return nil
end

--- The type of an expression that is not a chain: a name, a literal, a function, a table, a unary operator or an `if`.
local function leaf(ctx: Ctx, e: Ast.Exp, expected: Type | nil): Type
  local store = ctx.store
  if e is Ast.Name then
    return name_value(ctx, e)
  elseif e is Ast.Integer then
    return store.integer
  elseif e is Ast.Float then
    return store.number
  elseif e is Ast.String then
    return string_literal(ctx, e, expected)
  elseif e is Ast.Boolean then
    return boolean_literal(ctx, e, expected)
  elseif e is Ast.Nil then
    return ctx.nil_type
  elseif e is Ast.Paren then
    return expr(ctx, e.inner, expected)
  elseif e is Ast.Table then
    return table_literal(ctx, e, expected)
  elseif e is Ast.FunctionLit then
    return function_literal(ctx, e, expected)
  elseif e is Ast.Unary then
    return unary(ctx, e, expr(ctx, e.operand, nil))
  elseif e is Ast.IfExp then
    return if_expression(ctx, e, expected)
  elseif e is Ast.Vararg then
    local rest = vararg_rest(ctx, e)
    return rest.tag == "invalid" and rest or store:optional(rest)
  end
  return ctx.invalid
end

--- Applies the chain node `n` to the type `t` of its first operand.
local function apply(ctx: Ctx, n: Ast.Exp, t: Type, expected: Type | nil, wants_lists: boolean): Type, {Alt} | nil
  if n is Ast.Binary then
    return binary(ctx, n, t, expected), nil
  elseif n is Ast.Field then
    local base = readable(ctx, n.object, t, "it has no field " .. quoted(n.name) .. " to read")
    if base == nil then
      return ctx.invalid, nil
    end
    return member_read(ctx, n, base, n.name), nil
  elseif n is Ast.Index then
    return index_read(ctx, n, t), nil
  elseif n is Ast.Call then
    local saved = ctx.lenient
    ctx.lenient = 0
    local alts = apply_call(ctx, n, t)
    ctx.lenient = saved
    if wants_lists then
      return ctx.invalid, alts
    end
    return first_value(ctx, n, alts), nil
  elseif n is Ast.MethodCall then
    local saved = ctx.lenient
    ctx.lenient = 0
    local alts = apply_method(ctx, n, t)
    ctx.lenient = saved
    if wants_lists then
      return ctx.invalid, alts
    end
    return first_value(ctx, n, alts), nil
  elseif n is Ast.IsTest then
    return is_test(ctx, n, t), nil
  elseif n is Ast.Cast then
    report(ctx, "cast_refused", n, "`as` is not in the language: " .. subject(ctx, n) .. " changes a type by no check",
      "validate the value with a [`cosmic.shape`] validator, test it with `is` or a guard, or delete the cast")
    return ctx.invalid, nil
  end
  return ctx.invalid, nil
end

--- The type of `e`, and the lists it answers where `wants_lists` and it is a call.
local function evaluate(ctx: Ctx, e: Ast.Exp, expected: Type | nil, wants_lists: boolean): Type, {Alt} | nil
  local base = ctx.top
  local node: Ast.Exp = e
  while true do
    local nxt = spine_child(node)
    if nxt == nil then
      break
    end
    if node is Ast.Binary and node.op == "or" and nxt is Ast.Binary and nxt.op == "and" then
      ctx.ternaries[nxt.id] = node
    end
    ctx.top = ctx.top + 1
    ctx.spine[ctx.top] = node
    node = nxt
  end
  local t = leaf(ctx, node, ctx.top == base and expected or nil)
  local alts: {Alt} | nil = nil
  for i = ctx.top, base + 1, -1 do
    local n = ctx.spine[i]
    ctx.top = i - 1
    t, alts = apply(ctx, n, t, i == base + 1 and expected or nil, wants_lists and i == base + 1)
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

expr = function(ctx: Ctx, e: Ast.Exp, expected: Type | nil): Type
  local t, _ = evaluate(ctx, e, expected, false)
  return t
end

lists_of = function(ctx: Ctx, e: Ast.Exp, expected: Type | nil): {Alt}
  local t, alts = evaluate(ctx, e, expected, true)
  if alts ~= nil then
    return alts
  end
  return { { items = { t } } }
end

-- Statements -----------------------------------------------------------------------------------

--- The type column `i` of the lists `alts` gives a name: the union of what each has there, `T?` where one has a tail
--- and nil where one lacks the position.
local function column(ctx: Ctx, alts: {Alt}, i: integer): Type
  local types: {Type} = {}
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
local function value_at(ctx: Ctx, vals: Values, i: integer): Type | nil
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
        ", so the " .. (written - n == 1 and "value" or "values") .. " after the last " .. what .. " are dropped",
      "remove the extra " .. (written - n == 1 and "value" or "values") .. ", or add the " .. what .. "s that take them")
    return false
  elseif given < n and not open then
    report(ctx, "value_count", node, "this gives " .. plural(given, "value") .. " to " .. plural(n, what) ..
        ", so the last " .. (n - given == 1 and what .. " is" or what .. "s are") .. " nil",
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
  elseif t is Named then
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
  elseif t is Union then
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
  local what = t is Named and not t.value and t.decl.kind == "class" and "the class " .. tq(ctx, t) .. " declares no `__close`" or
    tq(ctx, t) .. " is not a class"
  report(ctx, "close_not_closable", b, quoted(b.name) .. " is a `<close>` local of " .. tq(ctx, t) .. ", and " .. what ..
      ": Lua would raise at the declaration, since the value has no `__close` to call at the end of the block",
    "hold a class that declares `function __close(self)` (or nil) in " .. quoted(b.name) .. ", or release the value by " ..
      "hand and make " .. quoted(b.name) .. " an ordinary local", { show(ctx, t) })
end

--- `local a, b: T, U = f(), g()`.
local function local_statement(ctx: Ctx, s: Ast.Local)
  local n = #s.bindings
  local wants: {Type} = {}
  for i, t in ipairs(s.types) do
    wants[i] = ctx.lowered.types[t.id] or ctx.invalid
  end
  if #s.values == 0 then
    for i, b in ipairs(s.bindings) do
      ctx.vars[b.id] = wants[i] or ctx.invalid
      if wants[i] == nil then
        report(ctx, "local_untyped", b, quoted(b.name) .. " has no type and no value",
          "write its type: `local " .. b.name .. ": T` (`T?` if it may stay unset), or give it a value")
      elseif b.attr == "close" then
        check_closable(ctx, b, wants[i])
      end
    end
    return
  end
  local vals = values_of(ctx, s.values, wants, nil)
  local counted = check_counts(ctx, s, n, vals, #s.values, "name")
  for i, b in ipairs(s.bindings) do
    local t = value_at(ctx, vals, i)
    local want = wants[i]
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
    if b.attr == "close" then
      check_closable(ctx, b, ctx.vars[b.id])
    end
  end
end

--- Whether `a` and `b` name the same place: a name, or fields of one.
local function same_place(a: Ast.Exp, b: Ast.Exp): boolean
  local x, y = peel(a), peel(b)
  if x is Ast.Name and y is Ast.Name then
    return x.binding ~= nil and x.binding == y.binding
  elseif x is Ast.Field and y is Ast.Field then
    return x.name == y.name and same_place(x.object, y.object)
  end
  return false
end

--- Whether the key of `target` is `#object + 1`, which appends.
local function is_append(target: Ast.Index): boolean
  local key = peel(target.key)
  if key is Ast.Binary and key.op == "+" then
    local len, one = key.left, key.right
    return len is Ast.Unary and len.op == "#" and same_place(len.operand, target.object) and one is Ast.Integer and
      one.value == 1
  end
  return false
end

--- The type of `object` to write a member of, after reporting what it may not be.
local function writable_base(ctx: Ctx, object: Ast.Exp): Type | nil
  local t = expr(ctx, object, nil)
  return readable(ctx, object, t, "it has no member to write")
end

--- The place `target` writes, reporting what may not be written.
local function place_of_target(ctx: Ctx, target: Ast.Exp): Type | nil, boolean
  local store = ctx.store
  if target is Ast.Name then
    local t = name_value(ctx, target)
    return t
  elseif target is Ast.Field then
    local base = writable_base(ctx, target.object)
    if base == nil then
      return nil
    end
    if base is Named then
      local list = member_types(ctx, base, target.name)
      if list == nil or list[1].method then
        field_unknown(ctx, target, base, target.name)
        return nil
      end
      local field = list[1]
      if not field.mut then
        report(ctx, "field_fixed", target, quoted(base.decl.name .. "." .. target.name) .. " is fixed: it is not declared `mut`",
          "declare `mut " .. target.name .. ": " .. show(ctx, field.type) .. "` in " .. quoted(base.decl.name) ..
            ", or make a new " .. quoted(base.decl.name), { show(ctx, base) })
      end
      return put_in(ctx, base, field.type)
    end
    local read = member_read(ctx, target, base, target.name)
    ctx.cands, ctx.cand_node = nil, nil
    if read.tag ~= "invalid" then
      -- A union has no one field to write, and a string's functions are the library's.
      report(ctx, "field_fixed", target, subject(ctx, target) .. " is a field of " .. tq(ctx, base) ..
          ", which is fixed: only a record's `mut` field is written",
        "narrow the value to one record, then write its `mut` field", { show(ctx, base) })
    end
    return nil
  elseif target is Ast.Index then
    local base = writable_base(ctx, target.object)
    if base == nil then
      local _ = expr(ctx, target.key, nil)
      return nil
    end
    local owner = subject(ctx, target.object)
    if base is Types.Array then
      local k = expr(ctx, target.key, store.integer)
      local _ = key_ok(ctx, target.key, k, store.integer, owner)
      if not base.mut then
        report(ctx, "view_written", target, owner .. " is a view " .. tq(ctx, base) .. ", so " .. subject(ctx, target) ..
            " cannot be assigned",
          "declare " .. owner .. " `mut " .. show(ctx, base) .. "` where it is made or received", { show(ctx, base) })
      elseif not is_append(target) then
        report(ctx, "array_hole", target, subject(ctx, target) .. " may leave a hole in the array " .. owner,
          "append with `" .. text_of(ctx, target.object) .. "[#" .. text_of(ctx, target.object) .. " + 1] = v` or " ..
            "`table.insert`, remove with `table.remove`, or key a map `{integer: T}` for sparse data", { show(ctx, base) })
      end
      return base.element
    elseif base is Types.Map then
      local k = expr(ctx, target.key, base.key)
      local _ = key_ok(ctx, target.key, k, base.key, owner)
      if not base.mut then
        report(ctx, "view_written", target, owner .. " is a view " .. tq(ctx, base) .. ", so " .. subject(ctx, target) ..
            " cannot be assigned",
          "declare " .. owner .. " `mut " .. show(ctx, base) .. "` where it is made or received", { show(ctx, base) })
      end
      return base.value, true
    elseif base is Named and (base.decl.kind == "record" or base.decl.kind == "class") then
      local k = expr(ctx, target.key, nil)
      if k.tag == "invalid" then
        return nil
      end
      local names = key_names(target.key, k)
      local index = members_index(ctx, base.decl, base.value)
      if names == nil and index ~= nil and index.array ~= nil and below(ctx, k, store.integer) then
        -- TODO: let a record declare its array part `mut`, once the grammar can write it (`record R is mut {T}`): the
        -- array part follows the collection rule, a view unless `mut`, and nothing can declare it so yet.
        report(ctx, "view_written", target, subject(ctx, target) .. " writes the array part of " .. tq(ctx, base) ..
            ", which is a view: no declaration can make it `mut`",
          "keep the elements in a field declared `mut {T}`, and write that", { show(ctx, base) })
        return nil
      end
      if names ~= nil and #names == 1 then
        local list = member_types(ctx, base, names[1])
        if list ~= nil and not list[1].method then
          if not list[1].mut then
            report(ctx, "field_fixed", target, quoted(base.decl.name .. "." .. names[1]) .. " is fixed: it is not declared `mut`",
              "declare `mut " .. names[1] .. ": " .. show(ctx, list[1].type) .. "` in " .. quoted(base.decl.name) ..
                ", or make a new " .. quoted(base.decl.name), { show(ctx, base) })
          end
          return put_in(ctx, base, list[1].type)
        end
        field_unknown(ctx, target.key, base, names[1])
        return nil
      end
      report(ctx, "record_index", target, subject(ctx, target.key) .. " is " .. tq(ctx, k) .. ", which names no one field of " ..
          tq(ctx, base) .. ": a record is not a map",
        "write the field (`" .. text_of(ctx, target.object) .. ".field = v`), or index a `{K: V}`", { show(ctx, k) })
      return nil
    end
    local _ = expr(ctx, target.key, nil)
    report(ctx, "not_indexable", target, owner .. " is " .. tq(ctx, base) .. ", which has no elements to write",
      "write an element of an array or a map, or a field of a record", { show(ctx, base) })
    return nil
  end
  return nil
end

local function assign_statement(ctx: Ctx, s: Ast.Assign)
  local wants: {Type} = {}
  local deletes: {boolean} = {}
  for i, target in ipairs(s.targets) do
    local want, deleting = place_of_target(ctx, target)
    if want ~= nil then
      wants[i] = want
      deletes[i] = deleting
    end
  end
  local vals = values_of(ctx, s.values, wants, nil)
  local counted = check_counts(ctx, s, #s.targets, vals, #s.values, "target")
  if not counted then
    return
  end
  for i, target in ipairs(s.targets) do
    local t = value_at(ctx, vals, i)
    local want = wants[i]
    if t ~= nil and want ~= nil then
      local at = s.values[math.min(i, #s.values)]
      -- Only a literal nil deletes the key of a map; any other value is one of its value type.
      local written = peel(at)
      if not (deletes[i] and written is Ast.Nil) then
        local _ = expect(ctx, at, t, want, " in the assignment to " .. subject(ctx, target))
      end
    end
  end
end

--- Whether `list` fits the return list `alt`: the same number of values, or more with a tail, each below its item.
local function list_fits(ctx: Ctx, types: {Type}, tail: Type | nil, alt: Alt): boolean
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

local function return_statement(ctx: Ctx, s: Ast.Return)
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
  local wants: {Type} = {}
  local rest_want: Type | nil = nil
  local candidates: {Alt} = {}
  for _, alt in ipairs(alts) do
    if #alt.items == n or (#alt.items < n and alt.tail ~= nil) or (#alt.items > n) then
      candidates[#candidates + 1] = alt
    end
  end
  for i = 1, n do
    local types: {Type} = {}
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
      if literal is Ast.Boolean and vals.types[i] == ctx.store.boolean then
        vals.types[i] = ctx.store:atom(literal.value and "true" or "false")
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
          frame.declared and "remove the value" or "declare the return list: `function f(): T`")
      end
      return
    end
    local count = #vals.types
    if vals.tail == nil and (count < #alt.items or (count > #alt.items and alt.tail == nil)) then
      report(ctx, "return_arity", s, "this returns " .. plural(count, "value") .. ", where the function answers " ..
          plural(#alt.items, "value") .. (alt.tail ~= nil and " or more" or ""),
        "return " .. plural(#alt.items, "value") .. (alt.tail ~= nil and " or more" or "") ..
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
  local shown: {string} = {}
  for _, t in ipairs(vals.types) do
    shown[#shown + 1] = show(ctx, t)
  end
  report(ctx, "return_arity", s, "no list this function answers takes (" .. table.concat(shown, ", ") .. ")",
    "return the values of one of the lists the function declares")
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
  block(ctx, s.body)
end

local function for_generic(ctx: Ctx, s: Ast.ForIn)
  local store = ctx.store
  local vals = values_of(ctx, s.iterators, nil, nil)
  local iterator = vals.types[1] or vals.tail
  local types: {Type} = {}
  local several, last = vals.lists, vals.last
  if several ~= nil and last ~= nil then
    local _ = first_value(ctx, last, several)
  elseif iterator == nil then
    local first = s.iterators[1]
    report(ctx, "no_value", first, subject(ctx, first) .. " answers nothing, so there is no iterator to loop over",
      "iterate with `ipairs(...)`, `pairs(...)` or an iterator function")
  end
  if iterator == nil or iterator.tag == "invalid" then
    for i = 1, #s.vars do
      types[i] = ctx.invalid
    end
  elseif iterator is Fn and #iterator.tparams > 0 then
    unchecked(ctx, "unchecked_generic", s.iterators[1], "this iterator is a generic function")
    for i = 1, #s.vars do
      types[i] = ctx.invalid
    end
  elseif iterator is Fn then
    local alts: {Alt} = {}
    for _, alt in ipairs(iterator.rets) do
      local first = alt.items[1]
      if not (first ~= nil and first.tag == "nil") then
        alts[#alts + 1] = alt
      end
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
    if state ~= nil and iterator.params[1] ~= nil then
      local _ = expect_argument(ctx, s.iterators[math.min(2, #s.iterators)], state, iterator.params[1].type,
        " as the state of the iterator")
    end
    if control ~= nil and iterator.params[2] ~= nil then
      local _ = expect_argument(ctx, s.iterators[math.min(3, #s.iterators)] or final, control, iterator.params[2].type,
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
  for i, v in ipairs(s.vars) do
    ctx.vars[v.id] = types[i]
  end
  block(ctx, s.body)
end

--- The bodies of the methods of a class, and of the declarations nested in a record, interface or class.
local function declaration_bodies(ctx: Ctx, node: Ast.Node, decl: Decl | nil)
  local members: {Ast.Member} = {}
  if node is Ast.Record or node is Ast.Interface or node is Ast.Class then
    members = node.members
  end
  local body = decl ~= nil and decl.body or nil
  local binder = decl ~= nil and body ~= nil and #body.tparams > 0
  if binder and decl ~= nil and body ~= nil then
    local names: {string} = {}
    for i, p in ipairs(body.tparams) do
      names[i] = p.name
    end
    local tparams = Relation.binder(decl)
    ctx.judge:enter(tparams)
    ctx.binders[#ctx.binders + 1] = names
    ctx.bounds[#ctx.bounds + 1] = tparams
  end
  for _, m in ipairs(members) do
    if m is Ast.Method then
      local ft = ctx.lowered.types[m.id] or ctx.invalid
      function_body(ctx, m.params, m.body, ft, {}, m, m.rets ~= nil)
    elseif m is Ast.Record or m is Ast.Interface or m is Ast.Class then
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
  local out: {string} = {}
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
    function_body(ctx, s.fn.params, s.fn.body, function_type(ctx, s.fn, nil, "this function"), {}, s, s.fn.rets ~= nil)
    return
  end
  local owner = name_value(ctx, head)
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
  function_body(ctx, s.fn.params, s.fn.body, ft, names_of_params(s.typeparams), s, s.fn.rets ~= nil)
end

local function stat(ctx: Ctx, s: Ast.Stat)
  if s is Ast.Local then
    local_statement(ctx, s)
  elseif s is Ast.CallStat then
    local c = s.call
    if c is Ast.Call or c is Ast.MethodCall then
      local _ = lists_of(ctx, c, nil)
    end
  elseif s is Ast.Assign then
    assign_statement(ctx, s)
  elseif s is Ast.If then
    for _, arm in ipairs(s.arms) do
      local _ = condition(ctx, arm.cond)
      block(ctx, arm.body)
    end
    local else_body = s.else_body
    if else_body ~= nil then
      block(ctx, else_body)
    end
  elseif s is Ast.Return then
    return_statement(ctx, s)
  elseif s is Ast.LocalFunction then
    local ft = function_type(ctx, s.fn, nil, quoted(s.name.name))
    ctx.vars[s.name.id] = ft
    function_body(ctx, s.fn.params, s.fn.body, ft, names_of_params(s.typeparams), s, s.fn.rets ~= nil)
  elseif s is Ast.Function then
    function_statement(ctx, s)
  elseif s is Ast.While then
    local _ = condition(ctx, s.cond)
    block(ctx, s.body)
  elseif s is Ast.Repeat then
    block(ctx, s.body)
    local _ = condition(ctx, s.cond)
  elseif s is Ast.Do then
    block(ctx, s.body)
  elseif s is Ast.ForNum then
    for_numeric(ctx, s)
  elseif s is Ast.ForIn then
    for_generic(ctx, s)
  elseif s is Ast.Match then
    unchecked(ctx, "unchecked_match", s, "a `match`")
    local c = s.scrutinee
    ctx.lenient = ctx.lenient + 1
    if c is Ast.Call or c is Ast.MethodCall then
      local _ = lists_of(ctx, c, nil)
    end
    ctx.lenient = ctx.lenient - 1
    for _, arm in ipairs(s.arms) do
      for _, p in ipairs(arm.pats) do
        if p is Ast.PatBind then
          ctx.vars[p.name.id] = ctx.invalid
        end
      end
      block(ctx, arm.body)
    end
  elseif s is Ast.Record or s is Ast.Interface or s is Ast.Class then
    local decl = ctx.lowered.decls[s.id]
    if decl ~= nil then
      ctx.declared[decl] = true
    end
    declaration_bodies(ctx, s, decl)
  end
end

block = function(ctx: Ctx, b: Ast.Block)
  for _, s in ipairs(b.stats) do
    stat(ctx, s)
  end
end

function Check.check(program: Declarations.Program, input: Declarations.Input, lowered: Declarations.Lowered): Check.Checked
  local store = program.store
  local ctx: Ctx = {
    program = program, store = store, judge = program.judge, input = input, lowered = lowered, scoped = input.scoped,
    tokens = input.chunk.tokens, filename = input.filename, errors = {}, vars = {}, frames = {}, binders = {},
    bounds = {}, lenient = 0, members = {}, value_members = {}, literals = {}, declared = {}, union_fields = {}, spine = {}, top = 0, ternaries = {}, invalid = store.invalid, nil_type = store:atom("nil"),
  }
  ctx.frames[1] = { alts = {}, rest = store.string, chunk = true, declared = false }
  block(ctx, input.chunk.body)
  -- Source order; errors at one place stay in the order they were found.
  local position: {Codes.Error: integer} = {}
  for i, e in ipairs(ctx.errors) do
    position[e] = i
  end
  table.sort(ctx.errors, function(a: Codes.Error, b: Codes.Error): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return position[a] < position[b]
  end)
  return { errors = ctx.errors, vars = ctx.vars, literals = ctx.literals }
end

return Check
