--- A differential property for the recursive alias ([`lang.relation`]): for the random types of [`lang.types_programs`],
--- whether a type is below `V = string | number | boolean | Null | {V} | {string: V}` is whether a definition written apart
--- from the relation says it is: an atom of those, an enum, `Null` (a userdata record), an array or a map keyed by `string`
--- of such types, a union of such types with no `nil`, or `V` itself; a record, a class or an interface is none of them, with
--- an array part or not. The relation answers it by reading the alias one level at a time, so a comparison that did not
--- read it (or read it for ever) would differ from the definition on some type here. `FUZZ_SEED` and `FUZZ_ITERS` pick the
--- inputs (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local Programs = require("lang.relation_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")
local TypesPrograms = require("lang.types_programs")

Test.policy{}

local type Type = Types.Type

local function gen_draws(src: Fuzz.Source): string
  local out: {string} = {}
  while Fuzz.more(src, #out, 120) do
    out[#out + 1] = tostring(src:int(0, 99))
  end
  return table.concat(out, " ")
end

--- What the definition says of `t`: "yes" or "no".
local function defined(t: Type, v: Type, null: Type): string
  if t == v or t == null then
    return "yes"
  elseif t is Types.Atom then
    local tag = t.tag
    if tag == "string" or tag == "number" or tag == "integer" or tag == "boolean" or tag == "true" or tag == "false" or
        tag == "never" or tag == "invalid" then
      return "yes"
    end
    return "no"
  elseif t is Types.Union then
    if t.nilable then
      return "no"
    end
    for _, m in ipairs(t.members) do
      if defined(m, v, null) == "no" then
        return "no"
      end
    end
    return "yes"
  elseif t is Types.Array then
    return defined(t.element, v, null)
  elseif t is Types.Map then
    local key = t.key
    if key.tag ~= "string" then
      return "no"
    end
    return defined(t.value, v, null)
  elseif t is Types.Named then
    return t.decl.kind == "enum" and "yes" or "no"
  end
  return "no"
end

--- A world with the alias `V` in it, and `V`.
local function with_alias(): Programs.World, Type, Type
  local w = Programs.world()
  local s = w.store
  local null_decl = s:declare("userdata", "m", { "Null" }, 0)
  local null = s:named(null_decl, {})
  s:define(null_decl, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
  local decl = s:declare("alias", "m", { "V" }, 0)
  local v = s:named(decl, {})
  local body = s:union({ s.string, s.number, s.boolean, null, s:array(v, false), s:map(s.string, v, false) })
  s:define(decl, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, alias = body })
  return w, v, null
end

local function test_a_type_is_below_the_alias_when_the_definition_of_a_json_value_says_so(tmp: string)
  Fuzz.run({
    name = "recursive alias against its definition",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local w, v, null = with_alias()
      local draws = TypesPrograms.numbers(input)
      local count = 1 + (draws[1] or 0) % 4
      for k = 1, count do
        local part: {integer} = {}
        for i = 2 + (k - 1) * 17, #draws do
          part[#part + 1] = draws[i]
        end
        local t = TypesPrograms.generate(w.store, w.fixture, part)
        local want = defined(t, v, null)
        local got = w.judge:subtype(t, v)
        -- The reason and the answer agree, and a refusal names the alias as written.
        local why = w.judge:refuse(t, v)
        if (why == nil) ~= got then
          return false, Types.display(t) .. ": the reason and the answer differ"
        end
        if why ~= nil and why.sub == v then
          return false, Types.display(t) .. ": the refusal names the alias as its source"
        end
        do
          Fuzz.label(want == "yes" and "below" or "not below")
          if got ~= (want == "yes") then
            return false, Types.display(t) .. (got and " is" or " is not") .. " below V, and the definition says " .. want
          end
          -- Read the other way: V is below only what V is: itself, `any` is no sink, and nothing smaller.
          if t ~= v and w.judge:subtype(v, t) and t.tag ~= "invalid" then
            local body = Types.unfold(v)
            if not w.judge:subtype(body, t) then
              return false, "V is below " .. Types.display(t) .. " and its body is not"
            end
            Fuzz.label("the alias is below")
          end
        end
      end
      return true, ""
    end,
    requires = { "below", "not below" },
  })
end
