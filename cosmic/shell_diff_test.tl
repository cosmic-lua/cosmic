--- cosmic.shell's calls return what the commands they are named after print: wc -l, grep -n -F, sed s///g,
--- LC_ALL=C sort, uniq -c and find -type f. What the system's commands printed on fixtures drawn at random is
--- recorded in testdata/shell_diff/cases.json (`bin/cosmic testdata/shell_diff/record.tl` makes it again), and the tests
--- replay it, so no program runs. The fixtures keep to what both read alike: no `\r` (Shell.grep and Shell.lines
--- drop one before a newline), no NUL, and needles of letters, so sed's regular expression is plain text.
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local Shell = require("cosmic.shell")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "testdata/shell_diff", letters = "r" } } }

local DATA <const> = "testdata/shell_diff/cases.json"

--- What the system's commands printed on one fixture file.
local record FileCase
  text: string
  needle: string
  wc: integer
  grep: string
  sort: string
  uniq: string
  sed: string
end

--- What `find` printed on one tree: the files made, under the root, and what it listed (sorted, relative).
local record TreeCase
  made: {string}
  find: {string}
  find_tl: {string}
end

--- The recorded cases.
local record Cases
  files: {FileCase}
  trees: {TreeCase}
end

local CASES <const> = Shape.record_of("Cases")

--- The recorded cases of the file.
local function recorded(): Cases
  return (assert(Shape.decode_into(assert(Fs.read(DATA)), CASES.spec)))
end

--- wc, grep, sed, sort and uniq return what their commands printed on each fixture.
local function test_the_file_calls_answer_as_their_commands(tmp: string)
  local cases = recorded().files
  assert(#cases == 40)
  for number, case in ipairs(cases) do
    local text = case.text
    local path = tmp .. "/f" .. tostring(number) .. ".txt"
    assert(Fs.write(path, text))
    local shown = "case " .. tostring(number) .. ": " .. string.format("%q", text)
    -- wc -l counts newlines.
    assert(assert(Shell.wc(path)) == case.wc, shown)
    -- grep -n -F: each line holding the needle, by number.
    local needle = case.needle
    local hits: mut {string} = {}
    for _, hit in ipairs(assert(Shell.grep(needle, { path }, true))) do
      hits[#hits + 1] = tostring(hit.line) .. ":" .. hit.text .. "\n"
    end
    assert(table.concat(hits, "") == case.grep, shown .. " grep " .. needle)
    -- sort, LC_ALL=C: by bytes, a line with no newline given one.
    local lines = assert(Shell.lines(path))
    local sorted = Shell.sort(lines)
    local want = case.sort
    local got = if #sorted == 0 then "" else table.concat(sorted, "\n") .. "\n" end
    assert(got == want, shown .. " sort")
    -- uniq -c of the sorted lines: each line and how often.
    local counts = Shell.uniq(lines)
    local distinct = 0
    for count, line in case.uniq:gmatch("%s*(%d+) ([^\n]*)\n") do
      assert(counts[line] == math.tointeger(tonumber(count)), shown .. " uniq " .. line)
      distinct = distinct + 1
    end
    local keys = 0
    for _ in pairs(counts) do keys = keys + 1 end
    assert(keys == distinct, shown .. " uniq: " .. tostring(keys) .. " keys, " .. tostring(distinct) .. " lines")
    -- sed s/needle/X/g, line by line, the end as it was.
    local _ = assert(Shell.sed(path, needle, "X", true))
    local after = assert(Fs.read(path))
    -- GNU sed ends a last line that had no newline with none, as Shell.sed does.
    assert(after == case.sed, shown .. " sed " .. needle)
  end
end

--- find -type f lists the files of a tree as Shell.find does, once both are sorted.
local function test_find_lists_what_find_lists(tmp: string)
  local cases = recorded().trees
  assert(#cases == 10)
  for number, case in ipairs(cases) do
    local root = tmp .. "/t" .. tostring(number)
    assert(Fs.mkdirs(root))
    for _, name in ipairs(case.made) do
      local parts: mut {string} = {}
      for part in name:gmatch("[^/]+") do parts[#parts + 1] = part end
      parts[#parts] = nil
      assert(Fs.mkdirs(table.concat({ root, table.unpack(parts) }, "/")))
      assert(Fs.write(root .. "/" .. name, ""))
    end
    local function relative(found: {string}): string
      local out: mut {string} = {}
      for _, path in ipairs(found) do out[#out + 1] = path:sub(#root + 2) end
      return table.concat(Shell.sort(out), "\n")
    end
    local label = "case " .. tostring(number)
    assert(relative(assert(Shell.find(root))) == table.concat(case.find, "\n"), label)
    assert(relative(assert(Shell.find(root, ".tl"))) == table.concat(case.find_tl, "\n"), label .. " .tl")
  end
end
