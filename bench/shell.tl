--- cosmic.shell's calls timed in this process, on a small file and on 1 MiB: `bin/cosmic bench/shell.tl [name...]`.
--- It measures absolute time only and runs no program.
local Bench = require("bench.harness")
local Fs = require("cosmic.fs")
local Shell = require("cosmic.shell")

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

for _, file in ipairs({ { "small", small }, { "1 MiB", big } }) do
  local label, path = assert(file[1]), assert(file[2])
  bench.case("wc " .. label, function(n: integer)
    for _ = 1, n do assert(Shell.wc(path)) end
  end)
  bench.case("grep " .. label, function(n: integer)
    for _ = 1, n do assert(Shell.grep("TODO", { path }, true)) end
  end)
  bench.case("sort " .. label, function(n: integer)
    for _ = 1, n do local _ = Shell.sort(assert(Shell.lines(path))) end
  end)
  bench.case("sort|uniq -c " .. label, function(n: integer)
    for _ = 1, n do local _ = Shell.top(Shell.uniq(assert(Shell.lines(path)))) end
  end)
end
bench.case("find 200 files", function(n: integer)
  for _ = 1, n do assert(Shell.find(dir .. "/tree")) end
end)

return function(argv: {string}): integer
  local ok, code = pcall(bench.main, argv)
  local _, _ = Fs.remove_tree(dir)
  if not ok then error(code, 0) end
  return code
end
