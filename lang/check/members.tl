--- The members of a type the checker reads: the methods a receiver takes and the members a record or a module has.

local Declarations = require("lang.declarations")
local Relation = require("lang.relation")
local Types = require("lang.types")
local Context = require("lang.check.context")
local type Type = Types.Type
local type Named = Types.Named
local type Decl = Types.Decl
local type Ctx = Context.Ctx
local type Members = Context.Members

local record Lookup
  KIND_WORDS: {Types.DeclKind: string}
end

--- Whether the function type `given`, or the function it is when optional, takes a value of the declaration `decl` first: the
--- shape of a method of it. An optional method (`cb?: function(P): string`) is the function or nil: the receiver is the
--- function's.
function Lookup.takes_receiver(ctx: Ctx, decl: Decl, given: Type): boolean
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
local takes_receiver = Lookup.takes_receiver

--- The members of `decl` by name, or nil where it has no body to read. Where `value` they are those of the
--- declaration used as a value: the statics its `function R.m(...)` statements gave it besides, and no array part. The
--- table of a class holds its methods and statics and none of the fields of its values, so a class's value has no
--- field. A record's value keeps the fields it declares, since a module record declares its functions and constants
--- as fields.
function Lookup.members_index(ctx: Ctx, decl: Decl, value: boolean): Members?
  local cache = value and ctx.value_members or ctx.members -- checked: and_ternary
  local held = cache[decl]
  if held ~= nil then
    return held
  end
  local body = decl.body
  if body == nil then
    return nil
  end
  local schema = if value and body.schema ~= nil then ctx.store:find("cosmic.sqlite", "Schema") else nil end
  if schema ~= nil then
    -- A `local schema` used as a value is [`Sqlite.schema`] of its DDL.
    local of_schema = Lookup.members_index(ctx, schema, false)
    if of_schema ~= nil then
      cache[decl] = of_schema
    end
    return of_schema
  end
  local index: Members = { by_name = {}, array = not value and body.array or nil, selfish = {} } -- checked: and_ternary
  local absent = ctx.program.absent[decl] or {}
  for _, f in ipairs(body.fields) do
    -- A function field that every value holds and no statement gives the table of the functions is not in that table.
    if not (value and (decl.kind == "class" or absent[f.name] == true)) then
      local list = index.by_name[f.name] or {}
      list[#list + 1] = { type = f.type, mut = f.mut == true, method = false, params = f.params } -- checked: view_written
      index.by_name[f.name] = list
    end
  end
  for _, m in ipairs(body.methods) do
    local list = index.by_name[m.name] or {}
    list[#list + 1] = { type = m.type, mut = false, method = true, params = m.params } -- checked: view_written
    index.by_name[m.name] = list
  end
  if not value then
    -- A declaration that lists an interface has the fields it leaves out from it.
    for _, f in ipairs(Declarations.inherited(ctx.store, ctx.judge, decl)) do
      index.by_name[f.name] = { { type = f.type, mut = f.mut == true, method = false, params = f.params } }
    end
  end
  if value and decl.kind == "integer_enum" then
    -- The table of an integer enum holds its members, each a value of the enum, and two functions: `of` returns the
    -- member an integer is, or nil, and `name` the name of a member. No member takes either name
    -- ([`lang.declarations`]).
    local store = ctx.store
    local member = store:named(decl, {}, false)
    for _, v in ipairs(body.values) do
      index.by_name[v] = { { type = member, mut = false, method = false } }
    end
    local of = store:fn({ params = { { type = store.integer } }, rets = { { items = { store:optional(member) } } } })
    local name = store:fn({ params = { { type = member } }, rets = { { items = { store.string } } } })
    index.by_name["of"] = { { type = of, mut = false, method = false } }
    index.by_name["name"] = { { type = name, mut = false, method = false } }
  end
  if value then
    for name, f in pairs(ctx.program.statics[decl] or {}) do
      local list = index.by_name[name] or {}
      list[#list + 1] = { type = f.type, mut = false, method = false, params = f.params } -- checked: view_written
      index.by_name[name] = list
    end
  else
    -- A function that takes a value of the declaration first (`function R.m(self: R, ...)`) has the shape of a method. The
    -- table of a class is the metatable of its values, so `v:m(...)` reaches it at run time, as it reaches the methods
    -- inside the class. A record's value has no metatable and holds no such function: the name is listed in `selfish` for
    -- [`Fields.field_unknown`] to say so. The name cannot be one of the declaration's own: a class holds its members in one
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
local members_index = Lookup.members_index

--- `t`, a type written in the declaration of `n`, with the type arguments of `n` put in.
function Lookup.put_in(ctx: Ctx, n: Named, t: Type): Type
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
function Lookup.names_of(ctx: Ctx, n: Named): {string}
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
  record = "record", class = "class", interface = "interface", enum = "enum", integer_enum = "integer enum",
  userdata = "userdata record",
}
Lookup.KIND_WORDS = KIND_WORDS

return Lookup
