--- `cosmic codec` (build/codec.tl), run in this process with its input and
--- output stood in for: RFC 4648's test vectors in both directions for
--- each encoding, binary bytes, whitespace, wrapping, refusals with their
--- offsets, `--lenient`, standard input and a failed write.
--- build/codec_tool_test.tl starts the program for what a process alone
--- shows.

local Fs = require("cosmic.fs")
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
