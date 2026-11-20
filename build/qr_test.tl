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
