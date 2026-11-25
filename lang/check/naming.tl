--- How an error of the checker ([`lang.check`]) names what it shows, and the report that tells it ([`Naming.report`]).

local Ast = require("lang.ast")
local Codes = require("lang.check_codes")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")
local Types = require("lang.types")
local type Alt = Types.Alt
local type Code = Codes.Code
local Context = require("lang.check.context")
local Lookup = require("lang.check.members")
local type Ctx = Context.Ctx
local type Type = Types.Type
local members_index = Lookup.members_index
local names_of = Lookup.names_of
local base_of = Context.base_of
local dropped_by = Context.dropped_by
local quoted = Context.quoted
local text_of = Context.text_of

--- How an error names what it shows: the type parameters by their authors' names, and the statement a nil test runs.
local record Naming
end

--- The names the lowering of `module` kept for the type parameters of the generic functions it declares, by the id of
--- each one's type: a copy, which the check adds the functions in bodies to.
function Naming.declared(program: Declarations.Program, module: string): mut {integer: {string}}
  local out: mut {integer: {string}} = {}
  local info = program.modules[module]
  local held = if info ~= nil then info.fn_names else nil end
  if held ~= nil then
    for id, names in pairs(held) do
      out[id] = names
    end
  end
  return out
end

--- Whether `names` can name a binder inside `binders`: each distinct, and none the name of a type parameter in scope.
function Naming.free_of(binders: {{string}}, names: {string}): boolean
  local seen: mut {string: boolean} = {}
  for _, b in ipairs(binders) do
    for _, n in ipairs(b) do
      seen[n] = true
    end
  end
  for _, n in ipairs(names) do
    if n == "" or seen[n] == true then
      return false
    end
    seen[n] = true
  end
  return true
end

--- The statement a fix puts in `if <name> == nil then ... end`, written for the place it is in: a function that may
--- return `nil, string` returns that, one that may return nothing or nil returns, and the module's own chunk or a function
--- whose results take no nil raises.
function Naming.on_nil(ctx: Ctx, name: string): string
  local missing = string.format("%q", name .. " is missing")
  local frame = ctx.frames[#ctx.frames]
  if frame ~= nil and not frame.chunk then
    local plain: string? = nil
    for _, alt in ipairs(frame.alts) do
      local first = alt.items[1]
      if #alt.items == 0 and alt.tail == nil then
        plain = plain or "return"
      elseif first ~= nil and ctx.judge:subtype(ctx.nil_type, first) then
        local second = alt.items[2]
        if #alt.items == 2 and second ~= nil and ctx.judge:subtype(ctx.store:atom("string"), second) then
          return "return nil, " .. missing
        elseif #alt.items == 1 then
          plain = plain or "return nil"
        end
      end
    end
    if plain ~= nil then
      return plain
    end
  end
  return "error(" .. missing .. ")"
end

--- Reports `code` on the tokens of `node`. A value that may be nil because an assignment dropped what a test had
--- shown is told that (`narrowing_dropped`), with the assignment as the second place.
function Naming.report(ctx: Ctx, code: Code, node: Ast.Node, msg: string, fix: string, shown?: {string},
                       other?: Scopes.Place)
  if ctx.quiet > 0 then
    return
  end
  local b = base_of(node)
  local tokens = ctx.tokens
  local first, last = b.first, math.max(b.first, b.last)
  local spill = ctx.spill
  if spill ~= nil then
    fix = fix .. spill
  end
  local why = code == "nil_not_allowed" and dropped_by(ctx, node) or nil -- checked: and_ternary
  if why ~= nil then
    code = "narrowing_dropped"
    other = why
    local at = why.y .. ":" .. why.x
    local name = text_of(ctx, node)
    msg = msg .. " (a test showed it was not nil, and the assignment at " .. at .. " dropped that)"
    fix = "test " .. quoted(name) .. " again after the assignment at " .. at .. " (`if " .. name ..
      " == nil then " .. Naming.on_nil(ctx, name) .. " end`), or read the value into a new local that nothing assigns (`local v = " ..
      name .. "`) and test that"
  end
  table.insert(ctx.errors, {
    filename = ctx.filename, code = code, msg = msg, fix = fix, y = Lexer.y(tokens, first), x = Lexer.x(tokens, first),
    offset = Lexer.offset(tokens, first), length = math.max(0, Lexer.stop(tokens, last) - Lexer.offset(tokens, first)),
    other = other, types = shown or {}, argument = ctx.argument,
  })
end

--- Names that bind the values of a call returning `alts`, as a fix spells them: two at least, as many as the longest
--- list has; `ok` for a first value of `true` or `false`, `v` otherwise, then `why` for a second and `v3`, `v4`, ... for
--- the rest; `_` in place of each when `discard` is true.
function Naming.bound(alts: {Alt}, discard?: boolean): string
  local width, tagged = 2, false
  for _, alt in ipairs(alts) do
    width = math.max(width, #alt.items)
    local first = alt.items[1]
    tagged = tagged or (first ~= nil and (first.tag == "true" or first.tag == "false"))
  end
  local out: mut {string} = {}
  for i = 1, width do
    local name = "v" .. tostring(i)
    if i == 1 then
      name = if tagged then "ok" else "v" end
    elseif i == 2 then
      name = "why"
    end
    out[i] = if discard == true then "_" else name end
  end
  return table.concat(out, ", ")
end

--- The call `node` as a fix spells it: its text, or its callee and `(...)` where the text is too long to show whole.
function Naming.call(ctx: Ctx, node: Ast.Node): string
  local text = text_of(ctx, node)
  if text:sub(-3) == "..." then
    local open = text:find("(", 1, true)
    if open ~= nil then
      return text:sub(1, open) .. "...)"
    end
  end
  return text
end

--- What `t` (named) has, for a read of the field `name` it does not have: the members `name` may mean ([`Context.nearest`]
--- `close`, then [`NearNames.related`] ones) with their types, then the names of the others; nil where it has none.
function Naming.members_told(ctx: Ctx, t: Type, name: string, close: string): string?
  local NearNames = require("lang.near_names")
  if not (t.tag == "named") then return nil end
  local index = members_index(ctx, t.decl, t.value)
  if index == nil then return nil end
  local names = names_of(ctx, t)
  if #names == 0 then return nil end
  local picked: mut {string} = {}
  local taken: mut {string: boolean} = {}
  local function pick(n: string)
    if n ~= "" and taken[n] == nil and #picked < NearNames.TYPED then
      picked[#picked + 1] = n
      taken[n] = true
    end
  end
  pick(close)
  for _, n in ipairs(NearNames.related(name, names)) do pick(n) end
  local typed: mut {string} = {}
  for _, n in ipairs(picked) do
    local list = index.by_name[n]
    local first = if list ~= nil then list[1] else nil end
    local shown = if first ~= nil then
      NearNames.cut(Types.display(first.type, ctx.binders, ctx.fn_names, first.params), 120) else "" end
    -- A type that holds a type variable of the checker's own (`?0.0`) is shown by its name alone.
    typed[#typed + 1] = if shown ~= "" and shown:find("%?%d") == nil then "`" .. n .. ": " .. shown .. "`" else quoted(n) end
  end
  local rest: mut {string} = {}
  local more = 0
  for _, n in ipairs(names) do
    if taken[n] == nil then
      if #rest < NearNames.NAMED then rest[#rest + 1] = n else more = more + 1 end
    end
  end
  local owner = quoted(Types.decl_name(t.decl))
  local told = if #typed > 0 then owner .. " has " .. table.concat(typed, ", ") .. "; " ..
      (if #rest > 0 then "its other members: " else "" end) else owner .. " has: " end
  if #rest > 0 then
    told = told .. table.concat(rest, ", ") .. (if more > 0 then ", and " .. tostring(more) .. " more" else "" end)
  end
  return told
end

return Naming
