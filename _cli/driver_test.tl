#!/usr/bin/env cosmic
-- Tests for _cli.driver: the derived fence around a recipe step.
--
-- The derivation is a pure function of (verb, args) and the paths that
-- exist, so it is tested directly rather than through a kernel that may
-- not support Landlock -- `unveil()` no-ops without it, and CI's
-- enforce lane is where the fence is proven live. What matters here is
-- that the plan says the right thing, and that it exists for every verb.

local build = require("_cli.build")
local grants = require("_cli.grants")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local sandbox = require("cosmic.sandbox")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function touch(name: string): string
  local path = fs.join(tmpdir, name)
  assert(fs.write(path, "x\n"))
  return path
end

local function has(list: {string}, want: string): boolean
  for _, v in ipairs(list or {}) do
    if v == want then
      return true
    end
  end
  return false
end

-- Every verb must have a shape, or its step would run unfenced. The
-- vocabulary lives in _cli.build and the shapes live here, so a verb
-- added to one without the other fails now rather than silently
-- shipping an unfenced step.
local function test_every_verb_has_a_shape()
  local missing: {string} = {}
  for _, verb in ipairs(build.verbs()) do
    if grants.plan(verb, {"a", "b", "c"}) == nil then
      missing[#missing + 1] = verb
    end
  end
  assert(#missing == 0,
    "verbs with no fence shape: " .. table.concat(missing, ", "))
end
test_every_verb_has_a_shape()

local function test_copy_reads_src_and_writes_dst_parent()
  local src = touch("fence-src.txt")
  local dst = fs.join(tmpdir, "fence-out.txt")
  local p = grants.plan("copy", {src, dst})
  assert(p is sandbox.Fs, "copy must plan a policy")
  assert(has(p.ro, src), "src must be readable")
  -- The DIRECTORY, not the file: creating dst is a right on its parent,
  -- and dst does not exist yet, so a rule naming it could not be opened.
  assert(has(p.rw, tmpdir), "dst's parent must be writable")
  assert(not has(p.rw, dst), "the not-yet-existing file must not be a rule")
  assert(not has(p.rw, src), "src must NOT be writable")
end
test_copy_reads_src_and_writes_dst_parent()

local function test_missing_reads_are_dropped()
  -- A rule naming a path that cannot be opened fails the whole
  -- restrict, and a fence that fails is a fence that is not there. The
  -- verb still reports its own "cannot open" error.
  local absent = fs.join(tmpdir, "fence-absent.txt")
  local p = grants.plan("copy", {absent, fs.join(tmpdir, "o.txt")})
  assert(p is sandbox.Fs, "copy must still plan")
  assert(not has(p.ro, absent), "a missing input must not become a rule")
end
test_missing_reads_are_dropped()

local function test_compile_execs_the_bootstrap()
  local boot = touch("fence-boot")
  local src = touch("fence-a.tl")
  local p = grants.plan("compile", {boot, src, fs.join(tmpdir, "a.lua")})
  assert(p is sandbox.Fs, "compile must plan a policy")
  assert(has(p.exec, boot), "the bootstrap must be executable")
  assert(has(p.ro, src), "the source must be readable")
  assert(has(p.rw, tmpdir), "the output's parent must be writable")
  assert(not has(p.rw, src), "the source must NOT be writable")
end
test_compile_execs_the_bootstrap()

-- The floor a COMPILE needs beyond its argv. The type checker reads
-- `tlconfig.lua` and resolves modules through the include directories,
-- and argv names neither -- so a fence derived from argv alone denied
-- every real compile, which is the concrete reason it could not become
-- the default. The DENIAL half of that canary needs a kernel
-- (`_cli/fence_test.tl`, enforce lane); what the plan CONTAINS is
-- checkable anywhere, so it is checked here, where it runs on every
-- commit.
local function test_a_compile_may_read_the_checkers_own_inputs()
  local boot = touch("fence-cfg-boot")
  local src = touch("fence-cfg.tl")
  local p = grants.plan("compile", {boot, src, fs.join(tmpdir, "c.lua")})
  assert(p is sandbox.Fs, "compile must plan a policy")
  assert(has(p.ro, "tlconfig.lua"),
    "a compile must be allowed to read tlconfig.lua")
  local teal = require("cosmic.teal")
  local granted = false
  for _, dir in ipairs(teal.get_default_include_dirs()) do
    if has(p.ro, dir) then
      granted = true
    end
  end
  assert(granted,
    "a compile must be allowed to read the include dirs modules resolve " ..
    "through; derived from cosmic.teal so the two cannot drift")

  -- REAL host paths only. Two include dirs live inside the executable's
  -- own zip, where `fs.is_dir` answers yes and the kernel knows nothing:
  -- handing one to Landlock fails the whole policy with EBADFD, so the
  -- fenced compile died instead of denying anything. They need no grant
  -- — they are bytes in a file the exec grant already covers.
  for _, dir in ipairs(p.ro) do
    assert(dir:sub(1, 5) ~= "/zip/" and dir ~= "/zip",
      "a zip-internal path must never reach the sandbox: " .. dir)
  end

  -- And only for the verbs that run the checker: `copy` moves bytes.
  local q = grants.plan("copy", {src, fs.join(tmpdir, "c2.tl")})
  assert(q is sandbox.Fs, "copy must plan a policy")
  assert(not has(q.ro, "tlconfig.lua"),
    "a verb that does not compile gets no compiler grants")

  -- The other half of what a compile reads: its import closure, which
  -- travels in the variadic tail as `--deps <files...>`. A search path
  -- (`--include-dir <dir>`) is NOT an input and must not be granted —
  -- granting it would hand over the whole tree and undo the closure.
  local dep = touch("fence-cfg-dep.tl")
  local withdeps = grants.plan("compile",
    {boot, src, fs.join(tmpdir, "c3.lua"), "--include-dir", tmpdir,
      "--deps", dep})
  assert(withdeps is sandbox.Fs, "compile must plan a policy")
  assert(has(withdeps.ro, dep), "a named dependency is readable")
  assert(not has(withdeps.ro, tmpdir),
    "…but the search path beside it is not")
end
test_a_compile_may_read_the_checkers_own_inputs()

local function test_remove_takes_a_variadic_tail()
  -- unlink is a right on the parent directory, so every path in the
  -- tail contributes its parent.
  local a, b = touch("fence-rm-a"), touch("fence-rm-b")
  local p = grants.plan("remove", {a, b})
  assert(p is sandbox.Fs, "remove must plan a policy")
  assert(has(p.rw, tmpdir), "the parent must be writable to unlink")
end
test_remove_takes_a_variadic_tail()

local function test_list_does_not_read_its_items()
  -- `write-list <out> [items...]`: the items are text written INTO out, not
  -- paths the step opens, so granting them would widen the fence for
  -- nothing.
  local item = touch("fence-item.tl")
  local p = grants.plan("write-list", {fs.join(tmpdir, "files.txt"), item})
  assert(p is sandbox.Fs, "write-list must plan a policy")
  assert(has(p.rw, tmpdir), "the output's parent must be writable")
  assert(not has(p.ro, item), "items are content, not reads")
end
test_list_does_not_read_its_items()

-- A foreign program's reads are not derivable from its arguments -- a
-- compiler reads headers nobody listed -- so exec is fenced to the
-- UNITS its argv touches rather than to those arguments. The
-- alternative is "." -- the whole working tree -- which is no fence at
-- all: a fence wants a directory
-- where a stage wants a file list.
local function test_exec_gets_its_units_not_the_whole_tree()
  local prog = touch("fence-tool")
  local p = grants.plan("exec", {prog, "--flag"})
  assert(p is sandbox.Fs, "exec must plan a policy")
  assert(has(p.exec, prog), "the program must be executable")
  assert(has(p.ro, tmpdir), "the program's own unit must be readable")
  assert(not has(p.ro, "."), "the whole working tree must NOT be readable")
  assert(not has(p.ro, "--flag"), "arguments are not paths")
end
test_exec_gets_its_units_not_the_whole_tree()

-- A path argument brings its own unit, so a step reading an input from
-- elsewhere gets that directory and no more.
local function test_exec_reads_the_units_its_arguments_name()
  local prog = touch("fence-tool2")
  local input = fs.join(tmpdir, "unit-input")
  assert(fs.make_dirs(input))
  local src = fs.join(input, "a.txt")
  assert(fs.write(src, "x\n"))
  local p = grants.plan("exec", {prog, src})
  assert(p is sandbox.Fs, "exec must plan a policy")
  assert(has(p.ro, input), "the argument's unit must be readable")
end
test_exec_reads_the_units_its_arguments_name()

-- A generation unit spans its whole subtree, so a path inside one
-- resolves to the directory holding the *_gen.tl -- not to the path's
-- own directory. That is the one case where a unit is bigger than a
-- package.
local function test_a_generation_unit_is_the_whole_subtree()
  local prog = touch("fence-tool3")
  local unit = fs.join(tmpdir, "gen-unit")
  local deep = fs.join(unit, "sub")
  assert(fs.make_dirs(deep))
  assert(fs.write(fs.join(unit, "index_gen.tl"), "return {}\n"))
  local src = fs.join(deep, "input.txt")
  assert(fs.write(src, "x\n"))
  local p = grants.plan("exec", {prog, src})
  assert(p is sandbox.Fs, "exec must plan a policy")
  assert(has(p.ro, unit),
    "the generation unit's root must be readable, got: " ..
    table.concat(p.ro, " "))
  assert(not has(p.ro, deep),
    "…and the leaf directory alone is not the unit")
end
test_a_generation_unit_is_the_whole_subtree()

local function test_an_argumentless_verb_still_plans()
  -- A malformed line still reaches the verb, which reports its own
  -- usage error; the fence must not throw on the way there. The
  -- runtime floor is still granted -- what must be absent is any grant
  -- derived from arguments that were not given.
  local p = grants.plan("copy", {})
  assert(p is sandbox.Fs, "an argument-less copy must still plan")
  for _, path in ipairs(p.ro) do
    assert(path:sub(1, 5) == "/dev/",
      "no arguments, so only the floor may be readable, got: " .. path)
  end
end
test_an_argumentless_verb_still_plans()

local function test_the_running_binary_stays_executable()
  -- compile and capture re-exec cosmic; a fence that revoked that would
  -- deny the step its own driver.
  local p = grants.plan("copy", {touch("fence-x"), fs.join(tmpdir, "y")})
  assert(p is sandbox.Fs, "copy must plan a policy")
  if arg[-1] ~= nil then
    assert(has(p.exec, arg[-1]), "the running binary must stay executable")
  end
end
test_the_running_binary_stays_executable()

local function test_a_childs_own_paths_are_readable()
  -- `tee <out> <cmd> [args...]` hands the tail to a child: those
  -- arguments are the child's inputs (`--report o/x.got`), and the
  -- fence is inherited across the spawn, so the parent must grant
  -- them. Flags are not paths and drop out by not existing.
  local got = touch("fence-report.got")
  local p = grants.plan("tee", {fs.join(tmpdir, "sum.txt"), "cosmic", "--report", got})
  assert(p is sandbox.Fs, "tee must plan a policy")
  assert(has(p.ro, got), "the child's input must be readable")
  assert(not has(p.ro, "--report"), "a flag is not a path")
end
test_a_childs_own_paths_are_readable()

local function test_every_step_can_extract_and_run_the_ape_loader()
  -- A fat APE is a shell prologue the kernel will not load, so it
  -- extracts a small loader into `${TMPDIR:-${HOME:-.}}` and execs
  -- that. Granting write alone leaves the exec denied, and the parent
  -- reports ENOEXEC -- which reads like a corrupt binary rather than a
  -- denied path, and is the exact failure that turned the gate red
  -- once the fence became the default.
  local dir = fs.join(tmpdir, "apedir")
  assert(fs.make_dirs(dir))
  local prev = env.get("TMPDIR")
  env.set("TMPDIR", dir, true)
  local p = grants.plan("exec", {fs.join(dir, "tool")})
  if prev then env.set("TMPDIR", prev, true) else env.unset("TMPDIR") end
  assert(p is sandbox.Fs, "exec must plan a policy")
  assert(has(p.rw, dir), "the loader needs somewhere to be extracted")
  assert(has(p.exec, dir),
    "and the DIRECTORY must be executable: `mv -f` over an existing " ..
    "loader makes a new inode, and a rule names the inode it opened")
end
test_every_step_can_extract_and_run_the_ape_loader()

-- The claim the old ape grant rested on -- "every step gets a scratch
-- TMPDIR" -- was false: nothing set one, an unset TMPDIR fell through
-- to $HOME, and the fence granted rw+exec on the WHOLE home directory.
-- driver.ensure_build_tmpdir closes it: with TMPDIR unset it pins a
-- scratch under o/, and the grant follows there instead of $HOME.
local function test_an_unset_tmpdir_is_pinned_under_o_not_home()
  local driver = require("_cli.driver")
  local home = fs.join(tmpdir, "fakehome")
  local box = fs.join(tmpdir, "tmpbox")
  assert(fs.make_dirs(home))
  assert(fs.make_dirs(box))
  -- A loader in $HOME must be SEEDED into the pinned scratch: a nested
  -- driver (spawned by a fenced test) cannot read $HOME to find it, so
  -- its $TMPDIR probe is the one that has to hit.
  assert(fs.write(fs.join(home, ".ape-9.9"), "pretend loader"))
  local cwd = assert(fs.cwd())
  local prev_t, prev_h = env.get("TMPDIR"), env.get("HOME")
  assert(fs.chdir(box))
  env.unset("TMPDIR")
  env.set("HOME", home, true)

  driver.ensure_build_tmpdir()
  local pinned = env.get("TMPDIR")
  local seeded = pinned ~= nil
  and fs.is_file(fs.join(pinned as string, ".ape-9.9")) -- cast: guarded
  local p = grants.plan("record", {fs.join(box, "out")})

  assert(fs.chdir(cwd))
  if prev_t ~= nil then env.set("TMPDIR", prev_t, true) else env.unset("TMPDIR") end
  if prev_h ~= nil then env.set("HOME", prev_h, true) else env.unset("HOME") end

  assert(pinned ~= nil, "an unset TMPDIR must be pinned, got nil")
  local pin = pinned as string -- cast: asserted non-nil on the line above
  assert(pin:find("o/tmp", 1, true),
    "an unset TMPDIR must be pinned under o/, got: " .. pin)
  assert(seeded, "the $HOME loader must be seeded into the scratch")
  assert(p is sandbox.Fs, "record must plan a policy")
  assert(has(p.rw, pin) and has(p.exec, pin),
    "the o/ scratch is the extraction dir: rw AND exec")
  assert(not has(p.rw, home) and not has(p.exec, home),
    "and the home directory itself is never granted")
end
test_an_unset_tmpdir_is_pinned_under_o_not_home()

-- execve caches TMPDIR and HOME at each process's own startup, so the
-- driver -- whose TMPDIR the pin set after it started -- still probes
-- $HOME/.ape-<v>: the loader the unfenced bootstrap already extracted.
-- That probe needs the FILE, and only the file; the directory around
-- it is the over-grant the pin exists to remove.
local function test_an_existing_home_loader_is_granted_as_a_file_only()
  local home = fs.join(tmpdir, "loaderhome")
  assert(fs.make_dirs(home))
  local loader = fs.join(home, ".ape-1.10")
  assert(fs.write(loader, "pretend loader"))
  local scratch = fs.join(tmpdir, "loader-scratch")
  assert(fs.make_dirs(scratch))
  local prev_t, prev_h = env.get("TMPDIR"), env.get("HOME")
  env.set("TMPDIR", scratch, true)
  env.set("HOME", home, true)
  local p = grants.plan("copy",
    {touch("loader-src"), fs.join(tmpdir, "loader-dst")})
  if prev_t ~= nil then env.set("TMPDIR", prev_t, true) else env.unset("TMPDIR") end
  if prev_h ~= nil then env.set("HOME", prev_h, true) else env.unset("HOME") end
  assert(p is sandbox.Fs, "copy must plan a policy")
  assert(has(p.exec, loader), "the existing home loader file is exec-granted")
  assert(not has(p.rw, home) and not has(p.exec, home),
    "the home directory itself is never granted")
end
test_an_existing_home_loader_is_granted_as_a_file_only()

local function test_a_program_that_is_not_there_is_not_a_rule()
  -- A landlock rule is an OPEN, so naming a path that does not exist
  -- fails the whole policy — and a fence that cannot be constructed
  -- reports a sandbox error where the verb's own refusal belongs.
  -- `exec sh -c true` is the shape: `exec` exists to refuse a program
  -- outside the build root, and a bare `sh` resolves to nothing.
  local p = grants.plan("exec", {"sh", "-c", "true"})
  assert(p is sandbox.Fs, "exec must still plan a policy")
  assert(not has(p.exec, "sh"),
    "a program that is not there must not become a rule")
end
test_a_program_that_is_not_there_is_not_a_rule()

local function test_the_coverage_directory_is_granted_before_it_exists()
  -- The step CREATES this directory, so asking `isdir` first always
  -- said no and the grant was never added. Nothing errors when that
  -- happens — the step runs, the tests pass, and only the `.cov` dump
  -- at exit is denied — so it surfaced as three recipe-path files
  -- losing most of their coverage at once.
  local cov = fs.join(tmpdir, "cov-not-yet", "deeper")
  fs.remove_all(fs.dirname(cov))
  local prev = env.get("COSMIC_COVERAGE")
  env.set("COSMIC_COVERAGE", cov, true)
  local p = grants.plan("write-list", {fs.join(tmpdir, "out.txt")})
  -- `1` is the OTHER meaning of the variable — collect, but name no
  -- directory — which is what the coverage make rules set. Taken as a
  -- path it creates `./1` in the project root.
  env.set("COSMIC_COVERAGE", "1", true)
  local flagged = grants.plan("write-list", {fs.join(tmpdir, "out.txt")})
  if prev then
    env.set("COSMIC_COVERAGE", prev, true)
  else
    env.unset("COSMIC_COVERAGE")
  end
  assert(p is sandbox.Fs, "write-list must plan a policy")
  assert(has(p.rw, cov), "the coverage directory must be writable")
  assert(flagged is sandbox.Fs, "and still plan one for the flag form")
  assert(not has(flagged.rw, "1"), "`1` is a flag, not a directory")
end
test_the_coverage_directory_is_granted_before_it_exists()

local function test_the_runtime_floor_is_granted()
  -- Derived-from-argv says nothing about what every process needs.
  local p = grants.plan("write-list", {fs.join(tmpdir, "out.txt")})
  assert(p is sandbox.Fs, "write-list must plan a policy")
  assert(has(p.rw, "/dev/null"), "/dev/null must be writable")
  assert(has(p.ro, "/dev/urandom"), "/dev/urandom must be readable")
end
test_the_runtime_floor_is_granted()

-- The two nils are different answers and the caller acts on the
-- difference. A shapeless verb has nothing to fence; a plan that could
-- not create its output directory FAILED, and returning that as a bare
-- nil would read as "nothing to fence" -- dispatching the step with no
-- Landlock at all, which is the opposite of the refusal intended.
local function test_a_underivable_plan_is_an_error_not_an_absence()
  -- A regular file cannot be a parent directory, so the verb's own
  -- makedirs on `<file>/nope` fails the way a real ENOTDIR would.
  local blocker = touch("fence-blocker")
  local doomed = fs.join(blocker, "nope", "out.txt")
  local p, err = grants.plan("write-list", {doomed})
  assert(p == nil, "a plan that cannot create its output must not be returned")
  assert(err ~= nil, "and it must say why, or it reads as `no shape`")
  -- `string | nil` is a declared union, which `or` does not narrow;
  -- the assert above is what guarantees this is the real message.
  local msg = tostring(err)
  assert(msg:find("cannot create", 1, true),
    "expected the makedirs failure named, got: " .. msg)

  -- The other nil, for contrast: no shape, no error.
  local q, qerr = grants.plan("no-such-verb", {"a"})
  assert(q == nil, "an unknown verb plans nothing")
  assert(qerr == nil, "and says nothing -- that is what makes it distinct")
end
test_a_underivable_plan_is_an_error_not_an_absence()
