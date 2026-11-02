--- Presentation for the test runner. Inputs are fresh snapshots of strings
--- and counts; no job, verdict, database or cache is handed to this module.
--- The runner decides outcomes and exit codes independently of these strings.

local Errors = require("cosmic.errors")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local plural = require("build.plural")

local record test_report
  record Failure
    message: string
    rerun?: string
    printed?: string
  end

  --- The coverage floors a run was given (`--min`, `--min-file`), each a
  --- percentage from 0 to 100; nil for a floor not asked for.
  record Floors
    min?: number
    min_file?: number
  end

  --- The executable lines of one file of the run and how many a test hit.
  record FileLines
    path: string
    hit: integer
    lines: integer
  end

  --- What fell short of the floors: a line for each, and the clause the
  --- run's summary line carries ("" where nothing did).
  record Shortfall
    lines: {string}
    clause: string
  end

  --- A passing test and what it printed.
  record Shown
    id: string
    printed: string
  end

  record Build
    modules: integer
    compiled: integer
    cached: integer
    shared: integer
    parsed: integer
    shared_parses: integer
    files: integer
    read: integer
  end

  record Passed
    total: integer
    modules: integer
    ran: integer
    cached: integer
    skipped: integer
    --- Of those that ran, how many passed having made no call to `assert`.
    unchecked?: integer
    --- Of the tests chosen, how many are not applicable on this platform,
    --- none of which ran or stood.
    na?: integer
    every: integer
    shared: integer
  end
end

--- `word` as one word a POSIX shell reads back as it is: itself when
--- it holds nothing a shell treats specially, else single-quoted with
--- each `'` written `'\''`. One starting with `-` is prefixed `./`
--- first, so a command does not take it for an option.
local function shell_word(word: string): string
  if word:sub(1, 1) == "-" then word = "./" .. word end
  if word ~= "" and not word:find("[^%w_./:@%%+=,-]") then return word end
  return "'" .. (word:gsub("'", "'\\''")) .. "'"
end

--- What a test printed as `  | ` lines, the last 4096 bytes of it.
local function printed_lines(printed: string): {string}
  if #printed > 4096 then printed = "..." .. printed:sub(-4096) end
  local lines: mut {string} = {}
  for line in String.lines((printed:gsub("\n$", ""))) do
    lines[#lines + 1] = "  | " .. line
  end
  return lines
end

--- Each skipped test with its reason, sorted as the failure list is.
function test_report.skips(skips: mut {string}): {string}
  table.sort(skips)
  local lines: mut {string} = {}
  for _, skip in ipairs(skips) do lines[#lines + 1] = "test: SKIP  " .. skip end
  return lines
end

--- Each test that passed having made no call to `assert`, sorted as the
--- skips are.
function test_report.unchecked(ids: mut {string}): {string}
  table.sort(ids)
  local lines: mut {string} = {}
  for _, id in ipairs(ids) do lines[#lines + 1] = "test: NO ASSERT  " .. id end
  return lines
end

--- One line for each reason some tests gave [`Test.passed_unchecked`], with
--- how many gave it, sorted: they passed deliberately without checking.
function test_report.deliberate(reasons: {string}): {string}
  local counts: mut {string:integer} = {}
  local order: mut {string} = {}
  for _, reason in ipairs(reasons) do
    if counts[reason] == nil then order[#order + 1] = reason end
    counts[reason] = (counts[reason] or 0) + 1
  end
  table.sort(order)
  local lines: mut {string} = {}
  for _, reason in ipairs(order) do
    lines[#lines + 1] = "test: NOTHING TO CHECK  " .. plural.count(counts[reason], "test") ..
      " passed deliberately without checking: " .. reason
  end
  return lines
end

--- The line a fuzz property prints, in the output of the worker running it, when
--- it stops drawing inputs at its time limit (FUZZ_SECONDS, build/fuzz/init.tl);
--- the rest of the line is "<property> drew N of M inputs in S s ...".
function test_report.stopped_prefix(): string
  return "fuzz stopped: "
end

--- The one line that says which properties stopped drawing at their time
--- limit, sorted, or none when none did: what they drew of what was asked.
function test_report.stopped(entries: mut {string}): {string}
  table.sort(entries)
  if #entries == 0 then return {} end
  local names: mut {string} = {}
  for i, entry in ipairs(entries) do names[i] = entry:match("^(.-) in %d+ s") or entry end
  return { "test: fuzz: " .. plural.count(#entries, "property", "properties") ..
      " stopped by FUZZ_SECONDS: " .. table.concat(names, ", ") }
end

--- Each not applicable test with why, sorted as the skips are: its
--- module requires what this platform never has.
function test_report.nas(nas: mut {string}): {string}
  table.sort(nas)
  local lines: mut {string} = {}
  for _, na in ipairs(nas) do lines[#lines + 1] = "test: N/A  " .. na end
  return lines
end

--- Each failure with the hint its message earns ([`Errors.hint`]), its
--- rerun selector and the tail of what it printed.
--- The `<module> <name>: <message>` line keeps the shape CI reads.
function test_report.failures(failures: mut {test_report.Failure}, prefix: string): {string}
  table.sort(failures, function(a: test_report.Failure, b: test_report.Failure): boolean
    return a.message < b.message
  end)
  local lines: mut {string} = {}
  for _, failure in ipairs(failures) do
    -- The hint goes straight under the failure's own line, ahead of
    -- what the runner appended to the message (where its directory is
    -- kept).
    local head, rest = failure.message:match("^([^\n]*)\n?(.*)$")
    lines[#lines + 1] = "test: FAIL  " .. head
    local hint = Errors.hint(failure.message)
    if hint ~= nil then
      lines[#lines + 1] = "  hint: " .. hint
    end
    if rest ~= "" then
      lines[#lines + 1] = rest
    end
    local rerun = failure.rerun
    if rerun ~= nil then
      lines[#lines + 1] = "  rerun: " .. prefix .. "cosmic test " ..
        shell_word(rerun)
    end
    local printed = failure.printed
    if printed ~= nil then
      for _, line in ipairs(printed_lines(printed)) do lines[#lines + 1] = line end
    end
  end
  return lines
end

--- What passing tests printed (`cosmic test --show-output`), each test's id
--- on a line of its own and its output beneath it as a failure's is shown,
--- sorted by id.
function test_report.shown(shown: mut {test_report.Shown}): {string}
  table.sort(shown, function(a: test_report.Shown, b: test_report.Shown): boolean
    return a.id < b.id
  end)
  local lines: mut {string} = {}
  for _, one in ipairs(shown) do
    lines[#lines + 1] = "test: PASS  " .. one.id
    for _, line in ipairs(printed_lines(one.printed)) do lines[#lines + 1] = line end
  end
  return lines
end

--- What `--show-output` says of the `stood` tests that did not run, which
--- printed nothing: a verdict that stands is not run again.
function test_report.shown_note(stood: integer): string?
  if stood == 0 then return nil end
  return "test: show-output: " .. plural.count(stood, "test") .. " stood and so printed nothing; --all runs " ..
    (if stood == 1 then "it" else "them" end)
end

--- The relative paths of the tree that a failure's `message` says were not
--- found (`path: No such file or directory`), each once, in order: the ones
--- a sandboxed test may have been denied. An absolute path, a URL and a
--- path that leaves the tree are not.
function test_report.missing_relative_paths(message: string): {string}
  local found: mut {string} = {}
  local seen: mut {string:boolean} = {}
  local not_found = (sys.errno_message(sys.ENOENT):gsub("%p", "%%%0"))
  -- A path starts the message or follows a space, a quote or a parenthesis;
  -- the tail of a longer path or a URL (`//host/x`) never does.
  for path in ("\n" .. message):gmatch("[%s'\"(]([^%s:'\"/(][^%s:'\")]*)['\")]?: " .. not_found) do
    local leaves = false
    for part in path:gmatch("[^/]+") do
      if part == ".." then leaves = true end
    end
    if not leaves and seen[path] == nil then
      seen[path] = true
      found[#found + 1] = path
    end
  end
  return found
end

--- What a failure says of `path`, a file of the tree the test read without
--- declaring it: it is in the tree, not in the sandbox the test runs in.
function test_report.tree_hint(path: string): string
  return path .. " is not in this test's sandbox, though it is in the tree: grant it in " ..
    "Test.policy { grants = { { path = \"" .. path .. "\", letters = \"r\" } } } " ..
    "(see cosmic docs cosmic.test)"
end

--- Compilation and staging counts, including reuse from another checkout.
function test_report.build(counts: test_report.Build, elapsed: string): string
  return "build: " .. plural.count(counts.modules, "module") .. " (" .. tostring(counts.compiled) ..
    " compiled, " .. tostring(counts.cached) .. " cached" ..
    (if counts.shared > 0 then ", " .. tostring(counts.shared) .. " of them taken from another checkout" else "" end) ..
    (if (counts.parsed > 0 or counts.shared_parses > 0) then "; " ..
        plural.count(counts.parsed, "source") .. " parsed" ..
        (if counts.shared_parses > 0 then ", " .. tostring(counts.shared_parses) .. " taken from another checkout" else "" end) else "" end) ..
    "; " .. plural.count(counts.files, "file") .. " staged, " .. tostring(counts.read) .. " read) in " ..
    elapsed
end

--- The coverage line. Coverage is informational unless the run asked for a
--- floor (`floored`, `--min` or `--min-file`), which [`test_report.floor`]
--- holds it to; the runner separately enforces C-function entry.
function test_report.coverage(hit: integer, total: integer, floored?: boolean): string
  local percentage = if total > 0 then (hit * 100.0 / total) else 0.0 end
  local note = if floored ~= true then "; informational, never a failure" elseif total == 0 then
    "; no lines to cover, so a floor holds vacuously" else "" end
  return string.format("test: coverage %.1f%% (%d/%d %s%s)",
    percentage, hit, total, plural.noun(total, "line"), note)
end

--- The percentage `text` writes for the flag `flag`, from 0 to 100 with an
--- optional decimal part, or nil and why. The words `tonumber` takes beyond
--- that (hexadecimal, an exponent, `inf`, `nan`) are no percentage.
function test_report.percent(text: string, flag: string): number?, string
  local number = if text:match("^%d+$") or text:match("^%d+%.%d+$") then tonumber(text) else nil end
  if number == nil or number > 100 then
    return nil, flag .. " must be a percentage from 0 to 100, not " .. text
  end
  return number + 0.0, ""
end

--- Whether `hit` of `lines` is under the floor `least`, in percent: at the
--- floor is not under it. A run or file with no line to cover is under no
--- floor: there is nothing to reach.
local function under(hit: integer, lines: integer, least: number): boolean
  if lines == 0 then return false end
  return hit * 100.0 < least * lines
end

--- `hit` of `lines` as a percentage to one decimal, rounded down: a figure
--- the check found under a floor never prints as reaching it (1599/2000 is
--- 79.9%, not 80.0%).
local function shown(hit: integer, lines: integer): string
  if lines == 0 then return "0.0" end
  return string.format("%.1f", (hit * 1000 // lines) / 10)
end

--- What fell short of `floors` for a run that hit `hit` of `total` executable
--- lines, `files` among them: the total under `--min`, and each file of
--- `files` that has lines under `--min-file`, by path. Each is a failure
--- line, and the clause is what the summary carries.
function test_report.floor(hit: integer, total: integer, files: {test_report.FileLines},
                           floors: test_report.Floors): test_report.Shortfall
  local lines: mut {string} = {}
  local clauses: mut {string} = {}
  local min = floors.min
  if min ~= nil and under(hit, total, min) then
    lines[#lines + 1] = string.format("test: FAIL  coverage: %s%% (%d/%d %s) is under --min %g%%",
      shown(hit, total), hit, total, plural.noun(total, "line"), min)
    clauses[#clauses + 1] = string.format("%s%% under --min %g%%", shown(hit, total), min)
  end
  local least = floors.min_file
  if least ~= nil then
    local sorted: mut {test_report.FileLines} = {}
    for _, file in ipairs(files) do
      if file.lines > 0 and under(file.hit, file.lines, least) then sorted[#sorted + 1] = file end
    end
    table.sort(sorted, function(a: test_report.FileLines, b: test_report.FileLines): boolean
      return a.path < b.path
    end)
    for _, file in ipairs(sorted) do
      lines[#lines + 1] = string.format("test: FAIL  coverage: %s %s%% (%d/%d %s) is under --min-file %g%%",
        file.path, shown(file.hit, file.lines), file.hit, file.lines, plural.noun(file.lines, "line"), least)
    end
    if #sorted > 0 then
      clauses[#clauses + 1] = string.format("%s under --min-file %g%%", plural.count(#sorted, "file"), least)
    end
  end
  if #clauses == 0 then return { lines = lines, clause = "" } end
  return { lines = lines, clause = "coverage floor not met: " .. table.concat(clauses, ", ") }
end

--- A passing run's summary, after `test: `: an outcome a reader sees
--- at a glance, then the figures. A figure the summary adds goes after
--- `stood`: CI's driver reads the figures before it by their places
--- (ci/cosmic_ci/suite_output.tl).
function test_report.passed(counts: test_report.Passed, elapsed: string): string
  local unchecked, na = counts.unchecked or 0, counts.na or 0
  return plural.count(counts.total, "test") .. " passed in " ..
    plural.count(counts.modules, "module") .. "; " ..
    tostring(counts.ran) .. " ran, " .. tostring(counts.cached) .. " stood, " ..
    (if counts.skipped > 0 then (tostring(counts.skipped) .. " skipped (this host could not check " ..
      (if counts.skipped == 1 then "it" else "them" end) .. "), ") else "" end) ..
    (if unchecked > 0 then (tostring(unchecked) .. " made no call to assert, ") else "" end) ..
    (if na > 0 then (tostring(na) .. " n/a (this platform has none of what they check), ") else "" end) ..
    (if counts.every > 0 then (tostring(counts.every) .. " run every time (no key holds them), ") else "" end) ..
    (if counts.shared > 0 then (tostring(counts.shared) .. " of them on another checkout's verdict, ") else "" end) ..
    elapsed
end

--- A failing run's summary, after `test: `. The runner has already
--- decided failure before asking for it.
---
--- `not_run` counts the tests a bailing run (`cosmic test --bail`) never
--- started: they are in neither figure above, and are said last, after
--- what a reader of the figures by their places expects.
function test_report.failed(failures: integer, total: integer, errors: integer,
                            elapsed: string, not_run?: integer): string
  return tostring(failures) .. " of " .. plural.count(total, "test") .. " failed, " ..
    plural.count(errors, "infrastructure error") .. ", " .. elapsed ..
    (if (not_run or 0) > 0 then ("; " .. not_run .. " not run after the first failure") else "" end)
end

return test_report
