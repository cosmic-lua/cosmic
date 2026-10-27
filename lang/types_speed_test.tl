--- The speed of the type store ([`lang.types`]), held to ratios and never to a clock: a slow
--- machine slows every side of a ratio alike. Making a type that is already in the store costs no
--- more than making it the first time, and four times the input costs about four times the time for
--- each form that could cost more than its length: many types, a long union, a function of many
--- parameters or alternatives, a chain that shares its parts, refusals, a named type of many arguments, a
--- declaration of many fields, a deep nest, and the text of each read back.
local Speed = require("lang.speed")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

--- A store and `n` named types of distinct declarations, each also the element of an array.
local function populate(store: Types.Store, n: integer): {Types.Type}
  local out: mut {Types.Type} = {}
  for i = 1, n do
    local decl = store:declare("record", "m", { "R" .. i })
    out[i] = store:array(store:named(decl))
  end
  return out
end

local function test_making_types_again_costs_no_more_than_making_them()
  local store = Types.new()
  local n = 2000
  local first = Speed.least(function()
    local fresh = Types.new()
    local _ = populate(fresh, n)
  end)
  local _ = populate(store, n)
  local again = Speed.least(function()
    local _ = populate(store, n)
  end)
  -- Declaring again finds the declaration, and each type is found, so only the lookups remain.
  assert(again <= 2 * first, "making again took " .. again // 1000 .. " us against " .. first // 1000 .. " us")
end

--- Forms that a store could make slower than their length, each as a function of how many to make.
local FORMS <const>: {string: function(n: integer)} = {
  ["many types"] = function(n: integer)
    local _ = populate(Types.new(), n * 10)
  end,
  ["a long union"] = function(n: integer)
    local store = Types.new()
    local _ = store:union(populate(store, n * 10))
  end,
  ["a long union of optionals and repeats"] = function(n: integer)
    local store = Types.new()
    local members = populate(store, n * 10)
    local all: mut {Types.Type} = {}
    for i, m in ipairs(members) do
      all[i] = store:optional(m)
      all[#all + 1] = m
    end
    local _ = store:union(all)
  end,
  ["a function of many parameters"] = function(n: integer)
    local store = Types.new()
    local params: mut {Types.Param} = {}
    for i, t in ipairs(populate(store, n * 10)) do
      params[i] = { type = t, omittable = i % 3 == 0 }
    end
    local _ = store:fn({ params = params })
  end,
  ["a function of many alternatives"] = function(n: integer)
    local store = Types.new()
    local alts: mut {Types.Alt} = {}
    for i, t in ipairs(populate(store, n * 10)) do
      alts[i] = { items = { store:atom(if i % 2 == 0 then "true" else "false" end), t } }
    end
    local _ = store:fn({ rets = alts })
  end,
  ["a named type of many arguments"] = function(n: integer)
    local store = Types.new()
    local decl = store:declare("record", "m", { "Wide" })
    local _ = store:named(decl, populate(store, n * 10))
  end,
  ["a declaration of many fields"] = function(n: integer)
    local store = Types.new()
    local fields: mut {Types.Field} = {}
    for i, t in ipairs(populate(store, n * 10)) do
      fields[i] = { name = "f" .. i, type = t, mut = i % 2 == 0 }
    end
    local decl = store:declare("record", "m", { "Wide" })
    store:define(decl, { tparams = {}, supers = {}, fields = fields, methods = {}, values = {} })
    local _ = Types.encode_declaration(decl)
  end,
  ["a deep nest"] = function(n: integer)
    local store = Types.new()
    local t = store.integer
    for i = 1, n * 3 do
      t = if i % 2 == 0 then store:array(t) else store:optional(store:map(store.string, t)) end
    end
    local _ = Types.display(t)
    local _ = Types.digest(t)
  end,
  ["a chain that shares its parts"] = function(n: integer)
    local store = Types.new()
    local pair = store:declare("record", "m", { "Pair" }, 2)
    store:define(pair, { tparams = { { name = "A" }, { name = "B" } }, supers = {}, fields = {}, methods = {}, values = {} })
    local t = store.integer
    for _ = 1, n * 3 do
      t = store:named(pair, { t, t })
    end
    -- Its text is the tree it unfolds to, 2^n types: display stops, the hash is of the parts once
    -- each, and the text is refused.
    local _ = Types.digest(t)
    local _ = Types.display(t)
    assert(t.weight > 1000000 and not pcall(function()
      local _ = Types.encode(t)
    end))
  end,
  ["refusals with many uses pending"] = function(n: integer)
    local store = Types.new()
    local decl = store:declare("record", "m", { "Wide" })
    -- Uses of a declaration whose parameters are not known are held; a refusal does not look at them.
    for i = 1, n * 20 do
      local _ = store:named(decl, { store:var(0, i) })
    end
    for _ = 1, n * 20 do
      assert(store:decode("(array") == nil)
    end
  end,
  ["the text of a long union"] = function(n: integer)
    local store = Types.new()
    local members: mut {Types.Type} = {}
    for i = 1, n * 10 do
      members[i] = store:map(store.string, store:var(0, i))
    end
    local text = Types.encode(store:union(members))
    local decoded = Types.new():decode(text)
    assert(decoded ~= nil)
  end,
  ["the text of a deep nest"] = function(n: integer)
    local text = ("(array "):rep(n * 3) .. "integer" .. (")"):rep(n * 3)
    local decoded = Types.new():decode(text)
    assert(decoded ~= nil)
  end,
}

local function test_four_times_the_input_costs_about_four_times_the_time_for_each_form()
  for name, form in pairs(FORMS) do
    local ok, why = Speed.within(function()
      form(10)
    end, function()
      form(40)
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end
