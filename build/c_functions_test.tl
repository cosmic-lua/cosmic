--- `build.c_functions.tally` against made-up functions and hits, so the
--- rules hold whatever C the core has today.

local type Coverage = require("cosmic.coverage")
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

--- A host's own exemption holds on that host alone: spawn_child's hits
--- never reach the parent on macOS, but a run on Linux still has to
--- enter it.
local function test_a_host_s_own_exemption_holds_on_that_host_alone()
  local only = fn("core/syscalls.c", 1, "spawn_child")
  local darwin = c_functions.tally({ only }, {}, nil, "Darwin")
  assert(darwin.exempted == 1 and #darwin.unentered == 0)
  local linux = c_functions.tally({ only }, {}, nil, "Linux")
  assert(linux.exempted == 0 and #linux.unentered == 1 and
    linux.unentered[1] == "core/syscalls.c:spawn_child")
  local unknown = c_functions.tally({ only }, {})
  assert(unknown.exempted == 0 and #unknown.unentered == 1)
  local entered = c_functions.tally({ only }, { ["core/syscalls.c"] = { [1] = true } }, nil, "Darwin")
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
  -- Without it, the body runs to the next function, over the helper.
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
