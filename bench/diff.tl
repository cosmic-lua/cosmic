--- cosmic.diff against GNU `diff -u`: `bin/cosmic bench/diff.tl [name...]`.
--- Each size has two cases: [`Diff.lines`] and [`Diff.unified`] on two texts in this process, and the command as a
--- program (its start, its run and the read of its output, as a snippet that ran it would pay) with its ratio to the
--- call. The texts are code-like lines with 0.5 to 2 percent of them edited, and one pair of unrelated texts, where
--- `cost` bounds the search. GNU diff is the guide, not a target. [`bench.harness`] takes `--json`, `--rounds` and
--- `--against <old-binary>`. It measures; it gates nothing, and no test reads its numbers.
local Bench = require("bench.harness")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Diff = require("cosmic.diff")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

--- A generator of integers in [1, n], the same for a seed on every host.
local function drawer(seed: integer): function(integer): integer
  local state = seed
  return function(n: integer): integer
    state = (state * 1103515245 + 12345) % 2147483648
    return (state // 65536) % n + 1
  end
end

--- `n` lines of code-like text: some `end`, some blank, the rest unique.
local function code(draw: function(integer): integer, n: integer): {string}
  local out: mut {string} = {}
  for i = 1, n do
    local r = draw(100)
    if r <= 15 then
      out[#out + 1] = "end"
    elseif r <= 25 then
      out[#out + 1] = ""
    else
      out[#out + 1] = "  local v" .. tostring(draw(1000000)) .. " = f(" .. tostring(draw(100)) .. ", \"" .. tostring(i) .. "\")"
    end
  end
  return out
end

--- `lines` with about `permille` in a thousand of them removed, changed or given a line before.
local function edited(draw: function(integer): integer, lines: {string}, permille: integer): {string}
  local out: mut {string} = {}
  for _, line in ipairs(lines) do
    local r = draw(1000)
    if r <= permille / 3 then
      -- removed
    elseif r <= permille * 2 / 3 then
      out[#out + 1] = line .. " -- x"
    elseif r <= permille then
      out[#out + 1] = "  new line " .. tostring(draw(1000000000))
      out[#out + 1] = line
    else
      out[#out + 1] = line
    end
  end
  return out
end

local function joined(lines: {string}): string
  return table.concat(lines, "\n") .. "\n"
end

--- Runs `argv`, its first word found on PATH, and returns nothing: 0 and 1 are both a finished diff.
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

local dir = assert(Fs.mkdtemp("diff-bench-"))
local draw = drawer(2026)
local bench = Bench.new("diff")

--- Writes `old` and `new` to files and adds the call's case and the command's.
local function pair(name: string, old: string, new: string)
  local a, b = dir .. "/" .. name:gsub("[^%w]", "_") .. ".a", dir .. "/" .. name:gsub("[^%w]", "_") .. ".b"
  assert(Fs.write(a, old))
  assert(Fs.write(b, new))
  bench.case("diff " .. name, function(n: integer)
    for _ = 1, n do local _ = Diff.unified(Diff.lines(old, new)) end
  end, { bytes = #old + #new })
  bench.case("diff " .. name .. ": command", command({ "diff", "-u", a, b }), { baseline = "diff " .. name })
end

local record Size
  label: string
  n: integer
  permille: integer
end
local sizes: {Size} = {
  { label = "2k lines", n = 2000, permille = 20 },
  { label = "20k lines", n = 20000, permille = 10 },
  { label = "200k lines", n = 200000, permille = 5 },
}
for _, size in ipairs(sizes) do
  local old = code(draw, size.n)
  pair(size.label, joined(old), joined(edited(draw, old, size.permille)))
end
pair("20k unrelated lines", joined(code(draw, 20000)), joined(code(draw, 20000)))

return function(argv: {string}): integer
  local ok, code_ = pcall(bench.main, argv)
  local _, _ = Fs.remove_tree(dir)
  if not ok then error(code_, 0) end
  return code_
end
