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

local NAMES <const>: {Codec.Name} = { "hex", "base64", "base64url" }

--- The whole-string decoder for each encoding.
local function whole_decode(name: Codec.Name, text: string): string | nil, string
  if name == "hex" then return Codec.unhex(text) end
  if name == "base64" then return Codec.unbase64(text) end
  return Codec.unbase64url(text)
end

local function whole_encode(name: Codec.Name, bytes: string): string
  if name == "hex" then return Codec.hex(bytes) end
  if name == "base64" then return Codec.base64(bytes) end
  return Codec.base64url(bytes)
end

--- What `coder` answers to `pieces` in turn and then `finish`: the
--- output joined, or nil and the reason.
local function through(coder: Codec.Coder, pieces: {string}): string | nil, string
  local out: {string} = {}
  for _, piece in ipairs(pieces) do
    local part, why = coder:update(piece)
    assert(part ~= nil, "update refused: " .. why)
    out[#out + 1] = part
  end
  local last, why = coder:finish()
  if last == nil then return nil, why end
  out[#out + 1] = last
  return table.concat(out), ""
end

--- `s` cut into pieces of `size` bytes, the last one shorter.
local function pieces_of(s: string, size: integer): {string}
  local pieces: {string} = {}
  for first = 1, #s, size do pieces[#pieces + 1] = s:sub(first, first + size - 1) end
  return pieces
end

--- Every way of cutting `s` in two (empty halves included), and into
--- pieces of each size up to three, as lists of pieces.
local function cuts(s: string): {{string}}
  local all: {{string}} = {}
  for at = 0, #s do all[#all + 1] = { s:sub(1, at), s:sub(at + 1) } end
  for size = 1, 3 do all[#all + 1] = pieces_of(s, size) end
  return all
end

local SAMPLES <const>: {string} = {
  "", "f", "fo", "foo", "foob", "fooba", "foobar", "\0\1\xfb\xff\xfe\0\x80",
  "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
}

local function test_chunked_encoding_equals_the_whole_string_at_every_cut()
  for _, name in ipairs(NAMES) do
    for _, bytes in ipairs(SAMPLES) do
      local want = whole_encode(name, bytes)
      for _, pieces in ipairs(cuts(bytes)) do
        local got, why = through(Codec.encoder(name), pieces)
        assert(got == want, ("%s %q cut %q: %s"):format(name, bytes, table.concat(pieces, "|"), tostring(got)))
        assert(why == "")
      end
    end
  end
end

local function test_chunked_decoding_equals_the_whole_string_at_every_cut()
  for _, name in ipairs(NAMES) do
    for _, bytes in ipairs(SAMPLES) do
      local text = whole_encode(name, bytes)
      for _, pieces in ipairs(cuts(text)) do
        local got, why = through(Codec.decoder(name), pieces)
        assert(got == bytes, ("%s %q cut %q: %s"):format(name, text, table.concat(pieces, "|"), tostring(why)))
      end
    end
  end
end

local REFUSED <const>: {{string}} = {
  { "hex", "abc" }, { "hex", "66zz" }, { "hex", "6g6" }, { "hex", "zz6" },
  { "base64", "Zg" }, { "base64", "Zg=" }, { "base64", "Z=g=" }, { "base64", "Zm9v====" },
  { "base64", "Zg==Zg==" }, { "base64", "Zh==" }, { "base64", "Zm9-" }, { "base64", "Zm-" },
  { "base64", "Zg=x" }, { "base64", "Zg\xff=" }, { "base64", "Zm9v\nZm9v" }, { "base64", "Z===" },
  { "base64", "Zm8=Zm8=" }, { "base64", "=Zm9" }, { "base64", "Zm9vZg==" .. "=" },
  { "base64url", "Zm9vY" }, { "base64url", "Zg==" }, { "base64url", "Zh" }, { "base64url", "Zm+v" },
  { "base64url", "Zm9v_\xff" }, { "base64url", "Zm8=" }, { "base64url", "Zm9vZ-8x=" },
}

local function test_a_refusal_says_the_same_at_every_cut()
  for _, case in ipairs(REFUSED) do
    local name, text = case[1] as Codec.Name, case[2]
    local bytes, want = whole_decode(name, text)
    assert(bytes == nil and want ~= "", name .. " " .. text)
    for _, pieces in ipairs(cuts(text)) do
      local got, why = through(Codec.decoder(name), pieces)
      assert(got == nil and why == want,
        ("%s cut %q: %q, want %q"):format(name, table.concat(pieces, "|"), tostring(why), want))
    end
  end
end

local function test_offsets_are_absolute_across_chunks()
  local function refused(name: Codec.Name, pieces: {string}): string
    local got, why = through(Codec.decoder(name), pieces)
    assert(got == nil)
    return why
  end
  assert(refused("hex", { "66", "6g" }) == "codec: byte 0x67 at 4 is not a hex digit")
  assert(refused("hex", { "6", "6", "6", "z" }) == "codec: byte 0x7a at 4 is not a hex digit")
  assert(refused("base64", { "Zm9v", "Zm9v", "Zm-v" }) == "codec: byte 0x2d at 11 is outside the base64 alphabet")
  assert(refused("base64", { "Zm9v", "Z", "=", "g=" }) == "codec: base64 text has misplaced '=' padding at 6")
  assert(refused("base64url", { "Zm9", "vZ", "m+v" }) == "codec: byte 0x2b at 7 is outside the base64url alphabet")
  assert(refused("base64", { "Zm9vZm9v", "Z", "=", "=", "=" }) ==
    "codec: base64 text has misplaced '=' padding at 10")
  -- Lengths are of the whole text, not the last chunk.
  assert(refused("hex", { "666f", "6" }) == "codec: hex text of odd length 5")
  assert(refused("base64", { "Zm9v", "Zg" }) == "codec: base64 text of length 6, not a multiple of 4")
  assert(refused("base64url", { "Zm9v", "Y" }) == "codec: base64url text of length 5 leaves one character over")
end

local function test_a_finished_coder_raises_and_an_unknown_name_is_refused()
  for _, make in ipairs({ Codec.encoder, Codec.decoder }) do
    local c = make("base64")
    assert(c:update("") == "" and c:finish() == "")
    assert(not pcall(c.update, c, "x"))
    assert(not pcall(c.finish, c))
  end
  local bad = Codec.decoder("hex")
  assert(bad:update("z") == "")
  assert(bad:finish() == nil)
  assert(not pcall(bad.finish, bad))
  assert(not pcall(Codec.encoder, "base32" as Codec.Name))
  assert(not pcall(Codec.decoder, "base32" as Codec.Name))
end

local function test_a_long_stream_takes_bounded_memory()
  local block = {} as {integer}
  for i = 1, 65536 do block[i] = (i * 131 + (i >> 8)) & 255 end
  local pieces: {string} = {}
  for first = 1, #block, 4096 do
    pieces[#pieces + 1] = string.char(table.unpack(block, first, first + 4095))
  end
  local chunk = table.concat(pieces)
  local rounds = 32 -- 2 MiB of input through each encoding, and back
  local warm = 6
  for _, name in ipairs(NAMES) do
    local enc, dec = Codec.encoder(name), Codec.decoder(name)
    collectgarbage()
    collectgarbage()
    local base = collectgarbage("count")
    -- The peak growth (KiB) of live memory over the first `warm` chunks, and over the
    -- rest: a coder that kept what it saw would climb the whole way.
    local early, late = 0.0, 0.0
    local held = ""
    local matched = 0
    local function drain()
      while #held >= #chunk do
        assert(held:sub(1, #chunk) == chunk, name)
        held = held:sub(#chunk + 1)
        matched = matched + 1
      end
    end
    -- The decoder is fed what the encoder writes, and its output is
    -- compared with what went in, a chunk at a time and not kept.
    for round = 1, rounds do
      local text = assert(enc:update(chunk))
      held = held .. assert(dec:update(text))
      drain()
      collectgarbage()
      local grown = collectgarbage("count") - base
      if round <= warm then early = math.max(early, grown) else late = math.max(late, grown) end
    end
    local text = assert(enc:finish())
    held = held .. assert(dec:update(text)) .. assert(dec:finish())
    drain()
    assert(held == "" and matched == rounds, name)
    assert(early < 128 and late < early + 64,
      ("%s grew %.0f KiB, then %.0f KiB, over %d KiB of input"):format(
        name, early, late, #chunk * rounds // 1024))
  end
end
