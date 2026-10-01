--- `cosmic codec` (build/codec.tl), run in this process with its input and
--- output stood in for: RFC 4648's test vectors in both directions for
--- each encoding, binary bytes, whitespace, wrapping, refusals with their
--- offsets, `--lenient`, standard input and a failed write, and the
--- streaming coders under it: each answers as [`cosmic.codec`]'s
--- whole-string functions do, however its input is cut.
--- build/codec_tool_test.tl starts the program for what a process alone
--- shows.

local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Codec = require("cosmic.codec")
local codec = require("build.codec")

local record Ran
  code: integer
  out: string
  err: string
end

--- One run: `words` after `cosmic codec`, and `stdin` standing in for
--- standard input.
local function run(words: {string}, stdin?: string): Ran
  local argv: {integer:string} = { [0] = "cosmic", [1] = "codec" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = codec.run(argv, {
    out = function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    stdin = function(): string | nil, string
      if stdin == nil then return nil, "no standard input in this test" end
      return stdin, ""
    end,
  })
  return ran
end

local PLAIN <const>: {string} = { "", "f", "fo", "foo", "foob", "fooba", "foobar" }

local VECTORS <const>: {string:{string}} = {
  hex = { "", "66", "666f", "666f6f", "666f6f62", "666f6f6261", "666f6f626172" },
  base64 = { "", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy" },
  base64url = { "", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy" },
}

local function test_rfc_4648_vectors_encode_and_decode(_tmp: string)
  for name, texts in pairs(VECTORS) do
    for index, plain in ipairs(PLAIN) do
      local enc = run({ name }, plain)
      assert(enc.code == 0 and enc.out == texts[index] .. "\n" and enc.err == "",
        name .. " " .. plain .. ": " .. enc.out .. enc.err)
      local dec = run({ name, "-d" }, texts[index])
      assert(dec.code == 0 and dec.out == plain and dec.err == "",
        name .. " -d " .. texts[index] .. ": " .. dec.out .. dec.err)
    end
  end
end

local function test_binary_bytes_including_nul_and_the_url_alphabet()
  local bytes = "\0\1\xfb\xff\xfe\0"
  assert(run({ "hex" }, bytes).out == "0001fbfffe00\n")
  assert(run({ "base64" }, bytes).out == "AAH7//4A\n")
  assert(run({ "base64url" }, bytes).out == "AAH7__4A\n")
  for _, name in ipairs({ "hex", "base64", "base64url" }) do
    local back = run({ name, "-d" }, run({ name }, bytes).out)
    assert(back.code == 0 and back.out == bytes, name)
  end
  assert(run({ "hex", "-d" }, "0A0b").out == "\n\v")
end

local function test_a_file_and_dash_are_read(tmp: string)
  local path = tmp .. "/in.bin"
  assert(Fs.write(path, "foobar"))
  assert(run({ "base64", path }).out == "Zm9vYmFy\n")
  assert(run({ "base64", "-" }, "foobar").out == "Zm9vYmFy\n")
  local missing = run({ "base64", tmp .. "/nope" })
  assert(missing.code == 2 and missing.out == "" and missing.err:find("^cosmic: codec: "), missing.err)
end

local function test_wrap_breaks_lines_and_defaults_to_none()
  local long = ("a"):rep(60)
  local plain = run({ "base64" }, long)
  assert(plain.out == run({ "base64", "--wrap", "1000" }, long).out)
  assert(select(2, plain.out:gsub("\n", "")) == 1)
  local wrapped = run({ "base64", "--wrap", "16" }, long)
  local lines = 0
  for line in wrapped.out:gmatch("([^\n]*)\n") do
    lines = lines + 1
    assert(#line <= 16 and #line > 0, line)
  end
  assert(lines == 5, wrapped.out)
  local back = run({ "base64", "-d" }, wrapped.out)
  assert(back.out == long, back.err)
  local exact = run({ "hex", "--wrap=4" }, "abcd")
  assert(exact.out == "6162\n6364\n", exact.out)
  assert(run({ "hex", "--wrap", "0" }, "a").code == 2)
  assert(run({ "hex", "--wrap", "x" }, "a").code == 2)
  assert(run({ "hex", "-d", "--wrap", "4" }, "61").code == 2)
end

local function test_decoding_ignores_ascii_whitespace()
  assert(run({ "base64", "-d" }, " Zm9v\r\nYmFy\t\n\v\f").out == "foobar")
  assert(run({ "hex", "-d" }, "66 6f\n6f").out == "foo")
  assert(run({ "base64url", "-d" }, "Zm9v\nYg\n").out == "foob")
  assert(run({ "base64", "-d" }, "Zg =\n=").out == "f")
  -- Not ASCII whitespace: NUL, and a non-breaking space.
  assert(run({ "base64", "-d" }, "Zm9v\0").code == 2)
  assert(run({ "hex", "-d" }, "66\xc2\xa06f").code == 2)
end

local function refusal(words: {string}, text: string): string
  local ran = run(words, text)
  assert(ran.code == 2 and ran.out == "", ("%s %q: %d %q"):format(table.concat(words, " "), text, ran.code, ran.out))
  assert(ran.err:find("^cosmic: codec: standard input: "), ran.err)
  return ran.err
end

local function test_invalid_characters_name_the_byte_offset()
  assert(refusal({ "hex", "-d" }, "66zz"):find("at offset 2", 1, true))
  -- Whitespace counts in the offset, as the input was given.
  assert(refusal({ "hex", "-d" }, "66\n6g"):find("at offset 4", 1, true))
  assert(refusal({ "base64", "-d" }, "Zm9v\nY-Fy"):find("at offset 6", 1, true))
  assert(refusal({ "base64url", "-d" }, "Zm+v"):find("at offset 2", 1, true))
  assert(refusal({ "base64url", "-d" }, "Zm9v_\xff"):find("at offset 5", 1, true))
end

local function test_bad_padding_and_lengths_are_refused()
  assert(refusal({ "hex", "-d" }, "666"):find("odd length", 1, true))
  assert(refusal({ "base64", "-d" }, "Zg"):find("multiple of 4", 1, true))
  assert(refusal({ "base64", "-d" }, "Zg="):find("multiple of 4", 1, true))
  assert(refusal({ "base64", "-d" }, "Z=g="):find("misplaced '=' padding at offset 1", 1, true))
  assert(refusal({ "base64", "-d" }, "Zm9v===="):find("misplaced", 1, true))
  assert(refusal({ "base64", "-d" }, "Zg==Zg=="):find("misplaced '=' padding at offset 2", 1, true))
  assert(refusal({ "base64", "-d" }, "Zh=="):find("nonzero padding bits", 1, true))
  assert(refusal({ "base64url", "-d" }, "Zm9vY"):find("one character over", 1, true))
  assert(refusal({ "base64url", "-d" }, "Zg=="):find("padding at offset 2 is not accepted", 1, true))
end

local function test_lenient_accepts_the_other_padding_spelling()
  assert(run({ "base64", "-d", "--lenient" }, "Zg").out == "f")
  assert(run({ "base64", "-d", "--lenient" }, "Zm8").out == "fo")
  assert(run({ "base64", "-d", "--lenient" }, "Zg==").out == "f")
  assert(run({ "base64url", "-d", "--lenient" }, "Zg==").out == "f")
  assert(run({ "base64url", "-d", "--lenient" }, "Zm8=").out == "fo")
  -- Still strict about everything else.
  assert(run({ "base64", "-d", "--lenient" }, "Zm9vY").code == 2)
  assert(run({ "base64", "-d", "--lenient" }, "Zh").code == 2)
  assert(run({ "base64", "-d", "--lenient" }, "Zg=").code == 2)
  assert(run({ "base64url", "-d", "--lenient" }, "Zg=").code == 2)
  assert(run({ "base64url", "-d", "--lenient" }, "Z=g").code == 2)
  assert(run({ "hex", "-d", "--lenient" }, "66").code == 2)
  assert(run({ "hex", "--lenient" }, "66").code == 2)
end

local function test_a_command_line_it_cannot_read_exits_2()
  for _, words in ipairs({
    {}, { "base32" }, { "-d" }, { "--bogus", "hex" }, { "hex", "a", "b" }, { "hex", "" },
  } as {{string}}) do
    local ran = run(words, "x")
    assert(ran.code == 2 and ran.out == "", table.concat(words, " "))
    assert(ran.err:find("^cosmic: codec: "), ran.err)
  end
  assert(run({ "base32" }).err:find("hex, base64, base64url", 1, true))
end

local function test_a_failed_write_exits_2_and_says_so()
  for _, words in ipairs({ { "hex" }, { "base64", "-d" } } as {{string}}) do
    local complaints = ""
    local argv: {integer:string} = { [0] = "cosmic", [1] = "codec" }
    for index, word in ipairs(words) do argv[index + 1] = word end
    local code = codec.run(argv, {
      out = function(_: string): boolean, string return false, "No space left on device" end,
      err = function(line: string) complaints = complaints .. line .. "\n" end,
      stdin = function(): string | nil, string return "Zm9v", "" end,
    })
    assert(code == 2, code)
    assert(complaints == "cosmic: codec: standard output: No space left on device\n", complaints)
  end
end

--- Runs `words` with standard input a Reader that gives `chunk` `rounds`
--- times over and no more, and standard output a sink that keeps only
--- what it needs to answer: the bytes written, whether they are
--- `expect` over and over (less a last newline when `newline`), and how
--- far live memory grew, in KiB, over the first few writes and over the
--- rest.
local function stream(words: {string}, chunk: string, rounds: integer, expect: string, newline: boolean):
    integer, boolean, number, number
  local sent = 0
  local input: Stream.Reader = {}
  input.read = function(_self: Stream.Reader, _max?: integer): string | nil, string
    if sent == rounds then return nil, "" end
    sent = sent + 1
    return chunk, ""
  end
  input.close = function(_self: Stream.Reader): boolean, string
    return true, ""
  end
  collectgarbage()
  collectgarbage()
  local base = collectgarbage("count")
  local written, writes = 0, 0
  local early, late = 0.0, 0.0
  local same = true
  local repeated = expect:rep(2)
  local argv: {integer:string} = { [0] = "cosmic", [1] = "codec" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local code = codec.run(argv, {
    input = function(): Stream.Reader | nil, string return input, "" end,
    out = function(text: string): boolean, string
      local body = text
      if newline and body:sub(-1) == "\n" then body = body:sub(1, -2) end
      local from = written % #expect
      if repeated:sub(from + 1, from + #body) ~= body then same = false end
      written = written + #body
      writes = writes + 1
      collectgarbage()
      local grown = collectgarbage("count") - base
      if writes <= 4 then early = math.max(early, grown) else late = math.max(late, grown) end
      return true, ""
    end,
    err = function(line: string) error(line) end,
  })
  assert(code == 0, code)
  return written, same, early, late
end

local function test_a_large_stream_is_coded_in_bounded_memory()
  -- 48 KiB, so its base64 is whole groups and repeats without padding.
  local block = string.rep("streamed bytes\n", 3 * 1024)
  assert(#block % 3 == 0 and #block <= 1 << 16)
  local encoded = Codec.base64(block)
  assert(not encoded:find("=", 1, true))
  local rounds = 40 -- about 2 MiB
  local written, same, early, late = stream({ "base64" }, block, rounds, encoded, true)
  assert(written == rounds * #encoded and same, "encoded text differs")
  assert(early < 128 and late < early + 64,
    ("encoding grew %.0f KiB, then %.0f KiB, over %d KiB"):format(early, late, rounds * #block // 1024))
  local plain, plain_same, plain_early, plain_late = stream({ "base64", "-d" }, encoded, rounds, block, false)
  assert(plain == rounds * #block and plain_same, "decoded bytes differ")
  assert(plain_early < 128 and plain_late < plain_early + 64,
    ("decoding grew %.0f KiB, then %.0f KiB"):format(plain_early, plain_late))
end

local function test_a_fault_past_the_first_chunk_names_its_offset_in_the_input()
  -- Lines of four characters and a newline: the fault lies well past
  -- the first 64 KiB read, and whitespace counts in its offset.
  local text = string.rep("Zm9v\n", 30000) .. "Zm-v\n"
  local at = #text - 3 -- the "-", 0-based
  local ran = run({ "base64", "-d" }, text)
  assert(ran.code == 2 and ran.err:find(("byte 0x2d at offset %d is not in the base64 alphabet"):format(at), 1, true),
    ran.err)
  -- What was decoded before the fault, less the chunk it lies in, was written.
  assert(#ran.out > 0 and ran.out == ("foo"):rep(#ran.out // 3), #ran.out)
  -- A fault only the end of the text shows is found at the end.
  local short = run({ "base64", "-d" }, string.rep("Zm9v", 20000) .. "Zg")
  assert(short.code == 2 and #short.out > 0, short.code)
  assert(short.err:find("multiple of 4 (at offset 80001)", 1, true), short.err)
end

--- A Reader that gives `text` a few bytes a read, one to four in turn,
--- as a pipe does.
local function trickle(text: string): Stream.Reader
  local at, turn = 1, 0
  local reader: Stream.Reader = {}
  reader.read = function(_self: Stream.Reader, max?: integer): string | nil, string
    if at > #text then return nil, "" end
    turn = turn % 4 + 1
    local piece = text:sub(at, at + math.min(turn, max or turn) - 1)
    at = at + #piece
    return piece, ""
  end
  reader.close = function(_self: Stream.Reader): boolean, string
    return true, ""
  end
  return reader
end

local function run_trickled(words: {string}, text: string): Ran
  local argv: {integer:string} = { [0] = "cosmic", [1] = "codec" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = codec.run(argv, {
    input = function(): Stream.Reader | nil, string return trickle(text), "" end,
    out = function(text_out: string): boolean, string
      ran.out = ran.out .. text_out
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
  })
  return ran
end

local function test_short_reads_do_not_release_what_a_refusal_would_take_back()
  -- A pipe gives a few bytes a read; only a whole chunk of them is held.
  local refused = run_trickled({ "base64", "-d" }, "QUJDREVG!!!!")
  assert(refused.code == 2 and refused.out == "", refused.out)
  local short = run_trickled({ "base64", "-d" }, "QUJDREVGR")
  assert(short.code == 2 and short.out == "" and short.err:find("length 9", 1, true), short.out .. short.err)
  local fine = run_trickled({ "base64", "-d" }, "QUJD REVG\nR0hJ")
  assert(fine.code == 0 and fine.out == "ABCDEFGHI", fine.err)
  local encoded = run_trickled({ "hex", "--wrap", "4" }, "hello")
  assert(encoded.out == "6865\n6c6c\n6f\n", encoded.out)
end

local function test_an_encoder_writes_as_it_reads_but_a_decoder_holds_a_chunk()
  local writes = 0
  local sent = 0
  local input: Stream.Reader = {}
  input.read = function(_self: Stream.Reader, max?: integer): string | nil, string
    if sent == 3 then return nil, "" end
    sent = sent + 1
    return ("a"):rep(max or 1), ""
  end
  input.close = function(_self: Stream.Reader): boolean, string
    return true, ""
  end
  local seen: {integer} = {}
  local code = codec.run({ [0] = "cosmic", [1] = "codec", [2] = "hex" }, {
    input = function(): Stream.Reader | nil, string return input, "" end,
    out = function(_text: string): boolean, string
      writes = writes + 1
      seen[#seen + 1] = sent
      return true, ""
    end,
    err = function(line: string) error(line) end,
  })
  assert(code == 0)
  -- Each chunk's text was written before the next was read.
  assert(seen[1] == 1 and seen[2] == 2 and seen[3] == 3, tostring(seen[1]))
end

local function test_no_input_given_is_an_error_not_a_crash()
  local complaint = ""
  local code = codec.run({ [0] = "cosmic", [1] = "codec", [2] = "hex" }, {
    out = function(_text: string): boolean, string return true, "" end,
    err = function(line: string) complaint = line end,
  })
  assert(code == 2 and complaint:find("^cosmic: codec: "), complaint)
end

local NAMES <const>: {codec.Name} = { "hex", "base64", "base64url" }

--- The whole-string decoder for each encoding.
local function whole_decode(name: codec.Name, text: string): string | nil, string
  if name == "hex" then return Codec.unhex(text) end
  if name == "base64" then return Codec.unbase64(text) end
  return Codec.unbase64url(text)
end

local function whole_encode(name: codec.Name, bytes: string): string
  if name == "hex" then return Codec.hex(bytes) end
  if name == "base64" then return Codec.base64(bytes) end
  return Codec.base64url(bytes)
end

--- What `coder` answers to `pieces` in turn and then `finish`: the
--- output joined, or nil and the reason.
local function through(coder: codec.Coder, pieces: {string}): string | nil, string
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
        local got, why = through(codec.encoder(name), pieces)
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
        local got, why = through(codec.decoder(name), pieces)
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
    local name, text = case[1] as codec.Name, case[2]
    local bytes, want = whole_decode(name, text)
    assert(bytes == nil and want ~= "", name .. " " .. text)
    for _, pieces in ipairs(cuts(text)) do
      local got, why = through(codec.decoder(name), pieces)
      assert(got == nil and why == want,
        ("%s cut %q: %q, want %q"):format(name, table.concat(pieces, "|"), tostring(why), want))
    end
  end
end

local function test_offsets_are_absolute_across_chunks()
  local function refused(name: codec.Name, pieces: {string}): string
    local got, why = through(codec.decoder(name), pieces)
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
  for _, make in ipairs({ codec.encoder, codec.decoder }) do
    local c = make("base64")
    assert(c:update("") == "" and c:finish() == "")
    assert(not pcall(c.update, c, "x"))
    assert(not pcall(c.finish, c))
  end
  local bad = codec.decoder("hex")
  assert(bad:update("z") == "")
  assert(bad:finish() == nil)
  assert(not pcall(bad.finish, bad))
  assert(not pcall(codec.encoder, "base32" as codec.Name))
  assert(not pcall(codec.decoder, "base32" as codec.Name))
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
    local enc, dec = codec.encoder(name), codec.decoder(name)
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
