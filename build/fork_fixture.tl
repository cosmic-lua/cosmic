--- What the tests of the raw process table's `fork` share
--- (core/fork_test.tl, core/fork_scoped_test.tl, core/fork_darwin_test.tl).
--- Test support.

local process = require("cosmic.internal.process")

local record fork_fixture
end

--- Reaps `pid` and returns its exit status, -1 for one a signal ended.
function fork_fixture.status_of(pid: integer): integer
  local status, why = process.waitpid(pid, false)
  assert(status ~= nil, why)
  assert(status.pid == pid, "the wait reaped another process")
  return status.code
end

return fork_fixture
