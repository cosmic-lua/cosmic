local check = require("cosmic.check")
local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))

local function test_install_accepts_all_supported_absolute_root_forms()
  for _, root in ipairs({"C:/project", "C:\\project", "\\\\server\\share"}) do
    local program = "assert(require('cosmic.searcher').install_make_root(" .. string.format("%q", root) .. "))"
    local result = check.must(child.run({cosmic, "-e", program},
        {env = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1"}})}))
    assert(result.ok, root .. ": " .. result.stderr)
  end
end

local function test_source_only_strict_uncached_loader_and_restoration()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "make-searcher")
  assert(fs.make_dirs(fs.join(root, "o/_cli")))
  assert(fs.make_dirs(fs.join(root, "_cli")))
  assert(fs.write(fs.join(root, "_cli/lint.tl"),
      "return {lint_file = function(_path: string, _limit: integer): integer return 23 end}\n"))
  assert(fs.write(fs.join(root, "caller.tl"),
      "local lint = require('_cli.lint')\nreturn lint.lint_file('x', 10)\n"))
  assert(fs.write(fs.join(root, "o/caller.lua"), "return -1\n"))
  assert(fs.write(fs.join(root, "o/_cli/lint.lua"), "error('built shadow')\n"))
  -- No closure and no implicit built shadow: the original manifest fallback
  -- still checks a caller against the binary's one-argument lint signature.
  local manifest = fs.join(root, "root.modules")
  assert(fs.write(manifest, "root " .. root .. "\nbuild absent-build\n"))
  local negative = check.must(child.run({cosmic, "--modules", manifest,
        "-e", "require('caller')"}, {env = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1"}})}))
  assert(not negative.ok and negative.stderr:find("given 2, expects 1", 1, true), negative.stderr)
  local script = fs.join(root, "probe.lua")
  assert(fs.write(script, [[
local searcher = require('cosmic.searcher')
local context = require('cosmic._teal_project')
local fs = require('cosmic.fs')
local root = arg[1]
assert(not searcher.install_make_root('relative'))
assert(searcher.install_make_root(root))
local count = #package.searchers
assert(searcher.install_make_root(root))
assert(#package.searchers == count)
assert(not searcher.install_make_root(root .. '/other'))
local resolve = package.searchers[2]
local fn, path = resolve('caller')
assert(path == root .. '/caller.tl')
assert(fn() == 23)
assert(fs.write(root .. '/_cli/lint.tl', 'return {lint_file = function(_path: string): integer return 23 end}\n'))
local ok, err = pcall(resolve, 'caller')
assert(not ok and tostring(err):find('given 2, expects 1', 1, true), tostring(err))
assert(context.get_root() == nil)
assert(fs.write(root .. '/caller.tl', 'return 24\n'))
assert(resolve('caller')() == 24, 'compile failure must restore the guard')
assert(resolve('no_such_make_source') == nil)
assert(fs.write(root .. '/broken.lua', 'this is not lua'))
assert(not pcall(resolve, 'broken'))
assert(fs.write(root .. '/fine.lua', 'return 25'))
assert(resolve('fine')() == 25)
local teal = require('cosmic.teal')
local tl = require('tl')
local saved_compile, saved_path, saved_search = teal.compile_file, tl.path, tl.search_module
context.set_root('outer-context')
teal.compile_file = function()
  local nested, nested_path = resolve('caller')
  assert(nested == nil and nested_path == nil,
    'resolver must decline tree modules during compilation')
  tl.path = 'changed-during-error'
  tl.search_module = function() error('changed lookup') end
  error('forced-compiler-throw')
end
local failed, why = pcall(resolve, 'caller')
teal.compile_file = saved_compile
assert(not failed and tostring(why):find('forced-compiler-throw', 1, true))
assert(context.get_root() == 'outer-context', 'nested root must be restored')
assert(tl.path == saved_path and tl.search_module == saved_search)
context.set_root(nil)
assert(resolve('caller')() == 24, 'throw must restore the compilation guard')
print('source-only-ok')
]]))
  local r = check.must(child.run({cosmic, script, root},
      {env = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1"}})}))
  assert(r.ok and r.stdout:find("source-only-ok", 1, true), r.stdout .. r.stderr)
end

local function test_same_caller_sees_sibling_edits_in_a_new_process()
  local root = fs.join(os.getenv("TEST_TMPDIR") or "/tmp", "make-processes")
  assert(fs.make_dirs(root))
  local callee = fs.join(root, "sibling.tl")
  assert(fs.write(callee, "return {call = function(_arg: string, _n: integer): integer return 31 end}\n"))
  assert(fs.write(fs.join(root, "caller.tl"),
      "local sibling = require('sibling')\nreturn sibling.call('x', 1)\n"))
  local program = "assert(require('cosmic.searcher').install_make_root(" .. string.format("%q", root) ..
  ")); assert(require('caller') == 31)"
  local settings = env.list({set = {COSMIC_COVERAGE = "0", COSMIC_NO_WELCOME = "1"}})
  local first = check.must(child.run({cosmic, "-e", program}, {env = settings}))
  assert(first.ok, first.stderr)
  assert(fs.write(callee, "return {call = function(_arg: string): integer return 31 end}\n"))
  local second = check.must(child.run({cosmic, "-e", program}, {env = settings}))
  assert(not second.ok and second.stderr:find("given 2, expects 1", 1, true), second.stderr)
end
