--- Facts, [`checker/facts.tl`]: an immutable map from a place's id to its
--- narrowed type. The module is compiled here by the compiler the tree
--- carries. Property tests draw a program of operations on [`Facts`] and run
--- it against a model, a plain table of ids to masks and tombstones, held
--- to the definitions in the module's doc comments: every operation agrees
--- with the model, hands back the object it was given when nothing
--- changes, leaves its arguments as they were, and keeps the counts of
--- field paths and globals; `meet` is commutative, associative and
--- idempotent with a dead edge as its identity; and in debug mode every
--- result raises on a write. A type is an opaque token, here a set of three
--- bits, so `unite` is the intersection of two sets and an empty one drops
--- the key. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local Test = require("cosmic.test")
local teal = require("build.teal")

Test.policy{ grants = { { path = "checker/facts.tl", letters = "r" } } }

local record Type
  typename: string
end

local record Drop
  kind: string
  text: string
  y: integer
  x: integer
  place: string
end

local record Facts
  t: {string:Type}
  gone: {string:Drop}
  paths: integer
  globals: integer
end

local record Api
  debug: boolean
  empty: function(): Facts
  get: function(Facts | nil, string): Type | nil
  has: function(Facts | nil, string): boolean
  is_empty: function(Facts | nil): boolean
  dropped: function(Facts | nil, string): Drop | nil
  has_gone: function(Facts | nil): boolean
  note: function(Facts | nil, string, Drop): Facts | nil
  with: function(Facts | nil, string, Type): Facts | nil
  without: function(Facts | nil, string, Drop): Facts | nil
  without_prefix: function(Facts | nil, string, Drop): Facts | nil
  without_field: function(Facts | nil, string, Drop): Facts | nil
  without_paths: function(Facts | nil, Drop): Facts | nil
  without_globals: function(Facts | nil, Drop): Facts | nil
  meet: function(Facts | nil, Facts | nil, function(Type, Type): Type | nil): Facts | nil
  restrict: function(Facts | nil, Facts | nil, function(Type, Type): boolean): Facts | nil
  for_body: function(Facts | nil, (function(string): boolean), Drop): Facts | nil
end

local loaded = { value = nil as Api | nil }

--- [`checker/facts.tl`], compiled by the carried compiler and loaded once.
local function module(): Api
  local value = loaded.value
  if value ~= nil then
    return value
  end
  local compiled = assert(teal.load(true))
  local env = assert(compiled.new_env({ defaults = {
    feat_lax = "off", gen_compat = "off", gen_target = "5.4",
  } }))
  local code, result = compiled.gen(assert(Fs.read("checker/facts.tl")), env, nil, "tl")
  assert(code ~= nil and #result.type_errors == 0, "checker/facts.tl does not compile")
  local chunk = assert(load(code, "@checker/facts.tl", "t"))
  local api: any = chunk()
  loaded.value = api as Api
  return loaded.value
end

-- The types: one interned table per set of three bits, so two equal sets
-- are the same object, as the checker's own types are not but a test can
-- make them.
local tokens: {integer:Type} = {}
local masks: {Type:integer} = {}

local function token(mask: integer): Type
  local made = tokens[mask]
  if made == nil then
    made = { typename = "m" .. tostring(mask) }
    tokens[mask] = made
    masks[made] = mask
  end
  return made
end

local function mask_of(ty: Type): integer
  return masks[ty]
end

--- The meet of two types: the sets' intersection, and an empty one is no
--- type, which drops the key.
local function unite(x: Type, y: Type): Type | nil
  local both = mask_of(x) & mask_of(y)
  if both == 0 then
    return nil
  end
  return token(both)
end

--- Whether the set of `x` is within the set of `y`.
local function is_a(x: Type, y: Type): boolean
  return mask_of(x) & ~mask_of(y) == 0
end

--- Every id the programs use: a local, locals one of which is a prefix of
--- another as text without being its base (`"1"`, `"10"`, `"11"`), field
--- paths of several depths, a global and its field, and the ids that are
--- empty or begin or end in a dot.
local IDS <const>: {string} = {
  "", "1", "10", "11", "2", "1.f", "1.f.g", "1.g", "10.f", "2.f", "1.", ".f", "..",
  "g:x", "g:x.f", "g:y", "x.f.f", "1.fx",
}

--- The field names a write through a reference may write.
local FIELDS <const>: {string} = { "f", "g", "", "fx", "ff" }

-- The model: what each operation is defined to give, written plainly.
local record Model
  t: {string:integer}
  gone: {string:Drop}
end

local function model_copy(m: Model): Model
  local out: Model = { t = {}, gone = {} }
  for id, mask in pairs(m.t) do out.t[id] = mask end
  for id, w in pairs(m.gone) do out.gone[id] = w end
  return out
end

local function model_paths(m: Model): integer
  local n = 0
  for id in pairs(m.t) do
    if id:find("%.") ~= nil then n = n + 1 end
  end
  return n
end

local function model_globals(m: Model): integer
  local n = 0
  for id in pairs(m.t) do
    if id:find("^g:") ~= nil then n = n + 1 end
  end
  return n
end

--- Whether two models hold the same masks and the very same tombstones.
local function model_equal(a: Model | nil, b: Model | nil): boolean
  if a == nil or b == nil then
    return a == nil and b == nil
  end
  for id, mask in pairs(a.t) do
    if b.t[id] ~= mask then return false end
  end
  for id, mask in pairs(b.t) do
    if a.t[id] ~= mask then return false end
  end
  for id, w in pairs(a.gone) do
    if b.gone[id] ~= w then return false end
  end
  for id, w in pairs(b.gone) do
    if a.gone[id] ~= w then return false end
  end
  return true
end

--- Whether `f` is the model `m`: the same masks, the very same tombstones,
--- and counts that are what the keys say. Answers what differs, or nil.
local function differs(f: Facts | nil, m: Model | nil): string | nil
  if f == nil or m == nil then
    if f == nil and m == nil then return nil end
    return f == nil and "dead, but the model is live" or "live, but the model is dead"
  end
  for id, ty in pairs(f.t) do
    if m.t[id] ~= mask_of(ty) then
      return "'" .. id .. "' is " .. tostring(mask_of(ty)) .. ", the model has " .. tostring(m.t[id])
    end
  end
  for id, mask in pairs(m.t) do
    if f.t[id] == nil then return "'" .. id .. "' (" .. tostring(mask) .. ") is missing" end
  end
  for id, w in pairs(f.gone) do
    if m.gone[id] ~= w then return "tombstone of '" .. id .. "' is not the model's" end
  end
  for id in pairs(m.gone) do
    if f.gone[id] == nil then return "tombstone of '" .. id .. "' is missing" end
  end
  if f.paths ~= model_paths(m) then
    return "paths is " .. tostring(f.paths) .. ", the keys say " .. tostring(model_paths(m))
  end
  if f.globals ~= model_globals(m) then
    return "globals is " .. tostring(f.globals) .. ", the keys say " .. tostring(model_globals(m))
  end
  return nil
end

--- Whether two [`Facts`] hold the same keys with the same type objects, the
--- same tombstone objects and the same counts.
local function same_facts(a: Facts | nil, b: Facts | nil): boolean
  if a == nil or b == nil then
    return a == nil and b == nil
  end
  if a.paths ~= b.paths or a.globals ~= b.globals then return false end
  for id, ty in pairs(a.t) do
    if b.t[id] ~= ty then return false end
  end
  for id in pairs(b.t) do
    if a.t[id] == nil then return false end
  end
  for id, w in pairs(a.gone) do
    if b.gone[id] ~= w then return false end
  end
  for id in pairs(b.gone) do
    if a.gone[id] == nil then return false end
  end
  return true
end

--- `m` with `id` set to `mask`, as `with` is defined.
local function model_with(m: Model | nil, id: string, mask: integer): Model | nil
  if m == nil then return nil end
  local out = model_copy(m)
  out.t[id] = mask
  out.gone[id] = nil
  return out
end

--- `m` without the keys `drops` says, each tombstoned with `why`.
local function model_drop(m: Model | nil, drops: function(string): boolean, why: Drop): Model | nil
  if m == nil then return nil end
  local out = model_copy(m)
  for id in pairs(m.t) do
    if drops(id) then
      out.t[id] = nil
      out.gone[id] = why
    end
  end
  return out
end

--- The components of an id, split at its dots: `"1.f"` is `1`, `f`;
--- `""` is one empty component; `"1."` is `1` and an empty one.
local function components(id: string): {string}
  local out: {string} = {}
  local from = 1
  while true do
    local at = id:find(".", from, true)
    if at == nil then
      out[#out + 1] = id:sub(from)
      return out
    end
    out[#out + 1] = id:sub(from, at - 1)
    from = at + 1
  end
end

--- Whether `id` is `base` or a path under it, by components.
local function under(id: string, base: string): boolean
  local have, want = components(id), components(base)
  if #have < #want then return false end
  for i = 1, #want do
    if have[i] ~= want[i] then return false end
  end
  return true
end

--- Whether `id` has the field `name` as a component after its base.
local function has_field(id: string, name: string): boolean
  local have = components(id)
  for i = 2, #have do
    if have[i] == name then return true end
  end
  return false
end

local function is_path(id: string): boolean
  return #components(id) > 1
end

local function is_global(id: string): boolean
  return id:sub(1, 2) == "g:"
end

--- The earlier of two drops, by line.
local function earlier(x: Drop, y: Drop): Drop
  return x.y <= y.y and x or y
end

--- The model of `meet`.
local function model_meet(a: Model | nil, b: Model | nil): Model | nil
  if a == nil then return b end
  if b == nil then return a end
  local out: Model = { t = {}, gone = {} }
  for id, x in pairs(a.t) do
    local y = b.t[id]
    if y ~= nil and x & y ~= 0 then out.t[id] = x & y end
  end
  for _, side in ipairs({ a, b }) do
    for id, w in pairs(side.gone) do
      local have = out.gone[id]
      out.gone[id] = have == nil and w or earlier(have, w)
    end
  end
  return out
end

--- The model of `restrict`.
local function model_restrict(edge: Model | nil, back: Model | nil): Model | nil
  if edge == nil or back == nil then return edge end
  local out = model_copy(edge)
  for id, x in pairs(edge.t) do
    local y = back.t[id]
    if y == nil or y & ~x ~= 0 then
      out.t[id] = nil
      out.gone[id] = back.gone[id]
    end
  end
  return out
end

--- What [`for_body`] keeps: a local that `fixed` approves, by its length and
--- a salt.
local function fixed_by(salt: integer): function(string): boolean
  return function(id: string): boolean
    return (#id + salt) % 3 ~= 0
  end
end

-- A program is a list of steps, each five integers: the operation, two
-- operands, and two arguments. An operand 0 is a dead [`Facts`]; any other
-- counts back from the latest value made (1 the latest, 2 the one before,
-- and the first value, an empty [`Facts`], is the oldest a count reaches).
local KINDS <const>: {string} = {
  "with", "with", "with", "with", "with", "without", "without_prefix", "without_prefix",
  "without_field", "without_paths", "without_globals", "meet", "meet", "restrict", "for_body",
}

local function gen_program(src: Fuzz.Source): string
  local fields: {string} = {}
  while Fuzz.more(src, #fields, 40) do
    local kind = src:int(1, #KINDS)
    local one = src:int(0, 3) == 0 and src:int(0, 6) or 1
    local two = src:int(0, 6)
    fields[#fields + 1] = table.concat({
      kind, one, two, src:int(0, 60), src:int(0, 60),
    }, " ")
  end
  return Fuzz.pack(fields)
end

local record Value
  f: Facts | nil
  m: Model | nil
end

--- The operand `ref` counts back to in `values`.
local function operand(values: {Value}, ref: integer): Value
  if ref == 0 then return {} end
  return values[math.max(1, #values - ref + 1)]
end

--- Raises what differs between every value and its model.
local function check_all(values: {Value}, where: string)
  for i, value in ipairs(values) do
    local why = differs(value.f, value.m)
    if why ~= nil then
      error(where .. ": value " .. tostring(i) .. " differs from its model: " .. why, 0)
    end
  end
end

--- Whether the program is run against the model, and what it reached.
--- Returns the values the program made, the first an empty [`Facts`].
local function run_program(api: Api, input: string, with_model: boolean): {Value}
  local first = api.empty()
  local values: {Value} = { { f = first, m = { t = {}, gone = {} } } }
  local made = { drops = 0 }
  local function drop(): Drop
    made.drops = made.drops + 1
    return { kind = "call", text = "d" .. tostring(made.drops), y = made.drops, x = 0, place = "" }
  end
  for _, field in ipairs(Fuzz.unpack(input)) do
    local n: {integer} = {}
    for digits in field:gmatch("%d+") do
      n[#n + 1] = assert(math.tointeger(tonumber(digits)))
    end
    local kind = KINDS[n[1]]
    local a, b = operand(values, n[2]), operand(values, n[3])
    local id = IDS[n[4] % #IDS + 1]
    local result: Facts | nil
    local model: Model | nil
    local meets = false
    if kind == "with" then
      local mask = n[5] % 7 + 1
      result = api.with(a.f, id, token(mask))
      model = model_with(a.m, id, mask)
      Fuzz.label("with")
    elseif kind == "without" then
      local why = drop()
      result = api.without(a.f, id, why)
      model = model_drop(a.m, function(key: string): boolean return key == id end, why)
      Fuzz.label("without")
    elseif kind == "without_prefix" then
      local why = drop()
      result = api.without_prefix(a.f, id, why)
      model = model_drop(a.m, function(key: string): boolean return under(key, id) end, why)
      Fuzz.label("without_prefix")
    elseif kind == "without_field" then
      local written = FIELDS[n[4] % #FIELDS + 1]
      local why = drop()
      result = api.without_field(a.f, written, why)
      model = model_drop(a.m, function(key: string): boolean return has_field(key, written) end, why)
      Fuzz.label("without_field")
    elseif kind == "without_paths" then
      local why = drop()
      result = api.without_paths(a.f, why)
      model = model_drop(a.m, is_path, why)
      Fuzz.label("without_paths")
    elseif kind == "without_globals" then
      local why = drop()
      result = api.without_globals(a.f, why)
      model = model_drop(a.m, is_global, why)
      Fuzz.label("without_globals")
    elseif kind == "meet" then
      meets = true
      result = api.meet(a.f, b.f, unite)
      model = model_meet(a.m, b.m)
      Fuzz.label("meet")
    elseif kind == "restrict" then
      result = api.restrict(a.f, b.f, is_a)
      model = model_restrict(a.m, b.m)
      Fuzz.label("restrict")
    else
      local why = drop()
      local fixed = fixed_by(n[4])
      result = api.for_body(a.f, fixed, why)
      model = model_drop(a.m, function(key: string): boolean
        return is_path(key) or is_global(key) or not fixed(key)
      end, why)
      Fuzz.label("for_body")
    end
    if with_model then
      local why = differs(result, model)
      if why ~= nil then
        error(kind .. ": the result differs from the model: " .. why, 0)
      end
      -- An operation that changes nothing hands back the object it was given.
      if model_equal(model, a.m) then
        if result ~= a.f then error(kind .. ": changed nothing, but made a new object", 0) end
        Fuzz.label("same object")
      elseif meets and model_equal(model, b.m) then
        if result ~= b.f then
          error(kind .. ": equals its second argument, but made a new object", 0)
        end
        Fuzz.label("same object")
      else
        Fuzz.label("new object")
        if result == a.f or result == b.f then
          error(kind .. ": changed the facts, but handed an argument back", 0)
        end
      end
      if model == nil then Fuzz.label("dead") end
      if model ~= nil then
        local gone = 0
        for _ in pairs(model.gone) do gone = gone + 1 end
        if gone > 0 then Fuzz.label("tombstones") end
        if model_paths(model) > 0 then Fuzz.label("paths") end
        if model_globals(model) > 0 then Fuzz.label("globals") end
      end
    end
    values[#values + 1] = { f = result, m = model }
    -- No operation writes to an argument: every value made so far still
    -- is what it was.
    if with_model then check_all(values, kind) end
  end
  return values
end

local function agrees_with_the_model(input: string): boolean, string
  local api = module()
  api.debug = false
  run_program(api, input, true)
  return true, ""
end

local function test_operations_agree_with_the_model(tmp: string)
  Fuzz.run({
    name = "facts model",
    dir = tmp,
    gen = gen_program,
    check = agrees_with_the_model,
    requires = { "with", "without", "without_prefix", "without_field", "without_paths",
      "without_globals", "meet", "restrict", "for_body", "same object", "new object", "dead",
      "tombstones", "paths", "globals" },
    shares = { ["same object"] = 0.1, ["new object"] = 0.1, tombstones = 0.1, paths = 0.1 },
  })
end

--- Whether a write to `t` at `id` raises.
local function refuses_write(t: {string:any}, id: string): boolean
  local ok = pcall(function() t[id] = token(1) end)
  return not ok
end

--- Runs the program in debug mode, and holds each live value to be
--- read-only throughout.
local function frozen_in_debug(input: string): boolean, string
  local api = module()
  api.debug = true
  local ok, trouble = pcall(function(): string | nil
    local values = run_program(api, input, true)
    for i, value in ipairs(values) do
      local f = value.f
      if f ~= nil then
        Fuzz.label("frozen")
        local t, gone = f.t, f.gone
        if not refuses_write(t, "new key") then
          return "value " .. tostring(i) .. ": a new key was written"
        end
        if not refuses_write(gone, "new key") then
          return "value " .. tostring(i) .. ": a tombstone was written"
        end
        for id in pairs(f.t) do
          if not refuses_write(t, id) then
            return "value " .. tostring(i) .. ": '" .. id .. "' was overwritten"
          end
          if pcall(function() t[id] = nil end) then
            return "value " .. tostring(i) .. ": '" .. id .. "' was removed"
          end
        end
        for id in pairs(f.gone) do
          if not refuses_write(gone, id) then
            return "value " .. tostring(i) .. ": tombstone of '" .. id .. "' was overwritten"
          end
        end
        local counts = pcall(function() f.paths = 99 end)
        if counts then return "value " .. tostring(i) .. ": paths was written" end
        local replaced = pcall(function() f.t = {} end)
        if replaced then return "value " .. tostring(i) .. ": t was replaced" end
      end
    end
    return nil
  end)
  api.debug = false
  if not ok then return false, tostring(trouble) end
  if trouble ~= nil then return false, tostring(trouble) end
  return true, ""
end

local function test_results_are_frozen_in_debug_mode(tmp: string)
  Fuzz.run({
    name = "facts frozen",
    dir = tmp,
    gen = gen_program,
    check = frozen_in_debug,
    requires = { "frozen", "meet", "restrict" },
  })
end

--- A copy of `f` built with the module's own operations: its types, then
--- each tombstone by narrowing the key and dropping it again.
local function rebuilt(api: Api, f: Facts): Facts
  local out: Facts | nil = api.empty()
  for id, ty in pairs(f.t) do out = api.with(out, id, ty) end
  for id, w in pairs(f.gone) do
    out = api.with(out, id, token(1))
    out = api.without(out, id, w)
  end
  return assert(out)
end

local function meet_laws(input: string): boolean, string
  local api = module()
  api.debug = false
  local values = run_program(api, input, false)
  local a, b, c = operand(values, 1).f, operand(values, 2).f, operand(values, 3).f
  local ab, ba = api.meet(a, b, unite), api.meet(b, a, unite)
  if not same_facts(ab, ba) then return false, "meet is not commutative" end
  local left = api.meet(api.meet(a, b, unite), c, unite)
  local right = api.meet(a, api.meet(b, c, unite), unite)
  if not same_facts(left, right) then return false, "meet is not associative" end
  if api.meet(a, a, unite) ~= a then return false, "meet(a, a) is not a" end
  if api.meet(a, nil, unite) ~= a or api.meet(nil, a, unite) ~= a then
    return false, "a dead edge is not the identity"
  end
  if api.meet(nil, nil, unite) ~= nil then return false, "two dead edges are not dead" end
  if a ~= nil then
    local twin = rebuilt(api, a)
    if not same_facts(a, twin) then return false, "the rebuilt copy differs" end
    if api.meet(a, twin, unite) ~= a then return false, "meet of equal facts is not the first" end
    if api.meet(twin, a, unite) ~= twin then
      return false, "meet of equal facts is not the first (reversed)"
    end
    Fuzz.label("copied")
  end
  -- The result keeps only what both hold.
  if ab ~= nil and a ~= nil and b ~= nil then
    for id in pairs(ab.t) do
      if a.t[id] == nil or b.t[id] == nil then
        return false, "meet holds '" .. id .. "' that one edge lacks"
      end
    end
    local kept, held_by_a = 0, 0
    for _ in pairs(ab.t) do kept = kept + 1 end
    for _ in pairs(a.t) do held_by_a = held_by_a + 1 end
    if kept > 0 then Fuzz.label("kept something") end
    if kept < held_by_a then Fuzz.label("dropped something") end
  end
  -- Two edges that disagree on one key give a result that is neither.
  if a ~= nil then
    local x, y = api.with(a, "1", token(3)), api.with(a, "1", token(5))
    local both = assert(api.meet(x, y, unite))
    if both == x or both == y then return false, "meet of unlike edges is one of them" end
    if both.t["1"] ~= token(1) then return false, "'1' is not the intersection" end
    Fuzz.label("new object")
  end
  if ab == nil then Fuzz.label("dead") end
  return true, ""
end

local function test_meet_laws(tmp: string)
  Fuzz.run({
    name = "facts meet",
    dir = tmp,
    gen = gen_program,
    check = meet_laws,
    requires = { "copied", "kept something", "dropped something", "new object", "dead" },
    shares = { ["kept something"] = 0.1, ["dropped something"] = 0.1, copied = 0.1, ["new object"] = 0.1 },
  })
end

--- A set of keys, and the drop that removes some: the keys are drawn from
--- `IDS`, then one of a prefix and a field.
local function gen_removal(src: Fuzz.Source): string
  local keys: {string} = {}
  while Fuzz.more(src, #keys, 12) do
    keys[#keys + 1] = tostring(src:int(1, #IDS))
  end
  local by_prefix = src:int(0, 1) == 0
  local target = by_prefix and IDS[src:int(1, #IDS)] or FIELDS[src:int(1, #FIELDS)]
  return Fuzz.pack({ by_prefix and "prefix" or "field", target, table.concat(keys, " ") })
end

local function removes_the_right_keys(input: string): boolean, string
  local api = module()
  api.debug = false
  local parts = Fuzz.unpack(input)
  local by_prefix, target = parts[1] == "prefix", parts[2]
  local f: Facts | nil = api.empty()
  local held: {string:boolean} = {}
  for digits in parts[3]:gmatch("%d+") do
    local id = IDS[assert(math.tointeger(tonumber(digits)))]
    f = api.with(f, id, token(3))
    held[id] = true
  end
  local why: Drop = { kind = "write", text = "w", y = 1, x = 1, place = "" }
  local after = by_prefix and api.without_prefix(f, target, why) or api.without_field(f, target, why)
  local result = assert(after)
  local expected = 0
  for id in pairs(held) do
    local removed = by_prefix and under(id, target) or (not by_prefix and has_field(id, target))
    if removed then
      if result.t[id] ~= nil then return false, "'" .. id .. "' stayed" end
      if result.gone[id] ~= why then return false, "'" .. id .. "' has no tombstone" end
      Fuzz.label("removed")
    else
      expected = expected + 1
      if result.t[id] == nil then return false, "'" .. id .. "' was removed" end
      if result.gone[id] ~= nil then return false, "'" .. id .. "' has a tombstone but stayed" end
      Fuzz.label("kept")
    end
  end
  local kept = 0
  for _ in pairs(result.t) do kept = kept + 1 end
  if kept ~= expected then
    return false, "holds " .. tostring(kept) .. " keys, not " .. tostring(expected)
  end
  local paths, globals = 0, 0
  for id in pairs(result.t) do
    if is_path(id) then paths = paths + 1 end
    if is_global(id) then globals = globals + 1 end
  end
  if result.paths ~= paths or result.globals ~= globals then
    return false, "the counts are not the keys'"
  end
  if by_prefix and not (f ~= nil and f.t[target] ~= nil) and kept == 0 then
    Fuzz.label("emptied")
  end
  return true, ""
end

local function test_prefix_and_field_remove_exactly_the_right_keys(tmp: string)
  Fuzz.run({
    name = "facts removal",
    dir = tmp,
    gen = gen_removal,
    check = removes_the_right_keys,
    requires = { "removed", "kept" },
    shares = { removed = 0.1, kept = 0.1 },
  })
end

--- A fresh [`Facts`] holding each of `ids`, all of the widest type.
local function held(api: Api, ids: {string}): Facts | nil
  local f: Facts | nil = api.empty()
  for _, id in ipairs(ids) do f = api.with(f, id, token(7)) end
  return f
end

--- The keys of `f`, sorted.
local function sorted_keys(f: Facts | nil): string
  local keys: {string} = {}
  if f ~= nil then
    for id in pairs(f.t) do keys[#keys + 1] = id end
  end
  table.sort(keys)
  return table.concat(keys, ",")
end

local WHY <const>: Drop = { kind = "call", text = "f()", y = 3, x = 4, place = "" }

local function test_the_empty_key_is_a_local_not_a_path()
  local api = module()
  local f = held(api, { "", ".f", "g:" })
  assert(f ~= nil and f.paths == 1, "only '.f' is a path")
  assert(f.globals == 1, "'g:' is a global")
  local gone = api.without_paths(f, WHY)
  assert(sorted_keys(gone) == ",g:", "a call keeps the empty key and the global")
  local prefix = api.without_prefix(f, "", WHY)
  assert(sorted_keys(prefix) == "g:", "the empty id is the base of '' and '.f'")
  assert(api.dropped(prefix, "") == WHY)
end

local function test_ids_with_several_dots()
  local api = module()
  local f = held(api, { "a.b.c.d", "a.b.c", "a.b", "a.bc", "a", "a.b.cd" })
  assert(f ~= nil and f.paths == 5)
  assert(sorted_keys(api.without_prefix(f, "a.b", WHY)) == "a,a.bc", "a.b and everything under it")
  assert(sorted_keys(api.without_prefix(f, "a.b.c", WHY)) == "a,a.b,a.b.cd,a.bc")
  assert(sorted_keys(api.without_field(f, "d", WHY)) == "a,a.b,a.b.c,a.b.cd,a.bc")
  assert(sorted_keys(api.without_field(f, "c", WHY)) == "a,a.b,a.b.cd,a.bc")
  assert(sorted_keys(api.without_field(f, "b", WHY)) == "a,a.bc")
end

local function test_a_shorter_id_is_not_a_prefix_without_a_dot()
  local api = module()
  -- No paths held: the quick answer is the one key.
  local plain = held(api, { "1", "10", "11" })
  assert(sorted_keys(api.without_prefix(plain, "1", WHY)) == "10,11")
  assert(api.dropped(api.without_prefix(plain, "1", WHY), "10") == nil)
  -- Paths held: the scan.
  local nested = held(api, { "1", "10", "1.f", "10.f", "11.f", "1.g.h" })
  local result = api.without_prefix(nested, "1", WHY)
  assert(sorted_keys(result) == "10,10.f,11.f", sorted_keys(result))
  assert(result ~= nil and result.paths == 2 and result.globals == 0)
  assert(api.without_prefix(nested, "12", WHY) == nested, "no key of '12' is held")
  assert(sorted_keys(api.without_prefix(nested, "10", WHY)) == "1,1.f,1.g.h,11.f")
end

local function test_dead_stays_dead_and_unchanged_is_shared()
  local api = module()
  assert(api.with(nil, "1", token(1)) == nil)
  assert(api.without(nil, "1", WHY) == nil)
  assert(api.without_prefix(nil, "1", WHY) == nil)
  assert(api.without_field(nil, "f", WHY) == nil)
  assert(api.without_paths(nil, WHY) == nil)
  assert(api.without_globals(nil, WHY) == nil)
  assert(api.for_body(nil, fixed_by(0), WHY) == nil)
  assert(api.restrict(nil, api.empty(), is_a) == nil)
  local f = held(api, { "1", "2.f" })
  assert(api.without(f, "3", WHY) == f)
  assert(api.without_globals(f, WHY) == f)
  assert(api.with(f, "1", token(7)) == f)
  assert(api.restrict(f, nil, is_a) == f, "a back edge that never arrives supports every fact")
  assert(api.for_body(held(api, {}), fixed_by(1), WHY) ~= nil)
end

local function test_a_tombstone_lasts_until_the_place_is_narrowed_again()
  local api = module()
  local f = api.without(held(api, { "1" }), "1", WHY)
  assert(api.get(f, "1") == nil and api.dropped(f, "1") == WHY)
  local again = api.with(f, "1", token(3))
  assert(api.get(again, "1") == token(3) and api.dropped(again, "1") == nil)
  assert(api.dropped(f, "1") == WHY, "the earlier value is as it was")
end

--- A place that held no fact takes a tombstone (a test that narrowed nothing),
--- which holds until it is narrowed; a place that holds a fact takes none.
local function test_a_place_with_no_fact_takes_a_tombstone()
  local api = module()
  local f = held(api, { "1" })
  assert(not api.has_gone(f) and not api.has_gone(nil))
  assert(api.note(f, "1", WHY) == f, "a place that holds a fact has nothing gone")
  local noted = api.note(f, "2", WHY)
  assert(noted ~= f and api.has_gone(noted) and api.dropped(noted, "2") == WHY)
  assert(api.get(noted, "1") == token(7) and api.get(noted, "2") == nil)
  assert(api.note(noted, "2", WHY) == noted, "the same tombstone again is the same facts")
  local other: Drop = { kind = "write", text = "r.n = ...", y = 5, x = 1, place = "" }
  assert(api.dropped(api.note(noted, "2", other), "2") == other, "a later drop replaces it")
  assert(api.dropped(noted, "2") == WHY, "the earlier value is as it was")
  assert(api.dropped(api.with(noted, "2", token(3)), "2") == nil, "narrowing the place takes it away")
  assert(api.note(nil, "2", WHY) == nil, "a dead point stays dead")
end

local function test_unite_nil_drops_a_key_without_a_tombstone()
  local api = module()
  local a = api.with(api.with(api.empty(), "1", token(1)), "2", token(3))
  local b = api.with(api.with(api.empty(), "1", token(2)), "2", token(3))
  local both = api.meet(a, b, unite)
  assert(both ~= nil and sorted_keys(both) == "2" and api.dropped(both, "1") == nil and api.dropped(both, "2") == nil)
  assert(api.get(both, "2") == token(3))
end

local function test_the_earlier_tombstone_of_a_key_is_kept()
  local api = module()
  local late: Drop = { kind = "call", text = "late", y = 9, x = 1, place = "" }
  local soon: Drop = { kind = "call", text = "soon", y = 2, x = 7, place = "" }
  local base = held(api, { "1" })
  local a = api.without(base, "1", late)
  local b = api.without(base, "1", soon)
  assert(api.dropped(api.meet(a, b, unite), "1") == soon)
  assert(api.dropped(api.meet(b, a, unite), "1") == soon)
end

local function test_a_write_to_a_field_drops_every_path_through_it()
  local api = module()
  local f = held(api, { "17", "17.f", "17.f.g", "17.g.f", "17.ff", "17.g", "f", "18.f" })
  local result = api.without_field(f, "f", WHY)
  assert(sorted_keys(result) == "17,17.ff,17.g,f", sorted_keys(result))
  assert(api.dropped(result, "17.f.g") == WHY and api.dropped(result, "17.g.f") == WHY)
  assert(api.dropped(result, "17.f") == WHY and api.dropped(result, "17.ff") == nil)
  assert(api.has(result, "17.ff") and not api.has(result, "17.f"))
  assert(api.is_empty(api.empty()) and not api.is_empty(result) and not api.is_empty(nil))
end

--- The order in which the earlier of two tombstones is chosen: by line,
--- then column, kind, text and place, whichever edge is asked first.
local function test_the_earlier_tombstone_follows_the_full_order()
  local api = module()
  local base = held(api, { "1" })
  local function drop(y: integer, x: integer, kind: string, text: string, place: string): Drop
    return { kind = kind, text = text, y = y, x = x, place = place }
  end
  local ordered: {Drop} = {
    drop(1, 9, "z", "z", "z"), drop(2, 1, "z", "z", "z"), drop(2, 2, "a", "z", "z"),
    drop(2, 2, "b", "a", "z"), drop(2, 2, "b", "b", "a"), drop(2, 2, "b", "b", "b"),
  }
  for i = 1, #ordered do
    for j = i + 1, #ordered do
      local a, b = api.without(base, "1", ordered[i]), api.without(base, "1", ordered[j])
      assert(api.dropped(api.meet(a, b, unite), "1") == ordered[i], "forward " .. i .. "," .. j)
      assert(api.dropped(api.meet(b, a, unite), "1") == ordered[i], "reversed " .. i .. "," .. j)
    end
  end
end

local function test_identity_shortcuts()
  local api = module()
  local f = assert(api.without(held(api, { "1", "2" }), "2", WHY))
  assert(api.restrict(f, f, is_a) == f)
  local twin = { t = f.t, gone = f.gone, paths = f.paths, globals = f.globals } as Facts
  assert(api.meet(f, twin, unite) == f, "the same tables are the same facts")
end

local function test_a_bad_field_name_raises()
  local api = module()
  local ok = pcall(api.without_field, held(api, { "1.f" }), "f.g", WHY)
  assert(not ok, "a field name with a dot")
  local none = pcall(api.with, api.empty(), "1", nil as Type)
  assert(not none, "a fact needs a type")
end

local function test_debug_mode_checks_what_a_value_holds()
  local api = module()
  api.debug = true
  local ok, trouble = pcall(function()
    local f = held(api, { "1", "1.f", "g:x" })
    assert(f ~= nil)
    local wrote = pcall(function() f.t["2"] = token(1) end)
    assert(not wrote, "a new key")
    local overwrote = pcall(function() f.t["1"] = token(1) end)
    assert(not overwrote, "an existing key")
    assert(f.paths == 1 and f.globals == 1)
    assert(api.with(f, "1", token(7)) == f, "sharing still holds")
  end)
  api.debug = false
  assert(ok, tostring(trouble))
end
