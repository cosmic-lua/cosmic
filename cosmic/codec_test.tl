local Codec = require("cosmic.codec")

--- RFC 4648 section 10's test vectors: the input, its base16, and its
--- base64.
local VECTORS <const> = {
  { "", "", "" },
  { "f", "66", "Zg==" },
  { "fo", "666F", "Zm8=" },
  { "foo", "666F6F", "Zm9v" },
  { "foob", "666F6F62", "Zm9vYg==" },
  { "fooba", "666F6F6261", "Zm9vYmE=" },
  { "foobar", "666F6F626172", "Zm9vYmFy" },
}

local function test_hex_matches_rfc4648_in_lowercase()
  for _, v in ipairs(VECTORS) do
    assert(Codec.hex(v[1]) == v[2]:lower(), v[1])
  end
end

local function test_unhex_reads_either_case()
  for _, v in ipairs(VECTORS) do
    assert(Codec.unhex(v[2]) == v[1], v[2])
    assert(Codec.unhex(v[2]:lower()) == v[1], v[2])
  end
  assert(Codec.unhex("aBcD") == "\xab\xcd")
end

local function test_hex_covers_every_byte()
  local all: {string} = {}
  for b = 0, 255 do all[#all + 1] = string.char(b) end
  local bytes = table.concat(all)
  local text = Codec.hex(bytes)
  assert(#text == 512)
  assert(text:sub(1, 6) == "000102" and text:sub(-4) == "feff", text)
  assert(Codec.unhex(text) == bytes)
end

local function test_unhex_refuses_odd_length_and_non_digits()
  for _, bad in ipairs({ "a", "abc", "0g", "zz", " 00", "00\n", "0x00", "\0\0" }) do
    local out, why = Codec.unhex(bad)
    assert(out == nil, bad)
    assert(why:match("^codec: "), why)
  end
  local _, why = Codec.unhex("abc")
  assert(why:find("odd length 3", 1, true), why)
  _, why = Codec.unhex("00g0")
  assert(why:find("0x67 at 3", 1, true), why)
end

local function test_base64_matches_rfc4648()
  for _, v in ipairs(VECTORS) do
    assert(Codec.base64(v[1]) == v[3], v[1])
    local out, why = Codec.unbase64(v[3])
    assert(out == v[1] and why == "", v[3])
  end
end

local function test_base64url_is_unpadded_and_url_safe()
  for _, v in ipairs(VECTORS) do
    local bare = (v[3]:gsub("=", ""))
    assert(Codec.base64url(v[1]) == bare, v[1])
    assert(Codec.unbase64url(bare) == v[1], bare)
  end
  assert(Codec.base64("\xfb\xff") == "+/8=")
  assert(Codec.base64url("\xfb\xff") == "-_8")
  assert(Codec.unbase64("+/8=") == "\xfb\xff")
  assert(Codec.unbase64url("-_8") == "\xfb\xff")
end

local function test_unbase64_refuses_malformed_text()
  local cases: {{string}} = {
    { "Zg=", "not a multiple of 4" },
    { "Zm9", "not a multiple of 4" },
    { "Zm9v\n", "not a multiple of 4" },
    { "Zm 9", "0x20 at 3" },
    { "Zm9-", "0x2d at 4" },
    { "Zm9_", "0x5f at 4" },
    { "Z===", "misplaced '=' padding at 2" },
    { "====", "misplaced '=' padding at 1" },
    { "Zg==Zm9v", "misplaced '=' padding at 3" },
    { "Z=g=", "misplaced '=' padding at 2" },
    { "Zh==", "nonzero padding bits" },
    { "Zm9=", "nonzero padding bits" },
  }
  for _, c in ipairs(cases) do
    local out, why = Codec.unbase64(c[1])
    assert(out == nil, c[1])
    assert(why:find(c[2], 1, true), c[1] .. ": " .. why)
  end
end

local function test_unbase64url_refuses_padding_and_the_standard_alphabet()
  local cases: {{string}} = {
    { "Zg==", "misplaced '=' padding at 3" },
    { "Z", "one character over" },
    { "Zm9vY", "one character over" },
    { "+/8", "0x2b at 1" },
    { "Zh", "nonzero padding bits" },
  }
  for _, c in ipairs(cases) do
    local out, why = Codec.unbase64url(c[1])
    assert(out == nil, c[1])
    assert(why:find(c[2], 1, true), c[1] .. ": " .. why)
  end
end

local function test_a_megabyte_round_trips()
  local parts: {string} = {}
  for i = 1, 4096 do
    local row: {integer} = {}
    for j = 1, 256 do row[j] = (i * 31 + j * 7) & 255 end
    parts[i] = string.char(table.unpack(row))
  end
  local big = table.concat(parts)
  assert(Codec.unhex(Codec.hex(big)) == big)
  local text = Codec.base64(big .. "x")
  assert(#text == (#big + 1 + 2) // 3 * 4)
  assert(Codec.unbase64(text) == big .. "x")
  assert(Codec.unbase64url(Codec.base64url(big .. "xy")) == big .. "xy")
end
