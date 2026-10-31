local BuildPaths = require("cosmic_ci.build_paths")
-- fuzz.yml's run: every property fuzzed on the checked core, from the
-- checkout's root, its log streamed as it runs and kept for the run's
-- summary, which says what failed; and, for a run cancelled before it
-- finished, how far it got. FUZZ_SEED and FUZZ_ITERS come from the job.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Context = require("cosmic_ci.context")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Seams = require("cosmic_ci.seams")
local State = require("cosmic_ci.state")
local Signal = require("cosmic.signal")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local String = require("cosmic.string")

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

  --- What a run's output says of how it went, besides its end.
  record Scanned
    --- The last progress line `cosmic test` said, which names the failures
    --- so far and the tests that have run longest (build/test.tl's
    --- `running_detail`), or nil when it said none.
    mut progress?: string
    --- Every line that ended a slow test ("slow: <test> took <time>"),
    --- without its "test: ", the first `slow_lines`.
    mut slow: mut {string}
  end
end

--- The checked core, relative to the checkout's root: `bin/zig build
--- sanitized` builds it.
local executable <const> = "/sanitized/bin/cosmic"
--- Top-level trees the search leaves out: build output, vendored
--- sources, and the CI driver's own project.
local pruned <const>: {string:boolean} = { o = true, vendor = true, ci = true }
local suffix <const> = "_fuzz_test.tl"
local cut <const> = 300
local failing_lines <const> = 30
local report_lines <const> = 60
local tail_lines <const> = 40
local chunk <const> = 65536
--- Seconds a property may spend drawing inputs (build/fuzz/init.tl's
--- `FUZZ_SECONDS`), unless the job's environment says another number. A
--- property whose inputs cost 0.1 s to 0.5 s on the checked core (the
--- checker's, the relation's, the R*Tree's) would otherwise spend hours
--- on FUZZ_ITERS=10000, past the 1200 seconds a test may run and the
--- hour the job may: the first 64 inputs and as many more as fit are
--- drawn, and the run says how many.
local property_seconds <const> = "120"
local poll_ns <const> = 100 * 1000 * 1000
--- One drain yields to signal/status supervision after this many bytes.
local drain_bytes <const> = 4 * chunk
--- An escaped descendant cannot keep the completed fuzz run draining forever.
local final_output_ns <const> = 5 * 1000 * 1000 * 1000

--- Every `*_fuzz_test.tl` under `root`, outside its top-level o/,
--- vendor/ and ci/, as `./`-relative paths in byte order.
function Fuzz.discover(root: string): {string}
  local found = assert(Fs.walk(root, function(entry: string, _name: string, _kind: sys.Kind): boolean
    return pruned[entry] == true
  end))
  local tests: mut {string} = {}
  for _, entry in ipairs(found) do
    local name = Fs.basename(entry)
    if String.ends_with(name, suffix) then
      tests[#tests + 1] = "./" .. entry
    end
  end
  table.sort(tests)
  return tests
end

--- Up to `limit` of `from`, a line each.
local function joined(from: {string}, limit: integer): string
  local out: mut {string} = {}
  for i, line in ipairs(from) do
    if i > limit then break end
    out[#out + 1] = line .. "\n"
  end
  return table.concat(out)
end

--- How many bytes of the line being read [`each_line`] has kept.
local record Taken
  mut length: integer
end

--- Calls `each` with every line `next_chunk` answers, as grep reads them
--- (a last line without a newline is a line too), each cut to
--- bytes (`limit`, `cut` by default) so that a line of any length takes
--- no more than that. Stops when `next_chunk` answers "" or `each`
--- answers true.
local function each_line(next_chunk: function(): string,
                         each: function(string): boolean, limit?: integer)
  local line: mut {string} = {}
  local taken: Taken = { length = 0 }
  local longest = limit or cut
  local function add(piece: string)
    if taken.length < longest and #piece > 0 then
      local kept = piece:sub(1, longest - taken.length)
      line[#line + 1] = kept
      taken.length = taken.length + #kept
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
      line, taken.length = {}, 0
      if each(whole) then return end
      at = newline + 1
    end
  end
  if taken.length > 0 then each(table.concat(line)) end
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
  local failing: mut {string} = {}
  local reports: mut {string} = {}
  each_line(next_chunk, function(line: string): boolean
    if (line:sub(1, 10) == "test: FAIL" or line:match("^test: %d+ of %d+ tests? failed, ") ~= nil) and
        #failing < failing_lines then
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

--- The chunks of the file `path` holds, as [`Fuzz.failure`] reads them,
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

--- A byte range of a file: where a line starts and where it ends, its newline excluded.
local record Span
  first: integer
  last: integer
end

--- The lines [`Fuzz.tail`] has read, kept where the function that reads them under `pcall` can add to them.
local record Tailed
  lines: mut {string}
end

--- The last `tail_lines` lines of the file at `path`, as `tail -n` and
--- `cut` answer them, or nil when there is no such file. It reads the
--- file backwards from its end only as far as those lines begin, and
--- then only each one's first `cut` bytes.
function Fuzz.tail(path: string): {string}?
  local opened, _ = Fs.open_read(path)
  if opened == nil then return nil end
  local fd: integer = opened
  local tailed: Tailed = { lines = {} }
  local called, raised = pcall(function()
    local size = assert(Fs.stat(path)).size
    if size == 0 then return end
    local function at(offset: integer, count: integer): string
      return (assert(sys.pread(fd, count, offset)))
    end
    -- Each line as its start and end offsets, the newline after it
    -- excluded, the last line first.
    local stop = size
    if at(size - 1, 1) == "\n" then stop = size - 1 end
    local spans: mut {Span} = {}
    local block_end = stop
    while #spans < tail_lines do
      if block_end == 0 then
        spans[#spans + 1] = { first = 0, last = stop }
        break
      end
      local block_start = math.max(0, block_end - chunk)
      local block = at(block_start, block_end - block_start)
      local limit = #block
      while #spans < tail_lines do
        local newline = math.tointeger(tonumber(block:sub(1, limit):match("^.*()\n")))
        if newline == nil then break end
        spans[#spans + 1] = { first = block_start + newline, last = stop }
        stop = block_start + newline - 1
        limit = newline - 1
      end
      block_end = block_start
    end
    for i = #spans, 1, -1 do
      local span = spans[i]
      if span ~= nil then
        local line = ""
        if span.last > span.first then
          line = at(span.first, math.min(cut, span.last - span.first))
        end
        tailed.lines[#tailed.lines + 1] = line
      end
    end
  end)
  local closed, trouble = Fs.close(fd)
  if not called then error(raised) end
  assert(closed, trouble)
  return tailed.lines
end

--- A progress line, and the line that ends a test that ran slow
--- (build/test.tl's `slow_ns`), as `cosmic test` says them.
local progress_prefix <const> = "test: running "
local slow_prefix <const> = "test: slow: "
local slow_lines <const> = 60
--- The longest a progress line is read: it names three tests by their ids.
local progress_cut <const> = 1000

--- The last progress line and the slow tests' lines of the output that
--- `next_chunk` answers a chunk at a time until it answers "".
function Fuzz.scan(next_chunk: function(): string): Fuzz.Scanned
  local scanned: Fuzz.Scanned = { slow = {} }
  each_line(next_chunk, function(line: string): boolean
    if line:sub(1, #slow_prefix) == slow_prefix then
      if #scanned.slow < slow_lines then
        local said = line:sub(#"test: " + 1)
        scanned.slow[#scanned.slow + 1] = said
      end
    elseif line:sub(1, #progress_prefix) == progress_prefix and line:match("^test: running %d+/%d+ tests, ") ~= nil then
      scanned.progress = line
    end
    return false
  end, progress_cut)
  return scanned
end

--- What a summary adds for the tests that ran long, or nothing when none did.
function Fuzz.slow_summary(scanned: Fuzz.Scanned): string
  if #scanned.slow == 0 then return "" end
  return "\nTests that ran five minutes or more, each said as it ended:\n\n~~~~\n" ..
    joined(scanned.slow, slow_lines) .. "~~~~\n"
end

--- What a cancelled run's summary says: how far it got, as [`Fuzz.scan`]
--- found it (the tests still running when it last said, longest first, and
--- those that ran long), and the end of the output the run kept, as
--- [`Fuzz.tail`] answers it, or none when it kept none.
function Fuzz.cancelled_summary(tail: {string}?, scanned?: Fuzz.Scanned): string
  local out = "\nCancelled, at the time limit or by hand, before fuzzing finished:" ..
    " a property\nthat hangs is the likeliest cause.\n"
  local found = scanned or { slow = {} }
  local progress = found.progress
  if progress ~= nil then
    out = out .. "\nThe last progress line, which names the tests still running," ..
      " the longest first:\n\n~~~~\n" .. progress .. "\n~~~~\n"
  end
  return out .. Fuzz.slow_summary(found) ..
    "\nThe end of its output:\n\n~~~~\n" .. joined(tail or {}, tail_lines) .. "~~~~\n"
end

--- What [`streamed`] learns of the run, kept where the functions that run it under `pcall` can set it.
local record Streamed
  --- The child's exit status, once it is known.
  mut status?: integer
  --- Why the output is not whole, "" when it is.
  mut trouble: string
end

--- Keeps merged output in `out` and offers it to `log` as it arrives.
--- Each bounded drain yields to signal and exit supervision. After exit,
--- one deadline bounds inherited writers; an incomplete drain is a driver
--- failure, while any known child status remains available to be saved.
local function streamed(guard: Signal.Guard, argv: {string}, cwd: string,
                        env: {string:string}, out: string, log: integer): Streamed
  local program = assert(argv[1], "no program to run")
  local seams = Seams.calls()
  local out_fd = assert(seams.fs_open_write(out))
  local kept: Streamed = { trouble = "" }
  local called, failure = pcall(function()
    local sink = seams.stream_tee(Stream.to_fd(out_fd), Stream.to_fd(log))
    local started, start_trouble = seams.child_start(argv, { cwd = cwd, env = env,
      stdout = "stream", stderr = "stdout" })
    if started == nil then
      local there, _ = seams.fs_exists(program)
      if there == true then kept.status = 126 else kept.status = 127 end
      local wrote, why = sink:write(program .. ": " .. start_trouble .. "\n")
      if not wrote then kept.trouble = why end
      return
    end
    -- TODO: hold the child in a `<close>` local again, once ci/cosmic-driver.pin names a release that declares
    -- [`Child.Handle`] as a class: a `<close>` local must be one.
    local handle = started
    local function supervise(): string
      local deadline: integer? = nil
      local eof = false
      while true do
        local signal = guard:take()
        if signal ~= 0 then local _, _ = handle.stop(signal) end
        local waiting, why = handle.try_wait()
        if waiting == nil then return why end
        if waiting.finished and kept.status == nil then
          kept.status = Child.shell_status(assert(waiting.result))
          deadline = Clock.monotonic_ns() + final_output_ns
        end
        if eof then
          if kept.status ~= nil then return "" end
          local _, _ = Clock.sleep_ns(poll_ns)
        else
          local wait = poll_ns
          if deadline ~= nil then
            wait = math.min(wait, math.max(0, deadline - Clock.monotonic_ns()))
            if wait == 0 then return "fuzz output remained open after the child exited" end
          end
          local drained = handle.drain{ stdout = sink, stderr = nil, timeout_ns = wait, max_bytes = drain_bytes }
          if drained.kind == "failed" then return drained.reason end
          eof = drained.kind == "eof"
          -- limit, timeout and interrupted all resume supervision. A failed
          -- sink may have saved more than it logged; its chunk is never replayed.
        end
      end
    end
    local ran, reason = pcall(supervise)
    if not ran then
      kept.trouble = tostring(reason)
    elseif reason is string then
      kept.trouble = reason
    end
    -- drain may have observed exit before a sink failed or raised. Keep
    -- that actual status before scoped cleanup ends any remaining child.
    if kept.status == nil then
      local _, _ = pcall(function()
        local waiting, _ = handle.try_wait()
        if waiting ~= nil and waiting.finished then
          kept.status = Child.shell_status(assert(waiting.result))
        end
      end)
    end
    local _, _ = handle.close()
  end)
  local closed, close_trouble = Fs.close(out_fd)
  if not called then return { status = kept.status, trouble = tostring(failure) } end
  if kept.trouble ~= "" then return kept end
  if not closed then return { status = kept.status, trouble = close_trouble } end
  return { status = kept.status, trouble = "" }
end

--- A failed run's summary, kept where the function that makes it under `pcall` can set it.
local record Failed
  mut text: string
end

--- Fuzzes every property `r.root` holds on its checked core, writing
--- the output to `$temp/fuzz.out` and the status to `$temp/fuzz.status`,
--- and answers the status.
function Fuzz.execute(r: Fuzz.Run): integer
  local seed, iters = r.env["FUZZ_SEED"] or "", r.env["FUZZ_ITERS"] or ""
  r.summarize(Fuzz.header(seed, iters))
  -- A failing test's directory is left under TMPDIR, holding the
  -- shrunk input it kept (build/test.tl's sweep).
  local scratch = r.temp .. "/fuzz"
  assert(Fs.mkdirs(scratch))
  local env: mut {string:string} = {}
  for name, value in pairs(r.env) do env[name] = value end
  env["TMPDIR"] = scratch
  env["COSMIC_AUTO_BOOT"] = "0"
  env["COSMIC_TEST_TIMEOUT"] = "1200"
  env["FUZZ_SECONDS"] = r.env["FUZZ_SECONDS"] or property_seconds
  local argv: mut {string} = { BuildPaths.directory(r.root, env) .. executable, "test", "--all" }
  for _, test in ipairs(Fuzz.discover(r.root)) do argv[#argv + 1] = test end
  local out = r.temp .. "/fuzz.out"
  -- Streamed to the log as it runs, and kept for the summary: a run
  -- cancelled at its time limit still shows how far it got. A signal
  -- caught meanwhile is delivered again once the status is kept.
  -- TODO: hold the guard in a `<close>` local again, once ci/cosmic-driver.pin names a release that declares
  -- [`Signal.Guard`] as a class: a `<close>` local must be one.
  local guard = assert(Signal.guard())
  local kept: Streamed = { trouble = "" }
  local ran, raised = pcall(function()
    local answered = streamed(guard, argv, r.root, env, out, r.log)
    kept.status, kept.trouble = answered.status, answered.trouble
    local reached = kept.status
    if reached ~= nil then
      assert(Fs.write(r.temp .. "/fuzz.status", tostring(reached) .. "\n"))
    end
    assert(kept.trouble == "", kept.trouble)
    assert(reached ~= nil, "fuzz child ended without a status")
  end)
  local _, _ = guard:close()
  if not ran then error(raised, 0) end
  local status = assert(kept.status)
  local slow_next, slow_close = chunks(out)
  local scanned: Fuzz.Scanned = { slow = {} }
  local read, raised_scan = pcall(function()
    scanned = Fuzz.scan(slow_next)
  end)
  slow_close()
  if not read then error(raised_scan) end
  local slow = Fuzz.slow_summary(scanned)
  if slow ~= "" then r.summarize(slow) end
  if status ~= 0 then
    local next_chunk, close = chunks(out)
    local failed: Failed = { text = "" }
    local called, raised_failure = pcall(function()
      failed.text = Fuzz.failure(next_chunk, seed)
    end)
    close()
    if not called then error(raised_failure) end
    r.summarize(failed.text)
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
--- cancelled run got, from the output `fuzz` kept, if it kept any. The
--- job's log holds the same text, since the summary is a page of its own.
function Fuzz.cancelled(_argv: {string}): integer
  local out = Context.required("RUNNER_TEMP") .. "/fuzz.out"
  local tail = Fuzz.tail(out)
  local scanned: Fuzz.Scanned = { slow = {} }
  if tail ~= nil then
    local next_chunk, close = chunks(out)
    local read, raised = pcall(function()
      scanned = Fuzz.scan(next_chunk)
    end)
    close()
    if not read then error(raised) end
  end
  local text = Fuzz.cancelled_summary(tail, scanned)
  Context.summarize(text)
  local page = Env.get_or("GITHUB_STEP_SUMMARY", "")
  if page ~= "" then
    assert(Fs.put(Fs.stdout, text))
  end
  return 0
end

return Fuzz
