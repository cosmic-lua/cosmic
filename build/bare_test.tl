--- What the bare verbs share (build/bare.tl): the complaint prefix, the
--- exit codes, a lost write, the escape of a control byte, the redaction
--- of a URL. Reading a terminal is refused where a pty stands in for one,
--- which a test here has none of: the verbs' own tool tests cover it.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local bare = require("build.bare")

local function test_the_exit_codes_are_zero_one_two()
  assert(bare.ok == 0 and bare.failed == 1 and bare.refused == 2)
end

local function test_an_empty_file_name_has_one_wording()
  assert(bare.empty_file == "an empty file name")
end

local function test_a_complaint_carries_the_verb_name()
  local lines: {string} = {}
  local complain = bare.complainer("json", function(line: string) lines[#lines + 1] = line end)
  complain("no such thing")
  complain("")
  assert(lines[1] == "cosmic: json: no such thing", lines[1])
  assert(lines[2] == "cosmic: json: ", lines[2])
end

local function test_standard_output_takes_nothing_without_failing()
  local ok, _ = bare.out("")
  assert(ok)
end

local function test_a_lost_write_complains_once_and_answers_false()
  local lines: {string} = {}
  local complain = bare.complainer("hash", function(line: string) lines[#lines + 1] = line end)
  assert(bare.delivered(complain, true, "") == true)
  assert(#lines == 0)
  assert(bare.delivered(complain, false, "Broken pipe") == false)
  assert(#lines == 1 and lines[1] == "cosmic: hash: standard output: Broken pipe", lines[1])
end

local function test_the_lost_write_message_names_standard_output()
  assert(bare.lost("Bad file descriptor") == "standard output: Bad file descriptor")
end

local function test_written_is_zero_or_two()
  local lines: {string} = {}
  local complain = bare.complainer("rand", function(line: string) lines[#lines + 1] = line end)
  assert(bare.written(complain, true, "") == 0 and #lines == 0)
  assert(bare.written(complain, false, "No space left on device") == 2)
  assert(lines[1] == "cosmic: rand: standard output: No space left on device", lines[1])
end

local function test_standard_input_is_read_unless_it_is_a_terminal()
  if Proc.is_tty(Fs.stdin) then
    local reader, why = bare.stdin_reader("give a file")
    assert(reader == nil and why == "give a file")
    local text, text_why = bare.stdin_text("pipe it")
    assert(text == nil and text_why == "pipe it")
    return
  end
  local reader, why = bare.stdin_reader("give a file")
  assert(reader ~= nil and why == "", why)
  local _, _ = reader:close()
end

local function test_every_control_byte_becomes_hex()
  for code = 0, 31 do
    local byte = string.char(code)
    assert(bare.escape(byte) == string.format("\\x%02X", code), "byte " .. code)
  end
  assert(bare.escape("\127") == "\\x7F")
end

local function test_plain_text_and_high_bytes_pass_through()
  assert(bare.escape("") == "")
  assert(bare.escape("plain text: ~ {}") == "plain text: ~ {}")
  assert(bare.escape("caf\xC3\xA9") == "caf\xC3\xA9")
  -- Invalid UTF-8 and the C1 range are not a terminal's business here.
  assert(bare.escape("\xFF\xFE\x80\x9B") == "\xFF\xFE\x80\x9B")
  assert(bare.escape("a\0b") == "a\\x00b")
end

local function test_backslash_is_left_alone_unless_named()
  assert(bare.escape("a\\b") == "a\\b")
  assert(bare.escape("a\\b", { keep_tab_newline = true }) == "a\\b")
  assert(bare.escape("a\\b", { named = true }) == "a\\\\b")
end

local function test_named_escapes_spell_the_common_four()
  local named: bare.EscapeOptions = { named = true }
  assert(bare.escape("\t\n\r\\", named) == "\\t\\n\\r\\\\")
  assert(bare.escape("\1\27\127\0", named) == "\\x01\\x1B\\x7F\\x00")
  for code = 0, 31 do
    local byte = string.char(code)
    local want = ({ [9] = "\\t", [10] = "\\n", [13] = "\\r" })[code] or string.format("\\x%02X", code)
    assert(bare.escape(byte, named) == want, "byte " .. code)
  end
end

local function test_keep_tab_newline_leaves_the_tab_and_newline()
  local keep: bare.EscapeOptions = { keep_tab_newline = true }
  assert(bare.escape("a\tb", keep) == "a\tb")
  assert(bare.escape("a\nb\rc\27[31m\127\11\0", keep) == "a\nb\\x0Dc\\x1B[31m\\x7F\\x0B\\x00")
  assert(bare.escape("a\tb") == "a\\x09b")
  assert(bare.escape("a\nb") == "a\\x0Ab")
end

-- An oracle written out apart from `escape`'s patterns: each of the 256
-- bytes, alone, in each spelling, is what the verbs' own escapes made of it
-- before they shared this one.
local function test_each_single_byte_escapes_as_it_always_did()
  local common: {integer:string} = { [9] = "\\t", [10] = "\\n", [13] = "\\r" }
  for code = 0, 255 do
    local byte = string.char(code)
    local control = code < 32 or code == 127
    local hex = string.format("\\x%02X", code)
    local plain = control and hex or byte
    local named = code == 92 and "\\\\" or (control and (common[code] or hex) or byte)
    local kept = (code == 9 or code == 10) and byte or plain
    assert(bare.escape(byte) == plain, "plain " .. code)
    assert(bare.escape(byte, { named = true }) == named, "named " .. code)
    assert(bare.escape(byte, { keep_tab_newline = true }) == kept, "keep " .. code)
  end
end

local function test_escaped_text_holds_no_control_byte()
  local all: {string} = {}
  for code = 0, 255 do all[#all + 1] = string.char(code) end
  local text = table.concat(all)
  local options: {bare.EscapeOptions} = { {}, { named = true }, { keep_tab_newline = true } }
  for _, each in ipairs(options) do
    local safe = bare.escape(text, each)
    local kept = each.keep_tab_newline and "[\0-\8\11-\31\127]" or "[\0-\31\127]"
    assert(not safe:find(kept), "a control byte survived")
  end
end

local function test_a_url_loses_its_userinfo()
  assert(bare.redact_url("https://user:pw@example.com/a?b#c") == "https://***@example.com/a?b#c")
  assert(bare.redact_url("http://token@host:8080") == "http://***@host:8080")
  assert(bare.redact_url("https://a:b@c@host/p") == "https://***@host/p")
  assert(bare.redact_url("https://@host/") == "https://***@host/")
end

local function test_a_url_without_userinfo_is_unchanged()
  assert(bare.redact_url("https://example.com/a@b") == "https://example.com/a@b")
  assert(bare.redact_url("https://example.com?x=a@b") == "https://example.com?x=a@b")
  assert(bare.redact_url("example.com") == "example.com")
  assert(bare.redact_url("") == "")
  assert(bare.redact_url("not a url@x") == "not a url@x")
  assert(bare.redact_url("mailto:me@example.com") == "mailto:me@example.com")
end
