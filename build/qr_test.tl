--- `cosmic qr` (build/qr.tl), run in this process with its input and
--- output stood in for: the text from words or standard input, what each
--- option draws, and what it refuses. build/qr_tool_test.tl starts the
--- program for what a process alone shows.

local Qr = require("cosmic.qr")
local qr = require("build.qr")

local record Ran
  mut code: integer
  mut out: string
  mut err: string
  mut written: {string: string}
end

local function run(words: {string}, stdin?: string, write_fails?: boolean): Ran
  local argv: mut {string} = { "qr" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local written: mut {string: string} = {}
  local ran: Ran = { code = -1, out = "", err = "", written = written }
  ran.code = qr.run(argv, {
    out = function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    stdin = function(): string?, string
      if stdin == nil then return nil, "no standard input in this test" end
      return stdin, ""
    end,
    write = function(path: string, data: string): boolean, string
      if write_fails == true then return false, path .. ": no room" end
      written[path] = data
      return true, ""
    end,
    read = function(path: string): string?, string
      local data = written[path]
      if data == nil then return nil, path .. ": no such file" end
      return data, ""
    end,
  })
  return ran
end

local function test_the_words_joined_by_spaces_are_the_text()
  local ran = run({ "hello", "world" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out == Qr.text((assert(Qr.encode("hello world")))), ran.out)
end

local function test_standard_input_less_one_newline_is_the_text()
  for _, piped in ipairs({ "https://example.com/\n", "https://example.com/\r\n", "https://example.com/" }) do
    local ran = run({}, piped)
    assert(ran.code == 0 and ran.out == Qr.text((assert(Qr.encode("https://example.com/")))), ran.err)
  end
  local two = run({}, "a\n\n")
  assert(two.out == Qr.text((assert(Qr.encode("a\n")))), "only one newline goes")
  for _, empty in ipairs({ "", "\n" }) do
    local ran = run({}, empty)
    assert(ran.code == 2 and ran.out == "" and ran.err:find("the text is empty", 1, true) ~= nil, ran.err)
  end
  assert(run({ "" }).code == 2, "an empty word is an empty text")
  local none = run({})
  assert(none.code == 2 and none.out == "" and none.err == "cosmic: qr: no standard input in this test\n", none.err)
end

local function test_the_options_reach_the_drawing()
  local code = assert(Qr.encode("x", { level = "H" }))
  local ran = run({ "--level", "h", "--quiet", "1", "--invert", "--ascii", "x" })
  assert(ran.code == 0 and ran.out == Qr.text(code, { quiet = 1, invert = true, ascii = true }), ran.err)
  local printed = run({ "--svg", "-", "--scale", "2", "--title", "an x", "--level", "H", "--quiet", "0", "x" })
  assert(printed.code == 0 and printed.out == Qr.svg(code, { quiet = 0, scale = 2, title = "an x" }) .. "\n",
    printed.out)
  local written = run({ "--svg", "code.svg", "--level", "H", "x" })
  assert(written.code == 0 and written.out == "" and written.written["code.svg"] == Qr.svg(code) .. "\n")
end

local function test_a_text_that_starts_with_a_dash_follows_two_dashes()
  local ran = run({ "--", "-x" })
  assert(ran.code == 0 and ran.out == Qr.text((assert(Qr.encode("-x")))), ran.err)
end

local function test_a_text_too_large_is_exit_1()
  local ran = run({ "--max-version", "1", string.rep("a", 15) })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err == "cosmic: qr: the text is 15 bytes, and a version 1 code at level M holds 14\n", ran.err)
  assert(run({ "--max-version", "1", string.rep("a", 14) }).code == 0)
end

local function test_a_command_line_it_refuses_is_exit_2()
  local refused: {{string}} = {
    { "--level", "X", "x" }, { "--max-version", "41", "x" }, { "--max-version", "0", "x" },
    { "--quiet", "17", "x" }, { "--quiet", "-1", "x" }, { "--scale", "2", "x" }, { "--title", "t", "x" },
    { "--svg", "-", "--invert", "x" }, { "--svg", "-", "--ascii", "x" }, { "--svg", "", "x" },
    { "--svg", "-", "--scale", "0", "x" }, { "--nosuch", "x" },
  }
  for _, words in ipairs(refused) do
    local ran = run(words)
    local line = table.concat(words, " ")
    assert(ran.code == 2 and ran.out == "", line)
    assert(ran.err:find("^cosmic: qr: ") ~= nil and ran.err:find("; cosmic qr ", 1, true) ~= nil, line .. ": " .. ran.err)
  end
end

local function test_a_write_that_fails_is_exit_2()
  local ran = run({ "--svg", "code.svg", "x" }, nil, true)
  assert(ran.code == 2 and ran.err == "cosmic: qr: code.svg: no room\n", ran.err)
end

local function test_read_prints_the_text_of_each_drawing()
  local text = "https://example.com/ ✓"
  local drawings: {{string}} = { { "--invert" }, { "--ascii", "--quiet", "0" }, {} }
  for _, words in ipairs(drawings) do
    local argv: mut {string} = {}
    for _, word in ipairs(words) do argv[#argv + 1] = word end
    argv[#argv + 1] = text
    local drawn = run(argv)
    local read = run({ "--read" }, drawn.out)
    assert(read.code == 0 and read.out == text .. "\n" and read.err == "", read.err)
    local dashed = run({ "--read", "-" }, drawn.out)
    assert(dashed.code == 0 and dashed.out == text .. "\n", dashed.err)
  end
  local svg = run({ "--svg", "-", "--level", "H", text })
  local from_svg = run({ "--read" }, svg.out)
  assert(from_svg.code == 0 and from_svg.out == text .. "\n", from_svg.err)
end

local function test_read_refuses_options_and_what_is_no_code()
  local refused: {{string}} = { { "--read", "--invert" }, { "--read", "--svg", "-" }, { "--read", "a", "b" },
    { "--read", "" }, { "--read", "--level", "H" } }
  for _, words in ipairs(refused) do
    local ran = run(words, "")
    assert(ran.code == 2 and ran.out == "" and ran.err:find("^cosmic: qr: ") ~= nil, table.concat(words, " "))
  end
  local missing = run({ "--read", "nosuch.svg" })
  assert(missing.code == 2 and missing.err == "cosmic: qr: nosuch.svg: no such file\n", missing.err)
  local none = run({ "--read" }, "not a code\n")
  assert(none.code == 1 and none.out == "", none.out)
  assert(none.err == 'cosmic: qr: line 1 holds "no", where a module is ## or two spaces\n', none.err)
end
