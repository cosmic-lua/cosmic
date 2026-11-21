--- Proves [`cosmic.cbor`] against the examples of RFC 8949 appendix A,
--- decoded and written back, and that bytes which are not one well-formed
--- item are refused with a reason.

local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")
local Test = require("cosmic.test")

local function hex(h: string): string
  return (assert(Codec.unhex(h)))
end

local function decoded(h: string): Cbor.Item
  local item, why = Cbor.decode(hex(h))
  assert(item ~= nil, h .. ": " .. why)
  return item
end

--- Each integer of appendix A, and the head that spells it, which the
--- encoder writes back.
local function test_integers()
  local cases: {{integer | string}} = {
    { 0, "00" }, { 1, "01" }, { 10, "0a" }, { 23, "17" }, { 24, "1818" }, { 25, "1819" },
    { 100, "1864" }, { 1000, "1903e8" }, { 1000000, "1a000f4240" },
    { 1000000000000, "1b000000e8d4a51000" }, { -1, "20" }, { -10, "29" }, { -100, "3863" },
    { -1000, "3903e7" }, { math.maxinteger, "1b7fffffffffffffff" }, { math.mininteger, "3b7fffffffffffffff" },
  }
  for _, case in ipairs(cases) do
    local n, h = case[1], case[2]
    assert(n is integer and h is string)
    local item = decoded(h)
    assert(item.kind == "integer" and item.integer == n, h)
    assert(Codec.hex(Cbor.encode(Cbor.integer(n))) == h, h)
  end
end

--- 2^64 - 1 and -2^64, which no Lua integer holds, are "big" items.
local function test_integers_past_the_signed_range()
  local top = decoded("1bffffffffffffffff")
  assert(top.kind == "big" and top.bytes == ("\xff"):rep(8) and top.negative == false)
  local bottom = decoded("3bffffffffffffffff")
  assert(bottom.kind == "big" and bottom.negative == true)
  assert(Codec.hex(Cbor.encode(top)) == "1bffffffffffffffff")
  assert(Codec.hex(Cbor.encode(bottom)) == "3bffffffffffffffff")
  assert(Codec.hex(Cbor.encode({ kind = "big", bytes = "\1\0", negative = false })) == "190100")
end

local function test_floats()
  local cases: {{number | string}} = {
    { 0.0, "f90000" }, { -0.0, "f98000" }, { 1.0, "f93c00" }, { 1.1, "fb3ff199999999999a" },
    { 1.5, "f93e00" }, { 65504.0, "f97bff" }, { 100000.0, "fa47c35000" },
    { 3.4028234663852886e+38, "fa7f7fffff" }, { 1.0e+300, "fb7e37e43c8800759c" },
    { 5.960464477539063e-8, "f90001" }, { 0.00006103515625, "f90400" }, { -4.0, "f9c400" },
    { -4.1, "fbc010666666666666" }, { math.huge, "f97c00" }, { -math.huge, "f9fc00" },
  }
  for _, case in ipairs(cases) do
    local x, h = case[1], case[2]
    assert(x is number and h is string)
    local item = decoded(h)
    assert(item.kind == "float" and item.number == x, h)
    if x == 0 then assert(1 / assert(item.number) == 1 / x, h) end
    assert(Codec.hex(Cbor.encode(Cbor.float(x))) == h, h .. " written " .. Codec.hex(Cbor.encode(Cbor.float(x))))
  end
  local nan = assert(decoded("f97e00").number)
  assert(nan ~= nan)
  assert(Codec.hex(Cbor.encode(Cbor.float(0.0 / 0.0))) == "f97e00")
  -- The same values, spelled longer, decode alike.
  assert(decoded("fa3fc00000").number == 1.5 and decoded("fb3ff8000000000000").number == 1.5)
end

local function test_simple_values()
  assert(decoded("f4").simple == 20 and decoded("f5").simple == 21)
  assert(decoded("f6").simple == 22 and decoded("f7").simple == 23)
  assert(decoded("f0").simple == 16 and decoded("f8ff").simple == 255)
  assert(Codec.hex(Cbor.encode(Cbor.boolean(true))) == "f5")
  assert(Codec.hex(Cbor.encode({ kind = "simple", simple = 255 })) == "f8ff")
end

local function test_strings()
  assert(decoded("40").bytes == "" and decoded("40").kind == "bytes")
  assert(decoded("4401020304").bytes == "\1\2\3\4")
  assert(decoded("60").kind == "text" and decoded("6161").bytes == "a")
  assert(decoded("6449455446").bytes == "IETF")
  assert(decoded("62c3bc").bytes == "\u{fc}")
  assert(decoded("64f0908591").bytes == "\u{10151}")
  assert(Codec.hex(Cbor.encode(Cbor.text("IETF"))) == "6449455446")
  assert(Codec.hex(Cbor.encode(Cbor.bytes("\1\2\3\4"))) == "4401020304")
end

local function test_tags()
  local item = decoded("c074323031332d30332d32315432303a30343a30305a")
  assert(item.kind == "tag" and item.tag == 0 and assert(item.of).bytes == "2013-03-21T20:04:00Z")
  assert(Codec.hex(Cbor.encode(item)) == "c074323031332d30332d32315432303a30343a30305a")
  assert(decoded("d74401020304").tag == 23)
end

local function test_arrays_and_maps()
  for _, h in ipairs({
      "80", "83010203", "8301820203820405",
      "98190102030405060708090a0b0c0d0e0f101112131415161718181819",
      "a0", "a201020304", "a26161016162820203", "826161a161626163",
      "a56161614161626142616361436164614461656145",
  }) do
    assert(Codec.hex(Cbor.encode(decoded(h))) == h, h)
  end
  local map = decoded("a26161016162820203")
  assert(assert(Cbor.get(map, "a")).integer == 1)
  assert(#assert(assert(Cbor.get(map, "b")).items) == 2)
  assert(Cbor.get(map, "c") == nil and Cbor.get(map, 1) == nil)
  assert(assert(Cbor.get(decoded("a201020304"), 3)).integer == 4)
end

--- Indefinite lengths decode to the definite item, which is what is
--- written back.
local function test_indefinite_lengths()
  assert(decoded("5f42010243030405ff").bytes == "\1\2\3\4\5")
  assert(decoded("7f657374726561646d696e67ff").bytes == "streaming")
  assert(#assert(decoded("9fff").items) == 0)
  local cases: {{string}} = {
    { "9f018202039f0405ffff", "8301820203820405" },
    { "9f01820203820405ff", "8301820203820405" },
    { "83018202039f0405ff", "8301820203820405" },
    { "bf61610161629f0203ffff", "a26161016162820203" },
    { "826161bf61626163ff", "826161a161626163" },
    { "bf6346756ef563416d7421ff", "a26346756ef563416d7421" },
  }
  for _, case in ipairs(cases) do
    local from, to = assert(case[1]), assert(case[2])
    assert(Codec.hex(Cbor.encode(decoded(from))) == to, from)
  end
end

local function test_sort()
  local map = Cbor.map({
    { Cbor.text("aa"), Cbor.integer(1) }, { Cbor.integer(10), Cbor.integer(2) },
    { Cbor.text("b"), Cbor.integer(3) }, { Cbor.integer(-1), Cbor.integer(4) },
  })
  assert(Codec.hex(Cbor.encode(map)) == "a4626161010a02616203" .. "2004")
  assert(Codec.hex(Cbor.encode(map, { sort = true })) == "a40a022004616203626161" .. "01")
end

local function test_decode_first()
  local first = assert(Cbor.decode_first(hex("a1010203ff"), 1))
  assert(first.item.kind == "map" and first.next == 4)
  local second = assert(Cbor.decode_first(hex("a1010203ff"), first.next))
  assert(second.item.integer == 3 and second.next == 5)
end

local function test_what_is_no_item_is_refused()
  local cases: {{string}} = {
    { "", "end" },
    { "1901", "past the end" },
    { "1c", "reserved" },
    { "ff", "break" },
    { "61ff", "UTF-8" },
    { "5affffffff", "past the end" },
    { "9bffffffffffffffff", "past the end" },
    { "a20101", "end" },
    { "a201010102", "twice" },
    { "a2616101616102", "twice" },
    { "0000", "follow" },
    { "5f6161ff", "another type" },
    { "5f5f4101ffff", "indefinite" },
    { "f818", "one byte" },
    { "1f", "indefinite" },
    { "df00", "indefinite" },
    { "dbffffffffffffffff00", "tag number" },
    { "9f01", "end" },
    { "a26161017f6161ff02", "twice" },
    { "a20101180102", "twice" },
    { "a24101015f4101ff02", "twice" },
    { "7f61c361bcff", "UTF-8" },
  }
  for _, case in ipairs(cases) do
    local h, says = assert(case[1]), assert(case[2])
    local item, why = Cbor.decode(hex(h))
    assert(item == nil and why:find(says, 1, true) ~= nil, h .. ": " .. why)
  end
  local deep, why = Cbor.decode(("\x81"):rep(65) .. "\0")
  assert(deep == nil and why:find("max_depth", 1, true) ~= nil, why)
  assert(Cbor.decode(("\x81"):rep(64) .. "\0") ~= nil)
  assert(Cbor.decode(("\x81"):rep(3) .. "\0", { max_depth = 2 }) == nil)
  for _, opener in ipairs({ "\xa1\0", "\xc1" }) do
    local nested, said = Cbor.decode(opener:rep(65) .. "\0")
    assert(nested == nil and said:find("max_depth", 1, true) ~= nil, said)
    assert(Cbor.decode(opener:rep(64) .. "\0") ~= nil)
  end
  local at_zero, wrong = Cbor.decode_first("\1", 0)
  assert(at_zero == nil and wrong:find("from 1", 1, true) ~= nil)
  Test.raises(function() Cbor.decode("\0", { max_depth = 1000000 }) end, "max_depth")
end

local function test_subnormal_floats()
  assert(decoded("f98001").number == -5.960464477539063e-8)
  assert(Codec.hex(Cbor.encode(Cbor.float(-5.960464477539063e-8))) == "f98001")
  assert(decoded("fa00000001").number == 1.401298464324817e-45)
  assert(Codec.hex(Cbor.encode(Cbor.float(1.401298464324817e-45))) == "fa00000001")
end

local function test_what_cannot_be_written_raises()
  Test.raises(function() Cbor.encode({ kind = "big", bytes = ("\1"):rep(9), negative = false }) end, "64 bits")
  Test.raises(function() Cbor.encode({ kind = "simple", simple = 24 }) end, "simple value")
  Test.raises(function() Cbor.encode({ kind = "tag", of = Cbor.integer(1) }) end, "no tag")
  Test.raises(function() Cbor.encode({ kind = "tag", tag = -1, of = Cbor.integer(1) }) end, "cannot be written")
  Test.raises(function() Cbor.encode({ kind = "float" }) end, "no number")
  Test.raises(function() Cbor.text("\xff") end, "UTF-8")
end
