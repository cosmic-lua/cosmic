--- A narrow root-only fixture for the real local-runner privilege boundary.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local record Proof
end

local function command(argv: {string}, env: {string:string}): Child.Result
  local result, trouble = Child.run(argv, { env = env, stdout = "capture", stderr = "capture",
    process_group = true, timeout_ns = Clock.seconds(20) })
  return (assert(result, trouble))
end

local function good(result: Child.Result)
  assert(result.ok, (result.stderr or "") .. (result.stdout or "") ..
      "proof child status " .. tostring(result.code))
end

function Proof.main(argv: {integer:string}): integer
  assert(sys.getuid() == 0, "run-local proof requires root")
  local _guard <close> = assert(Child.guard())
  local source, driver = assert(argv[1]), assert(argv[2])
  local relaunch = assert(Proc.relaunch())
  local cached = assert(Fs.stat(relaunch.argv[1]))
  local cache_digest = Hash.hex_sha256((assert(Fs.read(relaunch.argv[1]))))
  local function runtime_scratch(): string
    local names: {string} = {}
    for _, name in ipairs((assert(Fs.list("/tmp")))) do
      if name:match("^cosmic%-local%-runtime%.") then names[#names + 1] = name end
    end
    table.sort(names)
    return table.concat(names, "\n")
  end
  local initial_scratch = runtime_scratch()
  local account = assert(Proc.user("nobody"))
  assert(account.uid ~= 0 and account.gid ~= 0)
  local scratch = assert(sys.mkdtemp("/tmp/cosmic-local-proof.XXXXXX"))
  local ok, why = pcall(function(): boolean
    assert(Fs.chmod(scratch, 0x1ed))
    local root, state = scratch .. "/source tree", scratch .. "/state space"
    assert(Fs.mkdirs(root .. "/ci/cosmic_ci") and Fs.mkdirs(root .. "/o/bin"))
    assert(Fs.write(root .. "/ci/run_local.tl", (assert(Fs.read(source .. "/ci/run_local.tl")))))
    assert(Fs.write(root .. "/ci/cosmic_ci/driver.tl", "fixture driver"))
    assert(Fs.write(root .. "/ci/.hidden", "hidden"))
    assert(Fs.write(root .. "/tracked", "initial"))
    assert(Fs.write(root .. "/.gitignore", "o/\nignored\n"))
    assert(Fs.write(root .. "/o/bin/cosmic", [=[#!/bin/sh
set -eu
[ "$(id -u)" = "$PROOF_UID" ] && [ "$(id -g)" = "$PROOF_GID" ]
grep -Eq '^Groups:[[:space:]]*$' /proc/self/status
[ -z "$COSMIC_ZIG_CACHE_FROM" ]
[ -r "$SSL_CERT_FILE" ] && [ "$(cat "$SSL_CERT_FILE")" = ca-proof ]
[ "$GIT_CONFIG_COUNT" = 2 ] && [ "$GIT_CONFIG_KEY_0" = proof.keep ]
[ "$GIT_CONFIG_VALUE_0" = original ] && [ "$GIT_CONFIG_KEY_1" = safe.directory ]
[ "$GIT_CONFIG_VALUE_1" = "$GITHUB_WORKSPACE" ]
[ -w "$HOME" ] && [ -w "$TMPDIR" ] && [ -w "$COSMIC_ZIG_GLOBAL_CACHE" ]
count=0
for runtime in /tmp/cosmic-local-runtime.*/core; do
  [ -f "$runtime" ] || continue
  [ "$(stat -c %u "$runtime")" = 0 ] || continue
  count=$((count+1))
  [ "$(stat -c %a "$runtime")" = 555 ]
  [ "$(stat -c %a "${runtime%/*}")" = 711 ]
  [ -r "$runtime" ] && [ -x "$runtime" ] && [ ! -w "$runtime" ] && [ ! -w "${runtime%/*}" ]
  [ "$(sha256sum "$runtime" | cut -d ' ' -f 1)" = "$PROOF_CORE_SHA" ]
  printf '%s\n' "$runtime" >> "$GITHUB_WORKSPACE/runtime-grants"
done
[ "$count" = 1 ]
printf '%s\n' "$3" >> "$GITHUB_WORKSPACE/phases"
printf 'error: fixture phase\n'
[ "$3" != failure ] || exit 23
]=], 0x1ed))
    local private = scratch .. "/private"
    assert(sys.mkdir(private, 0x1c0) and sys.mkdir(private .. "/seed", 0x1c0))
    assert(Fs.write(private .. "/ca", "ca-proof", 0x180))
    local outside = scratch .. "/outside"
    assert(sys.mkdir(outside, 0x1ed) and Fs.write(outside .. "/keep", "sentinel"))
    assert(Fs.symlink(outside .. "/keep", root .. "/file-link"))
    assert(Fs.symlink(outside, root .. "/dir-link"))
    assert(Fs.symlink(outside .. "/missing", root .. "/dangling"))
    assert(Fs.mkdirs(state))
    assert(Fs.symlink(outside, state .. "/external-link"))
    local env = Env.all()
    env.GIT_AUTHOR_NAME, env.GIT_COMMITTER_NAME = "Local proof", "Local proof"
    env.GIT_AUTHOR_EMAIL, env.GIT_COMMITTER_EMAIL = "proof@example.invalid", "proof@example.invalid"
    env.COSMIC_CI_LOCAL, env.COSMIC_CI_LOCAL_USER = state, "nobody"
    env.COSMIC_ZIG_CACHE, env.SSL_CERT_FILE = private .. "/seed", private .. "/ca"
    env.PROOF_UID, env.PROOF_GID = tostring(account.uid), tostring(account.gid)
    env.PROOF_CORE_SHA = cache_digest
    env.GIT_CONFIG_COUNT, env.GIT_CONFIG_KEY_0, env.GIT_CONFIG_VALUE_0 = "1", "proof.keep", "original"
    local git = assert(Proc.find("git"))
    local function git_run(args: {string}): string
      local words = { git, "-C", root }
      for _, word in ipairs(args) do words[#words + 1] = word end
      local answer = command(words, env)
      good(answer)
      return answer.stdout or ""
    end
    git_run({ "init", "-q" })
    git_run({ "add", "." })
    git_run({ "commit", "-qm", "initial" })
    assert(Fs.write(root .. "/tracked", "staged"))
    git_run({ "add", "tracked" })
    local index = git_run({ "write-tree" })
    assert(Fs.write(root .. "/tracked", "working") and Fs.write(root .. "/untracked", "included"))
    assert(Fs.write(root .. "/ignored", "excluded"))
    local function run(phases: {string}): Child.Result
      local words = { driver, "--standalone", root .. "/ci/run_local.tl" }
      for _, phase in ipairs(phases) do words[#words + 1] = phase end
      local result = command(words, env)
      assert(runtime_scratch() == initial_scratch, "runtime grant survived runner exit")
      return result
    end
    good(run({ "build", "fixtures" }))
    local candidate = state .. "/candidate"
    assert(Fs.read(candidate .. "/phases") == "build\nfixtures\n")
    local grants = assert(Fs.read(candidate .. "/runtime-grants"))
    local first, second = grants:match("^([^\n]+)\n([^\n]+)\n$")
    assert(first and first == second, "one invocation did not reuse its runtime grant")
    assert(Fs.read(candidate .. "/tracked") == "working" and Fs.read(candidate .. "/untracked") == "included")
    assert(Fs.exists(candidate .. "/ignored") == false)
    assert(git_run({ "write-tree" }) == index and git_run({ "stash", "list" }) == "")
    assert(assert(Fs.stat(root)).uid == 0 and assert(Fs.stat(private .. "/seed")).uid == 0)
    assert(assert(Fs.stat(outside)).uid == 0 and assert(Fs.stat(outside .. "/keep")).uid == 0)
    assert(Fs.read(outside .. "/keep") == "sentinel")
    for _, path in ipairs({ state .. "/external-link", candidate .. "/file-link",
        candidate .. "/dir-link", candidate .. "/dangling" }) do
      local st = assert(sys.lstat(path))
      assert(st.kind == "link" and st.uid == account.uid)
    end
    assert(Fs.mkdirs(state .. "/ci/o") and Fs.write(state .. "/ci/o/keep", "kept"))
    assert(Fs.write(root .. "/ci/.hidden", "edited") and Fs.write(root .. "/tracked", "later"))
    good(run({ "fixtures" }))
    assert(Fs.read(candidate .. "/tracked") == "working" and Fs.read(state .. "/ci/.hidden") == "edited")
    assert(Fs.read(state .. "/ci/o/keep") == "kept")
    local failed = run({ "failure", "later" })
    assert(failed.code == 23 and Fs.read(candidate .. "/phases") == "build\nfixtures\nfixtures\nfailure\n")
    assert(Fs.read(state .. "/logs/failure.log") == "error: fixture phase\n")
    -- The default base shares one global cache per selected numeric user,
    -- while each checkout retains its checksum-named state.
    env.COSMIC_CI_LOCAL, env.TMPDIR = nil, scratch
    good(run({ "build", "fixtures" }))
    local base = scratch .. "/cosmic-ci-local-0"
    local shared_cache = base .. "/zig-global-" .. tostring(account.uid)
    assert(assert(Fs.stat(shared_cache)).uid == account.uid)
    local states = 0
    for _, name in ipairs((assert(Fs.list(base)))) do
      if name:match("^%d+$") then
        states = states + 1
        assert(assert(Fs.stat(base .. "/" .. name)).uid == account.uid)
      end
    end
    assert(states == 1)
    good(run({ "fixtures" }))
    assert(assert(Fs.stat(shared_cache)).uid == account.uid)
    env.COSMIC_CI_LOCAL = state
    env.COSMIC_CI_LOCAL_USER = "root"
    assert(run({ "later" }).code == 2)
    env.COSMIC_CI_LOCAL_USER = "cosmic-proof-account-does-not-exist"
    assert(run({ "later" }).code == 2)
    env.COSMIC_CI_LOCAL_USER = "nobody"
    env.GIT_CONFIG_COUNT = "invalid"
    assert(run({ "later" }).code == 2)
    assert(Fs.read(candidate .. "/phases") == "build\nfixtures\nfixtures\nfailure\n")
    return true
  end)
  local removed, trouble = Fs.remove_tree(scratch)
  assert(runtime_scratch() == initial_scratch, "runtime grant survived proof failure")
  local after = assert(Fs.stat(relaunch.argv[1]))
  assert(after.uid == cached.uid and after.mode == cached.mode and after.ino == cached.ino and
      Hash.hex_sha256((assert(Fs.read(relaunch.argv[1])))) == cache_digest, "private runtime cache changed")
  if not ok then error(why) end
  assert(removed, trouble)
  print("run-local: PASS (real credentials, physical ownership, snapshot, rerun and refusal)")
  return 0
end

return Proof
