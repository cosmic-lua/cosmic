--- Artifact-level mutations of the exact generated production Lua. The base
--- and tracked Teal stay unchanged. Run from the repo root after build:
--- bin/cosmic _build/testdata/make_mutations.tl
local check = require('cosmic.check')
local fs = require('cosmic.fs')
local child = require('cosmic.child')
local env = require('cosmic.env')
local embed = require('cosmic.embed')
local root = fs.absolute_path('o/lmuu-mutations')
assert(fs.make_dirs(root .. '/baseline'))
local base = root .. '/baseline/cosmic'
assert(fs.copy('o/bin/cosmic', base))
local tests = {'_make/startup_test.lua', 'cosmic/_searcher_make_test.lua',
  'cosmic/_teal_project_test.lua', '_cli/script_test.lua', '_build/make_boundary_test.lua'}
local function run(binary: string, dir: string, test: string): child.Result
  local tmp = dir .. '/tmp-' .. test:gsub('/', '-')
  assert(fs.make_dirs(tmp))
  local result = check.must(child.run({binary, fs.absolute_path('o/' .. test)},
      {env = env.list({drop = {'TL_PATH', 'COSMIC_MAKE_ROOT'}, set = {TEST_BIN = fs.dirname(binary),
              TEST_TMPDIR = tmp, COSMIC_COVERAGE = '0', COSMIC_NO_WELCOME = '1'}})}))
  assert(fs.write(dir .. '/' .. test:gsub('/', '-') .. '.log', result.stdout .. result.stderr))
  return result
end
for _, test in ipairs(tests) do
  local result = run(base, root .. '/baseline', test)
  assert(result.ok, 'BASELINE ' .. test .. '\n' .. result.stdout .. result.stderr)
end
print('baseline: PASS (5 focused files)')
local record Mutation
  name: string
  file: string
  stored: string
  old: string
  new: string
  count: integer
  test: string
  failure: string
end
local cases: {Mutation} = {
  {name = 'early-install', file = 'cmd/cosmic/main.lua', stored = 'main.lua',
    old = 'local ready, startup_err = require("_make.startup").prepare(opts, _margs_ok)',
    new = 'local ready, startup_err = true, nil', count = 1, test = tests[1],
    failure = 'test_early_make_loads_tree_handler_but_keeps_boundary_and_scripts_pinned'},
  {name = 'root-precedence', file = 'cosmic/_teal_engine.lua', stored = 'cosmic/_teal_engine.lua',
    old = 'local root = project_context.get_root()', new = 'local root = nil', count = 2, test = tests[2],
    failure = 'test_source_only_strict_uncached_loader_and_restoration'},
  {name = 'strict-code-cache', file = 'cosmic/_searcher_make.lua', stored = 'cosmic/_searcher_make.lua',
    old = 'pcall(teal.compile_file, path, { strict = true, werror = false })',
    new = [[pcall(function(file)
      local code, err = teal.compile_cached(file, {strict=true})
      return {ok=code~=nil,code=code,errors={{file=file,line=0,column=0,message=err or ''}}}
   end, path)]], count = 1, test = tests[2],
    failure = 'test_source_only_strict_uncached_loader_and_restoration'},
  {name = 'implicit-built-reuse', file = 'cosmic/_searcher_make.lua', stored = 'cosmic/_searcher_make.lua',
    old = 'local stem = root .. "/" .. name:gsub("%.", "/")',
    new = [[local stem = root .. "/" .. name:gsub("%.", "/")
   local built = root .. '/o/' .. name:gsub('%.','/') .. '.lua'
   local f = io.open(built,'r'); if f then f:close(); return built end]], count = 1, test = tests[2],
    failure = 'test_source_only_strict_uncached_loader_and_restoration'},
  {name = 'shared-type-environment', file = 'cosmic/_teal_engine.lua', stored = 'cosmic/_teal_engine.lua',
    old = 'local cacheable = project_context.get_root() == nil', new = 'local cacheable = true',
    count = 1, test = tests[3], failure = 'test_root_compiles_observe_changed_siblings_and_restore_normal_mode'},
  {name = 'eager-child-handler', file = 'cmd/cosmic/main.lua', stored = 'main.lua',
    old = 'if not ready then return 1, startup_err end',
    new = 'if not ready then return 1, startup_err end\n   local forced = require("_cli.main_handlers")',
    count = 1, test = tests[4], failure = 'test_manifest_scripts_do_not_load_unselected_handlers'},
  {name = 'script-through-handler', file = 'cmd/cosmic/main.lua', stored = 'main.lua',
    old = 'require("_cli.script").load_script_file(opts.script)',
    new = 'require("_cli.main_handlers").load_script_file(opts.script)',
    count = 1, test = tests[4], failure = 'test_manifest_scripts_do_not_load_unselected_handlers'},
}
local function replace(source: string, old: string, new: string): string, integer
  local output: {string} = {}
  local start, count = 1, 0
  while true do
    local at, last = source:find(old, start, true)
    if not at then output[#output + 1] = source:sub(start); break end
    output[#output + 1] = source:sub(start, at - 1); output[#output + 1] = new
    start = last + 1; count = count + 1
  end
  return table.concat(output), count
end
for _, case in ipairs(cases) do
  local dir = root .. '/' .. case.name
  local payload = dir .. '/payload/' .. case.stored
  assert(fs.make_dirs(fs.dirname(payload)))
  local source = check.must(fs.read('o/' .. case.file))
  local mutated, count = replace(source, case.old, case.new)
  assert(count == case.count, case.name .. ': mutation anchor count ' .. count)
  assert(fs.write(payload, mutated))
  local binary = dir .. '/cosmic'
  assert(embed.write({dir .. '/payload'}, {output = binary, exe_path = base}))
  local result = run(binary, dir, case.test)
  assert(not result.ok, case.name .. ': mutant survived')
  assert((result.stdout .. result.stderr):find(case.failure, 1, true),
    case.name .. ': failed outside target\n' .. result.stdout .. result.stderr)
  print(case.name .. ': KILLED by ' .. case.failure)
end
for _, test in ipairs(tests) do
  local result = run(base, root .. '/baseline', test)
  assert(result.ok, 'RESTORED ' .. test .. '\n' .. result.stdout .. result.stderr)
end
print('restored: PASS (5 focused files); 7/7 mutants killed')
