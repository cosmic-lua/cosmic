local Failure = require("cosmic.failure")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy{}

local function test_the_text_names_the_path_then_the_message()
  assert(tostring(Failure.new("not a number")) == "not a number")
  assert(tostring(Failure.new("not a number", "a.conf")) == "a.conf: not a number")
  local made = Failure.new("x")
  assert(made.errno == 0 and made.path == nil)
end

--- A failure at a place in a text names it as a compiler does where a
--- path is known, and after the words where none is.
local function test_a_failure_at_a_place_names_it()
  local quoted = Failure.at("csv: unclosed quote opened", 3, 5)
  assert(quoted.line == 3 and quoted.column == 5 and quoted.errno == 0)
  assert(tostring(quoted) == "csv: unclosed quote opened at line 3, column 5", tostring(quoted))
  assert(tostring(Failure.at("no root element", 7)) == "no root element at line 7")
  assert(tostring(Failure.at("bad", 3, 5, "a.csv")) == "a.csv:3:5: bad")
  assert(tostring(Failure.at("bad", 3, nil, "a.csv")) == "a.csv:3: bad")
end

local function test_a_system_failure_keeps_its_errno_and_words()
  local made = Failure.system(sys.ENOENT, "/nowhere")
  assert(made.errno == sys.ENOENT)
  assert(made.message == sys.errno_message(sys.ENOENT))
  assert(tostring(made) == "/nowhere: " .. sys.errno_message(sys.ENOENT), tostring(made))
end

--- What a function that returns a value or a failure does with one: the
--- caller tests the cause by its errno and reads the text by `tostring`.
local function open(path: string): (integer) | (nil, Failure)
  local fd, _, errno = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, Failure.system(errno, path)
  end
  return fd
end

local function test_a_caller_tells_the_cause_by_its_errno(tmp: string)
  local fd, why = open(tmp .. "/absent")
  if fd ~= nil then
    error("opened a path that is not there")
  end
  assert(why.errno == sys.ENOENT, tostring(why))
  assert(why.path == tmp .. "/absent")
  assert(tostring(why):find(": No such file or directory", 1, true) ~= nil, tostring(why))
end

local function test_a_raised_failure_reads_as_its_text()
  local ok, raised = pcall(function()
    error(Failure.new("refused", "here"))
  end)
  assert(not ok and tostring(raised) == "here: refused", tostring(raised))
end

--- Each constructor gives its kind, so a caller acts on the cause without
--- reading the words.
local function test_each_constructor_gives_its_kind()
  assert(Failure.new("x").kind == "other")
  assert(Failure.at("x", 1).kind == "parse")
  assert(Failure.system(sys.ENOENT).kind == "system")
  assert(Failure.coded("busy", 5).kind == "library")
  assert(Failure.coded("busy", 5, 5, "library").kind == "library")
  local stopped = Failure.coded("interrupted", 9, 9, "cancelled")
  assert(stopped.kind == "cancelled" and stopped.code == 9 and stopped.extended_code == 9)
  assert(Failure.coded("interrupted", 9, 9, "timeout").kind == "timeout")
end

local function test_a_timeout_and_a_cancel_say_what_they_are()
  local late = Failure.timeout()
  assert(late.kind == "timeout" and late.errno == 0 and tostring(late) == "timed out", tostring(late))
  assert(tostring(Failure.timeout("connect", "db.sock")) == "db.sock: connect")
  local stopped = Failure.cancelled()
  assert(stopped.kind == "cancelled" and tostring(stopped) == "cancelled", tostring(stopped))
  assert(tostring(Failure.cancelled("lookup")) == "lookup")
end

local function test_a_mismatch_says_what_it_is()
  local wrong = Failure.mismatch("sha256 mismatch: want a, got b", "out.bin")
  assert(wrong.kind == "mismatch" and wrong.errno == 0 and tostring(wrong) == "out.bin: sha256 mismatch: want a, got b",
    tostring(wrong))
end

--- A caller's `match` over the kind covers every one, so a kind added
--- later is a checker error at each place that must handle it.
local function test_a_match_over_the_kind_is_exhaustive()
  local function retry(why: Failure): boolean
    match why.kind do
    | "timeout" then return true
    | "cancelled" then return false
    | "other" then return false
    | "system" then return false
    | "parse" then return false
    | "library" then return false
    | "mismatch" then return false
    end
  end
  assert(retry(Failure.timeout()) and not retry(Failure.cancelled()))
end

--- A system call that timed out is a timeout by its kind, its errno kept.
local function test_a_system_timeout_is_a_timeout()
  local errno = 0
  for n = 1, 200 do
    if sys.errno_name(n) == "ETIMEDOUT" then errno = n end
  end
  assert(errno ~= 0, "no ETIMEDOUT")
  local late = Failure.system(errno)
  assert(late.kind == "timeout" and late.errno == errno)
end

local function test_within_adds_what_was_being_done_and_keeps_the_cause()
  local timeout = Failure.timeout()
  local within = Failure.within(timeout, "tar: add_file")
  assert(within.kind == "timeout" and within.errno == 0 and within.path == nil, within.kind)
  assert(tostring(within) == "tar: add_file: timed out", tostring(within))
  assert(timeout.message == "timed out", timeout.message)
  local missing = Failure.within(Failure.system(sys.ENOENT, "/nowhere"), "reading")
  assert(missing.kind == "system" and missing.errno == sys.ENOENT and missing.path == "/nowhere")
  assert(tostring(missing) == "/nowhere: reading: " .. sys.errno_message(sys.ENOENT), tostring(missing))
  local placed = Failure.within(Failure.at("bad", 3, 5), "csv")
  assert(placed.kind == "parse" and placed.line == 3 and placed.column == 5)
  local coded = Failure.within(Failure.coded("busy", 5, 261, "cancelled"), "query")
  assert(coded.kind == "cancelled" and coded.code == 5 and coded.extended_code == 261)
end
