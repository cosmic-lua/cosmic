--- The types of names and literals: locals, globals, the members of a module, strings and booleans.

local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Refusals = require("lang.check.refusals")
local type Type = Types.Type
local type Alt = Types.Alt
local type Decl = Types.Decl
local type Ctx = Context.Ctx
local base_of = Context.base_of
local listed = Context.listed
local members_of = Context.members_of
local nearest = Context.nearest
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local tq = Context.tq
local unchecked = Refusals.unchecked

local record Names
end

--- Checks the arguments of a call that is not typed, with no type expected of them: a literal there
--- has none to be checked against.
function Names.unchecked_arguments(ctx: Ctx, args: {Ast.Exp})
  ctx.lenient = ctx.lenient + 1
  for _, a in ipairs(args) do
    local _ = ctx.walk.expr(ctx, a, nil)
  end
  ctx.lenient = ctx.lenient - 1
end

--- The lists of values of an expression whose type is unknown: any number of `invalid`.
function Names.unknown_lists(ctx: Ctx): {Alt}
  return { { items = {}, tail = ctx.invalid } }
end

--- A declaration used as a value: the table of its functions, a type of its own that is no instance of the
--- declaration ([`Types.Named`]'s `value`). A module stored in a place typed with its record (a field `Seatbelt: Seatbelt`,
--- `Relay.Address = Address`, an array `{Child}`) is [`declaration_value`], and a program requires the module where it uses it
--- instead. A record's value still carries the fields its instances have, so the table of a record with a field it never
--- defines is typed as if it did.
function Names.declaration_value(ctx: Ctx, decl: Decl): Type
  local args: mut {Type} = {}
  for i = 1, decl.arity or 0 do
    args[i] = ctx.store:var(0, i - 1)
  end
  return ctx.store:named(decl, args, true)
end
local declaration_value = Names.declaration_value

--- The value `require("name")` returns: the declaration the module returns.
function Names.module_value(ctx: Ctx, node: Ast.Node, name: string): Type
  local program = ctx.program
  if program.external[name] == true then
    unchecked(ctx, "unchecked_binding", node, "the module " .. quoted(name) .. " is a binding of C that has no declarations")
    return ctx.invalid
  end
  local info = program.modules[name]
  if info == nil and program.provider ~= nil and program:provider(name) then
    info = program.modules[name]
  end
  if info == nil then
    local fix = "require a module of the project: `bin/cosmic docs` lists them; a file sees the modules of the tree " ..
      "it is in, so a scratch file that uses a project's modules goes inside that project"
    local says = "the project has no module " .. quoted(name)
    if program.library[name] == true then
      fix = quoted(name) .. " is a global the language declares, available without `require`: use it directly"
    elseif name:sub(1, 7) == "cosmic." then
      -- A program's `cosmic.*` modules are the binary's, which a project cannot add to.
      says = "cosmic has no module " .. quoted(name)
      fix = "`cosmic docs` lists the modules cosmic holds, and `cosmic docs <words>` finds a function by what it does"
    end
    report(ctx, "require_unknown", node, says, fix)
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
        quoted(Types.decl_name(decl)) .. " whose type arguments the checker has not read")
    return ctx.invalid
  elseif decl ~= nil then
    return declaration_value(ctx, decl)
  end
  local alias = export.alias
  local aliased = alias ~= nil and alias.type or nil -- checked: and_ternary
  if aliased == nil then
    return ctx.invalid
  end
  return aliased
end
local module_value = Names.module_value

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
--- returns nil where Lua does says so (`s:find(p)` is `integer?`), so each use of its result is held to that.
local function global_value(ctx: Ctx, node: Ast.Name): Type
  local program = ctx.program
  local values = program.values[node.text]
  if values ~= nil then
    if #values > 1 then
      ctx.cands = values
      ctx.cand_node = node
    end
    return values[1] -- checked: index_may_be_nil
  end
  local entry = program.globals[node.text]
  local decl = entry ~= nil and entry.decl or nil -- checked: and_ternary
  if decl ~= nil then
    return declaration_value(ctx, decl)
  end
  if unknown_offsets(ctx)[Lexer.offset(ctx.tokens, base_of(node).first)] == true then
    return ctx.invalid
  end
  unchecked(ctx, "unchecked_binding", node, "the global " .. quoted(node.text) .. " has no declaration the checker can read")
  return ctx.invalid
end

function Names.name_value(ctx: Ctx, node: Ast.Name): Type
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
  if v.kind == "record" or v.kind == "class" or v.kind == "integer_enum" then
    local entry = ctx.lowered.entries[id]
    local decl = entry ~= nil and entry.decl or nil -- checked: and_ternary
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

--- A string whose contents are `value`, written as `node`: an enum member where an enum is expected and it is one.
function Names.string_value(ctx: Ctx, node: Ast.Node, value: string, expected: Type?): Type
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
  local test = ctx.comparing
  local always = ""
  if test ~= nil and (peel(test.left) == node or peel(test.right) == node) then
    always = ", so the test is always " .. (if test.op == "==" then "false" else "true" end)
  end
  report(ctx, "enum_member", node, quoted(string.format("%q", value)) .. " is not a member of " .. tq(ctx, expected) ..
      (if close ~= "" then ", nearest " .. quoted(string.format("%q", close)) else "" end) .. always,
    "write " .. listed(shown), { show(ctx, expected) })
  return ctx.invalid
end
local string_value = Names.string_value

function Names.string_literal(ctx: Ctx, e: Ast.String, expected: Type?): Type
  return string_value(ctx, e, e.value, expected)
end

return Names
