--- `cosmic codec` (build/codec.tl), run in this process with its input and
--- output stood in for: RFC 4648's test vectors in both directions for
--- each encoding, binary bytes, whitespace, wrapping, refusals with their
--- offsets, `--lenient`, standard input and a failed write.
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
  assert(late < early + 256 and late < 2048,
    ("encoding grew %.0f KiB, then %.0f KiB, over %d KiB"):format(early, late, rounds * #block // 1024))
  local plain, plain_same, plain_early, plain_late = stream({ "base64", "-d" }, encoded, rounds, block, false)
  assert(plain == rounds * #block and plain_same, "decoded bytes differ")
  assert(plain_late < plain_early + 256 and plain_late < 2048,
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
