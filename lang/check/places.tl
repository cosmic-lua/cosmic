--- The places the facts of the flow hold for (a local, or a path of fixed fields from one), and how two flows merge.

local Ast = require("lang.ast")
local Flow = require("lang.flow")
local Scopes = require("lang.scopes")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Lookup = require("lang.check.members")
local Fields = require("lang.check.fields")
local type Type = Types.Type
local type Decl = Types.Decl
local type Ctx = Context.Ctx
local below = Context.below
local members_of = Context.members_of
local path_key = Context.path_key
local peel = Context.peel
local member_types = Fields.member_types
local put_in = Lookup.put_in

--- A place the facts may hold: a local, or a path of fixed fields from one.
local record Place
  key: string
  --- What the program declared it with.
  declared: Type
end

local record Places
  type Place = Place
  PLACE_KINDS: {Scopes.Kind: boolean}
end

--- The union `t` without a member that is below another, so that the join of two facts is the wider one (`{T}` for
--- `mut {T} | {T}`, a class for the interface it lists): a fact never carries a type its edges' do not need.
function Places.subsume(ctx: Ctx, t: Type): Type
  if not ((t.tag == "union")) then
    return t
  end
  local members = members_of(ctx.store, t)
  -- A record or a class is below another record or class only when that is its own declaration ([`lang.relation`]).
  -- Members that are all records and classes of declarations apart (a tagged union is one), and `nil`, are below none
  -- of each other, and the pairs need not be asked: for a union of many members that is all the cost of a join, and a
  -- left fold of joins asks every pair of every union it makes.
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
function Places.merge(ctx: Ctx, a: Flow.State, b: Flow.State): Flow.State
  return Flow.join(a, b, ctx.unite, ctx.covers)
end
local merge = Places.merge

--- The state where all of `list` meet; the first where there is one.
function Places.merge_all(ctx: Ctx, list: {Flow.State}): Flow.State
  local at = list[1]
  for i = 2, #list do
    at = merge(ctx, at, list[i]) -- checked: index_may_be_nil, nil_not_allowed
  end
  return at -- checked: nil_not_allowed
end

--- The type of `place` in `f`: what it was narrowed to, else what it was declared with.
function Places.current(f: Flow.State, place: Place): Type
  local fact = Flow.fact(f, place.key)
  if fact ~= nil then
    return fact.type
  end
  return place.declared
end
local current = Places.current

--- The kinds of binding a place may be.
local PLACE_KINDS <const>: {Scopes.Kind: boolean} = {
  ["local"] = true, ["function"] = true, param = true, loop = true, pattern = true,
}
Places.PLACE_KINDS = PLACE_KINDS

--- The place the expression `e` names in the state `f`, or nil: a local, or `a.b.c` from one with each field fixed
--- (not declared `mut`) of a record, class or interface, read through the type the facts hold of what is before it.
--- A global, a `mut` field, an index and a field of anything else are not places: code that runs between a test and a
--- use can change them. Nor is a local that any function assigns ([`Scopes.Var.closure_assigned`], known for the whole
--- scope before the first test, wherever the function is made): a call between a test and a use may run the assignment.
function Places.place_of(ctx: Ctx, f: Flow.State, e: Ast.Node): Place?
  local at = peel(e)
  if (at.kind == "Name") then
    local id = at.binding
    if id == nil then
      return nil
    end
    local v = ctx.scoped.vars[id]
    local declared = ctx.vars[id]
    local key = path_key(ctx, at)
    if v == nil or declared == nil or key == nil or PLACE_KINDS[v.kind] ~= true or v.closure_assigned or
        ctx.unfixed_now[id] == true then
      return nil
    end
    return { key = key, declared = declared }
  elseif (at.kind == "Field") then
    local base = Places.place_of(ctx, f, at.object)
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
    local m = list ~= nil and list[1] or nil -- checked: and_ternary
    if list == nil or m == nil or #list ~= 1 or m.method or m.mut then
      return nil
    end
    return { key = base.key .. "." .. at.name, declared = put_in(ctx, owner, m.type) }
  end
  return nil
end

return Places
