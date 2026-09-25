--- Fuzz properties for `cosmic.shape`: `into` is total on any value a
--- decoder could hand it, and what it answers is already its own shape.
--- A spec and a value are both built from one recipe of draws; the value
--- mostly follows the spec and sometimes strays from it, so both the
--- walk that succeeds and every way it can fail are reached.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

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
    spec = byte(r, 2) == 0 and Shape.strict_record(fields) or Shape.record(fields)
  else
    spec = Shape.either(gen_spec(r, depth - 1), gen_spec(r, depth - 1))
  end
  if byte(r, 4) == 0 then spec = Shape.optional(spec) end
  return spec
end

local STRAYS <const>: {any} = {
  "x", "\xff\xfe", 0, -1, math.mininteger, 1.5, 2.0, -0.0, 2.0 ^ 63, 1 / 0, 0 / 0,
  true, false, Json.null, print,
}

local gen_value: function(r: Recipe, spec: Shape.Spec, depth: integer, strict: boolean): any

--- A value for `spec`. Unless `strict`, one time in eight it is whatever
--- else, and a record's required field may be missing. A strict value
--- fits its spec and holds only what JSON can carry.
gen_value = function(r: Recipe, spec: Shape.Spec, depth: integer, strict: boolean): any
  if not strict and (byte(r, 8) == 0 or depth == 0) then
    local pick = byte(r, #STRAYS + 3)
    if pick < #STRAYS then return STRAYS[pick + 1] end
    if pick == #STRAYS then return nil end
    local t: {any: any} = {}
    for _ = 1, byte(r, 3) do
      local k: any = byte(r, 2) == 0 and key(r) or byte(r, 4)
      t[k] = gen_value(r, Shape.any, depth - 1, false)
    end
    if byte(r, 4) == 0 and next(t) == nil then Json.array(t as {any}) end
    return t
  end
  local kind = spec.kind
  if kind == "string" or kind == "any" then return key(r)
  elseif kind == "number" then return byte(r, 2) == 0 and byte(r, 100) or byte(r, 100) / 8
  elseif kind == "integer" then return byte(r, 2) == 0 and byte(r, 100) or byte(r, 100) * 1.0
  elseif kind == "boolean" then return byte(r, 2) == 0
  elseif kind == "one_of" then return spec.values[byte(r, #spec.values) + 1]
  elseif kind == "either" then
    return gen_value(r, spec.choices[byte(r, #spec.choices) + 1], depth, strict)
  elseif kind == "list" then
    local t: {any} = {}
    for i = 1, byte(r, 4) do t[i] = gen_value(r, spec.of, depth - 1, strict) end
    if byte(r, 4) ~= 0 then Json.array(t) end
    return t
  elseif kind == "map" then
    local t: {string: any} = {}
    for _ = 1, byte(r, 4) do t[key(r)] = gen_value(r, spec.of, depth - 1, strict) end
    return t
  elseif kind == "record" then
    local t: {string: any} = {}
    for _, name in ipairs(spec.names) do
      local field = spec.fields[name]
      local pick = byte(r, 6)
      if pick == 0 and (field.optional or not strict) then
        -- left out
      elseif pick == 1 and field.optional then
        t[name] = Json.null
      else
        t[name] = gen_value(r, field, depth - 1, strict)
      end
    end
    -- A strict value for a strict record has no key the record lacks.
    if byte(r, 4) == 0 and not (strict and spec.strict) then
      local extra = key(r)
      if spec.fields[extra] == nil then t[extra] = "extra" end
    end
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
  if not (a is table) or not (b is table) then
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

local fits: function(v: any, spec: Shape.Spec): boolean

--- Whether an answer strictly is `spec`: the oracle, written apart from
--- the walk. An answer is never `Json.null` outside an `any`, holds
--- integers where the spec says integer, a JSON array for a list, and no
--- key a record does not name.
fits = function(v: any, spec: Shape.Spec): boolean
  if v == nil then return spec.optional end
  if rawequal(v, Json.null) then return false end
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
      if fits(v, c) then return true end
    end
    return false
  end
  if not (v is table) then return false end
  local t = v as {any: any}
  if kind == "list" then
    if not Json.is_array(t) then return false end
    local n = 0
    for k, e in next, t do
      if not (k is integer) or k < 1 or not fits(e, spec.of) then return false end
      if k > n then n = k end
    end
    for i = 1, n do
      if rawget(t, i) == nil and not spec.of.optional then return false end
    end
    return true
  end
  if Json.is_array(t) then return false end
  if kind == "map" then
    for k, e in next, t do
      if not (k is string) or not fits(e, spec.of) then return false end
    end
    return true
  end
  for k in next, t do
    if not (k is string) or spec.fields[k] == nil then return false end
  end
  for _, name in ipairs(spec.names) do
    if not fits(rawget(t, name), spec.fields[name]) then return false end
  end
  return true
end

local function check_total(input: string): boolean, string
  local r: Recipe = { bytes = input, at = 0 }
  local spec = gen_spec(r, 3)
  local value = gen_value(r, spec, 4, false)
  local out, err: any, string = Shape.into(value, spec)
  if err ~= "" then
    if out ~= nil then return false, "a failure answered a value" end
    if err:sub(1, 1) ~= "$" then return false, "a failure without a path: " .. err end
    return true, ""
  end
  if not fits(out, spec) then return false, "the answer is not its shape" end
  local again, err2: any, string = Shape.into(out, spec)
  if err2 ~= "" then return false, "the answer does not fit its own shape: " .. err2 end
  if not same(out, again) then return false, "the answer changed on a second walk" end
  return true, ""
end

--- A value that fits, encoded and decoded, with nulls kept or not:
--- the decoded value still fits, its answer is its shape, and the answer
--- re-encodes and reads back as itself.
local function check_json(input: string): boolean, string
  local r: Recipe = { bytes = input, at = 0 }
  local spec = gen_spec(r, 3)
  local value = gen_value(r, spec, 4, true)
  local text, eerr = Json.encode(value)
  if text == nil then return false, "a strict value did not encode: " .. eerr end
  local opts: Json.DecodeOptions = {}
  if byte(r, 2) == 0 then opts.null_value = Json.null end
  local decoded, derr = Json.decode(text, opts)
  if derr ~= "" then return false, "its text did not decode: " .. derr end
  local out, err: any, string = Shape.into(decoded, spec)
  if err ~= "" then return false, ("%s no longer fits: %s"):format(text, err) end
  if not fits(out, spec) then return false, text .. ": the answer is not its shape" end
  local again_text, aerr = Json.encode(out, { sparse_as_null = true })
  if again_text == nil then return false, text .. ": the answer did not encode: " .. aerr end
  local again, err2: any, string = Shape.into(Json.decode(again_text), spec)
  if err2 ~= "" then return false, again_text .. " does not fit: " .. err2 end
  if not same(out, again) then return false, again_text .. " read back as another answer" end
  return true, ""
end

--- A strict record given a value that fits it but for one key it does
--- not name -- a string or an integer, whatever its value, `Json.null`
--- included -- refuses it, and names that key.
local function check_strict(input: string): boolean, string
  local r: Recipe = { bytes = input, at = 0 }
  local fields: {string: Shape.Spec} = {}
  for _ = 1, byte(r, 4) do fields[key(r)] = gen_spec(r, 2) end
  local spec = Shape.strict_record(fields)
  if byte(r, 2) == 0 then spec = Shape.optional(spec) end
  local value = gen_value(r, spec, 4, true) as {any: any}
  local extra: any
  local want: string
  if byte(r, 2) == 0 then
    extra = byte(r, 4) - 1
    want = ("$: expected record, got the integer key %d"):format(extra as integer)
  else
    local k = key(r)
    if fields[k] ~= nil then k = "not a field" end
    extra = k
  end
  value[extra] = STRAYS[byte(r, #STRAYS) + 1]
  local out, err: any, string = Shape.into(value, spec)
  if err == "" or out ~= nil then return false, "a strict record admitted an unknown key" end
  if want ~= nil then
    if err ~= want then return false, ("wanted %q, got %q"):format(want, err) end
  elseif err:sub(-13) ~= ": unknown key" or err:find("^%$[.[]") == nil then
    return false, "an unknown key reported as " .. err
  end
  return true, ""
end

local function test_into_is_total_and_its_answer_fits_its_shape(tmp: string)
  Fuzz.run({
    name = "shape into total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 200) end,
    check = check_total,
  })
end

local function test_a_fitting_value_survives_json(tmp: string)
  Fuzz.run({
    name = "shape through json",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 200) end,
    check = check_json,
  })
end

local function test_a_strict_record_refuses_an_unknown_key(tmp: string)
  Fuzz.run({
    name = "shape strict record",
    dir = tmp,
    gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 200) end,
    check = check_strict,
  })
end
