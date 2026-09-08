--- Encode structured test cases as byte strings without hidden generator state.
--- The bytes are a draw tape interpreted inside the property's check; even
--- values such as cycles, functions and threads can then be reconstructed.
local check = require("cosmic.check")
local json = require("cosmic.json")
local fuzz = require("cosmic.fuzz")

local function encode(draws: {fuzz.Draw}): string
  return check.must(json.encode({draws = draws}))
end

local function replay(input: string): fuzz.Recorder
  local parsed = check.must(json.decode_object(input))
  local raw = parsed.draws
  assert(raw is {any}, "expected draw tape")
  local draws: {fuzz.Draw} = {}
  for _, value in ipairs(raw) do
    assert(value is {string: any}, "expected draw record")
    local kind = value.kind
    assert(kind is string)
    if kind == "int" then
      local lo, hi, ivalue = value.lo, value.hi, value.ivalue
      assert(lo is integer)
      assert(hi is integer)
      assert(ivalue is integer)
      draws[#draws + 1] = {kind = kind, lo = lo, hi = hi, ivalue = ivalue}
    else
      local fvalue = value.fvalue
      assert(kind == "float" and fvalue is number)
      draws[#draws + 1] = {kind = kind, fvalue = fvalue}
    end
  end
  return fuzz.replay_source(draws)
end

return {encode = encode, replay = replay}
