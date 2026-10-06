--- [`build.c_functions.tally`] against made-up functions and hits, so the
--- rules hold whatever C the core has today.

local type Coverage = require("cosmic.coverage")
local type host_requires = require("build.host_requires")
local c_functions = require("build.c_functions")

local function fn(path: string, line: integer, name: string): Coverage.Function
  return { path = path, line = line, name = name }
end

local function test_a_function_is_entered_when_its_line_is_hit()
  local tally = c_functions.tally({
    fn("core/a.c", 10, "entered"),
    fn("core/a.c", 20, "missed"),
  }, { ["core/a.c"] = { [10] = true } })
  assert(tally.total == 2 and tally.entered == 1 and tally.exempted == 0)
  assert(#tally.unentered == 1 and tally.unentered[1] == "core/a.c:missed")
end

--- One function the core's exemptions name: the VFS never writes.
local exempt <const> = "core/vfs.c:file_write"

local function test_an_exempt_function_is_not_a_failure()
  local path, name = exempt:match("^(.-):([^:]+)$")
  local tally = c_functions.tally({ fn(path, 1, name) }, {})
  assert(tally.exempted == 1 and #tally.unentered == 0 and #tally.stale == 0)
end

--- An exempt function a test entered after all is named as stale, and
--- counted as entered rather than exempt.
local function test_an_exempt_function_entered_is_stale()
  local path, name = exempt:match("^(.-):([^:]+)$")
  local tally = c_functions.tally({ fn(path, 1, name) }, { [path] = { [1] = true } })
  assert(tally.entered == 1 and tally.exempted == 0)
  assert(#tally.stale == 1 and tally.stale[1] == exempt)
end

--- A host's own exemption holds on that host alone: libSystem's printf
--- never calls the core's strnlen on macOS, but a run on Linux still has
--- to enter it.
local function test_a_host_s_own_exemption_holds_on_that_host_alone()
  local only = fn("core/strnlen.c", 1, "strnlen")
  local darwin = c_functions.tally({ only }, {}, nil, "Darwin")
  assert(darwin.exempted == 1 and #darwin.unentered == 0)
  local linux = c_functions.tally({ only }, {}, nil, "Linux")
  assert(linux.exempted == 0 and #linux.unentered == 1 and
      linux.unentered[1] == "core/strnlen.c:strnlen")
  local unknown = c_functions.tally({ only }, {})
  assert(unknown.exempted == 0 and #unknown.unentered == 1)
  local entered = c_functions.tally({ only }, { ["core/strnlen.c"] = { [1] = true } }, nil, "Darwin")
  assert(entered.entered == 1 and #entered.stale == 1)
end

local function test_a_header_helper_is_left_out()
  local tally = c_functions.tally({ fn("core/check.h", 5, "helper") }, {})
  assert(tally.total == 0 and #tally.unentered == 0)
end

--- Inlined where it is called, a function's body runs without its
--- first line: a hit before the next function's first line enters it,
--- and one after enters only that next function.
local function test_a_hit_in_the_body_enters_an_inlined_function()
  local tally = c_functions.tally({
    fn("core/a.c", 10, "inlined"),
    fn("core/a.c", 20, "next"),
    fn("core/a.c", 30, "last"),
  }, { ["core/a.c"] = { [14] = true, [35] = true } })
  assert(tally.total == 3 and tally.entered == 2, tostring(tally.entered))
  assert(#tally.unentered == 1 and tally.unentered[1] == "core/a.c:next")
end

--- A file of `count` blank lines with `at` set.
local function source(count: integer, at: {integer: string}): {string}
  local lines: {string} = {}
  for i = 1, count do lines[i] = at[i] or "" end
  return lines
end

--- With the file's source, a body ends at its closing brace: a helper
--- after it that was inlined everywhere, and so is no function of its
--- own, does not lend its hits to the function before it.
local function test_the_source_ends_a_body_at_its_brace()
  local functions = { fn("core/a.c", 10, "dies"), fn("core/a.c", 30, "next") }
  local hits = { ["core/a.c"] = { [22] = true, [31] = true } }
  local lines = source(40, {
    [10] = "static void dies (void) {", [14] = "}",
    [20] = "static int helper (void) {", [25] = "}",
    [30] = "static int next (void) {", [33] = "}",
  })
  local tally = c_functions.tally(functions, hits, { ["core/a.c"] = lines })
  assert(tally.entered == 1 and tally.unentered[1] == "core/a.c:dies")
  -- Without the source, the body runs to the next function, over the helper.
  assert(c_functions.tally(functions, hits).entered == 2)
end

--- A helper inlined at the top of a function gives the function its first
--- instruction's line: the function's own body is found by its name, so
--- the helper running elsewhere does not enter it.
local function test_a_body_is_found_by_name_not_by_its_first_instruction()
  local lines = source(12, {
    [2] = "static sqlite3_vfs *helper (sqlite3_vfs *vfs) {", [5] = "}",
    [8] = "static int forward (sqlite3_vfs *vfs) {", [10] = "}",
  })
  local functions = { fn("core/a.c", 3, "forward") }
  local sources = { ["core/a.c"] = lines }
  assert(c_functions.tally(functions, { ["core/a.c"] = { [3] = true } }, sources).entered == 0)
  assert(c_functions.tally(functions, { ["core/a.c"] = { [9] = true } }, sources).entered == 1)
end

--- A function that opens and closes on its first line is that line.
local function test_a_one_line_function_is_its_line()
  local lines = source(12, {
    [5] = "static void close_it (void *p) { release(p); }",
    [7] = "static int after (void) {", [10] = "}",
  })
  local tally = c_functions.tally({ fn("core/a.c", 5, "close_it") },
    { ["core/a.c"] = { [8] = true } }, { ["core/a.c"] = lines })
  assert(tally.entered == 0 and #tally.unentered == 1)
end

local function test_one_copy_entered_enters_the_function()
  local tally = c_functions.tally({
    fn("core/a.c", 10, "copied"),
    fn("core/a.c", 30, "copied"),
  }, { ["core/a.c"] = { [30] = true } })
  assert(tally.total == 1 and tally.entered == 1 and #tally.unentered == 0)
end

local function test_only_a_functions_own_absent_prerequisite_removes_its_obligation()
  local functions = {
    fn("core/syscalls.c", 1, "first_child"),
    fn("core/a.c", 1, "ordinary"),
  }
  local tally = c_functions.tally(functions, {}, nil, nil,
    { ["path:/proc/thread-self/children"] = "requires children: absent" })
  assert(tally.exempted == 0 and #tally.unavailable == 1)
  assert(tally.unavailable[1] == "core/syscalls.c:first_child: requires children: absent")
  assert(#tally.unentered == 1 and tally.unentered[1] == "core/a.c:ordinary")
  local unrelated = c_functions.tally(functions, {}, nil, nil, { sandbox = "absent" })
  assert(#unrelated.unavailable == 0 and #unrelated.unentered == 2)
  local unknown = c_functions.tally(functions, {})
  assert(#unknown.unavailable == 0 and #unknown.unentered == 2)
  local present = c_functions.tally(functions, {}, nil, nil, {})
  assert(#present.unavailable == 0 and #present.unentered == 2)
end

local function test_an_entered_function_stays_entered_despite_a_missing_prerequisite()
  local tally = c_functions.tally({ fn("core/syscalls.c", 1, "first_child") },
    { ["core/syscalls.c"] = { [1] = true } }, nil, nil,
    { ["path:/proc/thread-self/children"] = "absent" })
  assert(tally.entered == 1 and #tally.unavailable == 0 and #tally.unentered == 0)
end

local function test_a_caller_cannot_change_the_prerequisites()
  local needs = c_functions.prerequisites()
  assert(needs["core/socket.c:reach_from"] == "unix_socket")
  needs["core/socket.c:reach_from"] = "root"
  assert(c_functions.prerequisites()["core/socket.c:reach_from"] == "unix_socket")
end

local function test_a_promised_absence_or_a_refused_probe_retains_the_obligation()
  local answers: {host_requires.Answer} = {
    { name = "unix_socket", class = "host", kind = "skipped", key = "", why = "absent" },
    { name = "landlock", class = "platform", kind = "present", key = "available", why = "" },
    { name = "path:/proc/thread-self/children", class = "host", kind = "refused", key = "",
      why = "could not inspect" },
  }
  local unheld = c_functions.unavailable(answers)
  assert(unheld.unix_socket == "requires unix_socket: absent")
  assert(unheld.landlock == nil and unheld["path:/proc/thread-self/children"] == nil)
  local held = c_functions.unavailable(answers, { "unix_socket" })
  assert(next(held) == nil)
  local tally = c_functions.tally({ fn("core/socket.c", 1, "reach_from") }, {}, nil, nil, held)
  assert(#tally.unavailable == 0 and #tally.unentered == 1)
end
