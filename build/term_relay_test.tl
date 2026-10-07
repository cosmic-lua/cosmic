local TermRelay = require("build.term_relay")
local sys = require("cosmic.sys")

--- A caller none of whose standard streams is a terminal is refused before
--- anything starts, naming it: there is no terminal to relay or to restore.
local function test_a_relay_needs_a_terminal()
  local null = assert(sys.open("/dev/null", sys.O_RDWR))
  local result, why = TermRelay.run({ "/bin/true" }, {}, { input = null, output = null, error = null })
  assert(result == nil)
  assert(why:find("is a terminal", 1, true), why)
  assert(sys.close(null))
end

--- The lines a notes pipe carries are written whole, each ending in CR LF
--- (the caller's terminal is raw), whatever the chunks they arrive in.
local function test_note_lines_are_whole_lines_ending_in_cr_lf()
  local first = TermRelay.note_lines("", "relay: #1 allowed\nrelay: #2 ref")
  assert(first.text == "relay: #1 allowed\r\n" and first.tail == "relay: #2 ref", first.text .. "|" .. first.tail)
  local second = TermRelay.note_lines(first.tail, "used\n")
  assert(second.text == "relay: #2 refused\r\n" and second.tail == "", second.text)
  local none = TermRelay.note_lines("", "half a line")
  assert(none.text == "" and none.tail == "half a line", "a tail is kept, not written")
  local two = TermRelay.note_lines("", "a\n\nb\n")
  assert(two.text == "a\r\n\r\nb\r\n" and two.tail == "", two.text)
  -- A tail flushed at the end is a line of its own.
  assert(TermRelay.note_lines("rest", "\n").text == "rest\r\n")
end

--- What a terminal could act on is shown as "?": the pipe carries all of the
--- relay's standard error, which a traceback or a program's bytes could fill.
local function test_note_lines_show_no_byte_a_terminal_could_act_on()
  local seen = TermRelay.note_lines("", "a\27[2Jb\r\0c\127d\255e\tf\n")
  assert(seen.text == "a?[2Jb??c?d?e?f\r\n", string.format("%q", seen.text))
  assert(not seen.text:find("[%z\1-\9\11-\12\14-\31\127-\255]"), "nothing but CR LF is a control")
end

--- A line that never ends is not held for ever.
local function test_a_line_that_never_ends_is_written_as_a_line_past_what_a_screen_holds()
  local long = ("x"):rep(9000)
  local seen = TermRelay.note_lines("", long)
  assert(seen.text == long .. "\r\n" and seen.tail == "", "the long line is written whole")
  assert(TermRelay.note_lines("", ("x"):rep(8000)).tail ~= "", "a shorter one waits")
end
