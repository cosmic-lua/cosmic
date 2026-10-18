--- [`build.teal`]'s `defaults` and `served`, which every environment the
--- tree makes for the checker and every module it hands the checker go
--- through (build/compile.tl, build/standalone.tl, build/lsp/check.tl, the
--- checker's own tests), apart from build/teal_test.tl, which holds as
--- many locals as a chunk may.
local teal = require("build.teal")

--- The defaults every environment of the tree is made with: compat off,
--- Lua 5.4, and `runtime_checks` only as asked, each call its own table
--- since an environment keeps the one it is made with.
local function test_defaults_are_lua_54_without_compat_and_fresh_each_call()
  local plain = teal.defaults()
  assert(plain.feat_lax == "off" and plain.gen_compat == "off" and plain.gen_target == "5.4")
  assert(plain.runtime_checks == nil)
  assert(teal.defaults(true).runtime_checks == true)
  assert(teal.defaults(false).runtime_checks == false)
  assert(teal.defaults() ~= plain, "two environments would share one defaults table")
  local built = assert(teal.load(true))
  local env = assert(built.new_env({ defaults = teal.defaults() }))
  -- Lua 5.4 without compat: integer division is written as itself, not
  -- through `math.floor`.
  local code = assert(built.gen("local a, b = 7, 2\nreturn a // b\n", env, nil, "tl"))
  assert(code:find("a // b", 1, true) ~= nil and code:find("floor", 1, true) == nil, code)
end

--- A module served by [`teal.served`] reads as its text, then closes; the
--- checker types a `require` of a standard module served so
--- ([`teal.serve_standard`]) from that text.
local function test_a_served_module_reads_as_its_text()
  local text = "return { n = 1 }\n"
  local handle = teal.served(text)
  assert(handle:read("*a") == text and handle:close())
  assert(handle:read("*a") == text, "a second read found other text")
  local built = assert(teal.load(true))
  teal.serve_standard(built)
  local function errors(program: string): integer
    local env = assert(built.new_env({ defaults = teal.defaults() }))
    return #built.check_string(program, env, "app.tl", "tl").type_errors
  end
  assert(errors('local Hash = require("cosmic.hash")\nlocal s: string = Hash.hex_sha256("")\nreturn s\n') == 0)
  assert(errors('local Hash = require("cosmic.hash")\nlocal n: integer = Hash.hex_sha256("")\nreturn n\n') == 1)
end
