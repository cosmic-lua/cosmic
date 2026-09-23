--- The environment core/surface.c builds: `print` over the syscall
--- table, a traceback where `debug` used to be, and a name the surface
--- removed saying what took its place.

local errors = require("cosmic.internal.errors")

--- One line longer than a `luaL_Buffer` holds inline (1 KB on a 64-bit
--- build), from arguments whose text only exists once `print` converts
--- them: the path that once freed the buffer out from under itself. A
--- core built with Lua's API checks or AddressSanitizer fails here; the
--- line itself is only ever read by a person.
local function test_print_carries_a_line_past_the_inline_buffer()
  local long = string.rep(".", 1100)
  local shown = setmetatable({}, {
    __tostring = function(): string return "(a value that prints itself)" end,
  })
  print("surface_test: a long print ->", 42, shown, long, true, nil)
end

local function test_print_with_nothing_writes_an_empty_line()
  print()
end

local function test_trace_names_the_message_and_the_stack()
  local trace = errors.trace("where it went wrong")
  assert(trace:find("where it went wrong", 1, true) == 1)
  assert(trace:find("stack traceback:", 1, true) ~= nil)
  assert(errors.trace():find("stack traceback:", 1, true) == 1)
end

local function test_a_removed_name_says_what_replaced_it()
  local globals = _G as {string: any}
  for name, replacement in pairs({ io = "cosmic.fs", os = "cosmic.time",
                                   debug = "cosmic.errors.trace",
                                   dofile = "require",
                                   loadfile = "require" }) do
    local ok, message = pcall(function(): any return globals[name] end)
    assert(not ok, name .. " must not be reachable")
    assert(tostring(message):find(replacement, 1, true) ~= nil,
      name .. "'s refusal must name " .. replacement)
  end
end

local function test_a_name_that_never_existed_is_nil()
  local globals = _G as {string: any}
  assert(globals["cosmic_surface_test_never_defined"] == nil)
end
