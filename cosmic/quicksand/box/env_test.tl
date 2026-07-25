#!/usr/bin/env cosmic
local jenv = require("cosmic.quicksand.box.env")

local function test_keep_filters_parent()
  local parent: {string: string} = {PATH = "/bin", HOME = "/h", SECRET = "s"}
  local out = jenv.apply({keep = {"PATH", "HOME"}}, parent)
  assert(out.PATH == "/bin")
  assert(out.HOME == "/h")
  assert(out.SECRET == nil, "SECRET should not leak")
end
test_keep_filters_parent()

local function test_set_overrides_and_adds()
  local parent: {string: string} = {PATH = "/bin"}
  local out = jenv.apply({keep = {"PATH"}, set = {PATH = "/usr/bin", FOO = "bar"}}, parent)
  assert(out.PATH == "/usr/bin", "set overrides kept")
  assert(out.FOO == "bar")
end
test_set_overrides_and_adds()

local function test_keep_missing_parent_dropped()
  local parent: {string: string} = {PATH = "/bin"}
  local out = jenv.apply({keep = {"PATH", "MISSING"}}, parent)
  assert(out.PATH == "/bin")
  assert(out.MISSING == nil)
end
test_keep_missing_parent_dropped()

local function test_nil_opts_returns_empty()
  local out = jenv.apply(nil, {PATH = "/bin"})
  assert(next(out) == nil, "nil opts → empty env")
end
test_nil_opts_returns_empty()

local function test_empty_keep_set_only()
  local out = jenv.apply({set = {TERM = "xterm"}}, {PATH = "/bin"})
  assert(out.TERM == "xterm")
  assert(out.PATH == nil, "no keep → parent dropped")
end
test_empty_keep_set_only()

local function test_render_sorted()
  local rendered = jenv.render({PATH = "/bin", HOME = "/h", FOO = "bar"})
  assert(#rendered == 3)
  assert(rendered[1] == "FOO=bar", "got: " .. rendered[1])
  assert(rendered[2] == "HOME=/h")
  assert(rendered[3] == "PATH=/bin")
end
test_render_sorted()
