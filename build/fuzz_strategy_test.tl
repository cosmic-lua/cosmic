local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local Strategy = require("build.fuzz_strategy")

local function test_composed_dependent_records_are_valid_and_repeatable()
  local integers = Strategy.integer(-100, 100)
  local text = Strategy.text({ "a", "é", "😀" }, 12)
  local bytes = Strategy.bytes(20)
  local function sample(): {string}
    local seen: {string} = {}
    Fuzz.run({ name = "strategy domains", iters = 200, gen = function(src: Fuzz.Source): string
      local record Pair
        low: integer
        high: integer
      end
      local pair = Strategy.draw(src, "bounds", function(s: Fuzz.Source): Pair
        local low = integers(s)
        return { low = low, high = Strategy.integer(low, 100)(s) }
      end)
      assert(pair.low >= -100 and pair.low <= pair.high and pair.high <= 100)
      local word, raw = text(src), bytes(src)
      assert(utf8.len(word) ~= nil and utf8.len(word) <= 12 and #raw <= 20)
      return Fuzz.pack({ tostring(pair.low), tostring(pair.high), word, raw })
    end, check = function(input: string): boolean, string
      seen[#seen + 1] = input
      return true, ""
    end })
    return seen
  end
  local a, b = sample(), sample()
  assert(#a == 200 and #b == #a)
  local distinct: {string: boolean} = {}
  for i = 1, #a do
    assert(a[i] == b[i], "same seed changed composed draws")
    distinct[a[i]] = true
  end
  local n = 0
  for _ in pairs(distinct) do n = n + 1 end
  assert(n > 100, "composed draws collapsed to a few values")
end

local function test_recursive_generation_respects_depth_and_shrinks(tmp: string)
  local leaf: Strategy.Gen<string> = function(_src: Fuzz.Source): string return "x" end
  local tree = Strategy.recursive(leaf, function(child: Strategy.Gen<string>): Strategy.Gen<string>
    return function(src: Fuzz.Source): string
      return "(" .. table.concat(Strategy.list(child, 3)(src)) .. ")"
    end
  end, 4)
  local ok, err = pcall(Fuzz.run, { name = "recursive strategy", dir = tmp, iters = 200,
    gen = tree, check = function(input: string): boolean, string
      local depth, deepest = 0, 0
      for char in input:gmatch(".") do
        if char == "(" then depth = depth + 1 end
        if char == ")" then depth = depth - 1 end
        deepest = math.max(deepest, depth)
        assert(depth >= 0)
      end
      assert(depth == 0 and deepest <= 4)
      return deepest < 2, "nested containers"
    end })
  assert(not ok, tostring(err))
  assert(tostring(err):find("shrink stopped: exhausted;", 1, true), tostring(err))
  assert(Fs.read(tmp .. "/recursive-strategy.input") == "(())", tostring(err))
end

local function test_signed_draws_simplify_toward_zero(tmp: string)
  local ok, err = pcall(Fuzz.run, { name = "signed target", dir = tmp, iters = 20,
    gen = function(src: Fuzz.Source): string
      return tostring(src:int(-1000000000, 1000000000, 0))
    end, check = function(input: string): boolean, string
      local n = tonumber(input)
      return n > -600000000 and n < 600000000, "large magnitude"
    end })
  assert(not ok, tostring(err))
  local kept = assert(Fs.read(tmp .. "/signed-target.input"))
  assert(math.abs(tonumber(kept)) == 600000000, tostring(err))
end

local function test_integer_domains_include_full_width_and_boundaries()
  local gen = Strategy.integer(math.mininteger, math.maxinteger)
  local seen: {integer: boolean} = {}
  Fuzz.run({ name = "integer boundaries", iters = 2000,
    gen = function(src: Fuzz.Source): string return tostring(gen(src)) end,
    check = function(input: string): boolean, string
      local n = assert(math.tointeger(tonumber(input)))
      seen[n] = true
      return true, ""
    end })
  assert(seen[math.mininteger] and seen[math.maxinteger] and seen[0])
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  assert(n > 500, "boundary bias lost broad exploration")
end

local function test_lists_refuse_nil_elements_without_losing_progress()
  local gen = Strategy.list(function(_src: Fuzz.Source): string return nil end, 8)
  local ok, err = pcall(Fuzz.run, { name = "nil list", iters = 100,
    gen = function(src: Fuzz.Source): string return table.concat(gen(src)) end,
    check = function(_input: string): boolean, string return true, "" end })
  assert(not ok and tostring(err):find("list element is nil", 1, true), tostring(err))
end
