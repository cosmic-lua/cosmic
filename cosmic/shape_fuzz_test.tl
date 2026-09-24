--- Fuzz properties for `cosmic.shape`: `into` is total on any value a
--- decoder could hand it, and what it answers is already its own shape.
--- A spec and a value are both built from one recipe of draws; the value
--- mostly follows the spec and sometimes strays from it, so both the
--- walk that succeeds and every way it can fail are reached.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Shape = require("cosmic.shape")

--- The stand-in for null the value may hold, as `Json.null` would be.
local NULL <const> = setmetatable({}, { __name = "null" })

--- Reads a recipe a byte at a time; past its end every byte is 0.
local record Recipe
  bytes: string
  at: integer
end

local function byte(r: Recipe, n: integer): integer
  r.at = r.at + 1
  local b = r.bytes:byte(r.at) or 0
  return b % n
end

local KEYS <const> = { "a", "b", "id", "a key", "", "é", "\n", "1" }

local function key(r: Recipe): string
  return KEYS[byte(r, #KEYS) + 1]
end

local gen_spec: function(r: Recipe, depth: integer): Shape.Spec

gen_spec = function(r: Recipe, depth: integer): Shape.Spec
  local pick = byte(r, depth > 0 and 11 or 6)
  local spec: Shape.Spec
  if pick == 0 then spec = Shape.string
  elseif pick == 1 then spec = Shape.number
  elseif pick == 2 then spec = Shape.integer
  elseif pick == 3 then spec = Shape.boolean
  elseif pick == 4 then spec = Shape.any
  elseif pick == 5 then spec = Shape.one_of("a", 1, true)
  elseif pick == 6 then spec = Shape.list(gen_spec(r, depth - 1))
  elseif pick == 7 then spec = Shape.map(gen_spec(r, depth - 1))
  elseif pick == 8 then
    local fields: {string: Shape.Spec} = {}
    for _ = 1, byte(r, 4) do fields[key(r)] = gen_spec(r, depth - 1) end
    spec = Shape.record(fields)
  else
    spec = Shape.either(gen_spec(r, depth - 1), gen_spec(r, depth - 1))
  end
  if byte(r, 4) == 0 then spec = Shape.optional(spec) end
  return spec
end

local STRAYS <const>: {any} = {
  "x", "\xff\xfe", 0, -1, math.mininteger, 1.5, 2.0, -0.0, 2.0 ^ 63, 1 / 0, 0 / 0,
  true, false, NULL, print,
}

local gen_value: function(r: Recipe, spec: Shape.Spec, depth: integer): any

--- A value for `spec`, or, one time in eight, whatever else.
gen_value = function(r: Recipe, spec: Shape.Spec, depth: integer): any
  if byte(r, 8) == 0 or depth == 0 then
    local pick = byte(r, #STRAYS + 3)
    if pick < #STRAYS then return STRAYS[pick + 1] end
    if pick == #STRAYS then return nil end
    local t: {any: any} = {}
    for _ = 1, byte(r, 3) do
      local k: any = byte(r, 2) == 0 and key(r) or byte(r, 4)
      t[k] = gen_value(r, Shape.any, depth - 1)
    end
    return t
  end
  local kind = spec.kind
  if kind == "string" then return key(r)
  elseif kind == "number" then return byte(r, 2) == 0 and byte(r, 100) or byte(r, 100) / 8
  elseif kind == "integer" then return byte(r, 2) == 0 and byte(r, 100) or byte(r, 100) * 1.0
  elseif kind == "boolean" then return byte(r, 2) == 0
  elseif kind == "one_of" then return spec.values[byte(r, #spec.values) + 1]
  elseif kind == "either" then
    return gen_value(r, spec.choices[byte(r, #spec.choices) + 1], depth)
  elseif kind == "list" then
    local t: {any: any} = {}
    for i = 1, byte(r, 4) do t[i] = gen_value(r, spec.of, depth - 1) end
    if byte(r, 4) == 0 then setmetatable(t, { __name = "array" }) end
    return t
  elseif kind == "map" then
    local t: {string: any} = {}
    for _ = 1, byte(r, 4) do t[key(r)] = gen_value(r, spec.of, depth - 1) end
    return t
  elseif kind == "record" then
    local t: {string: any} = {}
    for _, name in ipairs(spec.names) do
      if byte(r, 6) ~= 0 then t[name] = gen_value(r, spec.fields[name], depth - 1) end
    end
    if byte(r, 4) == 0 then t[key(r)] = "extra" end
    return t
  end
  return STRAYS[byte(r, #STRAYS) + 1]
end

local same: function(a: any, b: any): boolean

--- Whether `a` and `b` hold the same values, NaN matching NaN.
same = function(a: any, b: any): boolean
  if a is number and b is number then
    return a == b and math.type(a) == math.type(b) or (a ~= a and b ~= b)
  end
  if not (a is table) or not (b is table) or rawequal(a, NULL) then
    return rawequal(a, b)
  end
  local ta, tb = a as {any: any}, b as {any: any}
  for k, v in next, ta do
    if not same(v, rawget(tb, k)) then return false end
  end
  for k in next, tb do
    if rawget(ta, k) == nil then return false end
  end
  return true
end

local fits: function(v: any, spec: Shape.Spec, null: any): boolean

--- Whether an answer strictly is `spec`: the oracle, written apart from
--- the walk. An answer is never the stand-in for null, holds integers
--- where the spec says integer, and no key a record does not name.
fits = function(v: any, spec: Shape.Spec, null: any): boolean
  if v == nil then return spec.optional end
  if null ~= nil and rawequal(v, null) then return false end
  local kind = spec.kind
  if kind == "string" then return v is string
  elseif kind == "number" then return v is number
  elseif kind == "integer" then return math.type(v) == "integer"
  elseif kind == "boolean" then return v is boolean
  elseif kind == "any" then return true
  elseif kind == "one_of" then
    for _, want in ipairs(spec.values) do
      if v == want then return true end
    end
    return false
  elseif kind == "either" then
    for _, c in ipairs(spec.choices) do
      if fits(v, c, null) then return true end
    end
    return false
  end
  if not (v is table) then return false end
  local t = v as {any: any}
  if kind == "list" then
    local n = 0
    for k, e in next, t do
      if not (k is integer) or k < 1 or not fits(e, spec.of, null) then return false end
      if k > n then n = k end
    end
    for i = 1, n do
      if rawget(t, i) == nil and not spec.of.optional then return false end
    end
    return true
  elseif kind == "map" then
    for k, e in next, t do
      if not (k is string) or not fits(e, spec.of, null) then return false end
    end
    return true
  end
  for k in next, t do
    if not (k is string) or spec.fields[k] == nil then return false end
  end
  for _, name in ipairs(spec.names) do
    if not fits(rawget(t, name), spec.fields[name], null) then return false end
  end
  return true
end

local function check(input: string): boolean, string
  local r: Recipe = { bytes = input, at = 0 }
  local spec = gen_spec(r, 3)
  local value = gen_value(r, spec, 4)
  local opts: Shape.Options = byte(r, 2) == 0 and { null = NULL } or nil
  local out, err: any, string = Shape.into(value, spec, opts)
  if err ~= "" then
    if out ~= nil then return false, "a failure answered a value" end
    if err:sub(1, 1) ~= "$" then return false, "a failure without a path: " .. err end
    return true, ""
  end
  if not fits(out, spec, opts and opts.null) then return false, "the answer is not its shape" end
  local again, err2: any, string = Shape.into(out, spec, opts)
  if err2 ~= "" then return false, "the answer does not fit its own shape: " .. err2 end
  if not same(out, again) then return false, "the answer changed on a second walk" end
  return true, ""
end

local function test_into_is_total_and_its_answer_fits_its_shape(tmp: string)
  Fuzz.run({
    name = "shape into total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 200) end,
    check = check,
  })
end
