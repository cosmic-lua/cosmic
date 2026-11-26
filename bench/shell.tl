--- cosmic.shell's calls against the commands they are named after: `bin/cosmic bench/shell.tl [name...]`.
--- Each call has two cases: the call in this process, and the command as a program (its start, its run and the read
--- of its output, as a snippet that ran it would pay), on a small file and on 1 MiB. [`bench.harness`] times them
--- and prints the command's ratio to the call. GNU coreutils is the guide, not a target.
local Bench = require("bench.harness")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Shell = require("cosmic.shell")

--- Runs `argv`, its first word found on PATH, and returns its output.
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

local bench = Bench.new("shell")

--- Two cases: the call in this process, and the command as a program, with its ratio to the call.
local function pair(name: string, call: function(n: integer), program: function(n: integer))
  bench.case(name, call)
  bench.case(name .. ": command", program, { baseline = name })
end

for _, file in ipairs({ { "small", small }, { "1 MiB", big } }) do
  local label, path = assert(file[1]), assert(file[2])
  pair("wc " .. label, function(n: integer)
    for _ = 1, n do assert(Shell.wc(path)) end
  end, command({ "wc", "-l", path }))
  pair("grep " .. label, function(n: integer)
    for _ = 1, n do assert(Shell.grep("TODO", { path }, true)) end
  end, command({ "grep", "-n", "-F", "TODO", path }))
  pair("sort " .. label, function(n: integer)
    for _ = 1, n do local _ = Shell.sort(assert(Shell.lines(path))) end
  end, command({ "sort", path }))
  pair("sort|uniq -c " .. label, function(n: integer)
    for _ = 1, n do local _ = Shell.top(Shell.uniq(assert(Shell.lines(path)))) end
  end, command({ "sort", path }))
end
pair("find 200 files", function(n: integer)
  for _ = 1, n do assert(Shell.find(dir .. "/tree")) end
end, command({ "find", dir .. "/tree", "-type", "f" }))

return function(argv: {string}): integer
  local code = bench.main(argv)
  local _, _ = Fs.remove_tree(dir)
  return code
end
