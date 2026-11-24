--- cosmic.shell's calls against the commands they are named after: `bin/cosmic bench/shell.tl [name...]`.
--- Each case times the call in this process and the command as a program (its start, its run and the read of its
--- output, as a snippet that ran it would pay), on a small file and on 1 MiB, and prints both and their ratio. It
--- measures; it gates nothing, and no test reads its numbers. GNU coreutils is the guide, not a target.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Shell = require("cosmic.shell")

--- The fastest of five batches of `run(n)`, per operation, in ns; n doubles until a batch takes 50 ms.
local function timed(run: function(n: integer)): number
  local function batch(n: integer): integer
    collectgarbage("collect")
    local start = Clock.monotonic_ns()
    run(n)
    return Clock.monotonic_ns() - start
  end
  local n = 1
  while batch(n) < 50 * 1000 * 1000 do n = n * 2 end
  local best = math.huge
  for _ = 1, 5 do best = math.min(best, batch(n) / n) end
  return best
end

--- Runs `argv`, its first word found on PATH, and answers its output.
local function command(argv: {string}): function(n: integer)
  local program, why = Proc.find(argv[1] or "")
  if program == nil then error("no " .. tostring(argv[1]) .. ": " .. tostring(why)) end
  local words: mut {string} = { program }
  for i = 2, #argv do words[#words + 1] = argv[i] end
  return function(n: integer)
    for _ = 1, n do
      local result = assert(Child.run(words, { env = { LC_ALL = "C" }, stdout = "capture", stderr = "capture",
        timeout_ns = Clock.seconds(60) }))
      assert(result.code == 0 or result.code == 1, table.concat(argv, " "))
    end
  end
end

local dir = assert(Fs.mkdtemp("shell-bench-"))
local small, big = dir .. "/small.txt", dir .. "/big.txt"
local parts: mut {string} = {}
for i = 1, 20 do
  local line = "line " .. tostring(i) .. (if i % 3 == 0 then " TODO" else "" end)
  parts[#parts + 1] = line
end
assert(Fs.write(small, table.concat(parts, "\n") .. "\n"))
parts = {}
for i = 1, 16384 do
  local line = string.rep("x", 50 + i % 7) .. (if i % 97 == 0 then " TODO" else "" end) .. tostring(i % 89)
  parts[#parts + 1] = line
end
assert(Fs.write(big, table.concat(parts, "\n") .. "\n"))
for i = 1, 200 do
  local sub = dir .. "/tree/d" .. tostring(i % 10)
  assert(Fs.mkdirs(sub))
  assert(Fs.write(sub .. "/f" .. tostring(i) .. ".tl", ""))
end

local record Case
  name: string
  call: function(n: integer)
  command: function(n: integer)
end

local cases: mut {Case} = {}
for _, file in ipairs({ { "small", small }, { "1 MiB", big } }) do
  local label, path = assert(file[1]), assert(file[2])
  cases[#cases + 1] = { name = "wc " .. label, command = command({ "wc", "-l", path }),
    call = function(n: integer)
      for _ = 1, n do assert(Shell.wc(path)) end
    end }
  cases[#cases + 1] = { name = "grep " .. label, command = command({ "grep", "-n", "-F", "TODO", path }),
    call = function(n: integer)
      for _ = 1, n do assert(Shell.grep("TODO", { path }, true)) end
    end }
  cases[#cases + 1] = { name = "sort " .. label, command = command({ "sort", path }),
    call = function(n: integer)
      for _ = 1, n do local _ = Shell.sort(assert(Shell.lines(path))) end
    end }
  cases[#cases + 1] = { name = "sort|uniq -c " .. label, command = command({ "sort", path }),
    call = function(n: integer)
      for _ = 1, n do local _ = Shell.top(Shell.uniq(assert(Shell.lines(path)))) end
    end }
end
cases[#cases + 1] = { name = "find 200 files", command = command({ "find", dir .. "/tree", "-type", "f" }),
  call = function(n: integer)
    for _ = 1, n do assert(Shell.find(dir .. "/tree")) end
  end }

local wanted: mut {string: boolean} = {}
for _, name in ipairs(arg) do wanted[name] = true end
print(string.format("%-20s %14s %14s %8s", "case", "call ns/op", "command ns/op", "ratio"))
for _, c in ipairs(cases) do
  local selected = next(wanted) == nil
  for name in pairs(wanted) do
    if c.name:find(name, 1, true) ~= nil then selected = true end
  end
  if selected then
    local call, run = timed(c.call), timed(c.command)
    print(string.format("%-20s %14.0f %14.0f %7.1fx", c.name, call, run, run / call))
  end
end
local _, _ = Fs.remove_tree(dir)
