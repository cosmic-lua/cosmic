--- cosmic.shell's calls answer as the commands they are named after do, on fixtures drawn at random: wc -l, grep -n
--- -F, sed s///g, LC_ALL=C sort, uniq -c and find -type f, run here as programs. The fixtures keep to what both
--- read alike: no `\r` (Shell.grep and Shell.lines drop one before a newline), no NUL, and needles of letters, so
--- sed's regular expression is plain text.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Shell = require("cosmic.shell")
local Test = require("cosmic.test")

Test.policy{
  profiles = { "cosmic", "system" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "TMPDIR", "PATH" },
  requires = { "program:grep", "program:sed", "program:wc", "program:sort", "program:uniq", "program:find" },
}

--- How many fixtures each test draws.
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
  -- grep answers 1 where it found no line, which is no failure here.
  assert(result.code == 0 or (argv[1] == "grep" and result.code == 1), table.concat(argv, " ") .. ": " ..
      tostring(result.stderr))
  return result.stdout or ""
end

--- wc, grep, sed, sort and uniq answer as their commands do on each fixture.
local function test_the_file_calls_answer_as_their_commands(tmp: string)
  local draw = drawer(7)
  for case = 1, CASES do
    local text = text_of(draw)
    local path = tmp .. "/f" .. tostring(case) .. ".txt"
    assert(Fs.write(path, text))
    local shown = "case " .. tostring(case) .. ": " .. string.format("%q", text)
    -- wc -l counts newlines.
    local wc = math.tointeger(tonumber((ran({ "wc", "-l", path }):match("^%s*(%d+)")))) or -1
    assert(assert(Shell.wc(path)) == wc, shown)
    -- grep -n -F: each line holding the needle, by number.
    local needle = ({ "a", "b", "ab", "x" })[draw(4)] or "a"
    local hits: mut {string} = {}
    for _, hit in ipairs(assert(Shell.grep(needle, { path }, true))) do
      hits[#hits + 1] = tostring(hit.line) .. ":" .. hit.text .. "\n"
    end
    assert(table.concat(hits, "") == ran({ "grep", "-n", "-F", needle, path }), shown .. " grep " .. needle)
    -- sort, LC_ALL=C: by bytes, a line with no newline given one.
    local lines = assert(Shell.lines(path))
    local sorted = Shell.sort(lines)
    local want = ran({ "sort", path })
    local got = if #sorted == 0 then "" else table.concat(sorted, "\n") .. "\n" end
    assert(got == want, shown .. " sort")
    -- uniq -c of the sorted lines: each line and how often.
    local counts = Shell.uniq(lines)
    local distinct = 0
    for count, line in ran({ "uniq", "-c" }, want):gmatch("%s*(%d+) ([^\n]*)\n") do
      assert(counts[line] == math.tointeger(tonumber(count)), shown .. " uniq " .. line)
      distinct = distinct + 1
    end
    local keys = 0
    for _ in pairs(counts) do keys = keys + 1 end
    assert(keys == distinct, shown .. " uniq: " .. tostring(keys) .. " keys, " .. tostring(distinct) .. " lines")
    -- sed s/needle/X/g, line by line, the end as it was.
    local edited = ran({ "sed", "s/" .. needle .. "/X/g", path })
    local _ = assert(Shell.sed(path, needle, "X", true))
    local after = assert(Fs.read(path))
    -- GNU sed ends a last line that had no newline with none, as Shell.sed does.
    assert(after == edited, shown .. " sed " .. needle .. ": " .. string.format("%q / %q", after, edited))
  end
end

--- find -type f lists the files of a tree drawn at random, as Shell.find does, once both are sorted.
local function test_find_lists_what_find_lists(tmp: string)
  local draw = drawer(11)
  for case = 1, 10 do
    local root = tmp .. "/t" .. tostring(case)
    assert(Fs.mkdirs(root))
    for _ = 1, draw(15) do
      local depth = draw(3)
      local parts: mut {string} = { root }
      for _ = 1, depth - 1 do parts[#parts + 1] = "d" .. tostring(draw(3)) end
      assert(Fs.mkdirs(table.concat(parts, "/")))
      parts[#parts + 1] = "f" .. tostring(draw(5)) .. (if draw(2) == 1 then ".tl" else ".md" end)
      assert(Fs.write(table.concat(parts, "/"), ""))
    end
    local want: mut {string} = {}
    for line in ran({ "find", root, "-type", "f" }):gmatch("[^\n]+") do want[#want + 1] = line end
    local found = assert(Shell.find(root))
    assert(table.concat(Shell.sort(found), "\n") == table.concat(Shell.sort(want), "\n"), "case " .. tostring(case))
    local tl: mut {string} = {}
    for _, path in ipairs(want) do
      if path:sub(-3) == ".tl" then tl[#tl + 1] = path end
    end
    assert(table.concat(Shell.sort(assert(Shell.find(root, ".tl"))), "\n") == table.concat(Shell.sort(tl), "\n"))
  end
end
