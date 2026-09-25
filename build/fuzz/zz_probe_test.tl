local Fuzz = require("build.fuzz")

local function rep(p: Fuzz.Property): string
  local ok, err = pcall(Fuzz.run, p)
  if ok then return "HELD" end
  return tostring(err)
end

local function big(src: Fuzz.Source): string return Fuzz.bytes(src, 1600) end

local function test_probe()
  -- A: two 0xff bytes anywhere in a big input
  local e = rep({ name = "two ff", iters = 200, gen = big, check = function(s: string): boolean, string
    local _, n = s:gsub("\255", "")
    return n < 2, "two ff" end })
  print("A", e)
  -- B: length >= 100
  e = rep({ name = "long", iters = 200, gen = big, check = function(s: string): boolean, string
    return #s < 100, "long" end })
  print("B", e)
  -- C: case run's reproduce line
  local case = e:match("FUZZ_CASE=(%S+)")
  e = rep({ name = "long", gen = big, case = case, check = function(s: string): boolean, string
    return #s < 100, "long" end })
  print("C", e)
  -- D: typo'd case
  print("D", rep({ name = "long", gen = big, case = "lon:5", check = function(_s: string): boolean, string
    return false, "x" end }))
  -- E: whitespace / other forms
  for _, c in ipairs({ " long:5", "long:5 ", "long: 5", "long:+5", "long:-9223372036854775808", "long:9223372036854775808", ":5", "a:b:5" }) do
    local ok, err = pcall(Fuzz.run, { name = "long", gen = big, case = c, check = function(_s: string): boolean, string return false, "x" end })
    print("E", ("%q"):format(c), ok, ok and err or tostring(err):sub(1, 90))
  end
  -- F: more mean
  local Rand = require("cosmic.rand")
  for _, max in ipairs({ 0, 1, 2, 3, 8, 40, 1600 }) do
    local r = Rand.new(7)
    local src: Fuzz.Source = { int = function(_: Fuzz.Source, a: integer, b: integer): integer return r:int(a, b) end }
    local tot, atmax = 0, 0
    for _ = 1, 20000 do
      local n = 0
      while Fuzz.more(src, n, max) do n = n + 1 end
      tot = tot + n
      if n == max then atmax = atmax + 1 end
    end
    print("F", max, tot / 20000, atmax / 20000)
  end
end
