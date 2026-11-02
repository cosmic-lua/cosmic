--- A narrow root-only fixture for the real local-runner privilege boundary.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")

local record Proof
end

local function command(argv: {string}, env: {string:string}): Child.Result
  local result, trouble = Child.run(argv, { env = env, stdout = "capture", stderr = "capture",
    process_group = true, timeout_ns = Clock.seconds(20) })
  return (assert(result, trouble))
end

--- Whether nothing is at `path`.
local function missing(path: string): boolean
  local there, why = Fs.exists(path)
  assert(there ~= nil, why)
  return not there
end

local function good(result: Child.Result)
  assert(result.ok, (result.stderr or "") .. (result.stdout or "") ..
      "proof child status " .. tostring(result.code))
end

local function prove(argv: {string}): integer
  local source, driver = assert(argv[1]), assert(argv[2])
  local relaunch = assert(Proc.relaunch())
  local program = assert(relaunch.argv[1], "relaunch names no program")
  local cached = assert(Fs.stat(program))
  local cache_digest = Hash.hex_sha256((assert(Fs.read(program))))
  local function runtime_scratch(): string
    local names: mut {string} = {}
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
    assert(Fs.mkdirs(root .. "/ci/cosmic_ci"))
    assert(Fs.mkdirs(root .. "/o/bin"))
    assert(Fs.write(root .. "/ci/run_local.tl", (assert(Fs.read(source .. "/ci/run_local.tl")))))
    assert(Fs.write(root .. "/ci/cosmic_ci/driver.tl", "fixture driver"))
    assert(Fs.write(root .. "/ci/.hidden", "hidden"))
    assert(Fs.mkdirs(root .. "/build"))
    assert(Fs.write(root .. "/build/paths.tl", "local Fs = require(\"cosmic.fs\")\nlocal record Paths end\nfunction Paths.main(argv: {string}): integer\n  assert(Fs.put(Fs.stdout, assert(argv[1]) .. \"/o\\n\"))\n  return 0\nend\nreturn Paths\n"))
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
    assert(sys.mkdir(private, 0x1c0))
    assert(sys.mkdir(private .. "/seed", 0x1c0))
    assert(Fs.write(private .. "/ca", "ca-proof", 0x180))
    local outside = scratch .. "/outside"
    assert(sys.mkdir(outside, 0x1ed))
    assert(Fs.write(outside .. "/keep", "sentinel"))
    assert(Fs.symlink(outside .. "/keep", root .. "/file-link"))
    assert(Fs.symlink(outside, root .. "/dir-link"))
    assert(Fs.symlink(outside .. "/missing", root .. "/dangling"))
    assert(Fs.mkdirs(state))
    assert(Fs.symlink(outside, state .. "/external-link"))
    local env: mut {string:string} = {}
    for name, value in pairs(Env.all()) do env[name] = value end
    env["GIT_AUTHOR_NAME"], env["GIT_COMMITTER_NAME"] = "Local proof", "Local proof"
    env["GIT_AUTHOR_EMAIL"], env["GIT_COMMITTER_EMAIL"] = "proof@example.invalid", "proof@example.invalid"
    env["COSMIC_CI_LOCAL"], env["COSMIC_CI_LOCAL_USER"] = state, "nobody"
    env["COSMIC_ZIG_CACHE"], env["SSL_CERT_FILE"] = private .. "/seed", private .. "/ca"
    env["PROOF_UID"], env["PROOF_GID"] = tostring(account.uid), tostring(account.gid)
    env["PROOF_CORE_SHA"] = cache_digest
    env["GIT_CONFIG_COUNT"], env["GIT_CONFIG_KEY_0"], env["GIT_CONFIG_VALUE_0"] = "1", "proof.keep", "original"
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
    assert(Fs.write(root .. "/tracked", "working"))
    assert(Fs.write(root .. "/untracked", "included"))
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
    assert((assert(Fs.read(candidate .. "/phases"))) == "build\nfixtures\n")
    local grants = assert(Fs.read(candidate .. "/runtime-grants"))
    local first, second = grants:match("^([^\n]+)\n([^\n]+)\n$")
    assert(first and first == second, "one invocation did not reuse its runtime grant")
    assert((assert(Fs.read(candidate .. "/tracked"))) == "working" and assert(Fs.read(candidate .. "/untracked")) == "included")
    assert(missing(candidate .. "/ignored"))
    assert(git_run({ "write-tree" }) == index and git_run({ "stash", "list" }) == "")
    assert(assert(Fs.stat(root)).uid == 0 and assert(Fs.stat(private .. "/seed")).uid == 0)
    assert(assert(Fs.stat(outside)).uid == 0 and assert(Fs.stat(outside .. "/keep")).uid == 0)
    assert((assert(Fs.read(outside .. "/keep"))) == "sentinel")
    for _, path in ipairs({ state .. "/external-link", candidate .. "/file-link",
        candidate .. "/dir-link", candidate .. "/dangling" }) do
      local st = assert(sys.lstat(path))
      assert(st.kind == "link" and st.uid == account.uid)
    end
    -- An o/ an older driver left in the project, its user's: the refresh
    -- removes it with the rest, the driver's database being in its build
    -- directory outside the project.
    assert(Fs.mkdirs(state .. "/ci/o"))
    assert(Fs.write(state .. "/ci/o/stale", "stale"))
    for _, path in ipairs({ state .. "/ci/o", state .. "/ci/o/stale" }) do
      assert(sys.chown(path, account.uid, account.gid))
    end
    assert(Fs.write(root .. "/ci/.hidden", "edited"))
    assert(Fs.write(root .. "/tracked", "later"))
    good(run({ "fixtures" }))
    assert((assert(Fs.read(candidate .. "/tracked"))) == "working" and assert(Fs.read(state .. "/ci/.hidden")) == "edited")
    assert(missing(state .. "/ci/o"), "the refresh kept a stale o/")
    local failed = run({ "failure", "later" })
    assert(failed.code == 23 and assert(Fs.read(candidate .. "/phases")) == "build\nfixtures\nfixtures\nfailure\n")
    assert((assert(Fs.read(state .. "/logs/failure.log"))) == "error: fixture phase\n")
    -- The default base shares one global cache per selected numeric user,
    -- while each checkout retains its checksum-named state.
    env["COSMIC_CI_LOCAL"], env["TMPDIR"] = nil, scratch
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
    env["COSMIC_CI_LOCAL"] = state
    env["COSMIC_CI_LOCAL_USER"] = "root"
    assert(run({ "later" }).code == 2)
    env["COSMIC_CI_LOCAL_USER"] = "cosmic-proof-account-does-not-exist"
    assert(run({ "later" }).code == 2)
    env["COSMIC_CI_LOCAL_USER"] = "nobody"
    env["GIT_CONFIG_COUNT"] = "invalid"
    assert(run({ "later" }).code == 2)
    assert((assert(Fs.read(candidate .. "/phases"))) == "build\nfixtures\nfixtures\nfailure\n")
    return true
  end)
  local removed, trouble = Fs.remove_tree(scratch)
  assert(runtime_scratch() == initial_scratch, "runtime grant survived proof failure")
  local after = assert(Fs.stat(program))
  assert(after.uid == cached.uid and after.mode == cached.mode and after.ino == cached.ino and
      Hash.hex_sha256((assert(Fs.read(program)))) == cache_digest, "private runtime cache changed")
  if not ok then error(why) end
  assert(removed, trouble)
  print("run-local: PASS (real credentials, physical ownership, snapshot, rerun and refusal)")
  return 0
end

function Proof.main(argv: {string}): integer
  assert(sys.getuid() == 0, "run-local proof requires root")
  local _guard <close> = assert(Signal.guard())
  return prove(argv)
end

return Proof
