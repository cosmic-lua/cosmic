--- Functional check for the child-tcp task (_eval/tasks/child-tcp.md):
--- runs the built `o/bin/echotrip` orchestrator ten times in a row,
--- asserting every run exits 0 with the identical exact stdout (the
--- S-trap: a readiness race between server bind and client connect
--- fails intermittently under repetition), and asserts that no
--- `echotrip` process is left running afterward (the orchestrator must
--- reap its child, not orphan it).
---
--- Does NOT exercise `echotrip serve` directly as a scorer-side TCP
--- client -- that acceptance fact was judged not worth the fixture
--- complexity a live round-trip requires (see the issue for the
--- reasoning); the ten-run repetition above is what catches the
--- brief's actual S-trap.
local fs = require("cosmic.fs")
local support = require("_eval.checks.support")

local BIN < const > = "o/bin/echotrip"
local WANT_STDOUT < const > = "OK round-trip-42\n"
local RUNS < const > = 10

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
