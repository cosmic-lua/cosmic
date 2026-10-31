--- [`Net.Shutdown`] is the enum "read" | "write" | "both": a `shutdown` that
--- names a direction there is not does not compile, and the three there are,
--- written as plain strings, do.
local Snippet = require("build.snippet_fixture")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

-- A fixture reads the `cosmic.*` modules it requires out of the store, which
-- holds a test to its import closure.
local type _net = require("cosmic.net")

local function test_a_direction_there_is_not_does_not_compile()
  for _, how in ipairs({ "writes", "sideways", "" }) do
    local ok, trouble = Snippet.compiles(([[
local Net = require("cosmic.net")
local function end_it(conn: Net.Conn)
  local _, _ = conn:shutdown(%q)
end
return end_it
]]):format(how))
    assert(not ok, ("shutdown(%q) compiled"):format(how))
    assert(trouble:find("enum_member", 1, true) and trouble:find("Shutdown", 1, true), trouble)
  end
end

local function test_a_string_that_is_not_a_literal_does_not_compile()
  local ok, trouble = Snippet.compiles([[
local Net = require("cosmic.net")
local function end_it(conn: Net.Conn, how: string)
  local _, _ = conn:shutdown(how)
end
return end_it
]])
  assert(not ok, "a string variable compiled as a Net.Shutdown")
  assert(trouble:find("Shutdown", 1, true), trouble)
end

local function test_the_three_directions_written_as_strings_compile()
  local ok, trouble = Snippet.compiles([[
local Net = require("cosmic.net")
local function end_it(conn: Net.Conn)
  local _, _ = conn:shutdown("read")
  local _, _ = conn:shutdown("write")
  local _, _ = conn:shutdown("both")
  local how: Net.Shutdown = "write"
  local _, _ = conn:shutdown(how)
end
return end_it
]])
  assert(ok, trouble)
end
