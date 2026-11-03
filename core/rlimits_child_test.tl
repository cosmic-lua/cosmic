--- `spawn`'s `rlimits` (core/process.h) on a live child: the limits the
--- child reads back with getrlimit, soft and hard together. The child is a
--- stand-in (build/stand_in.tl), which prints what its script says. A host
--- that refuses to set one (ENOSYS: anything but Linux) skips the test
--- (Test.skip).

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

Test.policy{}

local process = require("cosmic.internal.process")

--- What `script` printed in a stand-in started with `rlimits`, or nil and why
--- the start was refused.
local function run(tmp: string, rlimits: {string:integer}, script: string): string?, string, integer
  local program = assert(stand_in.build(tmp .. "/stand-in"))
  local path = tmp .. "/said"
  local output = assert(sys.open(path, sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, trouble, errno = process.spawn(program, { program, script }, nil, nil, nil, output,
    output, false, nil, { rlimits = rlimits })
  if pid == nil then
    sys.close(output)
    return nil, trouble, errno
  end
  local status = assert(process.waitpid(pid, false))
  sys.close(output)
  assert(status.code == 0, "the script ended " .. tostring(status.code) .. ": " .. tostring((Fs.read(path))))
  return (Fs.read(path)), "", 0
end

local function test_every_limit_is_the_childs_soft_and_hard(tmp: string)
  local said, why, errno = run(tmp, { nofile = 48, fsize = 1 << 30, cpu = 5, core = 0 },
    "rlimit nofile; rlimit fsize; rlimit cpu; rlimit core")
  if said == nil then
    assert(errno == sys.ENOSYS, why)
    if assert(sys.uname()).sysname == "Linux" then Test.skip(why) end
    return
  end
  assert(said == "nofile 48 48\nfsize 1073741824 1073741824\ncpu 5 5\ncore 0 0\n", said)
end

local function test_a_limit_not_named_is_the_one_the_child_inherits(tmp: string)
  local said, why, errno = run(tmp, { core = 0 }, "rlimit core; rlimit cpu")
  if said == nil then
    assert(errno == sys.ENOSYS, why)
    if assert(sys.uname()).sysname == "Linux" then Test.skip(why) end
    return
  end
  local own = assert(sys.getrlimit(sys.RLIMIT_CPU))
  assert(said == ("core 0 0\ncpu %d %d\n"):format(own.soft, own.hard), said)
end

local function test_math_maxinteger_is_no_limit_and_an_empty_table_names_none(tmp: string)
  local said, why, errno = run(tmp, { fsize = math.maxinteger }, "rlimit fsize")
  if said == nil then
    assert(errno == sys.ENOSYS, why)
    if assert(sys.uname()).sysname == "Linux" then Test.skip(why) end
    return
  end
  assert(said == ("fsize %d %d\n"):format(math.maxinteger, math.maxinteger), said)
  local none = assert(run(tmp, {}, "rlimit core"))
  local own = assert(sys.getrlimit(sys.RLIMIT_CORE))
  assert(none == ("core %d %d\n"):format(own.soft, own.hard), none)
end

local function test_a_limit_the_call_cannot_hold_raises(tmp: string)
  local program = assert(stand_in.build(tmp .. "/stand-in"))
  local function refuses(sandbox: any, text: string)
    local ok, why = pcall(process.spawn, program, { program, "print x" }, nil, nil, nil, nil, nil, false, nil, -- checked: overload_none
      sandbox)
    assert(not ok and tostring(why):find(text, 1, true) ~= nil, text .. ": " .. tostring(why))
  end
  refuses({ rlimits = { bogus = 1 } }, "an rlimit is")
  refuses({ rlimits = { nofile = "many" } }, "an rlimit is an integer")
  refuses({ rlimits = { nofile = 1.5 } }, "an rlimit is an integer")
  refuses({ rlimits = { fsize = -1 } }, "an rlimit is not negative")
  refuses({ rlimits = "nofile" }, "rlimits must be a table")
  refuses({ rlimits = { [1] = 4 } }, "an rlimit is")
end
