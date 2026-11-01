--- Fuzz property for [`lang.boundaries`], over the random types of [`lang.types_programs`]: a value made for a type is
--- accepted by the kinds [`Boundaries.kinds`] answers for it, as the worker's `__cosmic_tc` reads them, and a mapping that
--- leaves a kind out is caught. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
local Boundaries = require("lang.boundaries")
local Fuzz = require("build.fuzz")
local Hash = require("cosmic.hash")
local Programs = require("lang.types_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")
local worker = require("build.test_worker")

Test.policy{ cpu_features = true }

local function gen_draws(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 120) do
    out[#out + 1] = tostring(src:int(0, 99))
  end
  return table.concat(out, " ")
end

local record Walk
  draws: {integer}
  mut at: integer
end

local function pick(walk: Walk, n: integer): integer
  walk.at = walk.at + 1
  return (walk.draws[walk.at] or 0) % n
end

--- Where the values made for a type go: `send` crosses the hook, and `enum` and `class` say which member or class a value
--- stands for, since the hook sees neither.
local record Sink
  send: function(value: any)
  enum: function(value: string)
  class: function(decl: Types.Decl)
  --- A value the type's kinds must not admit.
  reject: function(value: any)
end

--- Sends a value of a userdata record: a hasher, which the worker's hook tells by `type` alone.
local function send_userdata(sink: Sink)
  local hasher = assert(Hash.hasher("sha256"))
  sink.send(hasher)
end

--- Hands `sink` a value of the type `t`, drawn from `walk`, and answers whether the type has one (`never` has none).
local function emit(walk: Walk, t: Types.Type, sink: Sink): boolean
  local current = Types.unfold(t)
  local table_value: mut {string: boolean} = {}
  if (current.tag == "union") then
    local chosen = pick(walk, #current.members + (if current.nilable then 1 else 0 end)) + 1
    local member = current.members[chosen]
    if member == nil then
      sink.send(nil)
      return true
    end
    return emit(walk, member, sink)
  elseif current.tag == "integer" then
    sink.send(pick(walk, 100) - 50)
    -- A float is no integer, whole or not.
    sink.reject(2.0)
  elseif current.tag == "number" then
    sink.send(if pick(walk, 2) == 0 then 2 else 1.5 end)
  elseif current.tag == "string" then
    sink.send("text")
  elseif current.tag == "boolean" then
    sink.send(pick(walk, 2) == 0)
  elseif current.tag == "true" then
    sink.send(true)
  elseif current.tag == "false" then
    sink.send(false)
  elseif current.tag == "nil" then
    sink.send(nil)
  elseif current.tag == "never" then
    return false
  elseif current.tag == "fn" then
    sink.send(function() end)
  elseif current.tag == "array" or current.tag == "map" then
    sink.send(table_value)
  elseif (current.tag == "named") then
    local kind = current.decl.kind
    local body = current.decl.body
    if kind == "enum" and body ~= nil then
      local member = body.values[pick(walk, #body.values) + 1]
      if member == nil then
        return false
      end
      sink.enum(member)
      sink.send(member)
    elseif kind == "userdata" and current.decl.name == "Coroutine" then
      -- A thread at run time, though declared a userdata.
      sink.send(coroutine.create(function() end))
    elseif kind == "userdata" then
      send_userdata(sink)
    elseif kind == "interface" and pick(walk, 2) == 0 then
      -- A userdata record may implement an interface.
      send_userdata(sink)
    else
      if kind == "class" and not current.value then
        sink.class(current.decl)
      end
      sink.send(table_value)
    end
  else
    -- `any`, a variable or `invalid`: a value of any kind.
    local choice = pick(walk, 5)
    if choice == 0 then
      sink.send(1)
    elseif choice == 1 then
      sink.send("s")
    elseif choice == 2 then
      sink.send(true)
    elseif choice == 3 then
      sink.send(0.5)
    else
      sink.send(table_value)
    end
  end
  return true
end

local function violations_met(): integer
  local n = 0
  for _, each in ipairs(worker.violations()) do
    n = n + each.count
  end
  return n
end

--- The call of the worker's hook for a boundary of one value: `__cosmic_tc(2, text, value)`.
local function hook_of(): function(text: string, value: any)
  worker.install_checks()
  return function(text: string, value: any)
    worker.cross(text, value)
  end
end

local ORDER <const>: {string} = { "integer", "number", "string", "boolean", "table", "function", "userdata", "nil" }

--- The kinds with `dropped` taken out of the mapping, or the kinds themselves where it is "".
local function without(kinds: Boundaries.Kinds, dropped: string): Boundaries.Kinds
  local list: mut {string} = {}
  for _, kind in ipairs(kinds.list) do
    if kind ~= dropped then
      list[#list + 1] = kind
    end
  end
  return { list = list, strings = kinds.strings, classes = kinds.classes }
end

--- What a sink met: the first reason a value was refused.
local record Held
  mut why: string
end

--- Why a value made for the type drawn from `input` is not accepted by its kinds with `dropped` taken out of the mapping
--- ("" leaves it as it is), or "". `labelled` says whether the input counts toward the labels the property requires.
local function refused(input: string, cross: function(text: string, value: any), dropped: string, labelled: boolean): string
  local draws = Programs.numbers(input)
  local store = Types.new()
  local fixture = Programs.fixture(store)
  local t = Programs.generate(store, fixture, draws)
  local walk: Walk = { draws = draws, at = 0 }
  if pick(walk, 4) == 0 then
    local decl = store:declare("userdata", "m", { "Coroutine" }, 0)
    store:define(decl, { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
    t = store:union({ t, store:named(decl) })
  end
  local kinds = Boundaries.kinds(t)
  local held: Held = { why = "" }
  local text = "-"
  local mapped: Boundaries.Kinds? = nil
  if kinds ~= nil then
    mapped = without(kinds, dropped)
    text = "f;lang/boundaries_fuzz_test.tl:1;field;" .. Boundaries.spec(mapped)
  end
  local sink: Sink = {
    send = function(value: any)
      local before = violations_met()
      cross(text, value)
      if violations_met() ~= before and held.why == "" then
        held.why = Types.display(t) .. " is not satisfied by " .. text .. ": a " .. type(value)
      end
    end,
    reject = function(value: any)
      if mapped ~= nil and held.why == "" then
        local before = violations_met()
        cross(text, value)
        if violations_met() == before then
          held.why = Types.display(t) .. " is satisfied by " .. text .. ", though " .. type(value) .. " " ..
            "is not an integer"
        end
      end
    end,
    enum = function(value: string)
      local strings = if mapped ~= nil then mapped.strings else nil end
      if strings ~= nil and held.why == "" then
        local found = false
        for _, each in ipairs(strings) do
          found = found or each == value
        end
        if not found then
          held.why = Types.display(t) .. ": the member " .. value .. " is none of the strings it admits"
        end
      end
    end,
    class = function(decl: Types.Decl)
      local classes = if mapped ~= nil then mapped.classes else nil end
      if classes ~= nil and held.why == "" then
        local found = false
        for _, each in ipairs(classes) do
          found = found or each == decl
        end
        if not found then
          held.why = Types.display(t) .. ": the class " .. decl.name .. " is none of the classes it admits"
        end
      end
    end,
  }
  local has = emit(walk, t, sink)
  if labelled then
    Fuzz.label(if kinds == nil then "unchecked" elseif has then "checked" else "no value" end)
  end
  return held.why
end

local function test_a_value_made_for_a_type_is_accepted_by_its_kinds(tmp: string)
  local cross = hook_of()
  Fuzz.run({
    name = "boundaries accept",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local why = refused(input, cross, "", true)
      return why == "", why
    end,
    requires = { "checked", "unchecked" },
  })
end

--- Taking one kind out of the mapping is caught: some input has a value of that kind, and the hook records it.
local function test_a_mapping_that_leaves_a_kind_out_is_caught()
  local cross = hook_of()
  local caught: mut {string: boolean} = {}
  local state = 12345
  for _ = 1, 600 do
    local out: mut {string} = {}
    for _ = 1, 40 do
      state = (state * 1103515245 + 12345) % 2147483648
      out[#out + 1] = tostring((state // 65536) % 100)
    end
    local input = table.concat(out, " ")
    assert(refused(input, cross, "", false) == "", "the real mapping refused " .. input)
    for _, kind in ipairs(ORDER) do
      if refused(input, cross, kind, false) ~= "" then
        caught[kind] = true
      end
    end
  end
  for _, kind in ipairs(ORDER) do
    assert(caught[kind], "leaving out " .. kind .. " broke no input")
  end
end
