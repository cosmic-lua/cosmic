--- A fake build tool (`zig`, `codesign`) for build/'s tests, run as a
--- [`cosmic.fake`] main. What it does is the JSON [`Fake.given`] reads,
--- in this order, each step only where its field is given:
---
--- - `handed`: writes `[$COSMIC_REBUILD_LOCK_HANDED]` and a newline to
---   that file;
--- - `write_args`: writes its arguments, joined by spaces, and a newline
---   as the whole of that file; `append_args` adds them at its end;
--- - `stdout`: writes it to stdout, as it is;
--- - `trap`: holds SIGINT and SIGTERM, and ends with that status once
---   one arrives (checked while it waits or sleeps);
--- - `wait_for`: waits until that file exists;
--- - `signal` (INT, TERM or KILL): sends it to `pid`, or to the pid the
---   file `pid_file` holds (negated for a process group), or else to
---   itself, and then waits, two seconds at most, for it to end it;
--- - `sleep_ms`: sleeps that long.
---
--- Then it ends with `code`, 0 when not given.

local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fake = require("cosmic.fake")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local Signal = require("cosmic.signal")
local String = require("cosmic.string")
local sys = require("cosmic.sys")

--- What a placed copy is given.
local record Given
  handed?: string
  write_args?: string
  append_args?: string
  stdout?: string
  trap?: integer
  wait_for?: string
  signal?: string
  pid?: integer
  pid_file?: string
  sleep_ms?: integer
  code?: integer
end

local GIVEN <const> = Shape.record_of("Given")

local signals: {string:integer} = { INT = sys.SIGINT, TERM = sys.SIGTERM, KILL = sys.SIGKILL }

local function fail(why: string): integer
  local _, _ = Fs.put(2, "tool fake: " .. why .. "\n")
  return 1
end

--- Sleeps `ns`, a few milliseconds at a time: true where `guard` caught
--- a signal first.
local function slept_into_a_signal(ns: integer, guard: Signal.Guard?): boolean
  local deadline = Clock.monotonic_ns() + ns
  while Clock.monotonic_ns() < deadline do
    if guard ~= nil and guard:cancelled() ~= 0 then return true end
    assert(Clock.sleep(Clock.ms(5)))
  end
  return guard ~= nil and guard:cancelled() ~= 0
end

local function main(argv: {string}): integer
  local given, trouble = Shape.decode_into(Fake.given() or "{}", GIVEN.spec)
  if given == nil then return fail(trouble) end
  local args = table.concat(argv, " ") .. "\n"
  if given.handed ~= nil then
    assert(Fs.write(given.handed, "[" .. (Env.get("COSMIC_REBUILD_LOCK_HANDED") or "") .. "]\n"))
  end
  if given.write_args ~= nil then assert(Fs.write(given.write_args, args)) end
  if given.append_args ~= nil then
    local before, _ = Fs.read(given.append_args)
    assert(Fs.write(given.append_args, (before or "") .. args))
  end
  if given.stdout ~= nil then assert(Fs.put(1, given.stdout)) end
  local guard: Signal.Guard? = nil
  if given.trap ~= nil then
    local held, why = Signal.guard()
    if held == nil then return fail(tostring(why)) end
    guard = held
  end
  if given.wait_for ~= nil then
    while not assert(Fs.status(given.wait_for)).exists do
      if slept_into_a_signal(Clock.ms(5), guard) then return given.trap or 0 end
    end
  end
  if given.signal ~= nil then
    local signal = signals[given.signal]
    if signal == nil then return fail("no signal " .. given.signal) end
    local pid = given.pid
    if pid == nil and given.pid_file ~= nil then
      pid = math.tointeger(tonumber(String.trim(assert(Fs.read(given.pid_file)))))
      if pid == nil then return fail("no pid in " .. given.pid_file) end
    end
    local to_self = pid == nil
    pid = pid or sys.getpid()
    if pid == 0 or pid == -1 then return fail("refusing pid " .. tostring(pid)) end
    local sent, why = sys.kill(pid, signal)
    if not sent then return fail(tostring(why)) end
    if to_self then
      if slept_into_a_signal(Clock.seconds(2), guard) then return given.trap or 0 end
      return fail("SIG" .. given.signal .. " sent to itself did not end it in 2 s")
    end
  end
  if given.sleep_ms ~= nil and slept_into_a_signal(Clock.ms(given.sleep_ms), guard) then
    return given.trap or 0
  end
  if guard ~= nil and guard:cancelled() ~= 0 then return given.trap or 0 end
  return given.code or 0
end

return main
