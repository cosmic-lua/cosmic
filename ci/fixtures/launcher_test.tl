local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local sys = require("cosmic.sys")
local Time = require("cosmic.time")
local Fixture = require("cosmic_ci.fixture")
local Runner = require("cosmic_ci.runner")

local child_timeout_ms <const> = 30000
local handshake_timeout_ms <const> = 5000

local record Context
  artifact: string
  socket: string
  target: string
  work: string
  diagnostics: string
end

local record Running
  handle: Child.Handle
  out_fd: integer
  err_fd: integer
  input_fd: integer | nil
  out: string
  err: string
  closed: boolean
end

local private_environment = {
  "COSMIC_PORTABLE_ARTIFACT_FD", "COSMIC_PORTABLE_CORE_FD",
  "COSMIC_PORTABLE_TARGET_ID", "COSMIC_PORTABLE_CONFIGURATION_ID",
  "COSMIC_PORTABLE_CORE_OFFSET", "COSMIC_PORTABLE_CORE_LENGTH",
  "COSMIC_PORTABLE_CORE_SHA256", "COSMIC_PORTABLE_TEST_HOOK",
  "COSMIC_PORTABLE_TEST_READY", "COSMIC_PORTABLE_TEST_GO",
  "PORTABLE_PAYLOAD_MARKER", "PORTABLE_PAYLOAD_EXIT",
  "PORTABLE_PAYLOAD_SIGNAL", "PORTABLE_EXPECT_CWD",
  "PORTABLE_EXPECT_UMASK", "PORTABLE_CHECK_IO",
}

local function environment(cache?: string,
    extra?: {string:string}): {string:string}
  local values = Fixture.environment({
    PORTABLE_ORDINARY_ENV = "preserved",
    PORTABLE_CALLER_LOCALE = "preserved",
  })
  for _, name in ipairs(private_environment) do values[name] = nil end
  values.COSMIC_PORTABLE_CACHE = cache
  if extra then for name, value in pairs(extra) do values[name] = value end end
  return values
end

local function chmod(path: string, mode: integer)
  assert(sys.chmod(path, mode))
end

local function permissions(path: string): integer
  return assert(Fs.stat(path)).mode & 0x1ff
end

local function setup(tmp: string): Context
  local work = tmp .. "/launcher"
  local program = work .. "/program space"
  local run = work .. "/run space"
  local alias = work .. "/run alias"
  local diagnostics = work .. "/logs"
  Fixture.mkdir(program); Fixture.mkdir(run); Fixture.mkdir(diagnostics)
  Fixture.run("run-alias", { "/usr/bin/env", "ln", "-s", run, alias },
    work, diagnostics)
  local artifact = program .. "/launcher.test"
  Fixture.copy(Fixture.required("COSMIC_FIXTURE_LAUNCHER"), artifact, 0x1ed)
  return { artifact = artifact,
    socket = Fixture.required("COSMIC_FIXTURE_LAUNCHER_SOCKET"),
    target = Fixture.required("COSMIC_FIXTURE_TARGET"), work = work,
    diagnostics = diagnostics }
end

local function outcome_ok(outcome: Fixture.Outcome, label: string)
  assert(outcome.result.ok, label .. " failed; stdout=" .. outcome.out ..
    "; stderr=" .. outcome.err)
end

local function run(ctx: Context, label: string, cache?: string,
    extra?: {string:string}, program?: string): Fixture.Outcome
  return Fixture.call_with_environment(label, { program or ctx.artifact }, ctx.work,
    ctx.diagnostics, environment(cache, extra), child_timeout_ms)
end

local function expect_failure(ctx: Context, label: string, pattern: string,
    cache: string, program?: string): Fixture.Outcome
  local answer = run(ctx, label, cache, nil, program)
  assert(not answer.result.ok and not answer.result.timed_out,
    label .. " unexpectedly succeeded or timed out")
  Fixture.contains(answer.err, pattern)
  return answer
end

local function only_core(cache: string): string
  local found: string | nil = nil
  for _, name in ipairs((assert(Fs.list(cache)))) do
    local path = cache .. "/" .. name
    local st = assert(sys.lstat(path))
    if name:sub(1, 1) ~= "." and st.kind == "file" then
      assert(found == nil, "cache contains multiple public cores")
      found = path
    end
  end
  return (assert(found, "cache contains no public core"))
end

local function no_private_entries(cache: string, stem: string)
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(name:sub(1, #stem) ~= stem,
      "cache retained private entry: " .. name)
  end
end

local function start(ctx: Context, label: string, argv: {string},
    cwd: string, values: {string:string}, input?: string): Running
  local out = ctx.diagnostics .. "/" .. label .. ".out"
  local err = ctx.diagnostics .. "/" .. label .. ".err"
  local out_fd = assert(Fs.open_write(out))
  local err_fd = assert(Fs.open_write(err))
  local input_fd: integer | nil = nil
  if input then input_fd = assert(Fs.open_read(input)) end
  local options: Child.Options = { cwd = cwd, env = values,
    stdout = out_fd, stderr = err_fd, process_group = false }
  if input_fd then options.stdin = input_fd end
  local handle, trouble = Child.start(argv, options)
  if handle == nil then
    if input_fd then Fs.close(input_fd) end
    Fs.close(out_fd); Fs.close(err_fd)
    error(label .. ": " .. trouble)
  end
  return { handle = handle, out_fd = out_fd, err_fd = err_fd,
    input_fd = input_fd, out = out, err = err, closed = false }
end

local function close_descriptors(running: Running)
  if not running.closed then
    if running.input_fd then assert(Fs.close(running.input_fd)) end
    assert(Fs.close(running.out_fd)); assert(Fs.close(running.err_fd))
    running.closed = true
  end
end

local function finish(running: Running, timeout?: integer): Child.Result
  local result, trouble = running.handle:wait(timeout or child_timeout_ms)
  if result == nil then
    running.handle:close(); close_descriptors(running)
    error("launcher child wait failed: " .. trouble)
  end
  close_descriptors(running)
  return result
end

local function cleanup(running: Running)
  if not running.closed then
    running.handle:close()
    close_descriptors(running)
  end
end

local function supervised(action: function({Running}))
  local active: {Running} = {}
  local called, failure = pcall(function(): boolean
    action(active); return true
  end)
  for _, running in ipairs(active) do cleanup(running) end
  if not called then error(failure) end
end

local function fifo(ctx: Context, name: string): string
  local path = ctx.work .. "/" .. name
  Fixture.run("mkfifo-" .. name, { "/usr/bin/env", "mkfifo", path },
    ctx.work, ctx.diagnostics)
  return path
end

local function await_ready(ctx: Context, name: string, path: string)
  local answer = Fixture.run("ready-" .. name,
    { "/usr/bin/env", "cat", path }, ctx.work, ctx.diagnostics, nil,
    handshake_timeout_ms)
  assert(Fixture.small(answer.out, 128) == "ready\n",
    "launcher hook readiness differs")
end

local function release(ctx: Context, name: string, path: string)
  local input = ctx.work .. "/release-" .. name
  Fixture.write(input, "go\n")
  Fixture.run("release-" .. name, { "/usr/bin/env", "tee", path },
    ctx.work, ctx.diagnostics, nil, handshake_timeout_ms, input)
end

local function hook_environment(cache: string, hook: string, ready: string,
    go: string): {string:string}
  return environment(cache, { COSMIC_PORTABLE_TEST_HOOK = hook,
    COSMIC_PORTABLE_TEST_READY = ready, COSMIC_PORTABLE_TEST_GO = go })
end

local function test_launcher_cold_warm_and_default_paths(tmp: string)
  local ctx = setup(tmp)
  local cache = ctx.work .. "/cache \\ override"
  local marker = ctx.work .. "/basic.marker"
  local input = ctx.work .. "/input"
  Fixture.write(input, "input stays intact\n")
  supervised(function(active: {Running})
    local values = environment(cache, { PORTABLE_PAYLOAD_MARKER = marker,
      PORTABLE_EXPECT_CWD = ctx.work .. "/run alias",
      PORTABLE_EXPECT_UMASK = "0027", PORTABLE_CHECK_IO = "1" })
    local child = start(ctx, "basic", { "/bin/sh", "-c",
      "umask 027; exec \"$@\"", "sh", ctx.artifact, "a b", "", "--literal" },
      ctx.work .. "/run alias", values, input)
    active[#active + 1] = child
    local result = finish(child)
    assert(result.ok, "cold launcher failed")
    Fixture.contains(child.out, "pid=" .. tostring(child.handle.pid) .. "\n")
    Fixture.contains(child.out, "args=a b||--literal\n")
    Fixture.contains(child.err, "payload stderr\n")
  end)
  assert(Fixture.read(marker) == "ran\n", "cold launch did not run the payload")
  assert(permissions(cache) == 0x1c0, "cold cache mode differs")
  local core = only_core(cache)
  assert(permissions(core) == 0x140, "cold core mode differs")
  local core_hash = Fixture.hash(core)
  local cache_stat = assert(Fs.stat(cache))
  local core_stat = assert(Fs.stat(core))
  chmod(cache, 0x140)
  outcome_ok(run(ctx, "warm", cache), "warm launcher")
  local cache_after = assert(Fs.stat(cache))
  local core_after = assert(Fs.stat(core))
  assert(permissions(cache) == 0x140 and
    cache_after.mtime == cache_stat.mtime and
    cache_after.mtime_ns == cache_stat.mtime_ns and
    core_after.mtime == core_stat.mtime and
    core_after.mtime_ns == core_stat.mtime_ns and
    Fixture.hash(core) == core_hash, "warm launch changed cache state")
  chmod(cache, 0x1c0)

  local home, xdg = ctx.work .. "/home", ctx.work .. "/xdg"
  Fixture.mkdir(home); Fixture.mkdir(xdg)
  local default_env = environment()
  default_env.COSMIC_PORTABLE_CACHE = nil
  default_env.XDG_CACHE_HOME = nil
  default_env.HOME = home
  local default = Fixture.call_with_environment("default-cache",
    { ctx.artifact }, ctx.work,
    ctx.diagnostics, default_env)
  outcome_ok(default, "default cache")
  local default_cache = ctx.target == "aarch64-macos" and
    home .. "/Library/Caches/cosmic/cores" or home .. "/.cache/cosmic/cores"
  local default_exists = Predicate.is_dir(default_cache)
  assert(default_exists and permissions(default_cache) == 0x1c0,
    "default cache is missing or not 0700: " .. default_cache)
  local xdg_env = environment()
  xdg_env.COSMIC_PORTABLE_CACHE = nil; xdg_env.XDG_CACHE_HOME = xdg
  xdg_env.HOME = home
  outcome_ok(Fixture.call_with_environment("xdg-cache",
    { ctx.artifact }, ctx.work,
    ctx.diagnostics, xdg_env), "XDG cache")
  local xdg_exists = Predicate.is_dir(xdg .. "/cosmic/cores")
  assert(xdg_exists, "XDG cache was not made under " .. xdg)
  local relative_home = ctx.work .. "/relative-home"; Fixture.mkdir(relative_home)
  local relative_xdg = environment()
  relative_xdg.COSMIC_PORTABLE_CACHE = nil
  relative_xdg.XDG_CACHE_HOME = "relative"; relative_xdg.HOME = relative_home
  outcome_ok(Fixture.call_with_environment("relative-xdg",
    { ctx.artifact }, ctx.work,
    ctx.diagnostics, relative_xdg), "relative XDG fallback")

  for _, case in ipairs({
      { "empty-cache", "", home, "must be an absolute path" },
      { "relative-cache", "relative", home, "must be an absolute path" },
    }) do
    local values = environment(case[2]); values.HOME = case[3]
    local answer = Fixture.call_with_environment(case[1],
      { ctx.artifact }, ctx.work,
      ctx.diagnostics, values)
    assert(not answer.result.ok, case[1] .. " unexpectedly succeeded")
    Fixture.contains(answer.err, case[4])
  end
  for _, name in ipairs({ "relative-home", "unset-home" }) do
    local temp = ctx.work .. "/" .. name .. "-tmp"; Fixture.mkdir(temp)
    local values = environment(); values.COSMIC_PORTABLE_CACHE = nil
    values.XDG_CACHE_HOME = name == "relative-home" and "relative" or nil
    values.HOME = name == "relative-home" and "relative" or nil
    values.TMPDIR = temp
    outcome_ok(Fixture.call_with_environment(name,
      { ctx.artifact }, ctx.work,
      ctx.diagnostics, values), name .. " temp fallback")
    local made = assert(Fs.list(temp))
    assert(#made == 1 and made[1]:match("^cosmic%-cores%-%d+$") ~= nil,
      name .. " did not make its own cache leaf in TMPDIR")
    assert(permissions(temp .. "/" .. made[1]) == 0x1c0,
      name .. " cache leaf is not private")
  end
end

local function test_launcher_cache_policy_and_integrity(tmp: string)
  local ctx = setup(tmp)
  local target = ctx.work .. "/leaf-target"; Fixture.mkdir(target)
  Fixture.run("leaf-link", { "/usr/bin/env", "ln", "-s", target,
    ctx.work .. "/leaf-link" }, ctx.work, ctx.diagnostics)
  for i, suffix in ipairs({ "", "/", "////" }) do
    expect_failure(ctx, "leaf-link-failure-" .. tostring(i), "symbolic link",
      ctx.work .. "/leaf-link" .. suffix)
  end
  local mode_cache = ctx.work .. "/mode-cache"; Fixture.mkdir(mode_cache)
  chmod(mode_cache, 0x1ed)
  expect_failure(ctx, "unsafe-mode", "mode must be 0700 or 0500", mode_cache)
  local read_only = ctx.work .. "/cold-read-only"; Fixture.mkdir(read_only)
  chmod(read_only, 0x140)
  expect_failure(ctx, "cold-read-only", "cache is read-only", read_only)

  local base = ctx.work .. "/base-cache"
  outcome_ok(run(ctx, "base-cold", base), "base cold launch")
  local core = only_core(base); local key = core:match("([^/]+)$") as string
  local core_bytes, core_hash = Fixture.read(core), Fixture.hash(core)
  local sentinel = ctx.work .. "/sentinel"; Fixture.write(sentinel, "untouched\n")
  local linked = ctx.work .. "/symlink-cache"; Fixture.mkdir(linked)
  chmod(linked, 0x1c0)
  Fixture.run("core-link", { "/usr/bin/env", "ln", "-s", sentinel,
    linked .. "/" .. key }, ctx.work, ctx.diagnostics)
  local repaired = run(ctx, "symlink-repair", linked)
  outcome_ok(repaired, "symlink repair")
  assert(Fixture.read(sentinel) == "untouched\n" and
    assert(sys.lstat(linked .. "/" .. key)).kind == "file",
    "symlink repair wrote through the link or left no core file")
  Fixture.contains(repaired.err, "symbolic link; repairing")

  local directory_cache = ctx.work .. "/directory-cache"
  Fixture.mkdir(directory_cache .. "/" .. key); chmod(directory_cache, 0x1c0)
  outcome_ok(run(ctx, "directory-repair", directory_cache), "directory repair")
  assert(assert(Fs.stat(directory_cache .. "/" .. key)).kind == "file",
    "directory repair left no core file")
  local mode_entry = ctx.work .. "/entry-mode-cache"; Fixture.mkdir(mode_entry)
  chmod(mode_entry, 0x1c0); Fixture.write(mode_entry .. "/" .. key,
core_bytes, 0x1c0)
  local mode_repair = run(ctx, "entry-mode-repair", mode_entry)
  outcome_ok(mode_repair, "entry mode repair")
  Fixture.contains(mode_repair.err, "mode is not 0500; repairing")

  -- The launcher leaves a warm core's digest to startup (runtime_test), so
  -- the entries it refuses here are the ones it can see are wrong.
  Fixture.write(core, core_bytes:sub(1, 20), 0x140); chmod(base, 0x140)
  local marker = ctx.work .. "/read-only-short.marker"
  local refused = run(ctx, "read-only-short", base,
    { PORTABLE_PAYLOAD_MARKER = marker })
  assert(not refused.result.ok and Fs.exists(marker) == false,
    "read-only short core was not refused before the payload ran")
  Fixture.contains(refused.err, "length differs and cache is read-only")
  chmod(base, 0x1c0)
  local short = run(ctx, "short-repair", base); outcome_ok(short, "short repair")
  Fixture.contains(short.err, "length differs; repairing")
  assert(Fixture.hash(core) == core_hash, "short repair core digest differs")

  -- A launcher arm is the quoted `uname -sm` answer it selects.
  local host = ctx.target == "aarch64-macos" and "'Darwin arm64'" or
    (ctx.target == "aarch64-linux-musl" and "'Linux aarch64'" or "'Linux x86_64'")
  local artifact = Fixture.read(ctx.artifact)
  local selected: string | nil = nil
  for line in artifact:sub(1, 16384):gmatch("[^\n]+") do
    if line:sub(1, #host + 2) == "  " .. host then
      assert(selected == nil, "duplicate selected launcher header")
      selected = line
    end
  end
  local selected_line = assert(selected, "selected launcher header is missing")
  local offset = math.tointeger(assert(tonumber(
    selected_line:match("cosmic_offset=(%d+);"))))
  local length = math.tointeger(assert(tonumber(
    selected_line:match("cosmic_length=(%d+);"))))
  assert(offset and length, "selected launcher header offset or length is not an integer")
  local truncated = ctx.work .. "/truncated"
  Fixture.write(truncated, artifact:sub(1, offset + length - 1), 0x1ed)
  expect_failure(ctx, "truncated", "extracted core is truncated",
    ctx.work .. "/truncated-cache", truncated)
  local equal = ctx.work .. "/equal-corrupt"
  Fixture.write(equal, artifact:sub(1, offset) .. "Z" ..
    artifact:sub(offset + 2), 0x1ed)
  expect_failure(ctx, "equal-corrupt", "extracted core digest differs",
    ctx.work .. "/equal-cache", equal)
end

local function test_launcher_publication_and_interruption(tmp: string)
  local ctx = setup(tmp)
  supervised(function(active: {Running})
    local race = ctx.work .. "/race-cache"
    local ready1, go1 = fifo(ctx, "race-ready1"), fifo(ctx, "race-go1")
    local ready2, go2 = fifo(ctx, "race-ready2"), fifo(ctx, "race-go2")
    local first = start(ctx, "race1", { ctx.artifact }, ctx.work,
      hook_environment(race, "before_publish", ready1, go1))
    active[#active + 1] = first; await_ready(ctx, "race1", ready1)
    local second = start(ctx, "race2", { ctx.artifact }, ctx.work,
      hook_environment(race, "before_publish", ready2, go2))
    active[#active + 1] = second; await_ready(ctx, "race2", ready2)
    release(ctx, "race1", go1); release(ctx, "race2", go2)
    assert(finish(first).ok and finish(second).ok, "publisher race failed")
    only_core(race); no_private_entries(race, ".core.")
    no_private_entries(race, ".repair-")

    local interrupted = ctx.work .. "/interrupted-cache"
    local ready, go = fifo(ctx, "interrupt-ready"), fifo(ctx, "interrupt-go")
    local publisher = start(ctx, "interrupted", { ctx.artifact }, ctx.work,
      hook_environment(interrupted, "before_publish", ready, go))
    active[#active + 1] = publisher; await_ready(ctx, "interrupt", ready)
    assert(publisher.handle:stop(sys.SIGTERM))
    assert(not finish(publisher).ok, "interrupted publisher succeeded")
    no_private_entries(interrupted, ".core.")
    outcome_ok(run(ctx, "interrupt-next", interrupted), "post-interrupt launch")
    local core = only_core(interrupted); local bytes = Fixture.read(core)
    Fixture.write(core, bytes:sub(1, 20), 0x140)
    local repair_ready, repair_go =
      fifo(ctx, "repair-ready"), fifo(ctx, "repair-go")
    local repair = start(ctx, "repair-interrupted", { ctx.artifact }, ctx.work,
      hook_environment(interrupted, "after_repair_lock", repair_ready, repair_go))
    active[#active + 1] = repair; await_ready(ctx, "repair", repair_ready)
    assert(repair.handle:stop(sys.SIGTERM))
    assert(not finish(repair).ok, "interrupted repair succeeded")
    no_private_entries(interrupted, ".repair-")
    outcome_ok(run(ctx, "repair-next", interrupted), "post-repair launch")

    Fixture.write(core, bytes:sub(1, 20), 0x140)
    local kill_ready, kill_go = fifo(ctx, "kill-ready"), fifo(ctx, "kill-go")
    local killed = start(ctx, "repair-killed", { ctx.artifact }, ctx.work,
      hook_environment(interrupted, "after_repair_lock", kill_ready, kill_go))
    active[#active + 1] = killed; await_ready(ctx, "kill", kill_ready)
    assert(killed.handle:stop(sys.SIGKILL))
    assert(not finish(killed).ok, "killed repair succeeded")
    expect_failure(ctx, "stale-lock", "cache repair is already locked:", interrupted)
    local stale: string | nil = nil
    for _, name in ipairs((assert(Fs.list(interrupted)))) do
      if name:sub(1, 8) == ".repair-" then
        assert(stale == nil, "multiple stale repair owners")
        stale = interrupted .. "/" .. name
      end
    end
    assert(Fs.remove((assert(stale, "stale repair owner is missing"))))
    outcome_ok(run(ctx, "repair-after-stale", interrupted),
      "launch after stale owner removal")
  end)
end

local function test_launcher_descriptors_exit_and_signal(tmp: string)
  local ctx = setup(tmp)
  if ctx.socket ~= "" then
    local guard = ctx.work .. "/caller-write.guard"
    local mixed = Fixture.call_with_environment("mixed-descriptors",
      { "/bin/sh", "-c", [[
exec 3< "$1"
exec 8> "$2"
printf 'before\n' >&8
"$3" 9 "$1" > /dev/null
printf 'after\n' >&8
]], "sh", ctx.artifact, guard, ctx.socket }, ctx.work, ctx.diagnostics,
      environment(ctx.work .. "/mixed-fd-cache"))
    outcome_ok(mixed, "mixed descriptor launch")
    assert(Fixture.read(guard) == "before\nafter\n",
      "mixed descriptor launch disturbed the caller's descriptors")
  end
  for _, one in ipairs({
      { "one-free", [[
exec 3< "$1" 4< "$1" 5< "$1" 6< "$1"
exec 7< "$1" 8> "$2"
printf 'before\n' >&8
"$1" > /dev/null 2> "$3"
result=$?
printf 'after\n' >&8
exit "$result"
]], "8" },
      { "zero-free", [[
exec 3< "$1" 4< "$1" 5< "$1" 6< "$1"
exec 7< "$1" 8< "$1" 9> "$2"
printf 'before\n' >&9
"$1" > /dev/null 2> "$3"
result=$?
printf 'after\n' >&9
exit "$result"
]], "9" },
    }) do
    local guard = ctx.work .. "/" .. one[1] .. ".guard"
    local err = ctx.work .. "/" .. one[1] .. ".err"
    local answer = Fixture.call_with_environment(one[1],
      { "/bin/sh", "-c", one[2], "sh",
      ctx.artifact, guard, err }, ctx.work, ctx.diagnostics,
      environment(ctx.work .. "/" .. one[1] .. "-cache"))
    assert(not answer.result.ok, one[1] .. " unexpectedly succeeded")
    Fixture.contains(err,
      "fewer than two private descriptors are available in 3 through 9")
    assert(Fixture.read(guard) == "before\nafter\n" and
      Fs.exists(ctx.work .. "/" .. one[1] .. "-cache") == false,
      one[1] .. " disturbed the caller's descriptors or made a cache")
  end

  local exit_marker = ctx.work .. "/exit.marker"
  local exited = run(ctx, "payload-exit", ctx.work .. "/exit-cache",
    { PORTABLE_PAYLOAD_MARKER = exit_marker, PORTABLE_PAYLOAD_EXIT = "23" })
  assert(exited.result.code == 23 and Fixture.read(exit_marker) == "ran\n",
    "payload exit status 23 was not passed through")
  local signal_marker = ctx.work .. "/signal.marker"
  local signaled = run(ctx, "payload-signal", ctx.work .. "/signal-cache",
    { PORTABLE_PAYLOAD_MARKER = signal_marker, PORTABLE_PAYLOAD_SIGNAL = "1" })
  assert(not signaled.result.ok and Fixture.read(signal_marker) == "ran\n",
    "payload signal was not passed through")
end

local function test_launcher_noexec_timing_and_immutability(tmp: string)
  local ctx = setup(tmp); local before = Fixture.hash(ctx.artifact)
  local base = ctx.work .. "/base"; outcome_ok(run(ctx, "base", base), "base")
  local key = only_core(base):match("([^/]+)$") as string
  if ctx.target ~= "aarch64-macos" then
    local parent = Env.get_or("COSMIC_PORTABLE_NOEXEC_ROOT", "/dev/shm")
    local parent_is_dir = Predicate.is_dir(parent)
    if parent_is_dir then
      local made = Fixture.call("noexec-root", { "/usr/bin/env", "mktemp", "-d",
        parent .. "/cosmic-launcher.XXXXXXXX" }, ctx.work, ctx.diagnostics)
      if made.result.ok then
        local noexec = Fixture.small(made.out, 4096):match("([^\n]+)") as string
        local called, failure = pcall(function(): boolean
          local probe = noexec .. "/probe"
          Fixture.write(probe, "#!/bin/sh\nexit 0\n", 0x1c0)
          -- A noexec mount refuses the exec itself, so the probe may not
          -- even start; that is the answer, not a fixture error.
          local probe_run = Runner.execute({ argv = { probe }, cwd = ctx.work })
          if not probe_run.result or not probe_run.result.ok then
            local cache = noexec .. "/cache"
            local answer = run(ctx, "noexec-launch", cache)
            assert(answer.result.code == 126 and
              assert(Fs.stat(cache .. "/" .. key)).kind == "file",
              "noexec launch did not stop at 126 with the core intact")
            -- `[ -x ]` reflects noexec only where test(1) asks the kernel;
            -- BusyBox answers from the mode bits, so there the exec itself
            -- fails, the shell names the errno, and the launcher's EXIT
            -- trap ends the output. Either way the launcher stops at 126
            -- with the verified core left intact.
            local diagnostic = Fixture.small(answer.err, 4096)
            local refused =
              "\ncosmic portable: verified core was refused execution; " ..
              "Permission denied here usually means a noexec cache filesystem\n"
            assert(diagnostic ==
              "cosmic portable: verified core cannot execute on the cache filesystem\n" or
              diagnostic:sub(-#refused) == refused, diagnostic)
          end
          return true
        end)
        local removed = Fixture.call("noexec-remove",
          { "/bin/rm", "-rf", noexec }, ctx.work, ctx.diagnostics)
        outcome_ok(removed, "noexec cleanup")
        if not called then error(failure) end
      end
    end
  end
  local timing = ctx.work .. "/timing cache"
  local cold_started = assert(Time.monotonic_ns())
  outcome_ok(run(ctx, "timing-cold", timing), "cold timing launch")
  local cold_ms = (assert(Time.monotonic_ns()) - cold_started) // 1000000
  local warm_started = assert(Time.monotonic_ns())
  outcome_ok(run(ctx, "timing-warm", timing), "warm timing launch")
  local warm_ms = (assert(Time.monotonic_ns()) - warm_started) // 1000000
  assert(Fs.put(Fs.stderr, "portable launcher timing: cold=" ..
    tostring(cold_ms) .. "ms warm=" .. tostring(warm_ms) .. "ms\n"))
  assert(Fixture.hash(ctx.artifact) == before, "launcher artifact changed")
end
