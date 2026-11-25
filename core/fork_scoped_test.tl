--- A scoped `fork` of the raw process table (core/process.h), which is
--- Linux's: the copy is held to signalling itself by a Landlock ruleset.
--- The module requires Linux; macOS's refusal of a scoped fork is
--- core/fork_darwin_test.tl's.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local process = require("cosmic.internal.process")
local status_of = require("build.fork_fixture").status_of

Test.policy{ requires = { "os:linux" } }

--- A scoped child can signal itself and not its parent; an unscoped one can
--- signal its parent. Signal 0 asks only whether the signal may be sent.
local function test_a_scoped_fork_cannot_signal_its_parent()
  local abi, abi_why = process.landlock_abi()
  if abi == nil then
    Test.skip("no Landlock here: " .. abi_why)
    return
  end
  if abi < 6 then
    local refused, _, number = process.fork(true)
    if refused == 0 then sys.exit(0) end
    assert(refused == nil and number == sys.EOPNOTSUPP, "a scoped fork is refused below Landlock ABI 6")
    Test.skip("Landlock ABI " .. tostring(abi) .. " scopes no signal")
  end
  local parent = sys.getpid()
  -- Each child exits 0 where what it may signal is as its fork says, else with the step that was not.
  local function probe(scoped: boolean): integer
    local pid, why = process.fork(scoped)
    if pid == 0 then
      local own, _ = sys.kill(sys.getpid(), 0)
      if not own then sys.exit(2) end
      local reached, _, number = sys.kill(parent, 0)
      if scoped then
        sys.exit(if not reached and number == sys.EPERM then 0 else 3 end)
      end
      sys.exit(if reached then 0 else 4 end)
    end
    assert(pid ~= nil, why)
    return status_of(pid)
  end
  local unscoped = probe(false)
  if unscoped == 4 then
    Test.skip("this worker's filter holds a signal to its own pid, so no child signals its parent")
  end
  assert(unscoped == 0, "an unscoped child's status: " .. tostring(unscoped))
  local scoped = probe(true)
  assert(scoped == 0, "a scoped child's status: " .. tostring(scoped))
end

--- A scoped child moves a file from one directory to another, as its parent may: the ruleset that scopes its
--- signals refuses no move.
local function test_a_scoped_fork_moves_a_file_between_directories(tmp: string)
  local abi, abi_why = process.landlock_abi()
  if abi == nil then
    Test.skip("no Landlock here: " .. abi_why)
    return
  end
  if abi < 6 then Test.skip("Landlock ABI " .. tostring(abi) .. " scopes no signal") end
  assert(sys.mkdir(tmp .. "/from", 0x1c0))
  assert(sys.mkdir(tmp .. "/to", 0x1c0))
  local made = assert(sys.open(tmp .. "/from/file", sys.O_WRONLY | sys.O_CREAT, 0x180))
  assert(sys.close(made))
  local pid, why = process.fork(true)
  if pid == 0 then
    local moved, _, number = sys.rename(tmp .. "/from/file", tmp .. "/to/file")
    sys.exit(if moved then 0 elseif number == sys.EXDEV then 3 else 4 end)
  end
  assert(pid ~= nil, why)
  local status = status_of(pid)
  assert(status == 0, "a scoped child's move, 3 for one refused as between devices: " .. tostring(status))
  assert(sys.lstat(tmp .. "/to/file") ~= nil, "the file is where the child moved it")
end
