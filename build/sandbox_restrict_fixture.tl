--- What the tests of [`Sandbox.restrict`] on a live process share
--- (cosmic/sandbox_restrict_test.tl, cosmic/sandbox_restrict_refusal_test.tl):
--- a child of this program (`cosmic -e`, started past its launcher) that
--- restricts itself and prints what it could and could not do, and what
--- the test reads of that. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")

local record sandbox_restrict_fixture
  --- What a child said: its lines, `name=value`, by name, and how it ended.
  record Said
    code: integer
    lines: mut {string:string}
    raw: string
  end
end

--- What the child runs first: the modules it uses, loaded before it is
--- restricted since it may read nothing after, and the helpers that
--- report. `say(name, ...)` prints `name=` and its values; `reads(path)`
--- is what a file holds or why it cannot be read; `writes(path)` makes
--- it, or says why not; `limit(resource)` is a limit as "soft hard".
local PRELUDE <const> = [[
local sys = require("cosmic.sys")
local Sandbox = require("cosmic.sandbox")
local Child = require("cosmic.child")
local Net = require("cosmic.net")
local Store = require("cosmic.store")
local function say(name: string, ...: any)
  local words: mut {string} = {}
  for i = 1, select("#", ...) do words[#words + 1] = tostring((select(i, ...))) end
  print(name .. "=" .. table.concat(words, " "))
end
local function reads(path: string): string
  local fd, why = sys.open(path, sys.O_RDONLY)
  if fd == nil then return "denied: " .. why end
  local data = sys.read(fd, 100)
  sys.close(fd)
  return data or ""
end
local function writes(path: string): string
  local fd, why = sys.open(path, sys.O_WRONLY | sys.O_CREAT, 420)
  if fd == nil then return "denied: " .. why end
  sys.close(fd)
  return "wrote"
end
--- A limit as "soft hard", or "none" where it cannot be read.
local function limit(resource: integer): string
  local held = sys.getrlimit(resource)
  if held == nil then return "none" end
  return tostring(held.soft) .. " " .. tostring(held.hard)
end
local _, _, _, _, _, _ = Child, Net, Store.alone, reads, writes, limit
]]

--- Runs `chunk`, after `PRELUDE`, in a child of this program, and returns
--- what it printed. Skips the test where the child reports `skip=` and
--- why, which it does where this host's kernel gives no Landlock.
--- @param chunk the Teal source the child runs
--- @return what it said
function sandbox_restrict_fixture.in_child(chunk: string): sandbox_restrict_fixture.Said
  local started = Test.cosmic({ "-e", PRELUDE .. chunk }, {
    env = Test.environment(), stdout = "capture", stderr = "stdout",
    timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  local said: sandbox_restrict_fixture.Said = { code = result.code or -1, lines = {}, raw = result.stdout or "" }
  for line in said.raw:gmatch("[^\n]+") do
    local name, value = line:match("^([%w_]+)=(.*)$")
    if name ~= nil and value ~= nil then said.lines[name] = value end
  end
  local skip = said.lines["skip"]
  if skip ~= nil then Test.skip(skip) end
  assert(result.code == 0, "the child ended " .. tostring(result.code) .. ": " .. said.raw)
  return said
end

return sandbox_restrict_fixture
