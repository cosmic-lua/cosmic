local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Grammar = require("cosmic_ci.grammar")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local Maps = require("cosmic_ci.maps")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")

-- These tests start this program (the pinned driver's own cosmic, or a copy of it
-- as the bootstrap), which a worker on a sealed database does not have whole.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The environment a test's child runs with: this one's, less what
--- would change which cosmic bin/cosmic-bootstrap answers (a
--- COSMIC_BOOTSTRAP exported where the tests run is no part of them),
--- with `extra` over it.
local function environment(extra?: {string:string}): {string:string}
  local values = Maps.without(Env.all(), { "COSMIC_BOOTSTRAP",
    "COSMIC_BOOTSTRAP_VERIFY", "COSMIC_BOOTSTRAP_ATTEMPTS" })
  if extra then return Grammar.driver(Maps.with(values, extra)) end
  return Grammar.driver(values)
end

--- How long a spawned driver.tl may take. It compiles every cosmic_ci
--- module before it does anything, alongside the other self-tests, and on a
--- CI runner that alone has taken over 2 s: a few seconds is too little.
local driver_timeout = Clock.seconds(60)

--- How long any other child may take: only a hang reaches it. A retry in
--- bin/cosmic-bootstrap pauses 2 s, and copies and hashes this whole
--- program on each attempt (through perl's shasum on macOS); a slow or
--- loaded runner multiplies all of that. It is held under the 30 s a
--- test of cosmic_ci gets (ci.yml's "check the pinned CI driver" sets no
--- COSMIC_TEST_TIMEOUT), so a hang in a test's first call is named by
--- that call's own failure and its output; one later in a test may meet
--- the runner's end first.
local child_timeout = Clock.seconds(20)

--- The bound `driver.tl run` is given for a trivial /bin/sh child, which
--- only a hang reaches: this is no test of how fast the shell starts.
local trivial_timeout = tostring(Clock.seconds(10))

local function call(argv: {string}, cwd: string, output: string,
                    extra?: {string:string}, timeout?: integer): Child.Result
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run(argv, {
    cwd = cwd, env = environment(extra), stdout = fd, stderr = fd,
    process_group = true, timeout_ns = timeout or child_timeout,
  })
  assert(Fs.close(fd))
  return (assert(result, trouble))
end

--- The candidate checkout root: this test's cwd is `<checkout>/ci`, so
--- its parent is the checkout the self-check runs against.
local function checkout_root(): string
  local cwd = assert(Fs.absolute("."))
  return (assert(cwd:match("^(.*)/[^/]+$"), cwd .. ": no parent directory"))
end

local function pin(path: string, commit: string, digest: string)
  assert(Fs.write(path, commit .. "\n" ..
      "https://github.com/cosmic-lua/cosmic/releases/download/next-" ..
      commit .. "/cosmic\n" .. digest .. "\n"))
end

--- A checkout of its own at `tmp/root` for bin/cosmic-bootstrap, which
--- reads the pin beside it: the candidate's script, and a pin naming
--- `digest`. Its cache is `tmp/xdg/cosmic/bootstrap`.
local function bootstrap_root(tmp: string, commit: string, digest: string): string, string
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/bin") and Fs.mkdirs(root .. "/ci"))
  assert(Fs.write(root .. "/bin/cosmic-bootstrap",
    (assert(Fs.read(checkout_root() .. "/bin/cosmic-bootstrap"))), 0x1ed))
  pin(root .. "/ci/cosmic-driver.pin", commit, digest)
  local cache = tmp .. "/xdg/cosmic/bootstrap"
  assert(Fs.mkdirs(cache))
  return root, cache
end

--- Runs bin/cosmic-bootstrap under `root` as CI does, re-verifying its
--- cache, with `extra` in its environment, asking for the release's own path (`--raw-path`): with no argument it
--- answers an entry point, which test_the_entry_point_... holds.
local function bootstrap(tmp: string, root: string, output: string,
                         extra?: {string:string}): Child.Result
  local env: mut {string:string} = { XDG_CACHE_HOME = tmp .. "/xdg", COSMIC_BOOTSTRAP_VERIFY = "1" }
  if extra then
    for name, value in pairs(extra) do env[name] = value end
  end
  return call({ "/bin/sh", root .. "/bin/cosmic-bootstrap", "--raw-path" }, tmp, output, env)
end

--- A curl on a PATH of its own that writes `$DOWNLOAD_SOURCE` wherever
--- it is asked to, whatever URL it is given. Where `$FAIL_ONCE` names a
--- file that is there, it removes that file, leaves a scrap of a
--- transfer at the output and fails, as a dropped connection would.
--- Where `$WRONG_ONCE` names one, it removes that file and writes other
--- bytes than the source's, succeeding, as a transfer cut short without
--- an error would. Each call appends a line to `$CALLS` when set.
local function fake_curl(tmp: string): string
  local fake = tmp .. "/fake bin"
  assert(Fs.mkdirs(fake))
  assert(Fs.write(fake .. "/curl", [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi
done
[ -z "${CALLS:-}" ] || echo call >> "$CALLS"
if [ -n "${FAIL_ONCE:-}" ] && [ -e "$FAIL_ONCE" ]; then
  rm -f "$FAIL_ONCE"
  printf scrap > "$output"
  exit 56
fi
if [ -n "${WRONG_ONCE:-}" ] && [ -e "$WRONG_ONCE" ]; then
  rm -f "$WRONG_ONCE"
  printf 'not the pinned bytes' > "$output"
  exit 0
fi
cp "$DOWNLOAD_SOURCE" "$output"
]], 0x1ed))
  return fake .. ":" .. assert(Env.get("PATH"))
end

local function seeded_bootstrap(tmp: string): string, string
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("a", 40), digest)
  assert(Fs.write(cache .. "/cosmic-" .. digest, (assert(Fs.read(program))), 0x1ed))
  local result = bootstrap(tmp, root, tmp .. "/bootstrap.out")
  local out = assert(Fs.read(tmp .. "/bootstrap.out"))
  assert(result.ok, out)
  local runner = out:gsub("\n$", "")
  assert(runner == cache .. "/cosmic-" .. digest, out)
  return runner, digest
end

--- The driver reads its context (GITHUB_WORKSPACE, GITHUB_RUN_ID,
--- GITHUB_RUN_ATTEMPT, RUNNER_TEMP, COSMIC_WORKER) from the environment.
--- In CI the self-check runs inside a job where all of these are already
--- set to the real job's values, so a spawned driver.tl that inherited
--- them would write into that job's own $RUNNER_TEMP/cosmic-ci or append
--- to its real step summary; every test builds this context explicitly
--- and passes it as `call`'s extra env instead.
local function driver_context(candidate: string, runner_temp: string,
                              extra?: {string:string}): {string:string}
  local env: mut {string:string} = {
    GITHUB_WORKSPACE = candidate,
    GITHUB_RUN_ID = "run-1",
    GITHUB_RUN_ATTEMPT = "1",
    RUNNER_TEMP = runner_temp,
    COSMIC_WORKER = "worker",
  }
  if extra then
    for name, value in pairs(extra) do env[name] = value end
  end
  return env
end

--- The self-check holds a write transaction on `ci/`'s `build.db` while
--- tests run, so a test that spawns the host on `driver.tl` must never
--- give it project root `ci/` -- it copies the namespace into its own
--- tmp project first, the way `orchestration_test.tl`'s `command()`
--- does for the same reason.
local function driver_project(tmp: string): string
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  assert(assert(Child.run({ "/bin/cp", "-R",
    assert(Fs.absolute(".")) .. "/cosmic_ci", project })).ok)
  return project
end

local function test_bootstrap_rejects_corrupt_cache_and_download(tmp: string)
  local digest = string.rep("0", 64)
  local root, cache = bootstrap_root(tmp, string.rep("b", 40), digest)
  local cached = cache .. "/cosmic-" .. digest
  assert(Fs.write(cached, "bad cache", 0x1ed))
  assert(Fs.write(tmp .. "/download", "bad download"))
  -- One attempt: a retry would only pause and fetch the same bad bytes.
  local result = bootstrap(tmp, root, tmp .. "/bad.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = tmp .. "/download",
      COSMIC_BOOTSTRAP_ATTEMPTS = "1" })
  assert(not result.ok and Fs.exists(cached) == false,
    "corrupt replacement was accepted")
end

--- A download that fails partway is tried again from an empty file, and
--- the second, whole one is verified and kept; nothing partial is left.
local function test_bootstrap_retries_a_failed_download(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("e", 40), digest)
  assert(Fs.write(tmp .. "/fail-once", ""))
  local result = bootstrap(tmp, root, tmp .. "/retry.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program, FAIL_ONCE = tmp .. "/fail-once",
      CALLS = tmp .. "/calls", COSMIC_BOOTSTRAP_ATTEMPTS = "2" })
  local out = assert(Fs.read(tmp .. "/retry.out"))
  assert(result.ok, out)
  assert(out:find("retrying", 1, true) ~= nil, out)
  assert(assert(Fs.read(tmp .. "/calls")) == "call\ncall\n")
  assert(Hash.hex_sha256((assert(Fs.read(cache .. "/cosmic-" .. digest)))) == digest)
  local names = assert(Fs.list(cache))
  assert(#names == 1, "a partial download was left: " .. table.concat(names, " "))
end

--- A download with the wrong digest is tried again, not kept.
local function test_bootstrap_retries_a_download_with_the_wrong_digest(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("9", 40), digest)
  assert(Fs.write(tmp .. "/wrong-once", ""))
  local result = bootstrap(tmp, root, tmp .. "/wrong.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program, WRONG_ONCE = tmp .. "/wrong-once",
      CALLS = tmp .. "/calls", COSMIC_BOOTSTRAP_ATTEMPTS = "2" })
  local out = assert(Fs.read(tmp .. "/wrong.out"))
  assert(result.ok, out)
  assert(out:find("the pin says " .. digest .. "; retrying", 1, true) ~= nil, out)
  assert(assert(Fs.read(tmp .. "/calls")) == "call\ncall\n")
  assert(Hash.hex_sha256((assert(Fs.read(cache .. "/cosmic-" .. digest)))) == digest)
  assert(#assert(Fs.list(cache)) == 1, "a partial download was left")
end

--- COSMIC_BOOTSTRAP_ATTEMPTS is a count from 1 to 20, written plainly;
--- anything else stops the script before it downloads anything.
local function test_bootstrap_refuses_a_bad_attempt_count(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, _ = bootstrap_root(tmp, string.rep("8", 40), digest)
  for _, given in ipairs({ "0", "21", "07", "x", "-1", "" }) do
    local result = bootstrap(tmp, root, tmp .. "/count.out",
      { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program, CALLS = tmp .. "/calls",
        COSMIC_BOOTSTRAP_ATTEMPTS = given })
    local out = assert(Fs.read(tmp .. "/count.out"))
    if given == "" then
      -- Empty is unset: the default.
      assert(result.ok, out)
    else
      assert(not result.ok, given .. " was taken")
      assert(out:find("not a count from 1 to 20", 1, true) ~= nil, out)
    end
  end
  assert(assert(Fs.read(tmp .. "/calls")) == "call\n", "a refused count still downloaded")
  local one = bootstrap(tmp, root, tmp .. "/one.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program, COSMIC_BOOTSTRAP_ATTEMPTS = "20" })
  assert(one.ok, assert(Fs.read(tmp .. "/one.out")))
end

--- One attempt that fails says so in the singular.
local function test_bootstrap_counts_a_single_attempt(tmp: string)
  local digest = string.rep("0", 64)
  local root, _ = bootstrap_root(tmp, string.rep("7", 40), digest)
  assert(Fs.write(tmp .. "/fail-once", ""))
  local result = bootstrap(tmp, root, tmp .. "/single.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = tmp .. "/missing",
      FAIL_ONCE = tmp .. "/fail-once", COSMIC_BOOTSTRAP_ATTEMPTS = "1" })
  local out = assert(Fs.read(tmp .. "/single.out"))
  assert(not result.ok and out:find("(after 1 attempt)", 1, true) ~= nil, out)
end

--- Every attempt failing fails the script, saying how many it made.
local function test_bootstrap_gives_up_after_its_attempts(tmp: string)
  local digest = string.rep("0", 64)
  local root, cache = bootstrap_root(tmp, string.rep("f", 40), digest)
  assert(Fs.write(tmp .. "/fail-once", ""))
  local result = bootstrap(tmp, root, tmp .. "/gave-up.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = tmp .. "/missing",
      FAIL_ONCE = tmp .. "/fail-once", CALLS = tmp .. "/calls",
      COSMIC_BOOTSTRAP_ATTEMPTS = "2" })
  local out = assert(Fs.read(tmp .. "/gave-up.out"))
  assert(not result.ok, out)
  assert(out:find("after 2 attempts", 1, true) ~= nil, out)
  assert(assert(Fs.read(tmp .. "/calls")) == "call\ncall\n")
  assert(#assert(Fs.list(cache)) == 0, "a partial download was left")
end

local function test_bootstrap_replaces_a_corrupt_cache_from_a_verified_download(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("d", 40), digest)
  local cached = cache .. "/cosmic-" .. digest
  assert(Fs.write(cached, "corrupt", 0x1ed))
  local result = bootstrap(tmp, root, tmp .. "/download.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program })
  assert(result.ok, assert(Fs.read(tmp .. "/download.out")))
  assert(Hash.hex_sha256((assert(Fs.read(cached)))) == digest,
    "downloaded driver changed after verification")
end

--- A link at the cache's name is never followed: even one to the right
--- bytes is replaced by a verified download of its own.
local function test_bootstrap_replaces_a_linked_cache_entry(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, cache = bootstrap_root(tmp, string.rep("c", 40), digest)
  local cached = cache .. "/cosmic-" .. digest
  assert(Fs.symlink(program, cached))
  local result = bootstrap(tmp, root, tmp .. "/linked.out",
    { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program })
  assert(result.ok, assert(Fs.read(tmp .. "/linked.out")))
  assert(Fs.readlink(cached) == nil, "a linked cache entry was kept")
  assert(Hash.hex_sha256((assert(Fs.read(cached)))) == digest)
end

--- A stand-in cosmic at `tmp/stand-in` that prints "ran", the directory
--- it ran in, and the words it was run with, one to a line, so a test can
--- see who ran it, where and how.
local function stand_in(tmp: string): string
  local path = tmp .. "/stand-in"
  assert(Fs.write(path, "#!/bin/sh\necho ran\npwd -P\nfor word in \"$@\"; do echo \"$word\"; done\n", 0x1ed))
  return path
end

--- `dir` as `pwd -P` prints it, links resolved.
local function physical(dir: string): string
  local got = assert(Child.run({ "/bin/sh", "-c", "pwd -P" },
    { cwd = dir, stdout = "capture" }))
  return ((assert(got.stdout)):gsub("\n$", ""))
end

--- COSMIC_BOOTSTRAP stands in for the pin's cosmic: printed for `--raw-path`, run with the arguments when there are, and nothing fetched
--- either way -- the pin here names bytes no download could give.
local function test_bootstrap_runs_cosmic_bootstrap_in_place_of_the_pin(tmp: string)
  local root, _ = bootstrap_root(tmp, string.rep("d", 40), string.rep("0", 64))
  local cosmic = stand_in(tmp)
  local env: mut {string:string} = { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = tmp .. "/missing",
    CALLS = tmp .. "/calls", COSMIC_BOOTSTRAP = cosmic }
  local printed = call({ "/bin/sh", root .. "/bin/cosmic-bootstrap", "--raw-path" },
    tmp, tmp .. "/printed.out", env)
  local out = assert(Fs.read(tmp .. "/printed.out"))
  assert(printed.ok and out == cosmic .. "\n", out)
  local ran = call({ "/bin/sh", root .. "/bin/cosmic-bootstrap", "a b", "c" },
    tmp, tmp .. "/ran.out", env)
  out = assert(Fs.read(tmp .. "/ran.out"))
  assert(ran.ok and out == "ran\n" .. physical(tmp) .. "\na b\nc\n", out)
  -- A relative one is answered absolute, for a caller that moves on.
  env["COSMIC_BOOTSTRAP"] = "stand-in"
  local relative = call({ "/bin/sh", root .. "/bin/cosmic-bootstrap", "--raw-path" },
    tmp, tmp .. "/relative.out", env)
  out = assert(Fs.read(tmp .. "/relative.out"))
  assert(relative.ok and out:sub(1, 1) == "/" and out:find("/stand%-in\n$") ~= nil, out)
  -- With COSMIC_BOOTSTRAP_VERIFY, which asks for the pin's checked one,
  -- a stand-in is refused rather than answered unchecked.
  env["COSMIC_BOOTSTRAP"], env["COSMIC_BOOTSTRAP_VERIFY"] = cosmic, "1"
  local verified = call({ "/bin/sh", root .. "/bin/cosmic-bootstrap" },
    tmp, tmp .. "/verified.out", env)
  out = assert(Fs.read(tmp .. "/verified.out"))
  assert(not verified.ok and out:find("both set", 1, true) ~= nil, out)
  assert(not Predicate.exists(tmp .. "/calls"), "a stand-in still fetched the pin's cosmic")
end

--- A COSMIC_BOOTSTRAP that is not an executable file is refused, never
--- passed over for the pin's cosmic.
local function test_bootstrap_refuses_a_cosmic_bootstrap_it_cannot_run(tmp: string)
  local program = assert(Proc.executable())
  local digest = Hash.hex_sha256((assert(Fs.read(program))))
  local root, _ = bootstrap_root(tmp, string.rep("e", 40), digest)
  assert(Fs.write(tmp .. "/plain", "not a program\n", 0x1a4))
  for _, given in ipairs({ tmp .. "/plain", tmp .. "/absent", tmp }) do
    local result = call({ "/bin/sh", root .. "/bin/cosmic-bootstrap", "--version" },
      tmp, tmp .. "/refused.out",
      { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = program, CALLS = tmp .. "/calls",
        XDG_CACHE_HOME = tmp .. "/xdg", COSMIC_BOOTSTRAP = given })
    local out = assert(Fs.read(tmp .. "/refused.out"))
    assert(not result.ok, given .. " was taken")
    assert(out == "bin/cosmic-bootstrap: COSMIC_BOOTSTRAP=" .. given ..
        " is not an executable file\n", out)
  end
  assert(not Predicate.exists(tmp .. "/calls"), "a refused stand-in fell back to the pin")
end

--- Each tool behind bin/ runs its own Teal standalone, with the words it
--- was given, in the caller's directory, on the cosmic bin/cosmic-bootstrap
--- answers: seen through a stand-in, from another directory.
local function test_each_tool_runs_its_script_through_the_bootstrap(tmp: string)
  local root, _ = bootstrap_root(tmp, string.rep("f", 40), string.rep("0", 64))
  local cosmic = stand_in(tmp)
  local here = checkout_root()
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/ci/bootstrap-files.txt", "# listed\nbuild/zig.tl\nbuild/vendor.tl\nbuild/verify_codesign.tl\n"))
  for tool, script in pairs({ ["zig"] = "zig.tl", ["vendor"] = "vendor.tl",
      ["verify-codesign"] = "verify_codesign.tl" }) do
    assert(Fs.write(root .. "/bin/" .. tool,
      (assert(Fs.read(here .. "/bin/" .. tool))), 0x1ed))
    local result = call({ root .. "/bin/" .. tool, "x", "y z" }, tmp,
      tmp .. "/tool.out", { COSMIC_BOOTSTRAP = cosmic, PATH = fake_curl(tmp),
        DOWNLOAD_SOURCE = tmp .. "/missing", XDG_CACHE_HOME = tmp .. "/xdg" })
    local out = assert(Fs.read(tmp .. "/tool.out"))
    assert(result.ok and out == "ran\n" .. physical(tmp) .. "\n--standalone\n" ..
        root .. "/build/" .. script .. "\nx\ny z\n", tool .. ": " .. out)
  end
end

--- The list as the wrapper reads it: comments, a CR, leading and trailing space, and entries that are only a prefix of
--- a path.
local list_text = "# why\n  build/listed.tl  # trailing\r\nbuild/crlf.tl\r\n  build/space.tl \n# build/commented.tl\nbuild/paths.tl\n"

local refusal = "bin/cosmic-bootstrap: build/unlisted.tl is not in ci/bootstrap-files.txt, so it is not type-checked " ..
  "on the pinned release: list it there, then run `cosmic-driver cosmic_ci/driver.tl check-islands` from ci/\n"

--- A checkout at `tmp/root` whose list is `list_text` and whose files are all there, with files outside it.
local function listed_checkout(tmp: string): string
  local root, _ = bootstrap_root(tmp, string.rep("1", 40), string.rep("0", 64))
  assert(Fs.mkdirs(root .. "/build/sub") and Fs.mkdirs(tmp .. "/outside"))
  -- ci/d is a link to build/sub: `ci/d/..` is build/ where it stands, and ci/ only to a reader that takes `..` before the link.
  assert(Fs.symlink("../build/sub", root .. "/ci/d"))
  assert(Fs.write(root .. "/ci/bootstrap-files.txt", list_text))
  for _, name in ipairs({ "listed.tl", "crlf.tl", "space.tl", "commented.tl", "paths.tl", "paths.tl.evil", "paths",
      "unlisted.tl" }) do
    assert(Fs.write(root .. "/build/" .. name, "return 1\n"))
  end
  assert(Fs.write(tmp .. "/outside/free.tl", "return 1\n"))
  assert(Fs.symlink(root .. "/build/unlisted.tl", tmp .. "/outside/link.tl"))
  assert(Fs.symlink(root .. "/build", tmp .. "/outside/dir"))
  return root
end

--- `argv` run by `program` in `tmp` with the stand-in as COSMIC_BOOTSTRAP (or none), its output, and whether it
--- succeeded.
local function ran(tmp: string, program: {string}, stand_in_path: string?, argv: {string}, extra?: {string:string}): string, boolean
  local env: mut {string:string} = { PATH = fake_curl(tmp), DOWNLOAD_SOURCE = tmp .. "/missing", CALLS = tmp .. "/calls",
    XDG_CACHE_HOME = tmp .. "/xdg" }
  if stand_in_path ~= nil then env["COSMIC_BOOTSTRAP"] = stand_in_path end
  for name, value in pairs(extra or {}) do env[name] = value end
  local words: mut {string} = {}
  for _, word in ipairs(program) do words[#words + 1] = word end
  for _, word in ipairs(argv) do words[#words + 1] = word end
  local result = call(words, tmp, tmp .. "/s.out", env)
  return assert(Fs.read(tmp .. "/s.out")), result.ok
end

--- `--standalone` on a file of the checkout runs only if ci/bootstrap-files.txt lists it, in the pin's branch and the
--- stand-in's alike, however the path is spelled; a file outside the checkout, and a listed one, run.
local function test_standalone_runs_only_the_files_the_list_names(tmp: string)
  local root = listed_checkout(tmp)
  local cosmic = stand_in(tmp)
  local wrapper = { "/bin/sh", root .. "/bin/cosmic-bootstrap" }
  -- Refused before anything is fetched or run: the pin's branch, the stand-in's, a relative path, links into the
  -- checkout from outside it (to the file, and to its directory), an entry that is only a prefix of a path.
  local files = { root .. "/build/unlisted.tl", "root/build/unlisted.tl", tmp .. "/outside/link.tl",
    tmp .. "/outside/dir/unlisted.tl", root .. "/build/commented.tl", root .. "/build/paths.tl.evil", root .. "/build/paths",
    root .. "/build", root .. "/build/gone.tl" }
  for _, file in ipairs(files) do
    for _, stand in ipairs({ "", cosmic }) do
      local given: string? = nil
      if stand ~= "" then given = stand end
      local out, ok = ran(tmp, wrapper, given, { "--standalone", file })
      assert(not ok and out:find("^bin/cosmic%-bootstrap: ") ~= nil and out:find("is not in ci/bootstrap-files.txt", 1, true) ~= nil,
        file .. ": " .. out)
    end
  end
  local out, ok = ran(tmp, wrapper, cosmic, { "--standalone", root .. "/build/unlisted.tl" })
  assert(not ok and out == refusal, out)
  assert(not Predicate.exists(tmp .. "/calls"), "a refused run fetched the pin's cosmic")
  -- A `..` after a linked directory is the physical one: ci/d/../x.tl is build/x.tl, not ci/x.tl, for the list and for
  -- the first-word form alike.
  out, ok = ran(tmp, wrapper, cosmic, { "--standalone", root .. "/ci/d/../unlisted.tl" })
  assert(not ok and out == refusal, out)
  out, ok = ran(tmp, wrapper, cosmic, { root .. "/ci/d/../unlisted.tl" })
  assert(not ok and out:find("outside ci/", 1, true) ~= nil, out)
  out, ok = ran(tmp, wrapper, cosmic, { "--standalone", root .. "/ci/d/../listed.tl" })
  assert(ok and out == "ran\n" .. physical(tmp) .. "\n--standalone\n" .. root .. "/ci/d/../listed.tl\n", out)
  -- The sandbox verb runs any program, so it is refused through the wrapper.
  out, ok = ran(tmp, wrapper, cosmic, { "sandbox", "--", "true" })
  assert(not ok and out:find("the sandbox verb runs any program", 1, true) ~= nil, out)
  -- A target whose directory cannot be resolved, and no target at all, are refused too.
  out, ok = ran(tmp, wrapper, cosmic, { "--standalone", tmp .. "/nowhere/x.tl" })
  assert(not ok and out:find("cannot resolve the directory of", 1, true) ~= nil, out)
  for _, argv in ipairs({ { "--standalone" }, { "--standalone", "" } }) do
    out, ok = ran(tmp, wrapper, cosmic, argv)
    assert(not ok and out == "bin/cosmic-bootstrap: --standalone names no file\n", out)
  end
  -- A file given as the first word builds the tree around it, which is how CI runs its own driver from ci/: allowed for a
  -- file under the checkout's ci/ and outside the checkout, refused for any other file of the checkout, listed or not.
  assert(Fs.write(root .. "/ci/driver.tl", "return 1\n"))
  for _, file in ipairs({ root .. "/build/unlisted.tl", root .. "/build/listed.tl" }) do
    out, ok = ran(tmp, wrapper, cosmic, { file })
    assert(not ok and out:find("outside ci/, which runs on the pinned release only as `--standalone <file>`", 1, true) ~= nil,
      file .. ": " .. out)
  end
  for _, file in ipairs({ root .. "/ci/driver.tl", tmp .. "/outside/free.tl" }) do
    out, ok = ran(tmp, wrapper, cosmic, { file, "platform" })
    assert(ok and out == "ran\n" .. physical(tmp) .. "\n" .. file .. "\nplatform\n", file .. ": " .. out)
  end
  -- Under COSMIC_STANDALONE=1 the same first word is a standalone run, held to the list: an unlisted file of ci/ too.
  for _, file in ipairs({ root .. "/build/unlisted.tl", root .. "/ci/driver.tl" }) do
    out, ok = ran(tmp, wrapper, cosmic, { file }, { COSMIC_STANDALONE = "1" })
    assert(not ok and out:find("is not in ci/bootstrap-files.txt", 1, true) ~= nil, file .. ": " .. out)
  end
  for _, file in ipairs({ root .. "/build/listed.tl", tmp .. "/outside/free.tl" }) do
    out, ok = ran(tmp, wrapper, cosmic, { file }, { COSMIC_STANDALONE = "1" })
    assert(ok and out == "ran\n" .. physical(tmp) .. "\n" .. file .. "\n", file .. ": " .. out)
  end
  -- The listed files, whatever the list's spelling of them (a comment before, a CR, white space), and one outside the
  -- checkout, run.
  for _, file in ipairs({ root .. "/build/listed.tl", root .. "/build/crlf.tl", root .. "/build/space.tl",
      root .. "/build/paths.tl", tmp .. "/outside/free.tl" }) do
    out, ok = ran(tmp, wrapper, cosmic, { "--standalone", file })
    assert(ok and out == "ran\n" .. physical(tmp) .. "\n--standalone\n" .. file .. "\n", file .. ": " .. out)
  end
  -- With no list at all, the checkout's files are refused rather than let by.
  assert(Fs.remove(root .. "/ci/bootstrap-files.txt"))
  out, ok = ran(tmp, wrapper, cosmic, { "--standalone", root .. "/build/listed.tl" })
  assert(not ok and out:find("ci/bootstrap-files.txt, which lists the files of the checkout that may run --standalone", 1, true) ~= nil, out)
end

--- What `$(bin/cosmic-bootstrap)` answers is an entry point, which holds the same list and then runs the release without
--- fetching it again, in an environment of its own cache and with COSMIC_BOOTSTRAP_VERIFY set; `--raw-path` is the
--- release itself.
local function test_the_entry_point_holds_the_list_and_the_raw_path_is_asked_for_by_name(tmp: string)
  local root = listed_checkout(tmp)
  local cosmic = stand_in(tmp)
  local wrapper = { "/bin/sh", root .. "/bin/cosmic-bootstrap" }
  local printed, ok = ran(tmp, wrapper, cosmic, {})
  local entry = printed:gsub("\n$", "")
  assert(ok and entry ~= cosmic and entry:find(tmp .. "/xdg/cosmic/bootstrap/entry-", 1, true) == 1, printed)
  -- Named by a sha256 of the checkout and the release, not a short checksum two of them could share.
  assert(entry:match("/entry%-(%x+)$") ~= nil and #assert(entry:match("/entry%-(%x+)$")) == 64, entry)
  local raw, raw_ok = ran(tmp, wrapper, cosmic, { "--raw-path" })
  assert(raw_ok and raw == cosmic .. "\n", raw)
  -- It refuses what the wrapper does, without running the release, and runs what the list names.
  local out, run_ok = ran(tmp, { entry }, nil, { "--standalone", root .. "/build/unlisted.tl" })
  assert(not run_ok and out == refusal, out)
  out, run_ok = ran(tmp, { entry }, nil, { "--standalone", root .. "/build/listed.tl" }, { COSMIC_BOOTSTRAP_VERIFY = "1" })
  assert(run_ok and out == "ran\n" .. physical(tmp) .. "\n--standalone\n" .. root .. "/build/listed.tl\n", out)
  out, run_ok = ran(tmp, { entry }, nil, { "x y" })
  assert(run_ok and out == "ran\n" .. physical(tmp) .. "\nx y\n", out)
  out, run_ok = ran(tmp, { entry }, nil, {})
  assert(run_ok and out == "ran\n" .. physical(tmp) .. "\n", out)
  assert(not Predicate.exists(tmp .. "/calls"), "the entry point fetched the pin's cosmic")
end

--- The release an entry point runs gets its caller's environment: COSMIC_BOOTSTRAP, which the tree's tools read to mean
--- a stand-in toolchain (and keep no compile memo under), is not set by the entry point, nor is the variable the entry
--- point runs bin/cosmic-bootstrap with. (CI's every `cosmic-driver` is the release run through one.)
local function test_the_entry_point_leaves_no_bootstrap_variable_in_the_releases_environment(tmp: string)
  local root = listed_checkout(tmp)
  local reporter = tmp .. "/reporter"
  assert(Fs.write(reporter, "#!/bin/sh\necho \"COSMIC_BOOTSTRAP=${COSMIC_BOOTSTRAP-unset}\"\necho \"ENTRY=${COSMIC_BOOTSTRAP_ENTRY-unset}\"\necho \"VERIFY=${COSMIC_BOOTSTRAP_VERIFY-unset}\"\n", 0x1ed))
  local printed, ok = ran(tmp, { "/bin/sh", root .. "/bin/cosmic-bootstrap" }, reporter, {})
  assert(ok, printed)
  local entry = printed:gsub("\n$", "")
  local out, run_ok = ran(tmp, { entry }, nil, { "x" })
  assert(run_ok and out == "COSMIC_BOOTSTRAP=unset\nENTRY=unset\nVERIFY=unset\n", out)
  -- Nor does it drop what the caller set, COSMIC_BOOTSTRAP_VERIFY included.
  out, run_ok = ran(tmp, { entry }, nil, { "x" }, { COSMIC_BOOTSTRAP_VERIFY = "1" })
  assert(run_ok and out == "COSMIC_BOOTSTRAP=unset\nENTRY=unset\nVERIFY=1\n", out)
  -- What the caller set stays, as it does for a release run through the wrapper.
  out, run_ok = ran(tmp, { entry }, "/given", { "x" })
  assert(run_ok and out == "COSMIC_BOOTSTRAP=/given\nENTRY=unset\nVERIFY=unset\n", out)
end

local function test_driver_records_success_failures_timeout_and_interruption(tmp: string)
  local runner = seeded_bootstrap(tmp)
  local project = driver_project(tmp)
  local candidate = checkout_root()
  local driver = project .. "/cosmic_ci/driver.tl"
  -- RUNNER_TEMP always exists in CI; Context.read() resolves its scratch
  -- directory as an external path before creating anything under it, which
  -- requires RUNNER_TEMP itself to already be there.
  local runner_temp = tmp .. "/runner-temp"
  assert(Fs.mkdirs(runner_temp))
  local ctx_env = driver_context(candidate, runner_temp)
  local function run(phase: string, timeout: string, argv: {string}): Child.Result
    local command = { runner, driver, "run", phase, timeout, "--" }
    for _, value in ipairs(argv) do command[#command + 1] = value end
    return call(command, project, tmp .. "/" .. phase .. ".out", ctx_env,
      driver_timeout)
  end
  local spaced = tmp .. "/path with spaces"
  assert(run("success", trivial_timeout, { "/bin/sh", "-c",
    "test \"$PWD\" = \"$1\"; printf ok > \"$2\"", "sh",
    candidate, spaced }).ok)
  assert(assert(Fs.read(spaced)) == "ok", "success child lost cwd or spaced argv")
  assert(run("nonzero", trivial_timeout, { "/bin/sh", "-c", "exit 23" }).code == 23)
  assert(run("start-failure", trivial_timeout, { "/definitely/not/a/command" }).code == 1)
  assert(run("timeout", tostring(Clock.ms(20)), { "/bin/sh", "-c", "sleep 30" }).code == 124)

  local ready = tmp .. "/ready"
  local command = { runner, driver, "run", "interrupted", tostring(Clock.seconds(30)), "--", "/bin/sh", "-c",
    "printf ready > \"$1\"; sleep 30", "sh", ready }
  local fd = assert(Fs.open_write(tmp .. "/interrupted.out"))
  local child = assert(Child.start(command, { cwd = project, env = environment(ctx_env),
    stdout = fd, stderr = fd, process_group = true }))
  for _ = 1, driver_timeout // Clock.ms(20) do
    if Predicate.exists(ready) then break end
    Clock.sleep_ns(10 * 1000 * 1000)
  end
  assert(Predicate.exists(ready), "interrupted operation never started")
  assert(child:stop())
  local stopped = assert(child:wait(child_timeout))
  assert(Fs.close(fd))
  assert(not stopped.ok, "interrupted driver succeeded")

  local summary = tmp .. "/summary.md"
  assert(call({ runner, driver, "summarize" }, project, tmp .. "/summarize.out",
    driver_context(candidate, runner_temp, { GITHUB_STEP_SUMMARY = summary }),
    driver_timeout).ok)
  local text = assert(Fs.read(summary))
  for _, row in ipairs({ "| worker | run-1 | 1 | success | success |",
      "| worker | run-1 | 1 | nonzero | exit |",
      "| worker | run-1 | 1 | start-failure | start-error |",
      "| worker | run-1 | 1 | timeout | timeout |",
      "| worker | run-1 | 1 | interrupted | incomplete |" }) do
    assert(text:find(row, 1, true), "summary omitted " .. row)
  end

  -- Inside the candidate, so the boundary check fires on the resolved
  -- target, but in a hidden directory of its own, taken out after, so a
  -- regression can only ever touch a throwaway file.
  local inside = assert(sys.mkdtemp(candidate .. "/ci/.sentinel.XXXXXX"))
  local sentinel = inside .. "/sentinel.db"
  assert(Fs.write(sentinel, "sentinel"))
  local before = Hash.hex_sha256((assert(Fs.read(sentinel))))
  local symlink_runner_temp = tmp .. "/symlink-runner-temp"
  assert(Fs.mkdirs(symlink_runner_temp .. "/cosmic-ci"))
  assert(call({ "/bin/ln", "-s", sentinel,
    symlink_runner_temp .. "/cosmic-ci/operations.db" }, tmp, tmp .. "/db-ln.out").ok)
  local linked = call({ runner, driver, "run", "symlink-db", trivial_timeout,
    "--", "/bin/sh", "-c", "exit 0" }, project, tmp .. "/symlink-db.out",
    driver_context(candidate, symlink_runner_temp), driver_timeout)
  assert(not linked.ok, "symlink operation database was accepted")
  assert(Hash.hex_sha256((assert(Fs.read(sentinel)))) == before,
    "rejected symlink changed its target")
  assert(Fs.remove_tree(inside))
end

-- `summarize` runs `if: always()`, including after a failed checkout or a
-- failed self-check, so it must work from RUNNER_TEMP and
-- GITHUB_STEP_SUMMARY alone -- no GITHUB_WORKSPACE, COSMIC_WORKER, or any
-- of the rest of the full context `run`/`platform`/`provenance` need.
local function test_summarize_reports_unavailable_database(tmp: string)
  local runner = seeded_bootstrap(tmp)
  local project = driver_project(tmp)
  local driver = project .. "/cosmic_ci/driver.tl"
  local summary = tmp .. "/summary.md"
  local result = call({ runner, driver, "summarize" }, project,
    tmp .. "/summarize.out",
    { RUNNER_TEMP = tmp .. "/runner-temp", GITHUB_STEP_SUMMARY = summary },
    driver_timeout)
  assert(result.ok, "summarize failed for a missing operation database: " ..
      (Fs.read(tmp .. "/summarize.out") or "<no output>"))
  local text = assert(Fs.read(summary))
  assert(text:find("## Cosmic CI operations", 1, true) and
      text:find("unavailable", 1, true), "summary omitted the unavailable-database line")
end

local function test_driver_answers_help_and_refuses_an_unknown_command(tmp: string)
  local runner = seeded_bootstrap(tmp)
  local project = driver_project(tmp)
  local driver = project .. "/cosmic_ci/driver.tl"
  local env = { RUNNER_TEMP = tmp .. "/runner-temp" }
  local helped = call({ runner, driver, "--help" }, project, tmp .. "/help.out", env,
    driver_timeout)
  local help = assert(Fs.read(tmp .. "/help.out"))
  assert(helped.code == 0, help)
  for _, name in ipairs({ "platform", "provenance", "run", "summarize" }) do
    assert(help:find("\n  " .. name .. " ", 1, true), help)
  end
  local one = call({ runner, driver, "run", "--help" }, project, tmp .. "/run-help.out", env,
    driver_timeout)
  local run_help = assert(Fs.read(tmp .. "/run-help.out"))
  assert(one.code == 0 and run_help:find("driver.tl run PHASE TIMEOUT_NS -- EXECUTABLE", 1, true) ~= nil,
    run_help)
  local refused = call({ runner, driver, "platfrom" }, project, tmp .. "/unknown.out", env,
    driver_timeout)
  local why = assert(Fs.read(tmp .. "/unknown.out"))
  assert(refused.code == 2 and why:find("no such command: platfrom", 1, true) ~= nil, why)
  -- The form without "--" is refused with the usage that shows where it
  -- goes.
  local old = call({ runner, driver, "run", "p", "100", "/bin/sh", "-c", "exit 0" }, project,
    tmp .. "/old-run.out", env, driver_timeout)
  local told = assert(Fs.read(tmp .. "/old-run.out"))
  assert(old.code == 2 and told:find("usage: driver.tl run PHASE TIMEOUT_NS -- EXECUTABLE", 1, true) ~= nil,
    told)
end
