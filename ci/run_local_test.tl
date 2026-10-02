local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Local = require("run_local")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")

Test.needs{ system = true, tool = true }

local function git(root: string, args: {string}): string
  local argv = { assert(Proc.find("git")), "-C", root }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "capture",
    timeout_ns = Time.seconds(10) }))
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
  local env = Env.all()
  env.COSMIC_CI_LOCAL = tmp .. "/private state"
  env.COSMIC_ZIG_CACHE = tmp .. "/seed"
  env.COSMIC_ZIG_GLOBAL_CACHE = tmp .. "/global cache"
  env.TRACE = tmp .. "/trace"
  env.TMPDIR = tmp
  return root, env
end

local function invoke(root: string, env: {string:string}, phases: {string}, uid?: integer): integer, string
  local all, getuid, put = Env.all, sys.getuid, Fs.put
  local messages: {string} = {}
  Env.all = function(): {string:string} return env end
  -- This selects the ordinary path for snapshot tests on a root-only
  -- development host. It is not credential-transition evidence.
  sys.getuid = function(): integer return uid or 1000 end
  Fs.put = function(fd: integer, bytes: string): boolean, string
    if fd == Fs.stderr then messages[#messages + 1] = bytes; return true, "" end
    return put(fd, bytes)
  end
  local argv: {integer:string} = { [0] = root .. "/ci/run_local.tl" }
  for i, phase in ipairs(phases) do argv[i] = phase end
  local called, result = pcall(Local.main, argv)
  Env.all, sys.getuid, Fs.put = all, getuid, put
  assert(called, tostring(result))
  return result, table.concat(messages)
end

local function test_snapshot_keeps_working_changes_and_the_real_index(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/tracked", "working\n"))
  assert(Fs.write(root .. "/untracked", "new\n"))
  assert(Fs.write(root .. "/ignored", "excluded\n"))
  local index = assert(Fs.read(root .. "/.git/index"))
  local stash = git(root, { "stash", "list" })
  assert(invoke(root, env, { "build" }) == 0)
  local candidate = assert(Fs.absolute(env.COSMIC_CI_LOCAL .. "/candidate"))
  assert(Fs.read(candidate .. "/tracked") == "working\n")
  assert(Fs.read(candidate .. "/untracked") == "new\n")
  assert(Fs.exists(candidate .. "/ignored") == false)
  assert(Fs.read(root .. "/.git/index") == index and git(root, { "stash", "list" }) == stash)
  assert(Fs.exists(root .. "/ci/o") == false, "source CI database was created")
  local environment = assert(Fs.read(env.TRACE .. ".env"))
  assert(environment:find(candidate, 1, true) and environment:find(env.COSMIC_ZIG_CACHE, 1, true) and
    environment:find(env.COSMIC_ZIG_GLOBAL_CACHE, 1, true), "spaced paths or cache inputs changed")
end

local function test_snapshot_keeps_tracked_and_force_added_ignored_files(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/tracked", "updated tracked\n"))
  assert(Fs.write(root .. "/.gitignore", "o/\ntracked\nforced\nignored\n"))
  assert(Fs.write(root .. "/forced", "forced staged\n"))
  git(root, { "add", "-f", "forced" })
  local index = assert(Fs.read(root .. "/.git/index"))
  assert(invoke(root, env, { "build" }) == 0)
  local candidate = assert(Fs.absolute(env.COSMIC_CI_LOCAL .. "/candidate"))
  assert(Fs.read(candidate .. "/tracked") == "updated tracked\n")
  assert(Fs.read(candidate .. "/forced") == "forced staged\n")
  assert(Fs.read(root .. "/.git/index") == index, "private snapshot changed the actual index")
end

local function test_named_rerun_refreshes_ci_but_keeps_candidate_and_database(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "build" }) == 0)
  local state = env.COSMIC_CI_LOCAL
  assert(Fs.mkdirs(state .. "/ci/o"))
  assert(Fs.write(state .. "/ci/o/sentinel", "persistent"))
  assert(Fs.write(state .. "/ci/obsolete", "remove"))
  assert(Fs.write(root .. "/ci/cosmic_ci/driver.tl", "edited fixture\n"))
  assert(Fs.write(root .. "/tracked", "later\n"))
  assert(invoke(root, env, { "fixtures" }) == 0)
  assert(Fs.read(state .. "/candidate/tracked") == "old\n")
  assert(Fs.read(state .. "/ci/cosmic_ci/driver.tl") == "edited fixture\n")
  assert(Fs.read(state .. "/ci/o/sentinel") == "persistent")
  assert(Fs.exists(state .. "/ci/obsolete") == false)
  assert(Fs.read(env.TRACE) == "build\nfixtures\n")
end

local function test_default_phases_keep_the_workflow_order(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, {}) == 0)
  assert(Fs.read(env.TRACE) ==
    "build\nlocal-boundary\ndarwin-suite\nsandbox\nassemble\nportable\nportable-boundary\nfixtures\n")
end

local function test_phase_failure_stops_and_preserves_its_status(tmp: string)
  local root, env = checkout(tmp)
  local code, diagnostic = invoke(root, env, { "build", "fail", "fixtures" })
  assert(code == 23 and diagnostic:find("error: selected phase failed", 1, true))
  assert(Fs.read(env.TRACE) == "build\nfail\n")
end

local function test_failed_log_is_bounded_and_never_read_whole(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/o/bin/cosmic", [[#!/bin/sh
head -c 200000 /dev/zero | tr '\000' x
printf '\nerror: too late\n'
exit 29
]], 0x1ed))
  local read = Fs.read
  Fs.read = function(path: string): string | nil, string
    assert(not path:match("/logs/.*%.log$"), "failure log was read whole")
    return read(path)
  end
  local called, code, diagnostic = pcall(invoke, root, env, { "build" })
  Fs.read = read
  assert(called, tostring(code))
  assert(code == 29 and #diagnostic < 70000 and diagnostic:find("log diagnostics stopped", 1, true))
end

local function test_state_paths_refuse_containment_and_symlink_roots(tmp: string)
  local root, env = checkout(tmp)
  for _, path in ipairs({ root .. "/state", root, tmp, "/", "relative" }) do
    env.COSMIC_CI_LOCAL = path
    assert(invoke(root, env, { "build" }) == 2, "unsafe state accepted: " .. path)
  end
  local outside = tmp .. "/outside"
  assert(Fs.mkdirs(outside) and Fs.write(outside .. "/sentinel", "unchanged"))
  assert(Fs.chmod(outside, 0x1c0))
  local link = tmp .. "/state-link"
  assert(Fs.symlink(outside, link))
  env.COSMIC_CI_LOCAL = link
  assert(invoke(root, env, { "build" }) == 2)
  assert(Fs.read(outside .. "/sentinel") == "unchanged" and assert(Fs.stat(outside)).mode & 0x1ff == 0x1c0)
end

local function test_default_base_symlink_is_refused_before_mutation(tmp: string)
  local root, env = checkout(tmp)
  local outside = tmp .. "/outside"
  assert(Fs.mkdirs(outside) and Fs.write(outside .. "/sentinel", "unchanged"))
  assert(Fs.chmod(outside, 0x1c0))
  assert(Fs.symlink(outside, tmp .. "/cosmic-ci-local-0"))
  env.COSMIC_CI_LOCAL = nil
  assert(invoke(root, env, { "build" }, 0) == 2)
  assert(Fs.read(outside .. "/sentinel") == "unchanged" and assert(Fs.stat(outside)).mode & 0x1ff == 0x1c0)
  assert(#assert(Fs.list(outside)) == 1, "refusal created state beneath symlink target")
end

local function test_root_account_refusal_creates_no_state(tmp: string)
  local root, env = checkout(tmp)
  for _, name in ipairs({ "root", "cosmic-user-that-does-not-exist-95672" }) do
    env.COSMIC_CI_LOCAL_USER = name
    assert(invoke(root, env, { "build" }, 0) == 2)
    assert(Fs.exists(env.COSMIC_CI_LOCAL) == false and Fs.exists(env.TRACE) == false)
  end
end

local function test_credential_setup_refusal_precedes_state_and_phase(tmp: string)
  local root, env = checkout(tmp)
  local user, run = Proc.user, Child.run
  Proc.user = function(_name: string): Proc.User | nil, string return { uid = 65532, gid = 65532 }, "" end
  Child.run = function(argv: {string}, options?: Child.Options): Child.Result | nil, string
    if options and options.credentials then return nil, "injected credential refusal" end
    return run(argv, options)
  end
  local called, code, diagnostic = pcall(invoke, root, env, { "build" }, 0)
  Proc.user, Child.run = user, run
  assert(called, tostring(code))
  assert(code == 2 and diagnostic:find("injected credential refusal", 1, true))
  assert(Fs.exists(env.COSMIC_CI_LOCAL) == false and Fs.exists(env.TRACE) == false)
end

local function test_snapshot_error_cleans_private_index_and_keeps_old_candidate(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "build" }) == 0)
  local candidate = assert(Fs.absolute(env.COSMIC_CI_LOCAL .. "/candidate"))
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
  assert(Fs.exists(env.TRACE) == false)
  assert(invoke(root, env, { "../escape" }) == 2)
  assert(Fs.exists(tmp .. "/escape.log") == false)
end

local function test_state_ancestor_alias_cannot_place_state_inside_checkout(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.symlink(root, tmp .. "/checkout-alias"))
  env.COSMIC_CI_LOCAL = tmp .. "/checkout-alias/state"
  assert(invoke(root, env, { "build" }) == 2)
  assert(Fs.exists(root .. "/state") == false and Fs.exists(env.TRACE) == false)
end

local function test_phase_log_symlink_target_is_unchanged(tmp: string)
  local root, env = checkout(tmp)
  assert(invoke(root, env, { "build" }) == 0)
  local outside = tmp .. "/outside-log"
  assert(Fs.write(outside, "retain bytes"))
  assert(Fs.symlink(outside, env.COSMIC_CI_LOCAL .. "/logs/fixtures.log"))
  assert(invoke(root, env, { "fixtures" }) == 2)
  assert(Fs.read(outside) == "retain bytes" and Fs.read(env.TRACE) == "build\n")
end

local function test_failure_diagnostics_stop_after_twenty_matching_lines(tmp: string)
  local root, env = checkout(tmp)
  assert(Fs.write(root .. "/o/bin/cosmic", [[#!/bin/sh
i=1
while [ "$i" -le 30 ]; do printf 'error: line %s\n' "$i"; i=$((i+1)); done
exit 31
]], 0x1ed))
  local code, diagnostic = invoke(root, env, { "build" })
  assert(code == 31 and diagnostic:find("error: line 20\n", 1, true) and
    not diagnostic:find("error: line 21\n", 1, true))
  assert(assert(Fs.read(env.COSMIC_CI_LOCAL .. "/logs/build.log")):find("error: line 30\n", 1, true),
    "bounded diagnostics truncated the retained log")
end
