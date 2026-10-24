local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Local = require("run_local")
local Maps = require("cosmic_ci.maps")
local Hash = require("cosmic.hash")
local Predicate = require("cosmic_ci.fs_predicate")
local Proc = require("cosmic.proc")
local Signal = require("cosmic.signal")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

Test.policy{ profiles = { "system", "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A number a stand-in keeps.
local record Count
  value: integer
end

--- A string a stand-in keeps.
local record Text
  value: string
end

local function git(root: string, args: {string}): string
  local argv = { assert(Proc.find("git")), "-C", root }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(10) }))
  assert(result.code == 0, result.stderr)
  return ((assert(result.stdout)):gsub("\n$", ""))
end

--- A real Git checkout and a phase tool that records its inputs. Tests
--- of snapshot mechanics use the ordinary path; native CI separately
--- proves the unmodified root entry changes credentials.
local function checkout(tmp: string): string, {string:string}
  local root = tmp .. "/source tree"
  assert(Fs.mkdirs(root .. "/o/bin") and Fs.mkdirs(root .. "/ci/cosmic_ci"))
  assert(Fs.write(root .. "/ci/cosmic_ci/driver.tl", "fixture driver\n"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/paths.tl", "local Fs = require(\"cosmic.fs\")\nlocal record Paths end\nfunction Paths.main(argv: {string}): integer\n  assert(Fs.put(Fs.stdout, argv[1] .. \"/o\\n\"))\n  return 0\nend\nreturn Paths\n"))
  assert(Fs.write(root .. "/tracked", "old\n"))
  assert(Fs.write(root .. "/ci/run_local.tl", "fixture entry\n"))
  assert(Fs.write(root .. "/.gitignore", "o/\nignored\n"))
  assert(Fs.write(root .. "/o/bin/cosmic", [[#!/bin/sh
set -eu
phase=$3
printf '%s\n' "$phase" >> "$TRACE"
printf '%s\n' "$GITHUB_WORKSPACE" "$RUNNER_TEMP" "$TARGET" "$COSMIC_ZIG_CACHE_FROM" "$COSMIC_ZIG_GLOBAL_CACHE" "$XDG_CACHE_HOME" > "$TRACE.env"
printf '%s\n' "$PWD" > "$TRACE.cwd"
if [ "$phase" = fail ]; then
  printf 'error: selected phase failed\n'
  exit 23
fi
]], 0x1ed))
  git(root, { "init", "--quiet" })
  git(root, { "config", "user.name", "runner fixture" })
  git(root, { "config", "user.email", "fixture@example.invalid" })
  git(root, { "add", "-A" })
  git(root, { "commit", "--quiet", "-m", "initial" })
  local env = Maps.with(Env.all(), { COSMIC_CI_LOCAL = tmp .. "/private state", COSMIC_ZIG_CACHE = tmp .. "/seed",
    COSMIC_ZIG_GLOBAL_CACHE = tmp .. "/global cache", TRACE = tmp .. "/trace", TMPDIR = tmp })
  return root, env
end

local function invoke(root: string, env: {string:string}, phases: {string}, uid?: integer): integer, string
  local seams = Local.calls()
  local all, getuid, put = seams.env_all, seams.sys_getuid, seams.fs_put
  local messages: {string} = {}
  seams.env_all = function(): {string:string} return env end
  -- This selects the ordinary path for snapshot tests on a root-only
  -- development host. It is not credential-transition evidence.
  seams.sys_getuid = function(): integer return uid or 1000 end
  seams.fs_put = function(fd: integer, bytes: string): boolean, string
    if fd == Fs.stderr then
      messages[#messages + 1] = bytes
      return true, ""
    end
    return put(fd, bytes)
  end
  local status: Count = { value = -1 }
  local called, raised = pcall(function()
    status.value = Local.run(phases, root .. "/ci/run_local.tl")
  end)
  seams.env_all, seams.sys_getuid, seams.fs_put = all, getuid, put
  assert(called, tostring(raised))
  return status.value, table.concat(messages)
end

--- What [`invoke`] came to, a raise caught.
local record Tried
  ok: boolean
  code: integer
  diagnostic: string
  raised: string
end

local function trying(root: string, env: {string:string}, phases: {string}, uid?: integer): Tried
  local tried: Tried = { ok = false, code = -1, diagnostic = "", raised = "" }
  local called, raised = pcall(function()
    local code, diagnostic = invoke(root, env, phases, uid)
    tried.code, tried.diagnostic = code, diagnostic
  end)
  tried.ok = called
  if not called then tried.raised = tostring(raised) end
  return tried
end

local function test_snapshot_keeps_working_changes_and_the_real_index(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/tracked", "working\n"))
  assert(Fs.write(root .. "/untracked", "new\n"))
  assert(Fs.write(root .. "/ignored", "excluded\n"))
  local index = assert(Fs.read(root .. "/.git/index"))
  local stash = git(root, { "stash", "list" })
  assert(invoke(root, env, { "build" }) == 0)
  local candidate = assert(Fs.absolute(assert(env["COSMIC_CI_LOCAL"]) .. "/candidate"))
  assert(Fs.read(candidate .. "/tracked") == "working\n")
  assert(Fs.read(candidate .. "/untracked") == "new\n")
  assert(Predicate.exists(candidate .. "/ignored") == false)
  assert(Fs.read(root .. "/.git/index") == index and git(root, { "stash", "list" }) == stash)
  assert(Predicate.exists(root .. "/ci/o") == false, "source CI database was created")
  local environment = assert(Fs.read(assert(env["TRACE"]) .. ".env"))
  assert(environment:find(candidate, 1, true) and environment:find(assert(env["COSMIC_ZIG_CACHE"]), 1, true) and
      environment:find(assert(env["COSMIC_ZIG_GLOBAL_CACHE"]), 1, true), "spaced paths or cache inputs changed")
end

local function test_snapshot_keeps_tracked_and_force_added_ignored_files(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/tracked", "updated tracked\n"))
  assert(Fs.write(root .. "/.gitignore", "o/\ntracked\nforced\nignored\n"))
  assert(Fs.write(root .. "/forced", "forced staged\n"))
  git(root, { "add", "-f", "forced" })
  local index = assert(Fs.read(root .. "/.git/index"))
  assert(invoke(root, env, { "build" }) == 0)
  local candidate = assert(Fs.absolute(assert(env["COSMIC_CI_LOCAL"]) .. "/candidate"))
  assert(Fs.read(candidate .. "/tracked") == "updated tracked\n")
  assert(Fs.read(candidate .. "/forced") == "forced staged\n")
  assert(Fs.read(root .. "/.git/index") == index, "private snapshot changed the actual index")
end

--- A named rerun copies ci/ afresh, the candidate kept; the driver's
--- database is in the project's build directory, outside the copy, and
--- an o/ an older driver left in it goes with the rest.
local function test_named_rerun_refreshes_ci_but_keeps_candidate(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "build" }) == 0)
  local state = env["COSMIC_CI_LOCAL"]
  assert(Fs.mkdirs(assert(state) .. "/ci/o"))
  assert(Fs.write(assert(state) .. "/ci/o/sentinel", "stale"))
  assert(Fs.write(assert(state) .. "/ci/obsolete", "remove"))
  assert(Fs.write(root .. "/ci/cosmic_ci/driver.tl", "edited fixture\n"))
  assert(Fs.write(root .. "/tracked", "later\n"))
  assert(invoke(root, env, { "fixtures" }) == 0)
  assert(Fs.read(assert(state) .. "/candidate/tracked") == "old\n")
  assert(Fs.read(assert(state) .. "/ci/cosmic_ci/driver.tl") == "edited fixture\n")
  assert(Predicate.exists(assert(state) .. "/ci/o") == false)
  assert(Predicate.exists(assert(state) .. "/ci/obsolete") == false)
  assert(Fs.read(assert(env["TRACE"])) == "build\nfixtures\n")
end

local function test_default_phases_keep_the_workflow_order(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, {}) == 0)
  assert(Fs.read(assert(env["TRACE"])) ==
      "build\nlocal-boundary\ndeclared-types\ndarwin-suite\nsandbox\nassemble\nfixtures\nportable\nportable-boundary\n")
end

local function test_phase_failure_stops_and_preserves_its_status(tmp: string)
  local root, env = checkout(tmp)
  local code, diagnostic = invoke(root, env, { "build", "fail", "fixtures" })
  assert(code == 23 and diagnostic:find("error: selected phase failed", 1, true) ~= nil)
  assert(Fs.read(assert(env["TRACE"])) == "build\nfail\n")
end

local function test_failed_log_is_bounded_and_never_read_whole(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/o/bin/cosmic", [[#!/bin/sh
head -c 200000 /dev/zero | tr '\000' x
printf '\nerror: too late\n'
exit 29
]], 0x1ed))
  local seams = Local.calls()
  local read = seams.fs_read
  seams.fs_read = function(path: string): string | nil, string
    assert(not path:match("/logs/.*%.log$"), "failure log was read whole")
    return read(path)
  end
  local tried = trying(root, env, { "build" })
  seams.fs_read = read
  assert(tried.ok, tried.raised)
  assert(tried.code == 29 and #tried.diagnostic < 70000 and tried.diagnostic:find("log diagnostics stopped", 1, true) ~= nil)
end

local function test_state_paths_refuse_containment_and_symlink_roots(tmp: string)
  local root, env = checkout(tmp)
  for _, path in ipairs({ root .. "/state", root, tmp, "/", "relative" }) do
    assert(invoke(root, Maps.with(env, { COSMIC_CI_LOCAL = path }), { "build" }) == 2, "unsafe state accepted: " .. path)
  end
  local outside = tmp .. "/outside"
  assert(Fs.mkdirs(outside) and Fs.write(outside .. "/sentinel", "unchanged"))
  assert(Fs.chmod(outside, 0x1c0))
  local link = tmp .. "/state-link"
  assert(Fs.symlink(outside, link))
  assert(invoke(root, Maps.with(env, { COSMIC_CI_LOCAL = link }), { "build" }) == 2)
  assert(Fs.read(outside .. "/sentinel") == "unchanged" and assert(Fs.stat(outside)).mode & 0x1ff == 0x1c0)
end

local function test_default_base_symlink_is_refused_before_mutation(tmp: string)
  local root, env = checkout(tmp)
  local outside = tmp .. "/outside"
  assert(Fs.mkdirs(outside) and Fs.write(outside .. "/sentinel", "unchanged"))
  assert(Fs.chmod(outside, 0x1c0))
  assert(Fs.symlink(outside, tmp .. "/cosmic-ci-local-0"))
  assert(invoke(root, Maps.without(env, { "COSMIC_CI_LOCAL" }), { "build" }, 0) == 2)
  assert(Fs.read(outside .. "/sentinel") == "unchanged" and assert(Fs.stat(outside)).mode & 0x1ff == 0x1c0)
  assert(#assert(Fs.list(outside)) == 1, "refusal created state beneath symlink target")
end

local function test_root_account_refusal_creates_no_state(tmp: string)
  local root, env = checkout(tmp)
  for _, name in ipairs({ "root", "cosmic-user-that-does-not-exist-95672" }) do
    assert(invoke(root, Maps.with(env, { COSMIC_CI_LOCAL_USER = name }), { "build" }, 0) == 2)
    assert(Predicate.exists(assert(env["COSMIC_CI_LOCAL"])) == false and Predicate.exists(assert(env["TRACE"])) == false)
  end
end

local function test_credential_setup_refusal_precedes_state_and_phase(tmp: string)
  local root, env = checkout(tmp)
  local seams = Local.calls()
  local user, run = seams.proc_user, seams.child_run
  seams.proc_user = function(_name: string): Proc.User | nil, string
    return { uid = 65532, gid = 65532 }, ""
  end
  seams.child_run = function(argv: {string}, options?: Child.Options): Child.Result | nil, string
    if options and options.credentials then return nil, "injected credential refusal" end
    return run(argv, options)
  end
  local tried = trying(root, env, { "build" }, 0)
  seams.proc_user, seams.child_run = user, run
  assert(tried.ok, tried.raised)
  assert(tried.code == 2 and tried.diagnostic:find("injected credential refusal", 1, true) ~= nil)
  assert(Predicate.exists(assert(env["COSMIC_CI_LOCAL"])) == false and Predicate.exists(assert(env["TRACE"])) == false)
end

local function test_snapshot_error_cleans_private_index_and_keeps_old_candidate(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "build" }) == 0)
  local candidate = assert(Fs.absolute(assert(env["COSMIC_CI_LOCAL"]) .. "/candidate"))
  local snapshot = git(candidate, { "rev-parse", "HEAD" })
  assert(Fs.write(root .. "/.git/hooks/pre-commit", "unused"))
  assert(Fs.write(root .. "/.git/index", "corrupt private-index source"))
  assert(invoke(root, env, { "build" }) == 2)
  assert(git(candidate, { "rev-parse", "HEAD" }) == snapshot)
  for _, entry in ipairs((assert(Fs.list(tmp)))) do
    assert(not entry:match("^cosmic%-ci%-local%-index%."), "private index scratch survived failure")
  end
end

local function test_missing_candidate_and_invalid_phase_are_refused(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "fixtures" }) == 2)
  assert(Predicate.exists(assert(env["TRACE"])) == false)
  assert(invoke(root, env, { "../escape" }) == 2)
  assert(Predicate.exists(tmp .. "/escape.log") == false)
end

local function test_state_ancestor_alias_cannot_place_state_inside_checkout(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.symlink(root, tmp .. "/checkout-alias"))
  assert(invoke(root, Maps.with(env, { COSMIC_CI_LOCAL = tmp .. "/checkout-alias/state" }), { "build" }) == 2)
  assert(Predicate.exists(root .. "/state") == false and Predicate.exists(assert(env["TRACE"])) == false)
end

local function test_phase_log_symlink_target_is_unchanged(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "build" }) == 0)
  local outside = tmp .. "/outside-log"
  assert(Fs.write(outside, "retain bytes"))
  assert(Fs.symlink(outside, assert(env["COSMIC_CI_LOCAL"]) .. "/logs/fixtures.log"))
  assert(invoke(root, env, { "fixtures" }) == 2)
  assert(Fs.read(outside) == "retain bytes" and Fs.read(assert(env["TRACE"])) == "build\n")
end

local function test_failure_diagnostics_stop_after_twenty_matching_lines(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/o/bin/cosmic", [[#!/bin/sh
i=1
while [ "$i" -le 30 ]; do printf 'error: line %s\n' "$i"; i=$((i+1)); done
exit 31
]], 0x1ed))
  local code, diagnostic = invoke(root, env, { "build" })
  assert(code == 31 and diagnostic:find("error: line 20\n", 1, true) ~= nil and
      not diagnostic:find("error: line 21\n", 1, true))
  assert(assert(Fs.read(assert(env["COSMIC_CI_LOCAL"]) .. "/logs/build.log")):find("error: line 30\n", 1, true),
    "bounded diagnostics truncated the retained log")
end

--- Execute the copied runtime as the current user solely to check its
--- real startup/descriptor identity. The intercepted credential preflight
--- still returns refusal; native CI proves the unmodified dropped launch.
local function test_root_probe_grants_a_copy_without_mutating_cached_relaunch(tmp: string)
  local root, env = checkout(tmp)
  local launched = assert(Proc.relaunch())
  local slot = assert(math.tointeger(tonumber(launched.env["COSMIC_PORTABLE_CORE_FD"])))
  local borrowed = assert(launched.fds[slot])
  local original = assert(Fs.stat(assert(launched.argv[1])))
  local digest = Hash.hex_sha256((assert(Fs.read(assert(launched.argv[1])))))
  local argv_before = table.concat(launched.argv, "\0")
  local owner = sys.getuid()
  local at = assert(sys.lseek(borrowed, 0, sys.SEEK_CUR))
  assert(sys.lseek(borrowed, 13, sys.SEEK_SET))
  local seams = Local.calls()
  local user, run = seams.proc_user, seams.child_run
  local scratch: Text = { value = "" }
  local handed: Count = { value = -1 }
  local entered: Count = { value = 0 }
  seams.proc_user = function(_name: string): Proc.User | nil, string
    return { uid = 65532, gid = 65532 }, ""
  end
  seams.child_run = function(words: {string}, options?: Child.Options): Child.Result | nil, string
    if not options or not options.credentials then return run(words, options) end
    entered.value = entered.value + 1
    scratch.value = Fs.dirname(assert(words[1]))
    assert(words[1] ~= launched.argv[1] and assert(Fs.stat(scratch.value)).mode & 0x1ff == 0x1c9)
    local file = assert(Fs.stat(assert(words[1])))
    assert(file.uid == owner and file.mode & 0x1ff == 0x16d and file.size == original.size)
    assert(Hash.hex_sha256((assert(Fs.read(assert(words[1]))))) == digest)
    local option_fds, option_env = assert(options.fds), assert(options.env)
    local given = option_fds[slot]
    if given is integer then
      handed.value = given
    else
      error("the runtime grant is not a descriptor")
    end
    assert(handed.value ~= borrowed and assert(sys.fstat(handed.value)).ino == file.ino)
    for number, fd in pairs(launched.fds) do
      assert(option_fds[number] == (number == slot and handed.value or fd), "another runtime grant changed")
    end
    for name, value in pairs(launched.env) do assert(option_env[name] == value) end
    local probe: {string} = {}
    for position, word in ipairs(words) do
      if position < #words then probe[#probe + 1] = word end
    end
    probe[#probe + 1] = "assert(require('cosmic.proc').executable()==" ..
      string.format("%q", tostring((assert(Proc.executable())))) .. "); print('copied runtime identity')"
    local result = assert(run(probe, { env = options.env, fds = options.fds, cwd = "/",
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) }))
    assert(result.ok and result.stdout == "copied runtime identity\n", result.stderr)
    return nil, "injected credential refusal after copied-runtime check"
  end
  local tried = trying(root, env, { "build" }, 0)
  seams.proc_user, seams.child_run = user, run
  local after_offset = assert(sys.lseek(borrowed, 0, sys.SEEK_CUR))
  assert(sys.lseek(borrowed, at, sys.SEEK_SET))
  assert(tried.ok, tried.raised)
  assert(tried.code == 2 and tried.diagnostic:find("injected credential refusal", 1, true) ~= nil and entered.value == 1)
  assert(after_offset == 13 and table.concat(launched.argv, "\0") == argv_before and launched.fds[slot] == borrowed)
  local after = assert(Fs.stat(assert(launched.argv[1])))
  assert(after.ino == original.ino and after.mode == original.mode and
      Hash.hex_sha256((assert(Fs.read(assert(launched.argv[1]))))) == digest)
  assert(scratch.value ~= "" and Predicate.exists(scratch.value) == false and sys.fstat(handed.value) == nil,
    "refusal leaked the runtime scratch or descriptor")
  assert(Predicate.exists(assert(env["COSMIC_CI_LOCAL"])) == false and Predicate.exists(assert(env["TRACE"])) == false)
end

local function test_runtime_copy_failure_cleans_up_before_any_credential_child(tmp: string)
  local root, env = checkout(tmp)
  local seams = Local.calls()
  local user, pread, mkdtemp = seams.proc_user, seams.sys_pread, seams.sys_mkdtemp
  local scratch: Text = { value = "" }
  seams.proc_user = function(_name: string): Proc.User | nil, string
    return { uid = 65532, gid = 65532 }, ""
  end
  seams.sys_mkdtemp = function(template: string): string | nil, string, integer
    local path, why, errno = mkdtemp(template)
    if template:find("cosmic-local-runtime", 1, true) then scratch.value = path or "" end
    return path, why, errno
  end
  seams.sys_pread = function(_fd: integer, _count: integer, _offset: integer): string | nil, string, integer
    return nil, "injected runtime read failure", 5
  end
  local tried = trying(root, env, { "build" }, 0)
  seams.proc_user, seams.sys_pread, seams.sys_mkdtemp = user, pread, mkdtemp
  assert(tried.ok, tried.raised)
  assert(tried.code == 2 and tried.diagnostic:find("injected runtime read failure", 1, true) ~= nil)
  assert(scratch.value ~= "" and Predicate.exists(scratch.value) == false and Predicate.exists(assert(env["COSMIC_CI_LOCAL"])) == false)
end

local function test_ordinary_runner_creates_no_runtime_handoff(tmp: string)
  local root, env = checkout(tmp)
  local seams = Local.calls()
  local mkdtemp = seams.sys_mkdtemp
  local copies: Count = { value = 0 }
  seams.sys_mkdtemp = function(template: string): string | nil, string, integer
    if template:find("cosmic-local-runtime", 1, true) then copies.value = copies.value + 1 end
    return mkdtemp(template)
  end
  local tried = trying(root, env, { "build", "fixtures" })
  seams.sys_mkdtemp = mkdtemp
  assert(tried.ok, tried.raised)
  assert(tried.code == 0 and copies.value == 0)
end

local function test_cancelled_credential_probe_removes_its_runtime_grant(tmp: string)
  local root, env = checkout(tmp)
  local outer = assert(Signal.guard())
  local ran, raised = pcall(function()
    local seams = Local.calls()
    local user, run = seams.proc_user, seams.child_run
    local scratch: Text = { value = "" }
    seams.proc_user = function(_name: string): Proc.User | nil, string
      return { uid = 65532, gid = 65532 }, ""
    end
    seams.child_run = function(words: {string}, options?: Child.Options): Child.Result | nil, string
      if not options or not options.credentials then return run(words, options) end
      scratch.value = Fs.dirname(assert(words[1]))
      assert(sys.kill(sys.getpid(), sys.SIGTERM))
      return nil, "cancelled credential probe"
    end
    local tried = trying(root, env, { "build" }, 0)
    seams.proc_user, seams.child_run = user, run
    local signal = assert(outer:release())
    assert(tried.ok, tried.raised)
    assert(tried.code == 2 and signal == sys.SIGTERM and scratch.value ~= "" and Predicate.exists(scratch.value) == false)
    assert(Predicate.exists(assert(env["COSMIC_CI_LOCAL"])) == false)
  end)
  local _, _ = outer:close()
  if not ran then error(raised, 0) end
end

--- The open descriptors of this process, each with what it names.
local function descriptors(): string
  local out: {string} = {}
  -- /dev/fd where there is no /proc (macOS, the BSDs).
  local directory = "/proc/self/fd"
  if Predicate.is_dir(directory) ~= true then directory = "/dev/fd" end
  for _, number in ipairs((assert(Fs.list(directory)))) do
    local target, _ = Fs.readlink(directory .. "/" .. number)
    out[#out + 1] = number .. "=" .. (target or "?")
  end
  table.sort(out)
  return table.concat(out, "\n")
end

--- A run that ends well must let go of the phase logs it holds: [`Local.run`] releases what it holds on every path,
--- not only after an error.
local function test_a_successful_run_closes_the_descriptors_it_held(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "build" }) == 0)
  local before = descriptors()
  assert(invoke(root, env, { "build", "fixtures" }) == 0)
  assert(descriptors() == before, "a successful run left a descriptor open")
end

--- The run holds a signal guard for its whole length and closes it once, on success and on a failed phase.
local function test_a_run_closes_its_signal_guard_once(tmp: string)
  local root, env = checkout(tmp)
  local seams = Local.calls()
  local real = seams.signal_close
  local closed: Count = { value = 0 }
  seams.signal_close = function(guard: Signal.Guard): boolean, string
    closed.value = closed.value + 1
    return real(guard)
  end
  local ok = trying(root, env, { "build" })
  local failed = trying(root, env, { "fail" })
  seams.signal_close = real
  assert(ok.ok and ok.code == 0, ok.raised)
  assert(failed.ok and failed.code == 23, failed.raised)
  assert(closed.value == 2, "the guard was closed " .. tostring(closed.value) .. " times in two runs")
end

local record CredentialedTally
  runs: integer
end

--- A credentialed run that ends well removes the copy of the runtime it made and closes its descriptor: the copy
--- is the whole core, left in /tmp, and its descriptor stays open in a process that may go on to run more.
local function test_a_successful_credentialed_run_removes_its_runtime_copy(tmp: string)
  local root, env = checkout(tmp)
  local seams = Local.calls()
  local user, run, mkdtemp = seams.proc_user, seams.child_run, seams.sys_mkdtemp
  local scratch: Text = { value = "" }
  local credentialed: CredentialedTally = { runs = 0 }
  seams.proc_user = function(_name: string): Proc.User | nil, string
    return { uid = 65532, gid = 65532 }, ""
  end
  seams.sys_mkdtemp = function(template: string): string | nil, string, integer
    local path, why, errno = mkdtemp(template)
    if template:find("cosmic-local-runtime", 1, true) then scratch.value = path or "" end
    return path, why, errno
  end
  seams.child_run = function(words: {string}, options?: Child.Options): Child.Result | nil, string
    if options == nil or options.credentials == nil then return run(words, options) end
    credentialed.runs = credentialed.runs + 1
    local code = assert(words[#words])
    -- The preflight and the phase itself are stood in for; the probe that makes the phase directories runs as is.
    if code:find("getuid", 1, true) ~= nil or code == "success" then
      return run({ "/bin/true" }, { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10) })
    end
    return run(words, { cwd = options.cwd, env = options.env, fds = options.fds, input = options.input,
      stdin = options.stdin, stdout = options.stdout, stderr = options.stderr, timeout_ns = options.timeout_ns,
      process_group = options.process_group, capture_limit = options.capture_limit })
  end
  -- Proc.relaunch opens the running core once and caches it.
  local _ = assert(Proc.relaunch())
  local before = descriptors()
  local tried = trying(root, env, { "build" }, 0)
  seams.proc_user, seams.child_run, seams.sys_mkdtemp = user, run, mkdtemp
  assert(tried.ok, tried.raised)
  assert(tried.code == 0 and credentialed.runs > 0, "the run did not end well: " .. tried.diagnostic)
  assert(scratch.value ~= "" and Predicate.exists(scratch.value) == false, "the runtime copy was left in /tmp")
  local after = descriptors()
  assert(after == before, "the runtime descriptor stayed open:\n" .. before .. "\n--\n" .. after)
end
