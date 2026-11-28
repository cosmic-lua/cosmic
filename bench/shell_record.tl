--- Records what the system's `wc -l`, `grep -n -F`, `sed s///g`, `LC_ALL=C sort`, `uniq -c` and `find -type f`
--- print on the fixtures cosmic/shell_diff_test.tl replays, into testdata/shell_diff/cases.json:
---
---     bin/cosmic bench/shell_record.tl
---
--- The fixtures are drawn from a fixed seed, so a run on another host draws the same ones; the answers are the
--- host's commands' (GNU coreutils, grep, sed and findutils are the guide of cosmic.shell). The test keeps to what
--- both read alike: no `\r`, no NUL, and needles of letters, so sed's regular expression is plain text.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")

--- How many file fixtures are drawn.
local CASES <const> = 40

--- A generator of integers in [1, n], the same for a seed on every host.
local function drawer(seed: integer): function(integer): integer
  local state = seed
  return function(n: integer): integer
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end
end

--- Text of lines drawn from a few words, so lines repeat and needles are found; it may end with no newline.
local function text_of(draw: function(integer): integer): string
  local words = { "a", "b", "ab", "ba", "x", "", " ", "a b", "aa" }
  local lines: mut {string} = {}
  for _ = 1, draw(12) - 1 do
    local parts: mut {string} = {}
    for _ = 1, draw(3) do parts[#parts + 1] = assert(words[draw(#words)]) end
    lines[#lines + 1] = table.concat(parts, "")
  end
  local body = table.concat(lines, "\n")
  if #lines > 0 and draw(4) > 1 then body = body .. "\n" end
  return body
end

--- What `argv` printed, with `input` on its standard input where given.
local function ran(argv: {string}, input?: string): string
  local program, missing = Proc.find(argv[1] or "")
  if program == nil then error("no " .. tostring(argv[1]) .. ": " .. tostring(missing)) end
  local words: mut {string} = { program }
  for i = 2, #argv do words[#words + 1] = argv[i] end
  local result, why = Child.run(words, { env = { LC_ALL = "C", PATH = "/usr/bin:/bin" }, input = input,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(20) })
  assert(result ~= nil, tostring(why))
  -- grep exits 1 where it found no line, which is no failure here.
  assert(result.code == 0 or (argv[1] == "grep" and result.code == 1), table.concat(argv, " ") .. ": " ..
      tostring(result.stderr))
  return result.stdout or ""
end

local directory = assert(Fs.mkdtemp("shell-diff-"))
local files: mut {Json.Value} = {}
local draw = drawer(7)
for case = 1, CASES do
  local text = text_of(draw)
  local path = directory .. "/f" .. tostring(case) .. ".txt"
  assert(Fs.write(path, text))
  local needle = ({ "a", "b", "ab", "x" })[draw(4)] or "a"
  local sorted = ran({ "sort", path })
  files[#files + 1] = { text = text, needle = needle, wc = math.tointeger(tonumber((ran({ "wc", "-l", path }):match("^%s*(%d+)")))) or -1,
    grep = ran({ "grep", "-n", "-F", needle, path }), sort = sorted, uniq = ran({ "uniq", "-c" }, sorted),
    sed = ran({ "sed", "s/" .. needle .. "/X/g", path }) }
end

--- `lines` of `find`'s output, as paths under `root`, sorted.
local function relative(output: string, root: string): {string}
  local out: mut {string} = {}
  for line in output:gmatch("[^\n]+") do
    assert(line:sub(1, #root + 1) == root .. "/", line)
    out[#out + 1] = line:sub(#root + 2)
  end
  table.sort(out)
  return out
end

local trees: mut {Json.Value} = {}
draw = drawer(11)
for case = 1, 10 do
  local root = directory .. "/t" .. tostring(case)
  assert(Fs.mkdirs(root))
  local made: mut {string} = {}
  for _ = 1, draw(15) do
    local parts: mut {string} = {}
    for _ = 1, draw(3) - 1 do parts[#parts + 1] = "d" .. tostring(draw(3)) end
    assert(Fs.mkdirs(table.concat({ root, table.unpack(parts) }, "/")))
    parts[#parts + 1] = "f" .. tostring(draw(5)) .. (if draw(2) == 1 then ".tl" else ".md" end)
    local name = table.concat(parts, "/")
    assert(Fs.write(root .. "/" .. name, ""))
    made[#made + 1] = name
  end
  trees[#trees + 1] = { made = made, find = relative(ran({ "find", root, "-type", "f" }), root),
    find_tl = relative(ran({ "find", root, "-type", "f", "-name", "*.tl" }), root) }
end

local here = "testdata/shell_diff"
assert(Fs.write(here .. "/cases.json", assert(Json.encode({ files = files, trees = trees })) .. "\n"))
print("recorded " .. tostring(#files) .. " files and " .. tostring(#trees) .. " trees in " .. here .. "/cases.json")
