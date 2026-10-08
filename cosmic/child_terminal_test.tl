local Child = require("cosmic.child")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" } }

--- A pty's streams are named by number, each once and at least one, and
--- one the pty takes names no descriptor of the caller's.
local function test_start_on_pty_refuses_what_could_name_a_terminal_of_the_callers()
  local function raises(opts: Child.Options, streams: {integer}, why: string)
    local ok, trouble = pcall(Child.start_on_pty, { "/bin/true" }, opts, { streams = streams })
    assert(not ok and tostring(trouble):find(why, 1, true), tostring(trouble))
  end
  raises({ stdin = "null" }, { 0 }, "takes no stdin")
  raises({ input = "x" }, { 0 }, "takes no stdin")
  raises({ stdout = "null" }, { 1 }, "takes no stdin")
  raises({ stderr = "null" }, { 2 }, "takes no stdin")
  raises({}, {}, "at least one stream")
  raises({}, { 0, 0 }, "each of 0, 1 and 2 once")
  raises({}, { 3 }, "each of 0, 1 and 2 once")
end

--- The lowest free descriptor, which moves when a refused start leaves one
--- open.
local function lowest_free(): integer
  local fd = assert(sys.open("/dev/null", sys.O_RDONLY))
  assert(sys.close(fd))
  return fd
end

--- A size is both dimensions in 0..65535 or neither, and a bad one raises
--- before a descriptor is opened.
local function test_start_on_pty_validates_the_size_before_opening_a_pty()
  local before = lowest_free()
  local function raises(size: {string:any}, why: string)
    for _ = 1, 4 do
      local ok, trouble = pcall(Child.start_on_pty, { "/bin/true" }, {},
        { streams = { 1 }, rows = size.rows as integer, columns = size.columns as integer })
      assert(not ok and tostring(trouble):find(why, 1, true), tostring(trouble))
    end
  end
  raises({ rows = -1, columns = 80 }, "0..65535")
  raises({ rows = 24, columns = 65536 }, "0..65535")
  raises({ rows = 1.5, columns = 80 }, "0..65535")
  raises({ rows = 24 }, "given together")
  raises({ columns = 80 }, "given together")
  assert(lowest_free() == before)
end

--- A requested size is applied to the master the caller is given.
local function test_start_on_pty_applies_the_size()
  local probe, _ = sys.openpty()
  if probe == nil then Test.skip("this worker has no pty devices to open") end
  assert(probe)
  assert(sys.close(probe.slave))
  assert(sys.close(probe.master))
  local program = this_program.program({ "-e", "" }, {})
  local started = assert(Child.start_on_pty(program.argv, program.options, { streams = { 1 }, rows = 7, columns = 33 }))
  local size = assert(sys.winsize(started.master))
  assert(size.rows == 7 and size.columns == 33)
  assert(sys.close(started.master))
  started.child:wait()
end
