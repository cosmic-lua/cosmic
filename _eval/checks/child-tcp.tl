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
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/echotrip"
local WANT_STDOUT < const > = "OK round-trip-42\n"
local RUNS < const > = 10
local PROBE < const > = "probe"

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

  local sock, derr = net.dial("127.0.0.1", port)
  if not sock then
    support.fail(acc, "echotrip serve: scorer TCP client could not connect on port " ..
      tostring(port) .. ": " .. tostring(derr))
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
end

local M: child_tcp_check = {
  check = check,
}

return M
