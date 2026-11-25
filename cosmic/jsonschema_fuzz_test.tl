--- Fuzz properties for [`cosmic.jsonschema`], which reads schemas and
--- values from anyone: an MCP client compiles the `inputSchema` a server
--- sends, and a server checks the arguments a client sends. Drawn schemas
--- of the keywords it asserts, and drawn values, show that
--- [`JsonSchema.compile`] and a schema's `check` return and never raise,
--- and that the combinators mean what they say: `not` turns a result
--- over, and `allOf` with `true`, `anyOf` or `oneOf` with `false`, and
--- `if` it `then` `true` `else` `false` change none.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Array = require("cosmic.array")
local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local JsonSchema = require("cosmic.jsonschema")
local String = require("cosmic.string")

local TYPES <const> = { "null", "boolean", "integer", "number", "string", "array", "object" }
local NAMES <const> = { "a", "b", "n", "" }
local NUMBERS <const> = { "0", "1", "-1", "2", "0.5", "3", "1e3", "-0", "7" }
local STRINGS <const> = { '""', '"a"', '"ab"', '"b"', '"\\u00e9"' }

--- A JSON value's text, at most `depth` levels deep.
local function value(src: Fuzz.Source, depth: integer): string
  local kind = src:int(0, if depth > 0 then 6 else 4 end)
  if kind == 0 then return "null" end
  if kind == 1 then return Fuzz.pick(src, { "true", "false" }) end
  if kind == 2 then return Fuzz.pick(src, NUMBERS) end
  if kind == 3 then return Fuzz.pick(src, STRINGS) end
  if kind == 4 then return tostring(src:int(-3, 12)) end
  local items: mut {string} = {}
  if kind == 5 then
    while Fuzz.more(src, #items, 4) do items[#items + 1] = value(src, depth - 1) end
    return "[" .. table.concat(items, ",") .. "]"
  end
  while Fuzz.more(src, #items, 4) do
    -- Each member's name is the next of NAMES, so none is there twice.
    local member = ('"%s":%s'):format(Array.at(NAMES, #items + 1), value(src, depth - 1))
    items[#items + 1] = member
  end
  return "{" .. table.concat(items, ",") .. "}"
end

--- The drawers of a schema, which call each other.
local record Draw
end

--- A list of schemas, one at least.
function Draw.schemas(src: Fuzz.Source, depth: integer): string
  local items: mut {string} = { Draw.schema(src, depth) }
  while Fuzz.more(src, #items, 3) do items[#items + 1] = Draw.schema(src, depth) end
  return "[" .. table.concat(items, ",") .. "]"
end

local function count(src: Fuzz.Source): string
  return tostring(src:int(0, 4))
end

--- One keyword of a schema and its value, as `"key":value` text.
function Draw.keyword(src: Fuzz.Source, depth: integer): string
  local k = src:int(1, if depth > 0 then 30 else 18 end)
  if k == 1 then return '"type":"' .. Fuzz.pick(src, TYPES) .. '"' end
  if k == 2 then
    return '"type":["' .. Fuzz.pick(src, TYPES) .. '","' .. Fuzz.pick(src, TYPES) .. '"]'
  end
  if k == 3 then return '"enum":[' .. value(src, 1) .. "," .. value(src, 1) .. "]" end
  if k == 4 then return '"const":' .. value(src, 2) end
  if k == 5 then return '"minimum":' .. Fuzz.pick(src, NUMBERS) end
  if k == 6 then return '"maximum":' .. Fuzz.pick(src, NUMBERS) end
  if k == 7 then return '"exclusiveMinimum":' .. Fuzz.pick(src, NUMBERS) end
  if k == 8 then return '"exclusiveMaximum":' .. Fuzz.pick(src, NUMBERS) end
  if k == 9 then return '"multipleOf":' .. Fuzz.pick(src, { "1", "2", "0.5", "3", "0.1" }) end
  if k == 10 then return '"minLength":' .. count(src) end
  if k == 11 then return '"maxLength":' .. count(src) end
  if k == 12 then return '"minItems":' .. count(src) end
  if k == 13 then return '"maxItems":' .. count(src) end
  if k == 14 then return '"uniqueItems":' .. Fuzz.pick(src, { "true", "false" }) end
  if k == 15 then return '"minProperties":' .. count(src) end
  if k == 16 then return '"maxProperties":' .. count(src) end
  if k == 17 then return '"required":["' .. Fuzz.pick(src, NAMES) .. '"]' end
  if k == 18 then return '"dependentRequired":{"a":["' .. Fuzz.pick(src, NAMES) .. '"]}' end
  if k == 19 then
    return '"properties":{"' .. Fuzz.pick(src, NAMES) .. '":' .. Draw.schema(src, depth - 1) .. "}"
  end
  if k == 20 then return '"additionalProperties":' .. Draw.schema(src, depth - 1) end
  if k == 21 then return '"propertyNames":' .. Draw.schema(src, depth - 1) end
  if k == 22 then return '"items":' .. Draw.schema(src, depth - 1) end
  if k == 23 then return '"prefixItems":' .. Draw.schemas(src, depth - 1) end
  if k == 24 then
    local bound = Fuzz.pick(src, { "minContains", "maxContains" })
    return '"contains":' .. Draw.schema(src, depth - 1) .. ',"' .. bound .. '":' .. count(src)
  end
  if k == 25 then return '"allOf":' .. Draw.schemas(src, depth - 1) end
  if k == 26 then return '"anyOf":' .. Draw.schemas(src, depth - 1) end
  if k == 27 then return '"oneOf":' .. Draw.schemas(src, depth - 1) end
  if k == 28 then return '"not":' .. Draw.schema(src, depth - 1) end
  if k == 29 then
    return '"if":' .. Draw.schema(src, depth - 1) .. ',"then":' .. Draw.schema(src, depth - 1) ..
      ',"else":' .. Draw.schema(src, depth - 1)
  end
  -- A `$ref` to the root would move with the forms built around a
  -- schema, so the one a drawn schema makes is to a definition the
  -- check gives every form.
  return '"$ref":"#/$defs/d"'
end

function Draw.schema(src: Fuzz.Source, depth: integer): string
  local pick = src:int(0, 9)
  if pick == 0 then return "true" end
  if pick == 1 then return "false" end
  local parts: mut {string} = {}
  while Fuzz.more(src, #parts, 4) do parts[#parts + 1] = Draw.keyword(src, depth) end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Whether a failure is the bound on steps or depth, under which two
--- schemas that mean the same may disagree.
local function bounded(why: string): boolean
  return String.contains(why, "steps") or String.contains(why, "levels")
end

--- `text` compiled as a schema, or nil when it is refused.
local function compiled(text: string): JsonSchema.Schema?
  local decoded, _ = Json.decode(text)
  if decoded == nil then return nil end
  local s, why = JsonSchema.compile(decoded)
  if s == nil then
    if why.message == "" then error("a refusal with no reason") end
    return nil
  end
  return s
end

--- `check`'s result and its failure's message ("" when it allows).
local function answer(s: JsonSchema.Schema, v: Json.Value): boolean, string
  local ok, why = s:check(v)
  if ok then return true, "" end
  local message = why.message
  if message == "" then error("a check that refuses with no reason") end
  return false, message
end

--- A schema built around a drawn one, and the result its `check` must return.
local record Form
  text: string
  want: boolean
end

local function test_compile_and_check_answer_and_the_combinators_mean_what_they_say(tmp: string)
  Fuzz.run({
    name = "check a drawn value against a drawn schema",
    dir = tmp,
    requires = { "compiled", "allowed", "refused", "compared" },
    shares = { compiled = 0.3, compared = 0.2 },
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ Draw.schema(src, 3), value(src, 3), Draw.schema(src, 2) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local part, value_text = fields[1] or "", fields[2] or ""
      -- Every form holds the same definition, which a `$ref` names.
      local defs = '"$defs":{"d":' .. (fields[3] or "true") .. "},"
      local schema_text = "{" .. defs .. '"allOf":[' .. part .. "]}"
      local s = compiled(schema_text)
      if s == nil then return true, "" end
      Fuzz.label("compiled")
      local v, _ = Json.decode(value_text)
      if v == nil then return false, "a drawn value did not decode: " .. value_text end
      local ok, why = answer(s, v)
      Fuzz.label(if ok then "allowed" else "refused" end)
      if not ok and bounded(why) then return true, "" end
      Fuzz.label("compared")
      local forms: {Form} = {
        { text = "{" .. defs .. '"not":' .. part .. "}", want = not ok },
        { text = "{" .. defs .. '"allOf":[' .. part .. ",true]}", want = ok },
        { text = "{" .. defs .. '"anyOf":[false,' .. part .. "]}", want = ok },
        { text = "{" .. defs .. '"oneOf":[' .. part .. ",false]}", want = ok },
        { text = "{" .. defs .. '"if":' .. part .. ',"then":true,"else":false}', want = ok },
      }
      for _, form in ipairs(forms) do
        local text, want = form.text, form.want
        local other = compiled(text)
        if other == nil then return false, "refused " .. text .. " though its part compiled" end
        local got, said = answer(other, v)
        if got ~= want and not bounded(said) then
          return false, ("%s answered %s for %s, where its part answered %s"):format(text, tostring(got),
            value_text, tostring(ok))
        end
      end
      return true, ""
    end,
  })
end

local function test_compile_and_check_answer_for_changed_text(tmp: string)
  local sample <const> = '{"type":"object","properties":{"n":{"type":"integer","minimum":0},' ..
    '"tags":{"type":"array","items":{"enum":["a","b"]},"uniqueItems":true}},"required":["n"],' ..
    '"additionalProperties":false,"$defs":{"d":{"anyOf":[{"$ref":"#/$defs/d"},{"const":1}]}}}'
  local argument <const> = '{"n":3,"tags":["a","b"]}'
  Fuzz.run({
    name = "check changed text against a changed schema",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ Fuzz.mutate(src, sample, 6), Fuzz.mutate(src, argument, 4) })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local s = compiled(fields[1] or "")
      if s == nil then return true, "" end
      local v, _ = Json.decode(fields[2] or "")
      if v ~= nil then answer(s, v) end
      return true, ""
    end,
  })
end
