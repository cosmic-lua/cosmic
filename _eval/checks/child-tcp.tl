--- Functional check for the child-tcp task (_eval/tasks/child-tcp.md):
--- runs the built `o/bin/echotrip` orchestrator ten times in a row,
--- asserting every run exits 0 with the identical exact stdout (the
--- S-trap: a readiness race between server bind and client connect
--- fails intermittently under repetition), exercises `echotrip serve`
--- directly as a scorer-side TCP client would, and asserts that no
--- `echotrip` process is left running afterward (the orchestrator must
--- reap its child, not orphan it).
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local net = require("cosmic.net")
local stream = require("cosmic.stream")
local time = require("cosmic.time")
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/echotrip"
local WANT_STDOUT < const > = "OK round-trip-42\n"
local RUNS < const > = 10
local PROBE < const > = "probe"
local DIAL_RETRY_TOTAL_MS < const > = 2000
local DIAL_RETRY_STEP_MS < const > = 25

--- Best-effort scan of /proc for a process whose EXECUTABLE resolves to
--- `bin_path` exactly. /proc/<pid>/exe is a symlink the kernel points
--- at the real, absolute path of whatever was exec'd, dereferenced
--- regardless of how argv[0] was spelled -- so it still catches a real
--- echotrip spawned with the brief's RELATIVE argv[0] (`o/bin/echotrip
--- serve`, cwd'd into the workspace), which a /proc/<pid>/cmdline
--- substring match on the absolute path never would (cmdline preserves
--- argv verbatim). Linux-only (this eval host is Linux, per the
--- run-dir's meta.json os field); a host where /proc cannot be opened
--- cannot be checked and is treated as "not found" rather than failing
--- the assertion on an unrelated platform gap.
--- @param bin_path string The exact binary path to look for, as invoked
--- @return boolean True if a matching process is running
local function process_running(bin_path: string): boolean
  local dir = fs.open_dir("/proc")
  if not dir then
    return false
  end
  local found = false
  local entry = dir:read()
  while entry ~= nil do
    if entry:match("^%d+$") then
      local exe = fs.readlink(fs.join("/proc", entry, "exe"))
      if exe == bin_path then
        found = true
        break
      end
    end
    entry = dir:read()
  end
  dir:close()
  return found
end

--- Dial 127.0.0.1:port with a short bounded retry, closing the gap
--- between the server printing its `PORT=<n>` readiness line and the
--- listening socket actually being ready to accept -- the same class
--- of readiness race the module doc describes for the repeated-run
--- assertion above, but on the client's connect instead of the
--- server's bind. A printed port number promises the server intends
--- to listen there, not that accept(2) is live yet: nothing guarantees
--- the process scheduler ran the bind before the pipe byte reached us.
--- Retries every step_ms up to a total_ms budget rather than a single
--- fixed sleep, so it succeeds as soon as the server is ready and only
--- spends the full budget when it never becomes ready. total_ms and
--- step_ms default to DIAL_RETRY_TOTAL_MS/DIAL_RETRY_STEP_MS and are
--- parameters only so a test can shrink the budget instead of paying
--- the full two seconds to exercise the retry-then-give-up path.
--- @param port integer The port to connect to
--- @param total_ms integer? The total retry budget in milliseconds
--- @param step_ms integer? The delay between attempts in milliseconds
--- @return net.Socket | nil The connected socket, or nil after the retry budget
--- @return string The last dial error, when nil
local function dial_with_retry(port: integer, total_ms?: integer, step_ms?: integer):
  net.Socket | nil, string
  local deadline = time.monotonic_ms() + (total_ms or DIAL_RETRY_TOTAL_MS)
  local step = step_ms or DIAL_RETRY_STEP_MS
  local last_err = "no attempt made"
  while true do
    local sock, derr = net.dial("127.0.0.1", port)
    if sock then
      return sock
    end
    last_err = tostring(derr)
    if time.monotonic_ms() >= deadline then
      return nil, last_err
    end
    local _remaining, _serr = time.sleep_ms(step)
  end
end

--- Exercise `echotrip serve` as the brief's second Acceptance fact
--- describes: spawn it backgrounded, read its first stdout line as the
--- `PORT=<n>` readiness handshake, connect a scorer-side TCP client,
--- round-trip a probe, close, and confirm the server then exits 0 on
--- its own (the brief's stop mechanism is the peer closing, not a
--- signal -- the server's echo loop runs "until the peer closes, and
--- exit 0").
--- @param acc support.Acc The accumulator
--- @param workspace string Absolute path to the task's workspace
local function check_serve_mode(acc: support.Acc, workspace: string)
  local argv: {string} = {fs.join(workspace, BIN), "serve"}
  local h, serr = child.start(argv, {cwd = workspace})
  if not h then
    support.fail(acc, "echotrip serve: failed to start: " .. tostring(serr))
    return
  end
  local next_line = stream.lines(h)
  local port_line, lerr = next_line()
  if not (port_line is string and port_line:match("^PORT=%d+$")) then
    support.fail(acc, "echotrip serve: expected first stdout line to match " ..
      "'^PORT=[0-9]+$', got " .. string.format("%q", tostring(port_line)) ..
      (lerr and (" (" .. lerr .. ")") or ""))
    local _ok, _serr = h:stop()
    local _r, _werr = h:wait(1000)
    return
  end
  local port: integer | nil = nil
  local port_str = port_line:match("^PORT=(%d+)$")
  if port_str then
    local port_num = tonumber(port_str)
    if port_num then
      port = math.tointeger(port_num)
    end
  end
  if port == nil then
    support.fail(acc, "echotrip serve: could not parse a port from " ..
      string.format("%q", port_line))
    local _ok, _serr = h:stop()
    local _r, _werr = h:wait(1000)
    return
  end

  local sock, derr = dial_with_retry(port)
  if not sock then
    support.fail(acc, "echotrip serve: scorer TCP client could not connect on port " ..
      tostring(port) .. " within " .. tostring(DIAL_RETRY_TOTAL_MS) .. "ms: " ..
      tostring(derr))
    local _ok, _serr = h:stop()
    local _r, _werr = h:wait(1000)
    return
  end
  local sok, werr = sock:send_all(PROBE .. "\n")
  if not sok then
    support.fail(acc, "echotrip serve: sending probe failed: " .. tostring(werr))
  end
  local reply, rerr = (stream.lines(sock))()
  if reply ~= PROBE then
    support.fail(acc, "echotrip serve: expected the echo " ..
      string.format("%q", PROBE) .. ", got " .. string.format("%q", tostring(reply)) ..
      (rerr and (" (" .. rerr .. ")") or ""))
  end
  local _closed, _cerr = sock:close()

  local result, wait_err = h:wait(2000)
  if not result then
    support.fail(acc, "echotrip serve: server did not exit after the client closed: " ..
      tostring(wait_err))
  elseif result.code ~= 0 then
    support.fail(acc, "echotrip serve: expected the server to exit 0, got " ..
      tostring(result.code))
  end
end

--- @param workspace string Absolute path to the task's workspace
--- @return integer The number of failed Acceptance facts
--- @return {string} What failed, one entry per count
local function check(workspace: string): integer, {string}
  local acc = support.new()
  local bin_path = fs.join(workspace, BIN)

  for i = 1, RUNS do
    local res, err = support.run(workspace, BIN, {})
    local label = "echotrip run " .. i
    if support.expect_exit(acc, label, res, err, true) then
      support.expect_stdout(acc, label, res, WANT_STDOUT)
    end
    if process_running(bin_path) then
      support.fail(acc, label .. ": an echotrip process is still running (orphaned child)")
    end
  end

  check_serve_mode(acc, workspace)

  support.expect_test_file_present(acc, workspace)

  return support.result(acc)
end

local record child_tcp_check
  check: function(workspace: string): integer, {string}
  dial_with_retry: function(port: integer, total_ms?: integer, step_ms?: integer):
  net.Socket | nil, string
end

local M: child_tcp_check = {
  check = check,
  dial_with_retry = dial_with_retry,
}

return M
