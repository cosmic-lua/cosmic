-- fuzz.yml's run: every property fuzzed on the checked core, from the
-- checkout's root, its log streamed as it runs and kept for the run's
-- summary, which says what failed; and, for a run cancelled before it
-- finished, how far it got. FUZZ_SEED and FUZZ_ITERS come from the job.
local Child = require("cosmic.child")
local Context = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local State = require("cosmic_ci.state")
local Time = require("cosmic.time")

local record Fuzz
  --- One fuzz run: the checkout it runs in, the runner's scratch, the
  --- environment the test starts from, where its output streams to as
  --- it runs, and where the run's summary goes.
  record Run
    root: string
    temp: string
    env: {string:string}
    log: integer
    summarize: function(string)
  end
end

--- The checked core, relative to the checkout's root: `bin/zig build
--- sanitized` builds it.
local executable <const> = "o/sanitized/bin/cosmic"
--- Top-level trees the search leaves out: build output, vendored
--- sources, and the CI driver's own project.
local pruned <const>: {string:boolean} = { o = true, vendor = true, ci = true }
local suffix <const> = "_fuzz_test.tl"
local cut <const> = 300
local failing_lines <const> = 30
local report_lines <const> = 60
local tail_lines <const> = 40
local chunk <const> = 65536
local poll_ns <const> = 100 * 1000 * 1000

--- Every `*_fuzz_test.tl` under `root`, outside its top-level o/,
--- vendor/ and ci/, as `./`-relative paths in byte order.
function Fuzz.discover(root: string): {string}
  local found = assert(Fs.walk(root, function(entry: string, _name: string): boolean
    return pruned[entry] == true
  end))
  local tests: {string} = {}
  for _, entry in ipairs(found) do
    local name = Fs.basename(entry)
    if #name >= #suffix and name:sub(-#suffix) == suffix then
      tests[#tests + 1] = "./" .. entry
    end
  end
  table.sort(tests)
  return tests
end

--- `text`'s lines, as grep reads them: a last line without a newline
--- is a line too.
local function lines(text: string): {string}
  local out: {string} = {}
  for line in text:gmatch("([^\n]*)\n") do out[#out + 1] = line end
  local last = text:match("([^\n]+)$")
  if last then out[#out + 1] = last end
  return out
end

--- Up to `limit` of `from`, each cut to `cut` bytes, a line each.
local function bounded(from: {string}, limit: integer): string
  local out: {string} = {}
  for i = 1, math.min(#from, limit) do out[i] = from[i]:sub(1, cut) .. "\n" end
  return table.concat(out)
end

--- The summary's first lines, before the run.
function Fuzz.header(seed: string, iters: string): string
  return "FUZZ_SEED=" .. seed .. " FUZZ_ITERS=" .. iters .. "\n\n" ..
    "A failure's report names the FUZZ_CASE that checks its input again," ..
    " and its iteration under this seed.\n"
end

--- What a failed run's summary adds, from its output: every failing
--- test's line first, then the reports beneath them, bounded.
function Fuzz.failure(output: string, seed: string): string
  local failing: {string} = {}
  local reports: {string} = {}
  for _, line in ipairs(lines(output)) do
    if line:sub(1, 10) == "test: FAIL" then failing[#failing + 1] = line end
    if line:sub(1, 6) ~= "build:" and line:sub(1, 6) ~= "test: " then
      reports[#reports + 1] = line
    end
  end
  return "\nThe shrunk inputs are the run's fuzz-inputs-" .. seed ..
    " artifact; once fixed, keep each in testdata/fuzz/<property>/ as its" ..
    " report says.\n\n~~~~\n" .. bounded(failing, failing_lines) .. "\n" ..
    bounded(reports, report_lines) .. "~~~~\n"
end

--- What a cancelled run's summary says: the end of the output the run
--- kept, or none when it kept none.
function Fuzz.cancelled_summary(output: string | nil): string
  local all = lines(output or "")
  local tail: {string} = {}
  for i = math.max(1, #all - tail_lines + 1), #all do tail[#tail + 1] = all[i] end
  return "\nCancelled, at the time limit or by hand, before fuzzing finished:" ..
    " a property\nthat hangs is the likeliest cause. The end of its output:\n\n" ..
    "~~~~\n" .. bounded(tail, tail_lines) .. "~~~~\n"
end

--- Runs `argv` with both its streams written to `out`, copying what it
--- writes there to `log` as it goes, and answers its status as a shell
--- would: its exit code, 128 and the signal that ended it, or 127 when
--- it could not start. A SIGINT or SIGTERM this process gets meanwhile
--- is passed on to the child, and caught until `guard` closes.
-- TODO: copy the child's output from a pipe as it arrives, rather than
-- polling the file it writes every `poll_ns`, once the pinned cosmic
-- carries one a caller can read from (cosmic.child's "capture" only
-- answers at exit, and cosmic.fs has no pipe).
local function streamed(guard: Child.Guard, argv: {string}, cwd: string,
    env: {string:string}, out: string, log: integer): integer
  local out_fd = assert(Fs.open_write(out))
  local tail_fd, trouble = Fs.open_read(out)
  if tail_fd == nil then
    Fs.close(out_fd)
    error(trouble)
  end
  local function drain()
    while true do
      local bytes = assert(Fs.take(tail_fd, chunk))
      if bytes == "" then return end
      assert(Fs.put(log, bytes))
    end
  end
  local called, answer = pcall(function(): integer
    local handle, start_trouble = Child.start(argv, { cwd = cwd, env = env,
      stdout = out_fd, stderr = out_fd })
    if handle == nil then
      assert(Fs.put(out_fd, argv[1] .. ": " .. start_trouble .. "\n"))
      drain()
      return 127
    end
    local result: Child.Result = nil
    while result == nil do
      drain()
      local state = assert(handle:try_wait())
      if state.finished then
        result = state.result
      else
        local taken = guard:take()
        if taken ~= 0 then local _, _ = handle:stop(taken) end
        Time.sleep_ns(poll_ns)
      end
    end
    drain()
    if result.code then return result.code end
    return 128 + (result.signal or 0)
  end)
  local out_closed, out_trouble = Fs.close(out_fd)
  local tail_closed, tail_trouble = Fs.close(tail_fd)
  if not called then error(answer) end
  assert(out_closed, out_trouble)
  assert(tail_closed, tail_trouble)
  return answer as integer
end

--- Fuzzes every property `r.root` holds on its checked core, writing
--- the output to `$temp/fuzz.out` and the status to `$temp/fuzz.status`,
--- and answers the status.
function Fuzz.execute(r: Fuzz.Run): integer
  local seed, iters = r.env.FUZZ_SEED or "", r.env.FUZZ_ITERS or ""
  r.summarize(Fuzz.header(seed, iters))
  -- A failing test's directory is left under TMPDIR, holding the
  -- shrunk input it kept (build/test.tl's sweep).
  local scratch = r.temp .. "/fuzz"
  assert(Fs.mkdirs(scratch))
  local env: {string:string} = {}
  for name, value in pairs(r.env) do env[name] = value end
  env.TMPDIR = scratch
  env.COSMIC_AUTO_BOOT = "0"
  env.COSMIC_TEST_TIMEOUT = "1200"
  local argv: {string} = { r.root .. "/" .. executable, "test", "--all" }
  for _, test in ipairs(Fuzz.discover(r.root)) do argv[#argv + 1] = test end
  local out = r.temp .. "/fuzz.out"
  local status: integer
  do
    -- Streamed to the log as it runs, and kept for the summary: a run
    -- cancelled at its time limit still shows how far it got. A signal
    -- caught meanwhile is delivered again once the status is kept.
    local guard <close> = assert(Child.guard())
    status = streamed(guard, argv, r.root, env, out, r.log)
    assert(Fs.write(r.temp .. "/fuzz.status", tostring(status) .. "\n"))
  end
  if status ~= 0 then r.summarize(Fuzz.failure(assert(Fs.read(out)), seed)) end
  return status
end

--- `driver.tl fuzz`: the run, from the checkout GITHUB_WORKSPACE names,
--- with RUNNER_TEMP's scratch, and this process's environment.
function Fuzz.fuzz(_argv: {string}): integer
  return Fuzz.execute({
    root = State.canonical_directory(Context.required("GITHUB_WORKSPACE")),
    temp = Context.required("RUNNER_TEMP"),
    env = Env.all(),
    log = Fs.stdout,
    summarize = Context.summarize,
  })
end

--- `driver.tl fuzz-cancelled`: says on the run's summary how far a
--- cancelled run got, from the output `fuzz` kept, if it kept any.
function Fuzz.cancelled(_argv: {string}): integer
  local output = Fs.read(Context.required("RUNNER_TEMP") .. "/fuzz.out")
  Context.summarize(Fuzz.cancelled_summary(output))
  return 0
end

return Fuzz
