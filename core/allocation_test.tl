--- The paths a C binding takes when an allocation fails, walked the way
--- Lua's own test suite walks them: run the same work with the first
--- allocation refused, then the second, and so on, until it runs with
--- every allocation granted. Each refusal raises "not enough memory"
--- from wherever Lua asked, and each must leave nothing behind -- no
--- descriptor, no statement -- and nothing freed that is still in use.
---
--- "Nothing behind" is checked after a collection: when memory is so
--- short that Lua cannot even call a guard's close, the guard's __gc is
--- what releases it (core/guard.h), and a refusal walk reaches exactly
--- such points. Each run is followed by one, with allocations granted
--- again: a finalizer left pending would otherwise be run by a step of
--- the collector during the next run's refusals, fail to be called, and
--- never be called again.
---
--- Only the checked core can refuse an allocation (core/testing.h), and
--- CI runs this suite on it; any other core has no instrument to
--- refuse one with, which these tests say rather than pass unseen.

local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local testing = require("cosmic.internal.testing")

local checked = testing.configuration == "sanitized"

--- Runs `work` once per allocation it makes, refusing that allocation,
--- and a last time with none refused; answers how many runs a refusal
--- ended. A run that nothing was refused in must succeed.
---
--- `settle`, when given, runs after each run with allocations granted
--- again, to release what the run was handed. The work cannot release it
--- itself: a worker's coverage hook runs Lua between any two lines, and
--- can itself be refused, so a refusal can fall between a binding's
--- return and the line that would have released what it returned.
local function under_every_failure(work: function(), settle?: function()): integer
  local ended = 0
  for after = 0, 1000000 do
    testing.fail_allocations(after)
    local ok, failure = pcall(work as function(): any)
    local refused = testing.allow_allocations()
    if settle ~= nil then settle() end
    collectgarbage("collect")
    if refused == 0 then
      assert(ok, "the work failed with every allocation granted: " .. tostring(failure))
      return ended
    end
    ended = ended + 1
  end
  error("the work never ran with every allocation granted")
end

--- The descriptor the next open is handed: the lowest free one, so an
--- earlier one left open shows as a higher number.
local function next_descriptor(tmp: string): integer
  local fd = assert(sys.open(tmp .. "/probe", sys.O_CREAT | sys.O_RDWR, 420))
  sys.close(fd)
  return fd
end

--- Every core says what it is, and only the checked one carries the
--- instruments: no core that ships has an allocator a program can make
--- fail.
local function test_only_the_checked_core_carries_the_instruments()
  assert(type(testing.configuration) == "string" and testing.configuration ~= "")
  local instruments = testing as {string: any}
  for _, name in ipairs({ "fail_allocations", "allow_allocations", "open_statements" }) do
    assert((instruments[name] ~= nil) == checked,
      name .. " must be present exactly on the checked core, not on " ..
      testing.configuration)
  end
end

local function test_a_refused_allocation_raises_and_is_counted()
  if not checked then return end
  -- Made before refusal starts: the closure is itself an allocation,
  -- and nothing after a refusal outside pcall could even report.
  local allocate = function(): {string} return { string.rep("x", 100) } end
  testing.fail_allocations(0)
  local ok = pcall(allocate)
  local refused = testing.allow_allocations()
  assert(not ok, "a refused allocation must raise")
  assert(refused >= 1, "the refusal must be counted")
  assert(testing.allow_allocations() == 0, "the count starts over")
end

local function test_readdir_releases_its_directory_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  assert(sys.mkdir(tmp .. "/d"))
  for i = 1, 40 do
    sys.close((assert(sys.open(tmp .. "/d/entry-" .. i, sys.O_CREAT | sys.O_WRONLY, 420))))
  end
  local before = next_descriptor(tmp)
  local ended = under_every_failure(function()
    assert(sys.readdir(tmp .. "/d"))
  end)
  assert(ended > 0, "listing forty entries allocates")
  collectgarbage("collect")
  local after = next_descriptor(tmp)
  assert(after == before, "a refused allocation left descriptor " .. before .. " open")
end

local function test_the_store_finalizes_its_statement_whenever_an_allocation_fails()
  if not checked then return end
  local before = testing.open_statements()
  local ended = under_every_failure(function()
    assert(Store.bytecode("cosmic.fs"))
  end)
  ended = ended + under_every_failure(function()
    Store.meta("compiler")
  end)
  assert(ended > 0, "copying a module's bytes out allocates")
  collectgarbage("collect")
  assert(testing.open_statements() == before,
    "a refused allocation left " .. (testing.open_statements() - before) ..
    " statements open")
end

--- print builds its line in a buffer that moves to the heap past 1 KB;
--- a refusal at any point of that must raise, never free the buffer out
--- from under itself.
local function test_print_survives_every_refused_allocation()
  if not checked then return end
  local long = string.rep(".", 1100)
  local ended = under_every_failure(function()
    print("allocation_test: a long print under refusal ->", long, 42)
  end)
  assert(ended > 0, "a line past the inline buffer allocates")
end

--- open_temporary builds its answer with the descriptor already open; a
--- refusal while it does must close it, not leave it to the process.
local function test_open_temporary_closes_its_descriptor_whenever_an_allocation_fails(tmp: string)
  if not checked then return end
  local path = tmp .. "/t"
  local before = next_descriptor(tmp)
  -- Taken on the line that makes the call, so no hook runs between the
  -- binding's return and the test holding what it returned.
  local received: sys.TemporaryFile
  local opened = 0
  local ended = under_every_failure(function()
    received = sys.open_temporary(path, 420)
  end, function()
    if received ~= nil then
      sys.close(received.fd)
      received = nil
      opened = opened + 1
    end
  end)
  assert(ended > 0, "building the answer allocates")
  assert(opened >= 1, "the run with nothing refused opens a file")
  collectgarbage("collect")
  local after = next_descriptor(tmp)
  assert(after == before, "a refused allocation left descriptor " .. before .. " open")
end

--- execve holds its argv and environment arrays while it fills them from
--- the tables; a refusal at any point of that, and a failed execve after
--- it, must come back through the guards that free them.
local function test_execve_survives_every_refused_allocation(tmp: string)
  if not checked then return end
  local missing = tmp .. "/no-such-program"
  local ended = under_every_failure(function()
    local ok, trouble = sys.execve(missing, { missing, "an argument" }, { NAME = "value" })
    assert(ok == nil and trouble ~= nil, "a program that is not there cannot run")
  end)
  assert(ended > 0, "joining the environment allocates")
end
