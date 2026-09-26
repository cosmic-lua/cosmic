--- Fuzz properties for `build.flow`: `format` is total -- it refuses or
--- returns a text in the subset, of the same value, that it takes back
--- unchanged -- on flow-style texts with comments and blank lines drawn
--- between their tokens and on those texts mutated; and what `write`
--- makes of a Teal value is such a text, of that value.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local flow = require("build.flow")

local READ <const>: Json.DecodeOptions = { json5 = true, hash_comments = true, null_value = Json.null }

local SCALARS <const> = { '"a"', '"x # y"', '"\\u2028"', '"\\u0085"', '"\u{e9}"', '"${{ x }}"', '"q\\"\\\\"',
  "true", "false", "null", "0", "-12", "123456789012345", "x", "1.5", "'s'" }
local KEYS <const> = { "a", "name", "_x", '"runs-on"', '"a b"', '"on"', "on", "Yes", '"\\u00e9"' }
--- What may lie between two tokens: nothing, spaces, line breaks, blank
--- lines and comments, in and out of place.
local GAPS <const> = { "", " ", "\n", "\n\n", " # c\n", "\n  # d\n", "\n\n# e\n\n", "#f\n" }

local function gap(src: Fuzz.Source): string
  if src:int(0, 2) == 0 then return Fuzz.pick(src, GAPS) end
  return src:int(0, 1) == 0 and " " or "\n"
end

--- A flow-style value, its members drawn with `Fuzz.more`.
local function gen_value(src: Fuzz.Source, depth: integer): string
  local kind = depth <= 0 and 0 or src:int(0, 2)
  if kind == 0 then return Fuzz.pick(src, SCALARS) end
  local object = kind == 1
  local parts: {string} = { object and "{" or "[", gap(src) }
  local count = 0
  while Fuzz.more(src, count, 5) do
    count = count + 1
    if object then parts[#parts + 1] = Fuzz.pick(src, KEYS) .. ": " end
    parts[#parts + 1] = gen_value(src, depth - 1)
    parts[#parts + 1] = gap(src)
    if src:int(0, 5) > 0 then parts[#parts + 1] = "," .. gap(src) end
  end
  parts[#parts + 1] = object and "}" or "]"
  return table.concat(parts)
end

local function gen_text(src: Fuzz.Source): string
  local text = gap(src) .. gen_value(src, 3) .. gap(src) .. "\n"
  if src:int(0, 3) == 0 then return Fuzz.mutate(src, text, 2) end
  return text
end

local function value_of(text: string): string
  local value, _ = Json.decode(text, READ)
  return (assert(Json.encode(value)))
end

local function format_holds(input: string): boolean, string
  local out, why = flow.format(input)
  if out == nil then
    if not why is string or why == "" then return false, "refused with no reason" end
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("laid out")
  if out ~= input then Fuzz.label("changed") end
  local found = flow.problems(out)
  if #found > 0 then return false, "laid out outside the subset: " .. found[1] end
  if value_of(out) ~= value_of(input) then return false, "laid out as another value" end
  local before, after = flow.comments(input), flow.comments(out)
  table.sort(before)
  table.sort(after)
  if table.concat(before, "\n") ~= table.concat(after, "\n") then return false, "a comment lost or changed" end
  local again, again_why = flow.format(out)
  if again ~= out then return false, "not a fixed point: " .. tostring(again_why) end
  return true, ""
end

local function test_format_refuses_or_lays_out_a_fixed_point(tmp: string)
  Fuzz.run({
    name = "flow format",
    dir = tmp,
    gen = gen_text,
    check = format_holds,
    requires = { "laid out", "changed", "refused" },
    shares = { ["laid out"] = 0.1 },
  })
end

--- A Teal value `from` takes, drawn.
local function gen_teal(src: Fuzz.Source, depth: integer): any
  local kind = depth <= 0 and 0 or src:int(0, 2)
  if kind == 0 then
    local pick = src:int(0, 4)
    if pick == 0 then return Fuzz.pick(src, { "a", "x # y", "\u{2028}", "\u{85}", "\u{e9}", "q\"\\", "" }) end
    if pick == 1 then return src:int(0, 1) == 0 end
    if pick == 2 then return Json.null end
    return src:int(-999, 999)
  end
  local out: {any: any} = {}
  local count = 0
  while Fuzz.more(src, count, 4) do
    count = count + 1
    if kind == 1 then
      out[Fuzz.pick(src, { "a", "b", "name", "on", "runs-on", "steps", "a b", "Yes" })] = gen_teal(src, depth - 1)
    else
      out[count] = gen_teal(src, depth - 1)
    end
  end
  if kind == 2 then return Json.array(out as {any}) end
  return out
end

local function test_write_makes_a_laid_out_text_of_its_value(tmp: string)
  Fuzz.run({
    name = "flow write",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return (assert(Json.encode(gen_teal(src, 3))))
    end,
    check = function(input: string): boolean, string
      local value, _ = Json.decode(input, { null_value = Json.null })
      local text = flow.write(value)
      local out, why = flow.format(text)
      if out ~= text then return false, "written, not laid out: " .. tostring(why) .. "\n" .. text end
      if value_of(text) ~= value_of(input) then return false, "written as another value:\n" .. text end
      Fuzz.label("written")
      return true, ""
    end,
    requires = { "written" },
  })
end
