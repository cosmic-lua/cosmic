local TermFilter = require("build.term_filter")

--- What a filter passes and answers for `input` fed whole.
local function whole(input: string): string, string
  local filter = TermFilter.new()
  return filter:feed(input)
end

--- The same, fed in the pieces `cuts` ends (offsets into `input`).
local function pieces(input: string, cuts: {integer}): string, string
  local filter = TermFilter.new()
  local passed, answered: {string}, {string} = {}, {}
  local from = 1
  for _, cut in ipairs(cuts) do
    local out, replies = filter:feed(input:sub(from, cut))
    passed[#passed + 1], answered[#answered + 1] = out, replies
    from = cut + 1
  end
  local out, replies = filter:feed(input:sub(from))
  passed[#passed + 1], answered[#answered + 1] = out, replies
  return table.concat(passed), table.concat(answered)
end

--- Asserts that `input` gives `passed` and `answered` however it is cut:
--- whole, in two pieces at every offset, and a byte at a time.
local function check(name: string, input: string, passed: string, answered?: string)
  answered = answered or ""
  local out, replies = whole(input)
  assert(out == passed, name .. ": passed " .. string.format("%q", out) .. ", not " ..
      string.format("%q", passed))
  assert(replies == answered, name .. ": answered " .. string.format("%q", replies))
  for cut = 0, #input do
    local split_out, split_replies = pieces(input, { cut })
    assert(split_out == passed and split_replies == answered,
      name .. ": cut at " .. cut .. " passed " .. string.format("%q", split_out))
  end
  local every: {integer} = {}
  for cut = 1, #input do every[cut] = cut end
  local byte_out, byte_replies = pieces(input, every)
  assert(byte_out == passed and byte_replies == answered, name .. ": a byte at a time")
end

--- Asserts what `check` does of an input too long to cut at every offset:
--- whole, and in halves.
local function check_long(name: string, input: string, passed: string)
  local out = whole(input)
  assert(out == passed, name .. ": passed " .. #out .. " bytes")
  for _, cut in ipairs({ 1, #input // 2, #input - 1 }) do
    out = pieces(input, { cut })
    assert(out == passed, name .. ": cut at " .. cut)
  end
end

--- Text and the controls that pass, and the CSI and ESC sequences listed.
local function test_what_passes()
  local same: {string:string} = {
    text = "hello, world 0123 ~!",
    utf8 = "caf\u{e9} \u{4e2d}\u{6587} \u{1f600} \u{a0} \u{10ffff} \u{d7ff} \u{e000}",
    controls = "a\r\nb\tc\8d\7e",
    sgr = "\27[1;31m\27[0m\27[m\27[38;2;10;20;30m\27[48;5;200m\27[4:3m\27[;m",
    up = "\27[A\27[5B\27[12C\27[3D\27[2E\27[F\27[7G\27[4d",
    position = "\27[H\27[2;3H\27[;5H\27[2;f\27[10;10f",
    erase = "\27[J\27[0J\27[1J\27[2J\27[3J\27[K\27[1K\27[2K",
    region = "\27[r\27[1;24r",
    edit = "\27[L\27[3M\27[2P\27[4@\27[5X",
    save = "\27[s\27[u\27" .. "7\27" .. "8",
    modes = "\27[?25l\27[?25h\27[?1049h\27[?1049l\27[?47h\27[?1047l\27[?2004h\27[?1h\27[?7l" ..
      "\27[?25;7h",
  }
  for name, text in pairs(same) do check(name, text, text) end
  check("mixed", "a\27[1mb\27[0m\nc", "a\27[1mb\27[0m\nc")
end

--- OSC, DCS and the other strings, and every other ESC sequence.
local function test_strings_and_escapes_are_dropped()
  check("osc 52 clipboard", "a\27]52;c;aGVsbG8=\7b", "ab")
  check("osc 52 query", "a\27]52;c;?\27\\b", "ab")
  check("osc title", "\27]0;title\7\27]2;t\27\\x", "x")
  check("osc 8 link", "\27]8;;http://x\7link\27]8;;\7", "link")
  check("dcs", "a\27Pq#0;2;0;0;0\27\\b", "ab")
  check("apc", "a\27_Gf=100;AAAA\27\\b", "ab")
  check("pm", "a\27^private\27\\b", "ab")
  check("sos", "a\27Xstring\27\\b", "ab")
  check("a bel does not end a dcs", "a\27Pq\7still\27\\b", "ab")
  check("reset", "a\27cb", "ab")
  check("charset", "a\27(0\27)B\27*A\27+Bb", "ab")
  check("seven-bit c1", "a\27D\27E\27H\27M\27N\27O\27Z\27\\b", "ab")
  check("keypad", "a\27=\27>b", "ab")
  check("a lone esc", "a\27", "a")
  check("esc esc", "a\27\27[1mb", "a\27[1mb")
  check("string cut by esc starts a sequence", "\27]0;t\27[1mY", "\27[1mY")
  check("string cut by can", "\27]0;t\24Y", "Y")
  check("string cut by sub", "\27Pt\26Y", "Y")
end

local function test_other_csi_is_dropped()
  check("mouse", "a\27[?1000h\27[?1006hb", "ab")
  check("insert mode", "a\27[4h\27[20hb", "ab")
  check("a mode not listed among listed", "a\27[?25;1000hb", "ab")
  check("an empty mode", "a\27[?hb", "ab")
  check("a mode with a colon", "a\27[?25:7hb", "ab")
  check("too many modes", "a\27[?" .. ("25;"):rep(8) .. "25hb", "ab")
  check("eight modes", "\27[?" .. ("25;"):rep(7) .. "25h", "\27[?" .. ("25;"):rep(7) .. "25h")
  check("private mode report", "a\27[?25$pb", "ab")
  check("window ops", "a\27[8;24;80t\27[21tb", "ab")
  check("scroll", "a\27[2S\27[2Tb", "ab")
  check("intermediate", "a\27[1 q\27[!p\27[\"qb", "ab")
  check("kitty keyboard", "a\27[>1u\27[?u\27[=5;1ub", "ab")
  check("private prefix on a movement", "a\27[?5Ab", "ab")
  check("private prefix on sgr", "a\27[>4;1mb", "ab")
  check("prefix after a parameter", "a\27[1?hb", "ab")
  check("three coordinates", "a\27[1;2;3Hb", "ab")
  check("two movement parameters", "a\27[1;2Ab", "ab")
  check("erase out of range", "a\27[9J\27[3K\27[?2Jb", "ab")
  check("save with parameters", "a\27[1s\27[2ub", "ab")
  check("colon in a movement", "a\27[1:2Hb", "ab")
  check("device status", "a\27[5nb", "ab")
  check("secondary attributes", "a\27[>c\27[=c\27[1cb", "ab")
  check("remote report", "a\27[1;1Rb", "ab")
  check("title stack", "a\27[22;0t\27[23;0tb", "ab")
  check("a number of too many digits", "a\27[123456Ab\27[1;999999Hc\27[1;123456md", "abcd")
  check("six digits is the most refused, five pass", "\27[12345A", "\27[12345A")
end

local function test_c1_controls_are_dropped()
  check("8-bit csi", "a\155 31mb", "a 31mb")
  check("8-bit osc", "a\157 0;t\156b", "a 0;t" .. "b")
  check("every raw c1", "a\128\129\130\140\144\152\155\156\157\158\159b", "ab")
  check("utf-8 c1 csi", "a\u{9b}31mb", "a31mb")
  check("utf-8 c1 osc and st", "a\u{9d}0;t\u{9c}b", "a0;tb")
  check("every utf-8 c1", "a\u{80}\u{85}\u{8f}\u{90}\u{98}\u{9e}\u{9f}b", "ab")
  check("the first character past c1", "\u{a0}\u{a1}", "\u{a0}\u{a1}")
end

local function test_invalid_utf8_is_dropped()
  check("overlong slash", "a\192\175b", "ab")
  check("overlong three", "a\224\128\175b", "ab")
  check("overlong four", "a\240\128\128\175b", "ab")
  check("surrogate", "a\237\160\128b", "ab")
  check("past the last", "a\244\144\128\128b", "ab")
  check("lead past the last", "a\245\128\128\128\255b", "ab")
  check("stray continuation", "a\128\191b", "ab")
  check("cut character", "a\226\130b", "ab")
  check("cut character at the end", "a\226\130", "a")
  check("cut by an escape", "a\226\130\27[1mb", "a\27[1mb")
  check("cut by a lead", "a\226\130\226\130\172b", "a\u{20ac}b")
end

local function test_other_controls_are_dropped()
  check("c0", "a\0\1\2\3\4\5\6\11\12\14\15\16\17\20\21\22\23\25\28\29\30\31b", "ab")
  check("delete", "a\127b", "ab")
  check("cancel in text", "a\24\26b", "ab")
end

local function test_a_sequence_cut_short_is_dropped_whole()
  check("csi cut by newline", "a\27[1;\nb", "a\nb")
  check("csi cut by bel", "a\27[1\7b", "a\7b")
  check("csi cut by esc", "a\27[1\27[2Jb", "a\27[2Jb")
  check("csi cut by can", "a\27[1;2\24b", "ab")
  check("csi cut by sub", "a\27[1;2\26b", "ab")
  check("csi cut by a lead", "a\27[1\226\130\172b", "a\u{20ac}b")
  check("csi cut by a raw c1", "a\27[1\155b", "ab")
  check("esc cut by newline", "a\27\nb", "a\nb")
  check("esc cut by can", "a\27\24b", "ab")
  check("esc intermediates cut", "a\27(\27[1mb", "a\27[1mb")
  check("ignored csi cut by newline", "a\27[1 \nb", "a\nb")
  check("ignored csi ends at its final", "a\27[1 qb", "ab")
  check("ignored csi swallows an out-of-place parameter", "a\27[1 2Hb", "ab")
end

local function test_parameters_are_bounded()
  local ok_text = "\27[" .. ("1;"):rep(31) .. "1m"
  check("thirty-two sgr parameters", ok_text, ok_text)
  check("thirty-three sgr parameters", "a\27[" .. ("1;"):rep(32) .. "1mb", "ab")
  local long = ("1"):rep(128)
  check("past the byte bound", "a\27[" .. ("1;"):rep(128) .. "mb", "ab")
  check("a long number", "a\27[" .. long .. "mb", "ab")
  check_long("a long run is dropped to its final", "a\27[" .. ("9"):rep(100000) .. "mb", "ab")
  check("a run past the bound in two pieces", "a\27[" .. ("9"):rep(100) .. ("9"):rep(100) .. "mb", "ab")
  check("an ignored sequence is not a prefix of the next", "\27[" .. ("1;"):rep(200) .. "Hb", "b")
end

local function test_queries_are_answered_and_not_passed()
  check("cursor position", "a\27[6nb", "ab", "\27[1;1R")
  check("device attributes", "a\27[cb", "ab", "\27[?1;2c")
  check("device attributes zero", "a\27[0cb", "ab", "\27[?1;2c")
  check("two queries", "\27[6n\27[c\27[6n", "", "\27[1;1R\27[?1;2c\27[1;1R")
  check("not a query", "a\27[?6nb\27[06nb\27[6;1nc", "abbc")
end

local function test_restore_returns_the_terminal_to_where_it_started()
  local filter = TermFilter.new()
  assert(filter:restore() == "")
  filter:feed("\27[?25l\27[?1049h\27[?2004h\27[?7l\27[1m\27[1;5r\27[?1h\27[?1l")
  local restored = filter:restore()
  assert(restored == "\27[0m\27[r\27[?7h\27[?25h\27[?1049l\27[?2004l", string.format("%q", restored))
  assert(filter:restore() == "")
  filter:feed("\27[0m\27[?25h\27[?25l\27[?25h")
  assert(filter:restore() == "")
  filter:feed("\27[1")
  filter:restore()
  local out = filter:feed("mx")
  assert(out == "mx", "a sequence held at restore is dropped")
end

--- A hostile stream costs what its length does: a megabyte of each of
--- the shapes that a scan from the start would square.
local function test_long_streams_are_linear()
  local filter = TermFilter.new()
  local megabyte = ("x"):rep(1024 * 1024)
  local out = filter:feed("\27]0;" .. megabyte .. "\7ok")
  assert(out == "ok")
  out = filter:feed("\27[" .. ("1;"):rep(512 * 1024) .. "mok")
  assert(out == "ok")
  out = filter:feed("\27[" .. megabyte:gsub("x", "9") .. "Hok")
  assert(out == "ok")
  out = filter:feed("\27Pq" .. megabyte)
  assert(out == "")
  out = filter:feed("\27\\ok")
  assert(out == "ok")
  out = filter:feed(("\27[1m"):rep(100000))
  assert(#out == 4 * 100000)
  out = filter:feed(("\27"):rep(200000) .. "\n")
  assert(out == "\n")
  out = filter:feed(("\226\130"):rep(200000))
  assert(out == "")
  -- A megabyte fed a byte at a time costs a call each.
  local slow = TermFilter.new()
  local passed = 0
  for at = 1, 100000 do passed = passed + #slow:feed(megabyte:sub(at, at)) end
  assert(passed == 100000)
end
