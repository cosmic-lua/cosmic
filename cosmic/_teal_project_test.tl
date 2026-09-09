local check = require("cosmic.check")
local context = require("cosmic._teal_project")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")
local tl = require("tl")

local function test_root_compiles_observe_changed_siblings_and_restore_normal_mode()
  local tmp = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "teal-project")
  assert(fs.make_dirs(tmp))
  local other = fs.join(tmp, "other")
  assert(fs.make_dirs(other))
  local sibling = fs.join(tmp, "project_sibling.d.tl")
  local wide = "local record M\n  call: function(string, integer): boolean\nend\nreturn M\n"
  local narrow = "local record M\n  call: function(string): boolean\nend\nreturn M\n"
  assert(fs.write(sibling, wide))
  assert(fs.write(fs.join(other, "project_sibling.d.tl"), narrow))
  local caller = "local m = require('project_sibling')\nreturn m.call('x', 2)\n"
  local saved_path = env.get("TL_PATH")
  assert(env.set("TL_PATH", other .. "/?.d.tl"))
  local saved_search = tl.search_module
  local saved_tl_path = tl.path
  context.set_root(tmp)
  local first = teal.compile(caller, {strict = true, werror = false})
  assert(first.ok, teal.format_issues(first.errors))
  assert(tl.search_module == saved_search and tl.path == saved_tl_path)
  assert(fs.write(sibling, narrow))
  local second = teal.compile(caller, {strict = true, werror = false})
  assert(not second.ok, "unchanged callers must see sibling-only edits")
  assert(fs.write(sibling, wide))
  assert(teal.compile(caller, {strict = true, werror = false}).ok)
  context.set_root(other)
  assert(not teal.compile(caller, {strict = true, werror = false}).ok,
    "a second project must not reuse the first project's types")
  context.set_root(nil)
  assert(not teal.compile(caller, {strict = true, werror = false}).ok,
    "ordinary mode must still honor TL_PATH")
  if saved_path then assert(env.set("TL_PATH", saved_path)) else assert(env.unset("TL_PATH")) end
  assert(context.get_root() == nil)
end

local function test_project_paths_include_generated_types_and_missing_falls_through()
  local tmp = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "teal-generated")
  local dir = fs.join(tmp, "o/_types/types_gen/pkg")
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, "init.d.tl"), "return string\n"))
  local patterns = tmp .. "/o/_types/types_gen/?/init.d.tl"
  local path, f = context.search_module(patterns, "pkg", true)
  assert(path == fs.join(dir, "init.d.tl"))
  check.must(f):close()
  assert(context.search_module(patterns, "absent", true) == nil)
end

local function test_explicit_fallbacks_precede_user_tl_path_only_in_project_mode()
  local tmp = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "teal-fallback")
  local explicit = fs.join(tmp, "explicit")
  local user = fs.join(tmp, "user")
  assert(fs.make_dirs(explicit))
  assert(fs.make_dirs(user))
  assert(fs.write(fs.join(explicit, "fallback.d.tl"), "local record M\n  value: integer\nend\nreturn M\n"))
  assert(fs.write(fs.join(user, "fallback.d.tl"), "local record M\n  value: string\nend\nreturn M\n"))
  local saved = env.get("TL_PATH")
  assert(env.set("TL_PATH", user .. "/?.d.tl"))
  local caller = "local m = require('fallback')\nlocal n: integer = m.value\nreturn n\n"
  context.set_root(tmp)
  local result = teal.compile(caller, {strict = true, include_dirs = {explicit}})
  context.set_root(nil)
  assert(result.ok, teal.format_issues(result.errors))
  assert(not teal.compile(caller, {strict = true, include_dirs = {explicit}}).ok)
  if saved then assert(env.set("TL_PATH", saved)) else assert(env.unset("TL_PATH")) end
end
