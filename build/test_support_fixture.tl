--- Small helpers the tests of the tree each need: an element they know is
--- there, a list that holds a string, a fresh build directory, the open
--- descriptors, a named pipe and a small project. Test support.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local build_paths = require("build.paths")

local record test_support_fixture
  --- The two ends of a pipe.
  record Ends
    reader: integer
    writer: integer
  end
  --- What a callback leaves for the case that ran it: empty until set.
  record Cell<T>
    mut value?: T
  end
  --- A number a callback moves and the case reads.
  record Counter
    mut value: integer
  end
end

--- The element of `list` at `index`, which the case knows is there.
--- @param list the list
--- @param index where the element is
--- @return the element
function test_support_fixture.nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

--- Whether `list` holds `value`.
--- @param list the strings to look through
--- @param value the string to look for
function test_support_fixture.holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- The build directory for a project rooted at `root`, made if it is not
--- there ([`build.paths.prepare`]).
--- @param root the project's root
--- @return the build directory
function test_support_fixture.build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

--- The open descriptors of this process, each with what it names.
function test_support_fixture.descriptors(): string
  local out: mut {string} = {}
  -- /dev/fd where there is no /proc (macOS, the BSDs).
  local directory = "/proc/self/fd"
  local is_dir, _ = Fs.is_dir(directory)
  if is_dir ~= true then directory = "/dev/fd" end
  for _, number in ipairs((assert(Fs.list(directory)))) do
    local target, _ = Fs.readlink(directory .. "/" .. number)
    out[#out + 1] = number .. "=" .. (target or "?")
  end
  table.sort(out)
  return table.concat(out, "\n")
end

--- Writes a project of one program, `cmd/hello`, whose main requires `greet` and prints its `hello()`, `hello, <whom>`.
--- @param root the project's root
--- @param whom who the greeting greets
function test_support_fixture.write_project(root: string, whom: string)
  assert(Fs.mkdirs(root .. "/cmd/hello"))
  assert(Fs.write(root .. "/cmd/hello/main.tl", table.concat({
    'local greet = require("greet")',
    "return function(): integer",
    "  print(greet.hello())",
    "  return 0",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/greet.tl", table.concat({
    "local record greet",
    "end",
    "function greet.hello(): string",
    '  return "hello, ' .. whom .. '"',
    "end",
    "return greet",
    "",
  }, "\n")))
end

--- The two ends of a named pipe in `dir`, neither waiting: the reading
--- end open first, as a pipe with no reader refuses a nonblocking writer.
--- @param dir where to make it
--- @param name its name there
--- @return the descriptors of its ends
function test_support_fixture.fifo(dir: string, name: string): test_support_fixture.Ends
  local path = dir .. "/" .. name
  assert(sys.mkfifo(path, 384))
  local reader = assert(sys.open(path, sys.O_RDONLY | sys.O_NONBLOCK, 0))
  local writer = assert(sys.open(path, sys.O_WRONLY | sys.O_NONBLOCK, 0))
  return { reader = reader, writer = writer }
end

--- A temporary root whose o/cosmic.db holds one small table, `t`, of rows that need quoting.
--- @return the root
function test_support_fixture.sql_project(): string
  local root = assert(Fs.mkdtemp("cosmic-sql-test-"))
  assert(test_support_fixture.build_dir(root))
  local db = assert(Sqlite.open(test_support_fixture.build_dir(root) .. "/cosmic.db", { writable = true }))
  assert(db:exec("CREATE TABLE t (a, b); INSERT INTO t VALUES " ..
      "(1, 'one'), (NULL, x'00ff'), (1.5, 'tab' || char(9) || 'and\\'), (2.0, ''), " ..
      "(3, char(27) || '[31m' || char(127) || '\\N')"))
  assert(db:close())
  return root
end

return test_support_fixture
