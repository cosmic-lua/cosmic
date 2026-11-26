--- `cosmic --standalone`, run as this program: a file's path and
--- arguments and its exit status (the compile cache it keeps is in
--- `standalone_cache_tool_test.tl`). These start this program, its core and retained descriptor, only to run a
--- file standalone, so they declare `lua`; the in-process compiles are in `standalone_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local Clock = require("cosmic.clock")

--- The program itself, which its tests start to run a file `--standalone`
--- ([`build.standalone`]).
Test.policy{ profiles = { "cosmic" } }

--- End to end, from a directory holding no tree: the file gets its own
--- path at argv[0] and what follows it, its exit code is the process's,
--- and nothing is written beside it -- no `o/`.
local function test_a_run_writes_nothing_and_passes_its_arguments(tmp: string)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local record Script
  mut main: function({string}): integer
end
Script.main = function(argv: {string}): integer
  local _, _ = Fs.put(Fs.stdout, (argv[0] or "") .. "|" .. table.concat(argv, ",") .. "\n")
  return 5
end
return Script
]]))
  local started = Test.cosmic({ "--standalone", script, "one", "two" }, {
    cwd = tmp, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 5, tostring(result.stderr))
  assert(result.stdout == script .. "|one,two\n", tostring(result.stdout))
  local names = assert(Fs.list(tmp))
  assert(#names == 1 and names[1] == "script.tl", "a standalone run wrote beside the file")
end

--- What main returns is judged as a file run's is: a whole number
--- outside 0-255, text naming none, or a float that is not whole exits
--- 2, the complaint naming the file rather than cmd.cosmic.main; one
--- that has a whole value is that value.
local function test_a_main_that_returns_no_exit_status_is_refused(tmp: string)
  local function run(returned: string, kind: string): Child.Result
    local script = tmp .. "/script.tl"
    assert(Fs.write(script, "return function(_argv: {string}): " .. kind .. "\n  return " ..
        returned .. "\nend\n"))
    local started = Test.cosmic({ "--standalone", script }, {
      env = { XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30),
    })
    return (assert(Child.run(started.argv, started.options)))
  end
  local kinds: {string: string} = { ["300"] = "integer", ["\"three\""] = "string", ["1.5"] = "number" }
  for returned, shown in pairs({ ["300"] = "300", ["\"three\""] = "\"three\"", ["1.5"] = "1.5" }) do
    local result = run(returned, assert(kinds[returned]))
    assert(result.code == 2, returned .. " exited " .. tostring(result.code) .. ": " ..
        tostring(result.stderr))
    local complaint = "cosmic: " .. tmp .. "/script.tl returned " .. shown ..
      ", not an exit status 0-255"
    assert(tostring(result.stderr):find(complaint, 1, true) ~= nil, tostring(result.stderr))
  end
  local whole = run("4.0", "number")
  assert(whole.code == 4, tostring(whole.stderr))
  local text = run("\"4\"", "string")
  assert(text.code == 4, tostring(text.stderr))
end

local function test_a_run_without_a_file_is_a_usage_error()
  local started = Test.cosmic({ "--standalone" }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 2)
  assert(tostring(result.stderr):find("usage", 1, true) ~= nil)
end

--- A file that requires a module of the project it sits in is refused standalone, and the refusal says the file belongs to
--- the project; a file that requires nothing of the project's gets no such line.
local function test_a_project_module_is_told_to_drop_standalone(tmp: string)
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project .. "/cmd"))
  assert(Fs.write(project .. "/greet.tl", "local record Greet\n  hi: string\nend\nreturn Greet\n"))
  assert(Fs.write(project .. "/cmd/main.tl", 'local Greet = require("greet")\nprint(Greet.hi)\n'))
  assert(Fs.write(project .. "/cmd/alone.tl", 'local a: integer = "no"\nprint(a)\n'))
  local function run(args: {string}): Child.Result
    local started = Test.cosmic(args, { cwd = project, stdout = "capture", stderr = "capture",
      timeout_ns = Clock.seconds(30) })
    return (assert(Child.run(started.argv, started.options)))
  end
  for _, args in ipairs({ { "--standalone", "--check", "cmd/main.tl" }, { "--standalone", "cmd/main.tl" } }) do
    local result = run(args)
    local said = tostring(result.stdout) .. tostring(result.stderr)
    assert(result.code == 4, said)
    assert((result.stderr or ""):find("belongs to a project", 1, true) ~= nil, said)
    assert((result.stderr or ""):find("drop --standalone", 1, true) ~= nil, said)
    assert((result.stderr or ""):find("cosmic fix cmd/main.tl", 1, true) ~= nil, said)
  end
  local alone = run({ "--standalone", "--check", "cmd/alone.tl" })
  assert(alone.code == 4 and (alone.stderr or ""):find("belongs to a project", 1, true) == nil, tostring(alone.stderr))
end

--- A module of a nested name (`lib.deep.inner`) is found as `lib/deep/inner.tl` and a directory's `init.tl` as its name.
local function test_a_nested_project_module_is_found(tmp: string)
  local project = tmp .. "/nested"
  assert(Fs.mkdirs(project .. "/lib/deep"))
  assert(Fs.mkdirs(project .. "/pkg"))
  assert(Fs.write(project .. "/lib/deep/inner.tl", "return 1\n"))
  assert(Fs.write(project .. "/pkg/init.tl", "return 1\n"))
  assert(Fs.write(project .. "/a.tl", 'local n = require("lib.deep.inner")\nprint(n)\n'))
  assert(Fs.write(project .. "/b.tl", 'local n = require("pkg")\nprint(n)\n'))
  for _, file in ipairs({ "a.tl", "b.tl" }) do
    local started = Test.cosmic({ "--standalone", "--check", file }, { cwd = project,
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.code == 4 and (result.stderr or ""):find("belongs to a project", 1, true) ~= nil,
      file .. ": " .. tostring(result.stderr))
  end
end

--- A file of that name above the root `cosmic <file>` would build is no module of the project: the hint stays off.
local function test_a_stray_file_above_the_project_root_is_no_project_module(tmp: string)
  assert(Fs.write(tmp .. "/util.tl", "return 1\n"))
  local project = tmp .. "/stray/project"
  assert(Fs.mkdirs(project))
  assert(Fs.write(project .. "/main.tl", 'local u = require("util")\nprint(u)\n'))
  local started = Test.cosmic({ "--standalone", "--check", "main.tl" }, { cwd = project,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 4, tostring(result.stderr))
  assert((result.stderr or ""):find("belongs to a project", 1, true) == nil, tostring(result.stderr))
end

--- `--standalone --check` types a file as a run does and never runs it: a clean file whose body would write a marker and
--- raise exits 0 and leaves no marker, a broken one is refused as a run refuses it.
local function test_check_types_a_file_without_running_it(tmp: string)
  local marker = tmp .. "/marker"
  local clean = tmp .. "/clean.tl"
  assert(Fs.write(clean, 'local Fs = require("cosmic.fs")\nassert(Fs.write("' .. marker ..
      '", "ran"))\nerror("it ran")\n'))
  local broken = tmp .. "/broken.tl"
  assert(Fs.write(broken, 'local n: integer = "text"\nreturn n\n'))
  local function check(file: string): Child.Result
    local started = Test.cosmic({ "--standalone", "--check", file }, { cwd = tmp,
      env = { XDG_CACHE_HOME = tmp .. "/cache" }, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
    local result = assert(Child.run(started.argv, started.options))
    return result
  end
  local passed = check(clean)
  assert(passed.code == 0, tostring(passed.stderr))
  assert(not assert(Fs.status(marker)).exists, "--check ran the file")
  local refused = check(broken)
  assert(refused.code == 4, tostring(refused.stderr))
  assert(tostring(refused.stderr):find("not_assignable", 1, true), tostring(refused.stderr))
  local run = Test.cosmic({ "--standalone", broken }, { cwd = tmp, env = { XDG_CACHE_HOME = tmp .. "/cache" },
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local ran = assert(Child.run(run.argv, run.options))
  assert(ran.stderr == refused.stderr, "--check prints what a run does")
  local usage = Test.cosmic({ "--standalone", "--check" }, { stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) })
  assert(assert(Child.run(usage.argv, usage.options)).code == 2)
end

--- A run is no review: a file run alone, or `-e`, runs with a name it never uses, as an agent's snippet does; `--check`
--- still refuses it.
local function test_a_run_lets_an_unused_name_pass(tmp: string)
  local file = tmp .. "/unused.tl"
  assert(Fs.write(file, 'local unused = 1\nlocal function never() end\nprint("ran")\n'))
  for _, args in ipairs({ { "--standalone", file }, { "-e", 'local unused = 1\nprint("ran")' } }) do
    local started = Test.cosmic(args, { cwd = tmp, env = { XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
    local ran = assert(Child.run(started.argv, started.options))
    assert(ran.code == 0 and ran.stdout == "ran\n", tostring(ran.stderr))
    assert(tostring(ran.stderr):find("unused", 1, true) == nil, tostring(ran.stderr))
  end
  -- A check is a review: `--check` refuses the name a run let pass.
  local started = Test.cosmic({ "--standalone", "--check", file }, { cwd = tmp,
    env = { XDG_CACHE_HOME = tmp .. "/cache" }, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local checked = assert(Child.run(started.argv, started.options))
  assert(checked.code == 4 and tostring(checked.stderr):find("unused_variable", 1, true) ~= nil, tostring(checked.stderr))
end

--- A file's top level finds its words in `arg`, as `lua file a b` gives
--- them, where `...` is what `require` handed it.
local function test_a_file_finds_its_words_in_arg_at_its_top_level(tmp: string)
  local script = tmp .. "/top.tl"
  assert(Fs.write(script, 'print((arg[0] or "") .. "|" .. table.concat(arg, ","))\n'))
  local started = Test.cosmic({ "--standalone", script, "one", "two" }, { cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0 and result.stdout == script .. "|one,two\n",
    tostring(result.stdout) .. tostring(result.stderr))
end

--- COSMIC_STANDALONE=1 runs a file as `--standalone` does: its words
--- reach it, and nothing is written beside it.
local function test_cosmic_standalone_runs_a_file_standalone(tmp: string)
  local dir = tmp .. "/alone"
  assert(Fs.mkdirs(dir))
  local script = dir .. "/script.tl"
  assert(Fs.write(script, [[
return function(argv: {string}): integer
  print(table.concat(argv, ","))
  return 0
end
]]))
  local env = Test.environment()
  env.COSMIC_STANDALONE = "1" -- checked: map_field
  local started = Test.cosmic({ script, "one", "two" }, { cwd = dir, env = env,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0 and result.stdout == "one,two\n", tostring(result.stderr))
  local names = assert(Fs.list(dir))
  assert(#names == 1 and names[1] == "script.tl", "a standalone run wrote beside the file")
end

--- A test's child runs from its closure store, which records no boot hash: no build names the sources it checks a
--- file against, so it keeps no compile, and a file run there is checked afresh each time. (One that records one keeps
--- it: `standalone_cache_tool_test.tl`.)
local function test_a_run_with_no_boot_hash_keeps_no_compile(tmp: string)
  assert(require("cosmic.store").meta("boot_hash") == nil, "a test's closure store records a boot hash")
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, "return function(_argv: {string}): integer return 3 end\n"))
  local started = Test.cosmic({ "--standalone", script }, {
    env = { XDG_CACHE_HOME = tmp .. "/cache" }, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 3, tostring(result.code) .. tostring(result.stderr))
  local kept, _ = Fs.list(tmp .. "/cache/cosmic/standalone")
  assert(kept == nil or #kept == 0, "a compile is kept")
end
