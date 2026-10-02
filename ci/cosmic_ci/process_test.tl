local Fixture = require("cosmic_ci.fixture")
local Process = require("cosmic_ci.process")

local function test_await_ready_reads_the_childs_readiness(tmp: string)
  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)
  local ready = Process.fifo(tmp, diagnostics, "ready")
  Process.supervised(function(active: {Process.Running})
    local child = Process.start("paused", { "/bin/sh", "-c",
      "printf 'ready\\n' > \"$1\"", "sh", ready }, tmp,
      Fixture.environment(), diagnostics)
    active[#active + 1] = child
    Process.await_ready(tmp, diagnostics, "paused", ready, child)
    assert(Process.finish(child).ok)
  end)
end

-- A child that exits without writing its readiness fails the wait
-- then, naming the exit, rather than once the bound has passed.
local function test_await_ready_fails_when_the_child_exits_first(tmp: string)
  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)
  local ready = Process.fifo(tmp, diagnostics, "ready")
  local called, failure = pcall(function(): boolean
    Process.supervised(function(active: {Process.Running})
      local child = Process.start("early", { "/bin/sh", "-c", "exit 7" }, tmp,
        Fixture.environment(), diagnostics)
      active[#active + 1] = child
      Process.await_ready(tmp, diagnostics, "early", ready, child)
    end)
    return true
  end)
  local why = tostring(failure)
  assert(not called and why:find("early exited before it was ready (code=7", 1, true),
    why)
end
