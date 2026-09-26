-- fuzz.yml's run: every property fuzzed on the checked core, from the
-- checkout's root, its log streamed as it runs and kept for the run's
-- summary, which says what failed; and, for a run cancelled before it
-- finished, how far it got. FUZZ_SEED and FUZZ_ITERS come from the job.
local Child = require("cosmic.child")
local Context = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local State = require("cosmic_ci.state")
local sys = require("cosmic.sys")
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
--- How many chunks one round of the copy takes at most.
local round_chunks <const> = 4

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

--- Up to `limit` of `from`, a line each.
local function joined(from: {string}, limit: integer): string
  local out: {string} = {}
  for i = 1, math.min(#from, limit) do out[i] = from[i] .. "\n" end
  return table.concat(out)
end

--- Calls `each` with every line `next_chunk` answers, as grep reads
--- them -- a last line without a newline is a line too -- each cut to
--- `cut` bytes, so a line of any length takes no more than that; until
--- `next_chunk` answers "" or `each` answers true.
local function each_line(next_chunk: function(): string,
    each: function(string): boolean)
  local line: {string} = {}
  local length = 0
  local function add(piece: string)
    if length < cut and #piece > 0 then
      local kept = piece:sub(1, cut - length)
      line[#line + 1] = kept
      length = length + #kept
    end
  end
  while true do
    local bytes = next_chunk()
    if bytes == "" then break end
    local at = 1
    while true do
      local newline = bytes:find("\n", at, true)
      if newline == nil then
        add(bytes:sub(at))
        break
      end
      add(bytes:sub(at, newline - 1))
      local whole = table.concat(line)
      line, length = {}, 0
      if each(whole) then return end
      at = newline + 1
    end
  end
  if length > 0 then each(table.concat(line)) end
end

--- The summary's first lines, before the run.
function Fuzz.header(seed: string, iters: string): string
  return "FUZZ_SEED=" .. seed .. " FUZZ_ITERS=" .. iters .. "\n\n" ..
    "A failure's report names the FUZZ_CASE that checks its input again," ..
    " and its iteration under this seed.\n"
end

--- What a failed run's summary adds, from its output, read a chunk at a
--- time from `next_chunk` until it answers "": every failing test's
--- line first, then the reports beneath them, bounded.
function Fuzz.failure(next_chunk: function(): string, seed: string): string
  local failing: {string} = {}
  local reports: {string} = {}
  each_line(next_chunk, function(line: string): boolean
    if line:sub(1, 10) == "test: FAIL" and #failing < failing_lines then
      failing[#failing + 1] = line
    end
    if line:sub(1, 6) ~= "build:" and line:sub(1, 6) ~= "test: " and
        #reports < report_lines then
      reports[#reports + 1] = line
    end
    return #failing == failing_lines and #reports == report_lines
  end)
  return "\nThe shrunk inputs are the run's fuzz-inputs-" .. seed ..
    " artifact; once fixed, keep each in testdata/fuzz/<property>/ as its" ..
    " report says.\n\n~~~~\n" .. joined(failing, failing_lines) .. "\n" ..
    joined(reports, report_lines) .. "~~~~\n"
end

--- The chunks of the file `path` holds, as `Fuzz.failure` reads them,
--- until the end, and a function that closes it.
local type Next = function(): string
local type Close = function()
local function chunks(path: string): Next, Close
  local fd = assert(Fs.open_read(path))
  return function(): string
    return (assert(Fs.take(fd, chunk)))
  end, function()
    assert(Fs.close(fd))
  end
end

--- The last `tail_lines` lines of the file at `path`, as `tail -n` and
--- `cut` answer them, or nil when there is no such file. It reads the
--- file backwards from its end only as far as those lines begin, and
--- then only each one's first `cut` bytes.
function Fuzz.tail(path: string): {string} | nil
  local fd = Fs.open_read(path)
  if fd == nil then return nil end
  local called, answer = pcall(function(): {string}
    local size = assert(Fs.stat(path)).size
    if size == 0 then return {} end
    local function at(offset: integer, count: integer): string
      return (assert(sys.pread(fd, count, offset)))
    end
    -- Each line as its start and end offsets, the newline after it
    -- excluded, the last line first.
    local stop = size
    if at(size - 1, 1) == "\n" then stop = size - 1 end
    local spans: {{integer}} = {}
    local block_end = stop
    while #spans < tail_lines do
      if block_end == 0 then
        spans[#spans + 1] = { 0, stop }
        break
      end
      local block_start = math.max(0, block_end - chunk)
      local block = at(block_start, block_end - block_start)
      local limit = #block
      while #spans < tail_lines do
        local newline = block:sub(1, limit):match("^.*()\n") as integer
        if newline == nil then break end
        spans[#spans + 1] = { block_start + newline, stop }
        stop = block_start + newline - 1
        limit = newline - 1
      end
      block_end = block_start
    end
    local tail: {string} = {}
    for i = #spans, 1, -1 do
      local first, last = spans[i][1], spans[i][2]
      tail[#tail + 1] = last > first and at(first, math.min(cut, last - first)) or ""
    end
    return tail
  end)
  local closed, trouble = Fs.close(fd)
  if not called then error(answer) end
  assert(closed, trouble)
  return answer as {string}
end

--- What a cancelled run's summary says: the end of the output the run
--- kept, as `Fuzz.tail` answers it, or none when it kept none.
function Fuzz.cancelled_summary(tail: {string} | nil): string
  return "\nCancelled, at the time limit or by hand, before fuzzing finished:" ..
    " a property\nthat hangs is the likeliest cause. The end of its output:\n\n" ..
    "~~~~\n" .. joined(tail or {}, tail_lines) .. "~~~~\n"
end

--- Runs `argv` with both its streams written to `out`, copying what it
--- writes there to `log` as it goes, and answers its status as a shell
--- would: its exit code, 128 and the signal that ended it, or, when it
--- could not start, 127 for an executable that is not there and 126 for
--- one that is. A SIGINT or SIGTERM this process gets meanwhile is
--- passed on to the child, and caught until `guard` closes. Each round
--- copies at most `round_chunks` chunks before it looks for a signal
--- and the child's exit again, so a child that writes faster than the
--- copy keeps up cannot hold a signal back; it sleeps only once the
--- copy has caught up, and copies the rest once the child has exited.
-- TODO: copy the child's output from a pipe as it arrives, rather than
-- polling the file it writes every `poll_ns`, once ci/cosmic-driver.pin
-- names a cosmic that carries one a caller can read from (cosmic.child's
-- "capture" only answers at exit, and cosmic.fs has no pipe).
local function streamed(guard: Child.Guard, argv: {string}, cwd: string,
    env: {string:string}, out: string, log: integer): integer
  local out_fd = assert(Fs.open_write(out))
  local tail_fd, trouble = Fs.open_read(out)
  if tail_fd == nil then
    Fs.close(out_fd)
    error(trouble)
  end
  --- Copies up to `rounds` chunks, or all of it when nil, and answers
  --- whether it reached the end of what has been written.
  local function copy(rounds?: integer): boolean
    local copied = 0
    while rounds == nil or copied < rounds do
      local bytes = assert(Fs.take(tail_fd, chunk))
      if bytes == "" then return true end
      assert(Fs.put(log, bytes))
      copied = copied + 1
    end
    return false
  end
  local called, answer = pcall(function(): integer
    local handle, start_trouble = Child.start(argv, { cwd = cwd, env = env,
      stdout = out_fd, stderr = out_fd })
    if handle == nil then
      assert(Fs.put(out_fd, argv[1] .. ": " .. start_trouble .. "\n"))
      copy()
      local there = Fs.exists(argv[1])
      return there and 126 or 127
    end
    local result: Child.Result = nil
    while result == nil do
      local caught_up = copy(round_chunks)
      local taken = guard:take()
      if taken ~= 0 then local _, _ = handle:stop(taken) end
      local state = assert(handle:try_wait())
      if state.finished then
        result = state.result
      elseif caught_up then
        Time.sleep_ns(poll_ns)
      end
    end
    copy()
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
  if status ~= 0 then
    local next_chunk, close = chunks(out)
    local called, text = pcall(Fuzz.failure, next_chunk, seed)
    close()
    if not called then error(text) end
    r.summarize(text as string)
  end
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
  local tail = Fuzz.tail(Context.required("RUNNER_TEMP") .. "/fuzz.out")
  Context.summarize(Fuzz.cancelled_summary(tail))
  return 0
end

return Fuzz
