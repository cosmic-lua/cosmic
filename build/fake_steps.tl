--- Steps a test's own fake main ([`cosmic.fake`]) is made of: each does
--- one thing a test checks from inside a child -- read a file, make
--- one, read a limit, test a descriptor -- and returns nil to go on, or
--- the status to end with. A step that fails says why on stderr, as
--- `fake: <what>: <why>`, and returns 1.
---
---     local Steps = require("build.fake_steps")
---     local function main(argv: {string}): integer
---       return Steps.cat(argv[2]) or Steps.print("read") or 0
---     end

local Fs = require("cosmic.fs")
local Env = require("cosmic.env")
local sys = require("cosmic.sys")

local record Steps
end

--- Says `fake: <what>: <why>` on stderr; returns 1.
function Steps.fail(what: string, why: string): integer
  local _, _ = Fs.put(2, "fake: " .. what .. ": " .. why .. "\n")
  return 1
end

--- Writes `data` to descriptor `fd`, as it is.
function Steps.put(fd: integer, data: string): integer?
  local ok, trouble = Fs.put(fd, data)
  if not ok then return Steps.fail("write", tostring(trouble)) end
  return nil
end

--- `text` and a newline, to stdout.
function Steps.print(text: string): integer?
  return Steps.put(1, text .. "\n")
end

--- File `path`, or stdin to its end where `path` is nil, to stdout.
function Steps.cat(path?: string): integer?
  if path ~= nil then
    local bytes, trouble = Fs.read(path)
    if bytes == nil then return Steps.fail(path, tostring(trouble)) end
    return Steps.put(1, bytes)
  end
  while true do
    local chunk, trouble = Fs.take(0, 65536)
    if chunk == nil then return Steps.fail("stdin", tostring(trouble)) end
    if chunk == "" then return nil end
    local stopped = Steps.put(1, chunk)
    if stopped ~= nil then return stopped end
  end
end

--- `text` and a newline, as the whole of file `path`.
function Steps.write(path: string, text: string): integer?
  local ok, trouble = Fs.write(path, text .. "\n")
  if not ok then return Steps.fail(path, tostring(trouble)) end
  return nil
end

--- `text` and a newline, as a new file at `path`: one that is there
--- already fails.
function Steps.create(path: string, text: string): integer?
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 420)
  if fd == nil then return Steps.fail(path, trouble) end
  local written, write_trouble = sys.write(fd, text .. "\n")
  local _, _ = sys.close(fd)
  if written == nil then return Steps.fail(path, write_trouble) end
  return nil
end

--- Sets the mode bits of `path`, given in octal, as `chmod` does.
function Steps.chmod(path: string, octal: string): integer?
  local bits = math.tointeger(tonumber(octal, 8))
  if bits == nil then return Steps.fail("chmod", "no mode " .. octal) end
  local ok, trouble = Fs.chmod(path, bits)
  if not ok then return Steps.fail(path, tostring(trouble)) end
  return nil
end

--- `NAME=` and the variable's value, or `NAME unset`, and a newline, to
--- stdout.
function Steps.env_of(name: string): integer?
  local value = Env.get(name)
  return Steps.print(if value ~= nil then name .. "=" .. value else name .. " unset" end)
end

local resources: {string:integer} = {
  nofile = sys.RLIMIT_NOFILE, fsize = sys.RLIMIT_FSIZE, cpu = sys.RLIMIT_CPU,
  core = sys.RLIMIT_CORE, nproc = sys.RLIMIT_NPROC,
}

--- `<name> <soft> <hard>` of the limit `name` (nofile, fsize, cpu, core,
--- nproc), and a newline, to stdout.
function Steps.rlimit(name: string): integer?
  local resource = resources[name]
  if resource == nil then return Steps.fail("rlimit", "no resource " .. name) end
  local limits, trouble = sys.getrlimit(resource)
  if limits == nil then return Steps.fail("rlimit", trouble) end
  return Steps.print(name .. " " .. tostring(limits.soft) .. " " .. tostring(limits.hard))
end

--- Nil where descriptor `fd` is closed; 1 where it is open.
function Steps.fd_closed(fd: integer): integer?
  local open, _ = sys.fstat(fd)
  if open ~= nil then return 1 end
  return nil
end

return Steps
