local Array = require("cosmic.array")
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
    assert(Codec.hex(Array.at(v, 1)) == Array.at(v, 2):lower(), Array.at(v, 1))
  end
end

local function test_unhex_reads_either_case()
  for _, v in ipairs(VECTORS) do
    assert(assert(Codec.unhex(Array.at(v, 2))) == Array.at(v, 1), Array.at(v, 2))
    assert(assert(Codec.unhex(Array.at(v, 2):lower())) == Array.at(v, 1), Array.at(v, 2))
  end
  assert(assert(Codec.unhex("aBcD")) == "\xab\xcd")
end

local function test_hex_covers_every_byte()
  local all: mut {string} = {}
  for b = 0, 255 do all[#all + 1] = string.char(b) end
  local bytes = table.concat(all)
  local text = Codec.hex(bytes)
  assert(#text == 512)
  assert(text:sub(1, 6) == "000102" and text:sub(-4) == "feff", text)
  assert(assert(Codec.unhex(text)) == bytes)
end

local function test_unhex_refuses_odd_length_and_non_digits()
  for _, bad in ipairs({ "a", "abc", "0g", "zz", " 00", "00\n", "0x00", "\0\0" }) do
    local out, why = Codec.unhex(bad)
    assert(out == nil, bad)
    assert(tostring(why):match("^codec: "), tostring(why))
  end
  local _, odd = Codec.unhex("abc")
  assert(tostring(odd):find("odd length 3", 1, true), tostring(odd))
  local _, digit = Codec.unhex("00g0")
  assert(tostring(digit):find("0x67 at 3", 1, true), tostring(digit))
end

local function test_base64_matches_rfc4648()
  for _, v in ipairs(VECTORS) do
    assert(Codec.base64(Array.at(v, 1)) == Array.at(v, 3), Array.at(v, 1))
    local out, why = Codec.unbase64(Array.at(v, 3))
    assert(out == v[1] and why == nil, v[3])
  end
end

local function test_base64url_is_unpadded_and_url_safe()
  for _, v in ipairs(VECTORS) do
    local bare = (Array.at(v, 3):gsub("=", ""))
    assert(Codec.base64url(Array.at(v, 1)) == bare, Array.at(v, 1))
    assert(assert(Codec.unbase64url(bare)) == v[1], bare)
  end
  assert(Codec.base64("\xfb\xff") == "+/8=")
  assert(Codec.base64url("\xfb\xff") == "-_8")
  assert(assert(Codec.unbase64("+/8=")) == "\xfb\xff")
  assert(assert(Codec.unbase64url("-_8")) == "\xfb\xff")
end

local record Refusal
  text: string
  says: string
end

local function test_unbase64_refuses_malformed_text()
  local cases: {Refusal} = {
    { text = "Zg=", says = "not a multiple of 4" },
    { text = "Zm9", says = "not a multiple of 4" },
    { text = "Zm9v\n", says = "not a multiple of 4" },
    { text = "Zm 9", says = "0x20 at 3" },
    { text = "Zm9-", says = "0x2d at 4" },
    { text = "Zm9_", says = "0x5f at 4" },
    { text = "Z===", says = "misplaced '=' padding at 2" },
    { text = "====", says = "misplaced '=' padding at 1" },
    { text = "Zg==Zm9v", says = "misplaced '=' padding at 3" },
    { text = "Z=g=", says = "misplaced '=' padding at 2" },
    { text = "Zh==", says = "nonzero padding bits" },
    { text = "Zm9=", says = "nonzero padding bits" },
  }
  for _, c in ipairs(cases) do
    local out, why = Codec.unbase64(c.text)
    assert(out == nil, c.text)
    assert(tostring(why):find(c.says, 1, true), c.text .. ": " .. tostring(why))
  end
end

local function test_unbase64url_refuses_padding_and_the_standard_alphabet()
  local cases: {Refusal} = {
    { text = "Zg==", says = "misplaced '=' padding at 3" },
    { text = "Z", says = "one character over" },
    { text = "Zm9vY", says = "one character over" },
    { text = "+/8", says = "0x2b at 1" },
    { text = "Zh", says = "nonzero padding bits" },
  }
  for _, c in ipairs(cases) do
    local out, why = Codec.unbase64url(c.text)
    assert(out == nil, c.text)
    assert(tostring(why):find(c.says, 1, true), c.text .. ": " .. tostring(why))
  end
end

local function test_unbase64_lines_skips_mime_line_breaks()
  local bytes = ("cosmic"):rep(40)
  local flat = Codec.base64(bytes)
  local lines: mut {string} = {}
  for i = 1, #flat, 76 do lines[#lines + 1] = flat:sub(i, i + 75) end
  assert(assert(Codec.unbase64_lines(table.concat(lines, "\r\n") .. "\r\n")) == bytes)
  assert(assert(Codec.unbase64_lines(table.concat(lines, "\n"))) == bytes)
  assert(assert(Codec.unbase64_lines(flat)) == bytes)
  assert(assert(Codec.unbase64_lines("Zm9v\r\nYg==\r\n")) == "foob")
  assert(assert(Codec.unbase64_lines("")) == "")
  assert(assert(Codec.unbase64_lines("\r\n")) == "")
  assert(assert(Codec.unbase64_lines("Zg=\r\n=")) == "f")
  assert(assert(Codec.unbase64_lines("Zg\r\n==")) == "f")
  assert(assert(Codec.unbase64_lines("Zg==\r\n\r\n")) == "f")
end

local function test_unbase64_lines_refuses_as_unbase64_does_at_the_place_in_the_text()
  local cases: {Refusal} = {
    { text = "Zm9v\r\nZm9", says = "length 7 without its line breaks, not a multiple of 4" },
    { text = "Zm9v\r\nZ m9", says = "byte 0x20 at 8" },
    { text = "Zm9v\tZm9", says = "byte 0x09 at 5" },
    { text = "Zg==\r\nZm9v", says = "misplaced '=' padding at 3" },
    { text = "Zm9v\r\nZh==", says = "nonzero padding bits" },
    { text = "Zm9v\r\nZh\r\n==\r\n", says = "nonzero padding bits" },
    { text = "Z=\n=\n=", says = "misplaced '=' padding at 2" },
    { text = "=\r\n=\r\n=\r\n=", says = "misplaced '=' padding at 1" },
    { text = "Zm\n9\0", says = "byte 0x00 at 5" },
    { text = ("A"):rep(1024 * 1024 - 4) .. "\r\nAAA\0", says = "byte 0x00 at " .. tostring(1024 * 1024 + 2) },
  }
  for _, c in ipairs(cases) do
    local out, why = Codec.unbase64_lines(c.text)
    assert(out == nil, c.text)
    assert(tostring(why):find(c.says, 1, true), c.text .. ": " .. tostring(why))
  end
end

--- simdutf, which decodes first, skips every ASCII space; a long text
--- holding a space, tab, form feed or a line break where only
--- `unbase64_lines` takes one is refused all the same, at its place.
local function test_white_space_simdutf_skips_is_refused_in_long_texts()
  local flat = Codec.base64(("cosmic"):rep(400))
  for _, space in ipairs({ " ", "\t", "\f", "\r", "\n", "    " }) do
    local text = flat:sub(1, 1000) .. space .. flat:sub(1001)
    local out, why = Codec.unbase64(text)
    assert(out == nil, "unbase64 took " .. string.format("%q", space))
    assert(tostring(why):find("at 1001", 1, true) or tostring(why):find("length", 1, true), tostring(why))
    if space ~= "\r" and space ~= "\n" then
      local lines_out, lines_why = Codec.unbase64_lines(text)
      assert(lines_out == nil, "unbase64_lines took " .. string.format("%q", space))
      assert(tostring(lines_why):find("at 1001", 1, true) or tostring(lines_why):find("length", 1, true),
        tostring(lines_why))
    end
  end
  local url = Codec.base64url(("cosmic"):rep(400))
  local out, _ = Codec.unbase64url(url:sub(1, 500) .. " " .. url:sub(501))
  assert(out == nil, "unbase64url took a space")
  assert(Codec.unbase64(flat)! == ("cosmic"):rep(400))
  assert(Codec.unbase64url(url)! == ("cosmic"):rep(400))
end

local function test_a_megabyte_round_trips()
  local parts: mut {string} = {}
  for i = 1, 4096 do
    local row: mut {integer} = {}
    for j = 1, 256 do row[j] = (i * 31 + j * 7) & 255 end
    parts[i] = string.char(table.unpack(row))
  end
  local big = table.concat(parts)
  assert(assert(Codec.unhex(Codec.hex(big))) == big)
  local text = Codec.base64(big .. "x")
  assert(#text == (#big + 1 + 2) // 3 * 4)
  assert(assert(Codec.unbase64(text)) == big .. "x")
  assert(assert(Codec.unbase64url(Codec.base64url(big .. "xy"))) == big .. "xy")
end

--- Every byte's two hex digits decode in each of their four case spellings.
local function test_unhex_reads_every_byte_in_each_case()
  for byte = 0, 255 do
    local l = ("%02x"):format(byte)
    for _, spelled in ipairs({ l, l:upper(), l:sub(1, 1):upper() .. l:sub(2, 2), l:sub(1, 1) .. l:sub(2, 2):upper() }) do
      assert(assert(Codec.unhex(spelled)) == string.char(byte), spelled)
    end
  end
end
