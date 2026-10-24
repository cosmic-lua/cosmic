--- The proof that the tool can be bootstrapped from the new checker's seed, before the switch makes it so
--- (doc/plans/strict-teal.md, "the switch"): the pieces the switch swaps in, run beside the boot that still uses the fork's.
---
---     bin/cosmic build/seed_proof_main.tl prove <dir> [--seed <cosmic>] [--tool]
---
--- The steps, each printed with the time it took:
---
--- 1. The tree is written translated, with the steps of the pipeline ([`build.tree_writer`]), to `<dir>/tree`, as the switch
---    commits it.
--- 2. The files of [`build/seed.txt`] are compiled from it by the pinned release (`compile --grammar new`, the cosmic `--seed`
---    names, else [`bin/cosmic-bootstrap`]) to `<dir>/seed`, as `build.zig`'s seed step will. They are compiled again in this
---    process, and the files whose Lua differs are listed: they are the ones `lang/SEED_DIFFERS` has to name.
--- 3. A bare core boots the tree through the new bridge ([`core/bridge_new.lua`]) up to [`build.boot`], which it stops at: stage
---    one loads the seed, compiles the seed's files again and compares them with it, stage two compiles the closure of
---    [`build.boot`] with the new checker. The bridge's own account of the time and the memory is printed.
--- 4. With `--tool` the tree is booted for real: a copy of the repository with the translated files over it, the new bridge for
---    the build's code, and the fork's compiler for what still asks for one ([`build.compiler`]), staged and assembled into a tool
---    that runs a test and a check of the tree.
---
--- The sources the bridge reads are the tree as the switch commits it, so the proof stands in for the switch's own changes where
--- the tree does not make them yet: the lines [`build.new_declarations`] edits are in the files, so the pipeline's edit is
--- turned off in the copy, and the fork's bootstrap script ([`build/checker_wrapper.tl`]) stays in the fork's Teal.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local CompileGrammar = require("build.compile_grammar")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local String = require("cosmic.string")
local TreeWriter = require("build.tree_writer")
local artifact = require("build.artifact")

local record SeedProof
  --- What stands in for the bridge in a boot of a tree that has the new one alone: the module core/boot.c asks the
  --- bridge for, with `bootstrap` answering stage two in the place of the fork's compiler.
  shim: function(): string

  --- What [`SeedProof.boot`] ran.
  record Booted
    code: integer | nil
    stdout: string
    --- The bridge's account of its steps ([`core/bridge_new.lua`]'s `COSMIC_BRIDGE_TRACE`), one line each.
    trace: {string}
    --- The rest of the standard error.
    stderr: string
    nanoseconds: integer
  end

  --- The files of the seed list below `root`, in order.
  listed: function(root: string): {string} | nil, string

  --- Writes `paths` of the tree at `root` translated, as the switch commits them, below `out`.
  translate: function(root: string, paths: {string}, out: string): TreeWriter.Report | nil, string

  --- Compiles `files` of the tree `tree` in this process, as `cosmic compile --grammar new` does, and writes the Lua of each
  --- to `out`/`<basename>.lua`. The Lua by file, or nil and the syntax errors.
  compile: function(tree: string, files: {string}, out: string): {string: string} | nil, string

  --- Boots `tree` with the raw core `core` (a path), the seed in `seed` and the variables `env`, with the command line
  --- `args` that [`build.boot`] is given after the seed. `tree` holds core/bridge.lua, which loads the new bridge.
  boot: function(core: string, tree: string, seed: string, args: {string}, env: {string: string}): Booted | nil, string

  --- The command line of [`build/seed_proof_main.tl`].
  main: function(argv: {string}): integer
end

local SHIM <const> = [[
local root = ...
local sys = require('cosmic.sys')
local function read(path)
  local fd = assert(sys.open(path, sys.O_RDONLY))
  local parts = {}
  while true do
    local chunk = sys.read(fd, 65536)
    if not chunk or #chunk == 0 then break end
    parts[#parts + 1] = chunk
  end
  sys.close(fd)
  return table.concat(parts)
end
local new = assert(load(read(root .. '/core/bridge_new.lua'), '@core/bridge_new.lua', 't'))(root)
return {
  declare = new.declare,
  searcher_for = new.searcher_for,
  schema = new.schema,
  bootstrap = function(seed_dir, _entry, variables)
    return new.bootstrap(seed_dir, root .. '/build/seed.tl', variables), ''
  end,
}
]]

-- TODO: drop this shim, the fork's seed it needs and the copy's stop of [`build.new_declarations`]'s edits once the switch
-- (doc/plans/strict-teal.md, "the switch") deletes build/teal.tl and writes those lines into place: the boot then asks the
-- bridge for nothing but stage two, and the proof's bridge is [`SeedProof.shim`].

--- The shim for a boot that still needs the fork's compiler ([`build.compiler`]) besides the new checker: the fork's bridge,
--- kept as core/bridge_fork.lua, makes the compiler from the fork's seed, and the new bridge's stage two, from the seed `COSMIC_SEED_NEW`
--- names, answers the build's code.
local HYBRID <const> = [[
local root = ...
local sys = require('cosmic.sys')
local function read(path)
  local fd = assert(sys.open(path, sys.O_RDONLY))
  local parts = {}
  while true do
    local chunk = sys.read(fd, 65536)
    if not chunk or #chunk == 0 then break end
    parts[#parts + 1] = chunk
  end
  sys.close(fd)
  return table.concat(parts)
end
local function bridge(file)
  return assert(load(read(root .. '/core/' .. file), '@core/' .. file, 't'))(root)
end
local fork, new = bridge('bridge_fork.lua'), bridge('bridge_new.lua')
local stage_two
return {
  environment = fork.environment,
  schema = fork.schema,
  declare = function(name, text) new.declare(name, text) end,
  searcher_for = function(_compiler, variables) return new.searcher_for(stage_two, variables) end,
  bootstrap = function(seed_dir, file, variables)
    stage_two = new.bootstrap(sys.getenv('COSMIC_SEED_NEW'), root .. '/build/seed.tl', variables)
    return fork.bootstrap(seed_dir, file, variables)
  end,
}
]]

--- The bridge's lines that say a step (`bridge: <seconds> s ...`), and the rest of `text`.
local function split_trace(text: string): {string}, string
  local trace: {string} = {}
  local rest: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:find("^bridge: ") ~= nil then
      trace[#trace + 1] = line
    elseif line ~= "" then
      rest[#rest + 1] = line
    end
  end
  return trace, table.concat(rest, "\n")
end

function SeedProof.shim(): string
  return SHIM
end

function SeedProof.listed(root: string): {string} | nil, string
  local text, why = Fs.read(root .. "/build/seed.txt")
  if text == nil then
    return nil, why
  end
  local out: {string} = {}
  for line in text:gmatch("[^\n]+") do
    out[#out + 1] = line
  end
  return out, ""
end

function SeedProof.translate(root: string, paths: {string}, out: string): TreeWriter.Report | nil, string
  local allowance, why = TreeWriter.allowance(root)
  if allowance == nil then
    return nil, why
  end
  return TreeWriter.write(root, paths, out, { allowance = allowance, again = false, translator = nil, raw = false })
end

--- The name the seed writes the Lua of `file` under.
local function output_of(file: string): string
  return (file:match("([^/]*)%.tl$") or file) .. ".lua"
end

function SeedProof.compile(tree: string, files: {string}, out: string): {string: string} | nil, string
  local sources: {CompileGrammar.Source} = {}
  for _, file in ipairs(files) do
    local text, why = Fs.read(tree .. "/" .. file)
    if text == nil then
      return nil, why
    end
    sources[#sources + 1] = { path = file, relative = file, text = text, declaration = false }
  end
  local made = CompileGrammar.compile(sources)
  local lua: {string: string} = {}
  local problems: {string} = {}
  for index, compiled in ipairs(made) do
    local file = assert(files[index])
    for _, p in ipairs(compiled.syntax_errors) do
      problems[#problems + 1] = file .. ":" .. tostring(p.y) .. ":" .. tostring(p.x) .. ": " .. p.msg
    end
    if compiled.code == nil then
      problems[#problems + 1] = file .. ": no Lua" .. (compiled.trouble ~= "" and (": " .. compiled.trouble) or "")
    else
      lua[file] = compiled.code
    end
  end
  if #problems > 0 then
    return nil, table.concat(problems, "\n")
  end
  assert(Fs.mkdirs(out))
  for file, code in pairs(lua) do
    local written, why = Fs.write(out .. "/" .. output_of(file), code)
    if not written then
      return nil, why
    end
  end
  return lua, ""
end

--- The same files compiled by the cosmic `cosmic` (a path) in the grammar `grammar` (`new`, or `teal` for the fork's own
--- files), as `build.zig`'s seed step runs it from `tree`. The Lua by file.
local function compile_with(cosmic: string, grammar: string, tree: string, files: {string}, out: string):
    {string: string} | nil, string
  local argv: {string} = { cosmic, "compile" }
  if grammar ~= "teal" then
    argv[#argv + 1] = "--grammar"
    argv[#argv + 1] = grammar
  end
  argv[#argv + 1] = "-o"
  argv[#argv + 1] = out
  for _, file in ipairs(files) do
    argv[#argv + 1] = file
  end
  local ran, why = Child.run(argv, { cwd = tree, stdout = "capture", stderr = "capture" })
  if ran == nil then
    return nil, "compile with " .. cosmic .. " did not start: " .. why
  end
  if ran.code ~= 0 then
    return nil, "compile with " .. cosmic .. " failed: " .. (ran.stderr or "")
  end
  local lua: {string: string} = {}
  for _, file in ipairs(files) do
    -- A declaration file has no Lua.
    if file:match("%.d%.tl$") == nil then
      local text, read_why = Fs.read(out .. "/" .. output_of(file))
      if text == nil then
        return nil, read_why
      end
      lua[file] = text
    end
  end
  return lua, ""
end

--- Of `files`, the ones whose text differs between `a` and `b` (by file), in the order given.
local function differing(files: {string}, a: {string: string}, b: {string: string}): {string}
  local out: {string} = {}
  for _, file in ipairs(files) do
    if a[file] ~= b[file] then
      out[#out + 1] = file
    end
  end
  return out
end

function SeedProof.boot(core: string, tree: string, seed: string, args: {string}, env: {string: string}):
    SeedProof.Booted | nil, string
  local started = Clock.monotonic_ns()
  local argv: {string} = { core, "--boot", tree, seed }
  for _, word in ipairs(args) do
    argv[#argv + 1] = word
  end
  local ran, why = Child.run(argv,
    { env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(1500), capture_limit = 1 << 26 })
  if ran == nil then
    return nil, why
  end
  local trace, rest = split_trace(ran.stderr or "")
  return { code = ran.code, stdout = ran.stdout or "", trace = trace, stderr = rest, nanoseconds = Clock.monotonic_ns() - started }, ""
end

--- Seconds since `since`, as a figure for a line.
local function took(since: integer): string
  return string.format("%.1f s", (Clock.monotonic_ns() - since) / 1e9)
end

--- Runs `argv` in `cwd` with the environment `env` (this process's own where nil) and answers its end, nil and why if it
--- did not start. The program is found on the path of this process.
local function run(argv: {string}, cwd: string | nil, env: {string: string} | nil): Child.Result | nil, string
  local program, found_why = Proc.find(assert(argv[1]))
  if program == nil then
    return nil, found_why
  end
  return Child.run({ program, table.unpack(argv, 2) }, { cwd = cwd, env = env, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(1500), capture_limit = 1 << 26 })
end

--- Copies the files of the tree at `root` that git tracks to `to`, as a boot of it reads them.
local function copy_tracked(root: string, to: string): boolean, string
  local ran, why = run({ "sh", "-c", "git ls-files -z | tar --null -T - -cf - | tar -xf - -C \"$1\"", "copy", to }, root, nil)
  if ran == nil then
    return false, "copying the tree: " .. why
  end
  if ran.code ~= 0 then
    return false, "copying the tree: " .. (ran.stderr or "")
  end
  return true, ""
end

--- The last `count` lines of `text`.
local function tail(text: string, count: integer): string
  local lines: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local first = math.max(1, #lines - count)
  return table.concat(lines, "\n", first, #lines)
end

--- What a boot found: the bridge's steps and the end.
local function report(booted: SeedProof.Booted): {string}
  local lines: {string} = {}
  for _, line in ipairs(booted.trace) do
    lines[#lines + 1] = "  " .. line
  end
  if booted.stderr ~= "" then
    lines[#lines + 1] = "  " .. tail(booted.stderr, 12):gsub("\n", "\n  ")
  end
  return lines
end

local function say(lines: {string})
  for _, line in ipairs(lines) do
    print(line)
  end
end

--- Step 3: the closure check. Answers the failures.
local function closure_check(root: string, dir: string, seed: string, core: string): {string}
  local tree = dir .. "/tree"
  -- The headers boot derives the syscall declarations from, and the bridge that loads the new one.
  local names, names_why = Fs.list(root .. "/core")
  if names == nil then
    return { names_why }
  end
  for _, name in ipairs(names) do
    if name:match("%.h$") ~= nil then
      assert(Fs.write(tree .. "/core/" .. name, (assert(Fs.read(root .. "/core/" .. name)))))
    end
  end
  assert(Fs.write(tree .. "/core/bridge.lua", SeedProof.shim()))
  assert(Fs.write(tree .. "/core/bridge_new.lua", (assert(Fs.read(root .. "/core/bridge_new.lua")))))
  local started = Clock.monotonic_ns()
  -- build.boot asks for its host target and finds none: the closure is compiled and loaded by then.
  local booted, why = SeedProof.boot(core, tree, seed, { "status" }, { COSMIC_BRIDGE_TRACE = "1", COSMIC_BUILD_CACHE = "0" })
  if booted == nil then
    return { "the boot did not run: " .. why }
  end
  print("3. the bridge, cold, up to build.boot: " .. took(started))
  say(report(booted))
  local failures: {string} = {}
  local loaded = false
  for _, line in ipairs(booted.trace) do
    loaded = loaded or line:find("build.boot loaded", 1, true) ~= nil
  end
  if not loaded then
    failures[#failures + 1] = "the bridge did not reach build.boot"
  end
  return failures
end

--- The target records of build.zig and the name of the host this runs on.
local record Host
  records: string
  target: string
end

--- The host this runs on, nil and why for one with no core.
local function host_of(): Host | nil, string
  local ran, why = run({ "uname", "-sm" }, nil, nil)
  if ran == nil then
    return nil, why
  end
  local kernel, machine = (ran.stdout or ""):match("^(%S+)%s+(%S+)")
  local target: string | nil = nil
  if kernel == "Linux" and machine == "x86_64" then
    target = "x86_64-linux-musl"
  elseif kernel == "Linux" and (machine == "aarch64" or machine == "arm64") then
    target = "aarch64-linux-musl"
  elseif kernel == "Darwin" then
    target = "aarch64-macos"
  end
  if target == nil then
    return nil, "no target for " .. (ran.stdout or "")
  end
  return {
    records = "1\t1\trelease\tx86_64-linux-musl\tLinux\tx86_64\n" ..
      "2\t1\trelease\taarch64-linux-musl\tLinux\taarch64\n" ..
      "3\t1\trelease\taarch64-macos\tDarwin\tarm64\n",
    target = target,
  }, ""
end

--- Step 4: a boot of a copy of the repository, staged and assembled, and the tool it leaves. Answers the failures.
local function tool_check(root: string, dir: string, core: string, cosmic: string, list: {string}): {string}
  local copy = dir .. "/full"
  assert(Fs.mkdirs(copy))
  local started = Clock.monotonic_ns()
  local copied, copy_why = copy_tracked(root, copy)
  if not copied then
    return { copy_why }
  end
  -- The translated files over it, but for the fork's own bootstrap script, which the fork's seed step compiles in the fork's
  -- Teal; and the proof's own files, which the copy takes from the tree.
  local over, over_why = run({ "sh", "-c", "tar -C \"$1\" -cf - --exclude=build/checker_wrapper.tl . | tar -xf - -C \"$2\"", "over",
    dir .. "/tree", copy }, nil, nil)
  if over == nil or over.code ~= 0 then
    local said = over_why
    if over ~= nil then
      said = over.stderr or ""
    end
    return { "laying the translated files over the copy failed: " .. said }
  end
  assert(Fs.write(copy .. "/core/bridge_fork.lua", (assert(Fs.read(root .. "/core/bridge.lua")))))
  assert(Fs.write(copy .. "/core/bridge_new.lua", (assert(Fs.read(root .. "/core/bridge_new.lua")))))
  assert(Fs.write(copy .. "/core/bridge.lua", HYBRID))
  assert(Fs.write(copy .. "/build/seed.txt", (assert(Fs.read(root .. "/build/seed.txt")))))
  -- The switch writes the lines [`build.new_declarations`] edits into the files, and drops the edit; the copy has the lines
  -- already and stops the edit.
  local edits = assert(Fs.read(copy .. "/build/new_declarations.tl"))
  local patched, count = edits:gsub("NewDeclarations.files = {\n",
    "NewDeclarations.files = {}\n\nlocal _held_edits <const>: {string: {NewDeclarations.Edit}} = {\n", 1)
  if count ~= 1 then
    return { "build/new_declarations.tl no longer opens its table as the proof expects" }
  end
  assert(Fs.write(copy .. "/build/new_declarations.tl", patched))
  print("4. a copy of the repository with the translated files over it: " .. took(started))

  -- The fork's seed, for what still asks for a compiler, and the new one, from the copy.
  started = Clock.monotonic_ns()
  local listed_fork, listed_why = run({ "git", "ls-files", "checker/*.tl", "build/checker_wrapper.tl" }, root, nil)
  if listed_fork == nil then
    return { "listing the fork's files: " .. listed_why }
  elseif listed_fork.code ~= 0 then
    return { "listing the fork's files: " .. (listed_fork.stderr or "") }
  end
  local fork_files: {string} = {}
  for line in (listed_fork.stdout or ""):gmatch("[^\n]+") do
    fork_files[#fork_files + 1] = line
  end
  local forked, fork_why = compile_with(cosmic, "teal", root, fork_files, dir .. "/seed_fork")
  if forked == nil then
    return { fork_why }
  end
  local fresh, fresh_why = compile_with(cosmic, "new", copy, list, dir .. "/seed_copy")
  if fresh == nil then
    return { fresh_why }
  end
  print("   the fork's seed and the new seed of the copy: " .. took(started))

  local found, host_why = host_of()
  if found == nil then
    return { host_why }
  end
  local host = found.target
  local working = dir .. "/build_home"
  assert(Fs.mkdirs(working .. "/core/" .. host))
  assert(Fs.write(working .. "/core/" .. host .. "/cosmic-core", (assert(Fs.read(core))), 0x1ed))
  assert(Fs.write(working .. "/targets.tsv", found.records))
  local env: {string: string} = {
    PATH = Env.get_or("PATH", "/usr/bin:/bin"), HOME = Env.get_or("HOME", "/root"),
    COSMIC_GRAMMAR = "new", COSMIC_SEED_NEW = dir .. "/seed_copy", COSMIC_BRIDGE_TRACE = "1",
    COSMIC_BUILD_CACHE = dir .. "/cache.db", COSMIC_BUILD_HOME = working,
  }
  local dump = dir .. "/dump"
  assert(Fs.mkdirs(dump))
  env["COSMIC_BRIDGE_DUMP"] = dump
  started = Clock.monotonic_ns()
  local staged, staged_why = SeedProof.boot(core, copy, dir .. "/seed_fork", { "--host-only", "--stage", host, working .. "/targets.tsv", working }, env)
  if staged == nil then
    return { staged_why }
  end
  print("   --stage, cold, the tree compiled by the tool the bridge built (exit " .. tostring(staged.code) .. "): " .. took(started))
  say(report(staged))
  if staged.code ~= 0 then
    return { "--stage failed" }
  end
  started = Clock.monotonic_ns()
  local assembled, assembled_why = SeedProof.boot(core, copy, dir .. "/seed_fork", { "--host-only", "--assemble", host, working .. "/targets.tsv", working }, env)
  if assembled == nil then
    return { assembled_why }
  end
  print("   --assemble (exit " .. tostring(assembled.code) .. "): " .. took(started))
  say(report(assembled))
  if assembled.code ~= 0 then
    return { "--assemble failed" }
  end

  -- The tool: it boots (it runs a chunk), tests a small module, and checks a file.
  local failures: {string} = {}
  local tool = working .. "/bin/cosmic"
  local smoke: {{string}} = {
    { tool, "-e", "print(1 + 1)" },
    { tool, "test", "build/seed_test.tl" },
    { tool, "fix", "--check", "build/seed.tl" },
  }
  local run_env: {string: string} = {
    PATH = Env.get_or("PATH", "/usr/bin:/bin"), HOME = Env.get_or("HOME", "/root"),
    COSMIC_GRAMMAR = "new", COSMIC_BUILD_HOME = working, COSMIC_AUTO_BOOT = "0", COSMIC_BUILD_CACHE = dir .. "/cache.db",
  }
  for _, argv in ipairs(smoke) do
    started = Clock.monotonic_ns()
    local ran, ran_why = run(argv, copy, run_env)
    local label = table.concat(argv, " ", 2, #argv)
    if ran == nil then
      failures[#failures + 1] = label .. ": " .. ran_why
    else
      print("   " .. label .. ": exit " .. tostring(ran.code) .. ", " .. took(started))
      if ran.code ~= 0 then
        failures[#failures + 1] = label .. " exited " .. tostring(ran.code) .. ": " .. tail((ran.stdout or "") .. (ran.stderr or ""), 12)
      end
    end
  end
  return failures
end

function SeedProof.main(argv: {string}): integer
  local usage = "usage: bin/cosmic build/seed_proof_main.tl prove <dir> [--seed <cosmic>] [--tool]"
  if argv[1] ~= "prove" or argv[2] == nil then
    print(usage)
    return 2
  end
  local root = assert(Fs.absolute("."))
  local given = assert(argv[2])
  local dir = given
  if given:sub(1, 1) ~= "/" then
    dir = root .. "/" .. given
  end
  local seed_cosmic: string | nil = nil
  local tool = false
  local index = 3
  while argv[index] ~= nil do
    local word = assert(argv[index])
    if word == "--seed" then
      seed_cosmic = argv[index + 1]
      if seed_cosmic == nil then
        print(usage)
        return 2
      end
      index = index + 2
    elseif word == "--tool" then
      tool = true
      index = index + 1
    else
      print(usage)
      return 2
    end
  end
  local list, list_why = SeedProof.listed(root)
  if list == nil then
    print(list_why)
    return 1
  end
  assert(Fs.remove_tree(dir))
  assert(Fs.mkdirs(dir))

  local started = Clock.monotonic_ns()
  local paths, tracked_why = TreeWriter.tracked(root)
  if paths == nil then
    print("listing the tree: " .. tracked_why)
    return 1
  end
  local written, written_why = SeedProof.translate(root, paths, dir .. "/tree")
  if written == nil then
    print("translating: " .. written_why)
    return 1
  end
  print("1. translated " .. String.counted(#written.clean + #written.allowed, "file") .. " to " .. dir .. "/tree: " .. took(started))
  assert(Fs.write(dir .. "/tree/build/seed.txt", (assert(Fs.read(root .. "/build/seed.txt")))))

  started = Clock.monotonic_ns()
  local cosmic: string = seed_cosmic or (root .. "/bin/cosmic-bootstrap")
  local pinned, pinned_why = compile_with(cosmic, "new", dir .. "/tree", list, dir .. "/seed")
  if pinned == nil then
    print("2. " .. pinned_why)
    return 1
  end
  print("2. " .. cosmic .. " compiled " .. String.counted(#list, "file") .. " to " .. dir .. "/seed: " .. took(started))
  local ours, ours_why = SeedProof.compile(dir .. "/tree", list, dir .. "/own")
  if ours == nil then
    print("   this tool's compile of the seed's files failed: " .. ours_why)
    return 1
  end
  local differ = differing(list, pinned, ours)
  if #differ == 0 then
    print("   the seed equals this tool's compile of the same files: lang/SEED_DIFFERS is empty")
  else
    print("   the seed differs from this tool's compile in " .. table.concat(differ, ", ") .. ": lang/SEED_DIFFERS has to name them")
  end

  local trusted, trusted_why = artifact.trusted_core()
  if trusted == nil then
    print("3. no raw core to boot with: " .. trusted_why)
    return 1
  end
  local core = dir .. "/cosmic-core"
  assert(Fs.write(core, trusted.bytes, 0x1ed))
  local failures = closure_check(root, dir, dir .. "/seed", core)
  if tool then
    for _, failure in ipairs(tool_check(root, dir, core, cosmic, list)) do
      failures[#failures + 1] = failure
    end
  end
  for _, failure in ipairs(failures) do
    print("FAIL " .. failure)
  end
  return #failures == 0 and 0 or 1
end

return SeedProof
