--- The speed of the relation ([`lang.relation`]), held to ratios and never to a clock, as the speed
--- of the store ([`lang.types_speed_test`]) is: a pair already settled costs no more than the
--- lookup of it, and four times the input costs about four times the time for each form that
--- could cost more than its length: a union checked against a superset, a union that none of
--- whose members is below a type, a deep nest, a chain that shares its parts (which a relation
--- without a memo walks as a tree of two to the power of its length), a declaration that lists
--- many interfaces or extends a chain of them, a record with an array part against a deep nest, a
--- function of many parameters or return values, and a named type of many arguments.
local Relation = require("lang.relation")
local Speed = require("lang.speed")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

--- A store and `n` named types of distinct declarations.
local function populate(store: Types.Store, n: integer): {Types.Type}
  local out: mut {Types.Type} = {}
  for i = 1, n do
    out[i] = store:named(store:declare("record", "m", { "R" .. tostring(i) }))
  end
  return out
end

--- `n` interfaces and the class that lists all of them.
local function listing(store: Types.Store, n: integer): Types.Type, {Types.Type}
  local interfaces: mut {Types.Type} = {}
  for i = 1, n do
    local decl = store:declare("interface", "m", { "I" .. tostring(i) }, 0)
    store:define(decl, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
    interfaces[i] = store:named(decl)
  end
  local class = store:declare("class", "m", { "C" }, 0)
  store:define(class, { tparams = {}, supers = interfaces, fields = {}, methods = {}, values = {} })
  return store:named(class), interfaces
end

local record Chain
  store: Types.Store
  first: Types.Type
  last: Types.Type
end

--- A store and `n` interfaces that each extend the one before.
local function chain_of(n: integer): Chain
  local store = Types.new()
  local previous: Types.Type?
  local first: Types.Type?
  for i = 1, n do
    local decl = store:declare("interface", "m", { "E" .. tostring(i) }, 0)
    local supers: mut {Types.Type} = {}
    if previous ~= nil then
      supers[1] = previous
    end
    store:define(decl, { tparams = {}, supers = supers, fields = {}, methods = {}, values = {} })
    previous = store:named(decl)
    first = first or previous
  end
  assert(previous ~= nil and first ~= nil)
  return { store = store, first = first, last = previous }
end

local function test_a_pair_that_is_settled_costs_no_more_than_its_lookup()
  local store = Types.new()
  local judge = Relation.new(store)
  local views: mut {Types.Type} = {}
  local wider: mut {Types.Type} = {}
  for _, t in ipairs(populate(store, 2000)) do
    local view = store:array(store:array(t))
    local wide = store:array(store:array(store:optional(t)))
    views[#views + 1] = view
    wider[#wider + 1] = wide
  end
  local function settle()
    for i = 1, #views do
      assert(judge:subtype(views[i], wider[i]))
    end
  end
  local first = Speed.least(function()
    local fresh = Relation.new(store)
    for i = 1, #views do
      assert(fresh:subtype(views[i], wider[i]))
    end
  end)
  settle()
  local again = Speed.least(settle)
  assert(again <= first, "asking again took " .. tostring(again // 1000) .. " us against " .. tostring(first // 1000) .. " us")
end

--- Forms that a relation could make slower than their length, each as a function of how many.
local FORMS <const>: {string: function(n: integer)} = {
  ["many pairs"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    for _, t in ipairs(populate(store, n * 10)) do
      assert(judge:subtype(store:array(t), store:array(store:optional(t))))
    end
  end,
  ["a long union below a superset"] = function(n: integer)
    local store = Types.new()
    local members = populate(store, n * 10 + 1)
    local sub: mut {Types.Type} = {}
    for i = 1, n * 10 do
      sub[i] = assert(members[i])
    end
    local judge = Relation.new(store)
    assert(judge:subtype(store:union(sub), store:union(members)))
    assert(judge:refuse(store:union(sub), store:union(members)) == nil)
  end,
  ["a long union of optionals below a superset"] = function(n: integer)
    local store = Types.new()
    local members = populate(store, n * 10 + 1)
    local sub: mut {Types.Type} = {}
    for i = 1, n * 10 do
      sub[i] = assert(members[i])
    end
    sub[#sub + 1] = store:atom("nil")
    local judge = Relation.new(store)
    assert(judge:subtype(store:union(sub), store:optional(store:union(members))))
  end,
  ["a type below none of a long union"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local union = store:union(populate(store, n * 10))
    assert(not judge:subtype(store.integer, union))
    local reason = judge:refuse(store.integer, union)
    assert(reason ~= nil and reason.code == "union_none")
  end,
  ["a union of 72 records asked about records in it and outside it"] = function(n: integer)
    -- The syntax tree's union has 72 members and is asked about every member and about records that are none of them: a
    -- member is found by its id, and a record outside is compared with each of the 72, so the cost grows with the asks.
    local store = Types.new()
    local judge = Relation.new(store)
    local members = populate(store, 72)
    local union = store:union(members)
    local outside = populate(store, n * 10 + 72)
    for _ = 1, n do
      for _, member in ipairs(members) do
        assert(judge:subtype(member, union))
      end
    end
    local last = union
    for i, stranger in ipairs(outside) do
      if i > 72 then
        assert(not judge:subtype(stranger, union))
        last = stranger
      end
    end
    local reason = judge:refuse(last, union)
    assert(reason ~= nil and reason.code == "union_none")
    assert(judge:subtype(union, store:union(outside)))
  end,
  ["a deep nest"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local a, b = store.integer, store.number
    for i = 1, n * 3 do
      a, b = store:array(a), store:array(b)
      if i % 4 == 0 then
        a, b = store:optional(a), store:optional(b)
      end
    end
    assert(judge:subtype(a, b))
    assert(not judge:subtype(b, a))
    assert(judge:refuse(b, a) ~= nil)
  end,
  ["a chain that shares its parts"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local a, b = store.integer, store.number
    for _ = 1, n * 3 do
      a = store:union({ store:array(a), store:map(store.string, a) })
      b = store:union({ store:array(b), store:map(store.string, b) })
    end
    assert(judge:subtype(a, b))
    assert(not judge:subtype(b, a))
    assert(judge:refuse(b, a) ~= nil)
  end,
  ["a refusal whose alternatives share their pairs"] = function(n: integer)
    -- Each level of the target is a union of two members that both go on to the next level, so
    -- the reasons of one request are a graph of 2^n paths and must stay one object per pair.
    local store = Types.new()
    local judge = Relation.new(store)
    local src: Types.Type = store.number
    local dst: Types.Type = store.integer
    for _ = 1, n * 3 do
      src = store:array(src)
      dst = store:union({ store:array(dst), store:array(store:optional(dst)) })
    end
    local reason = judge:refuse(src, dst)
    local seen: {Relation.Refusal: boolean} = {}
    local counted = { count = 0 }
    local function walk(r: Relation.Refusal)
      if not seen[r] then
        seen[r] = true
        counted.count = counted.count + 1
        for _, alternative in ipairs(r.alternatives or {}) do
          walk(alternative)
        end
      end
    end
    walk(assert(reason))
    assert(counted.count <= 8 * n * 3, counted.count)
  end,
  ["a declaration that lists many interfaces"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local class, interfaces = listing(store, n * 10)
    for _, interface in ipairs(interfaces) do
      assert(judge:subtype(class, interface))
    end
    assert(not judge:subtype(interfaces[1], class))
  end,
  ["a record with an array part against a deep nest"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local node = store:declare("record", "m", { "Node" }, 0)
    local use = store:named(node)
    store:define(node, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {}, array = use })
    local wanted: Types.Type = use
    for _ = 1, n * 3 do
      wanted = store:array(wanted)
    end
    assert(judge:subtype(use, wanted))
    assert(not judge:subtype(use, store:array(store.string)))
  end,
  ["a function of many parameters"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local given: mut {Types.Param} = {}
    local wanted: mut {Types.Param} = {}
    for i = 1, n * 10 do
      given[i] = { type = store.number, omittable = i % 3 == 0 }
      wanted[i] = { type = store.integer, omittable = i % 3 == 0 }
    end
    assert(judge:subtype(store:fn({ params = given }), store:fn({ params = wanted })))
    assert(not judge:subtype(store:fn({ params = wanted }), store:fn({ params = given })))
  end,
  ["a function of many return values"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local given: mut {Types.Type} = {}
    local wanted: mut {Types.Type} = {}
    for i = 1, n * 10 do
      given[i] = store.integer
      wanted[i] = store.number
    end
    assert(judge:subtype(store:fn({ rets = { { items = given } } }), store:fn({ rets = { { items = wanted } } })))
    assert(judge:refuse(store:fn({ rets = { { items = wanted } } }), store:fn({ rets = { { items = given } } })) ~= nil)
  end,
  ["a named type of many arguments"] = function(n: integer)
    local store = Types.new()
    local judge = Relation.new(store)
    local decl = store:declare("record", "m", { "Wide" })
    local given = populate(store, n * 10)
    local wanted: mut {Types.Type} = {}
    for i, t in ipairs(given) do
      wanted[#wanted + 1] = if i == #given then store.integer else t end
    end
    assert(not judge:subtype(store:named(decl, given), store:named(decl, wanted)))
    local reason = judge:refuse(store:named(decl, given), store:named(decl, wanted))
    assert(reason ~= nil and reason.code == "invariant_generic")
  end,
}

--- The sizes the forms are timed at, small and four times it. Each is small enough that
--- [`Speed.least`] repeats a form many times to fill a sample: a sample is then an average over
--- several slices of the processor, as the sample of the other side is. A form of a few tens of
--- milliseconds is one run to a sample, which a host with more work than processors slows by the
--- number of runners that share it while the short side, which fits in a slice, escapes: four
--- times the input then read as more than ten times the time.
local SMALL <const> = 3
local LARGE <const> = 4 * SMALL

local function test_four_times_the_input_costs_about_four_times_the_time_for_each_form()
  for name, form in pairs(FORMS) do
    local ok, why = Speed.within(function()
      form(SMALL)
    end, function()
      form(LARGE)
    end, 8, 5)
    assert(ok, name .. ": four times the input " .. why)
  end
end

local function test_four_times_the_input_costs_about_four_times_the_time_for_a_chain_of_interfaces_that_extend_each_other()
  -- The store checks every declaration against a cycle by walking what it extends, so a chain
  -- costs its length squared to build while the relation, which is what is timed, is linear. Built
  -- inside the timed work, four times the length costs five or six times the time, which leaves
  -- little of the limit for a pause of the machine.
  --
  -- TODO: once [`Store.define`] keeps which declarations a declaration reaches, so that its cycle
  -- check is not a walk of the whole chain each time, build the chain inside the timed work and
  -- put it with the other forms.
  local function ask(chain: Chain)
    local judge = Relation.new(chain.store)
    assert(judge:subtype(chain.last, chain.first))
    assert(not judge:subtype(chain.first, chain.last))
  end
  local small, large = chain_of(160), chain_of(640)
  local ok, why = Speed.within(function()
    ask(small)
  end, function()
    ask(large)
  end, 10)
  assert(ok, "four times the input " .. why)
end
