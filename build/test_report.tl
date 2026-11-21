--- Presentation for the test runner. Inputs are fresh snapshots of strings
--- and counts; no job, verdict, database or cache is handed to this module.
--- The runner decides outcomes and exit codes independently of these strings.

local Errors = require("cosmic.errors")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local plural = require("build.plural")

--- A reason some tests gave for passing without checking, and how many gave it.
local record Tally
  reason: string
  count: integer
end

local record test_report
  --- Why a module's standing hits were dropped, in `stale` ([`build.test`]'s `decode_hits`), where they were numbered
  --- in a text other than the run's: what follows "hits of" a module, or "its hits".
  other_text: string

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

  --- Where a run's time went ([`test_report.time`]), in nanoseconds: the four stretches of the run in order, and of
  --- the stretch its tests ran in, what this process spent starting each worker and recording it, during which it
  --- starts and collects no other, and the tests' own time as their workers reported it, summed over the `ran` of
  --- them, `workers` at a time.
  record Spent
    mut building_ns: integer
    mut keying_ns: integer
    mut running_ns: integer
    mut settling_ns: integer
    mut starting_ns: integer
    mut recording_ns: integer
    mut tests_ns: integer
    mut ran: integer
    mut workers: integer
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

--- How many bytes of what a failing test printed are shown, the newest ones.
local printed_most <const> = 4096

--- What a test printed as `  | ` lines: all of it where `whole`, as a run that asked for it shows it, else its last
--- `printed_most` bytes under a line that says so.
local function printed_lines(printed: string, whole?: boolean): {string}
  local lines: mut {string} = {}
  if whole ~= true and #printed > printed_most then
    lines[1] = "  | (cut to its last " .. plural.count(printed_most, "byte") .. ": it printed " .. plural.count(#printed, "byte") .. ")"
    printed = printed:sub(-printed_most)
  end
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
  if #lines > 0 then
    lines[#lines + 1] = "  hint: a test that cannot check its subject here calls Test.skip(reason) of cosmic.test, and is listed as " ..
      "skipped; one that returns early passes unchecked"
  end
  return lines
end

--- One line for each reason some tests gave [`Test.passed_unchecked`], with
--- how many gave it, sorted: they passed deliberately without checking.
function test_report.deliberate(reasons: {string}): {string}
  local counts: mut {string:integer} = {}
  for _, reason in ipairs(reasons) do
    local seen = counts[reason]
    counts[reason] = if seen == nil then 1 else seen + 1 end
  end
  local order: mut {Tally} = {}
  for reason, count in pairs(counts) do order[#order + 1] = { reason = reason, count = count } end
  table.sort(order, function(a: Tally, b: Tally): boolean
    return a.reason < b.reason
  end)
  local lines: mut {string} = {}
  for _, row in ipairs(order) do
    lines[#lines + 1] = "test: NOTHING TO CHECK  " .. plural.count(row.count, "test") ..
      " passed deliberately without checking: " .. row.reason
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

--- `failures` with the tests of each module that failed to load folded into one failure of that module: each of its
--- tests failed for one cause, which ran at the module's top level, outside every test. The cause is the first test's
--- (sorted by name), since a load's text may differ from test to test (a path under each worker's own directory). The
--- folded failure names the tests, says where the cause ran, and is rerun by the module's file.
local function unloaded(failures: {test_report.Failure}): {test_report.Failure}
  local record Group
    module: string
    mut first: test_report.Failure
    mut cause: string
    mut first_name: string
    names: mut {string}
  end
  local out: mut {test_report.Failure} = {}
  local groups: mut {string: Group} = {}
  local order: mut {Group} = {}
  for _, failure in ipairs(failures) do
    local module, name, cause = failure.message:match("^(%S+) (%S+): (the module failed to load: .*)$")
    if module ~= nil and name ~= nil and cause ~= nil then
      local group = groups[module]
      if group == nil then
        local made: Group = { module = module, first = failure, cause = cause, first_name = name, names = {} }
        groups[module] = made
        order[#order + 1] = made
        group = made
      elseif name < group.first_name then
        group.first, group.cause, group.first_name = failure, cause, name
      end
      group.names[#group.names + 1] = name
    else
      out[#out + 1] = failure
    end
  end
  for _, group in ipairs(order) do
    local names, first, cause = group.names, group.first, group.cause
    table.sort(names)
    local newline = cause:find("\n", 1, true)
    local head = if newline == nil then cause else cause:sub(1, newline - 1) end
    local rest = if newline == nil then "" else cause:sub(newline) end
    local rerun = first.rerun
    local none = if #names == 1 then "its test did not run (" else "none of its " .. plural.count(#names, "test") .. " ran (" end
    out[#out + 1] = {
      message = group.module .. ": " .. head .. "\n  " .. none .. table.concat(names, ", ") ..
        "): what failed ran as the module loaded, at its top level and outside every test; move it into a test " ..
        "or a function the tests call" .. rest,
      rerun = if rerun ~= nil then (rerun:gsub(":[^:/]*$", "")) else nil end,
      printed = first.printed,
    }
  end
  return out
end

--- Each failure with the hint its message earns ([`Errors.hint`]), its
--- rerun selector and the tail of what it printed.
--- A failure's line is `test: FAIL  <module> <name>: <message>`, the shape CI reads, or `<module>: <message>` for a
--- module that failed to load (CI reads the `test: FAIL` alone).
function test_report.failures(given: {test_report.Failure}, prefix: string): {string}
  local failures: mut {test_report.Failure} = {}
  for _, failure in ipairs(unloaded(given)) do failures[#failures + 1] = failure end
  table.sort(failures, function(a: test_report.Failure, b: test_report.Failure): boolean
    return a.message < b.message
  end)
  local lines: mut {string} = {}
  for _, failure in ipairs(failures) do
    -- The hint goes straight under the failure's own line, ahead of
    -- what the runner appended to the message (where its directory is
    -- kept).
    local newline = failure.message:find("\n", 1, true)
    local head = if newline == nil then failure.message else failure.message:sub(1, newline - 1) end
    local rest = if newline == nil then "" else failure.message:sub(newline + 1) end
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
    for _, line in ipairs(printed_lines(one.printed, true)) do lines[#lines + 1] = line end
  end
  return lines
end

--- What a run without `--show-output` says of the `printed` tests that ran, passed and printed something: their output is
--- shown only for a failure, and a reader who printed to look at a value finds the flag here.
function test_report.unshown_note(printed: integer): string?
  if printed == 0 then return nil end
  return "test: " .. plural.count(printed, "passing test") .. " that ran printed output, which --show-output shows"
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
--- declaring it: it is in the tree, not in the sandbox the test runs in. A
--- file in a directory is told the directory's grant too, for a test that
--- reads more of it.
function test_report.tree_hint(path: string): string
  local dir = path:match("^(.+)/[^/]+$")
  return path .. " is not in this test's sandbox, though it is in the tree: grant it in " ..
    "Test.policy { grants = { { path = \"" .. path .. "\", letters = \"r\" } } }" ..
    (if dir ~= nil then ", or, for a test that reads more of " .. dir .. "/, grant the directory: " ..
        "{ path = \"" .. dir .. "/\", letters = \"r\" }" else "" end) ..
    " (see cosmic docs cosmic.test)"
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

test_report.other_text = "came from runs on other text"

--- How many modules `stale` names: those whose standing hits a run dropped,
--- each with why ([`build.test`]'s `decode_hits`).
local function modules_left_out(stale: {string:string}): integer
  local count = 0
  for _ in pairs(stale) do count = count + 1 end
  return count
end

--- How many modules dropped for another reason than another text [`partial_note`] names.
local named_kept <const> = 3

--- What the coverage line and a floor's failure say of a figure missing the
--- hits of the modules `stale` names, after a "; ": how many, and of each
--- dropped for another reason than [`test_report.other_text`], which and why.
local function partial_note(stale: {string:string}): string
  -- A few named are enough to start on; a mass of them would make one enormous coverage line.
  local partial = modules_left_out(stale)
  local others: mut {string} = {}
  for path, why in pairs(stale) do
    if why ~= test_report.other_text then others[#others + 1] = path end
  end
  if #others == 0 then
    return "partial: hits of " .. plural.count(partial, "module") .. " " .. test_report.other_text ..
      "; `--all` reruns them"
  end
  table.sort(others)
  local parts: mut {string} = {}
  if #others < partial then
    parts[1] = tostring(partial - #others) .. " " .. test_report.other_text
  end
  for index, path in ipairs(others) do
    if index > named_kept then
      parts[#parts + 1] = "and " .. tostring(#others - named_kept) .. " more"
      break
    end
    parts[#parts + 1] = "the hits of " .. path .. " " .. assert(stale[path], "a listed path is in stale")
  end
  return "partial: hits of " .. plural.count(partial, "module") .. " are left out (" ..
    table.concat(parts, "; ") .. "); `--all` reruns them"
end

--- The most decimals a floor may have: a figure held to it prints to as
--- many ([`places`]), and the check compares in millionths of a percent
--- ([`under`]), so each is exact.
local MOST_DECIMALS <const> = 4

--- The percentage `text` writes for the flag `flag`, from 0 to 100 with an
--- optional decimal part of at most [`MOST_DECIMALS`] digits, or nil and
--- why. The words `tonumber` takes beyond that (hexadecimal, an exponent,
--- `inf`, `nan`) are no percentage.
function test_report.percent(text: string, flag: string): number?, string
  local number = if text:match("^%d+$") or text:match("^%d+%.%d+$") then tonumber(text) else nil end
  if number == nil or number > 100 then
    return nil, flag .. " must be a percentage from 0 to 100, not " .. text
  end
  local decimals = text:match("%.(%d+)$")
  if decimals ~= nil and #decimals > MOST_DECIMALS then
    return nil, flag .. " takes at most " .. plural.count(MOST_DECIMALS, "decimal") .. ", which a figure prints to " ..
      "and the check compares exactly, not " .. text
  end
  return number + 0.0, ""
end

--- Whether `hit` of `lines` is under the floor `least`, in percent: at the
--- floor is not under it. A run or file with no line to cover is under no
--- floor: there is nothing to reach. The floor is compared in millionths of a
--- percent, as integers: `least * lines` in floating point rounds `64.4 * 250`
--- above 16100, which would put a file exactly at the floor under it.
local function under(hit: integer, lines: integer, least: number): boolean
  if lines == 0 then return false end
  return hit * 100000000 < math.floor(least * 1000000 + 0.5) * lines
end

--- 10 to the power of each count of decimals a figure prints with, 1 to
--- [`MOST_DECIMALS`].
local SCALES <const>: {integer} = { 10, 100, 1000, 10000 }

--- How many decimals a figure held to `floor` shows: as many as the floor
--- has, and one at least, so a figure under a floor of 97.35 shows 97.34,
--- never 97.3. A floor has at most [`MOST_DECIMALS`] ([`test_report.percent`]).
local function places(floor?: number): integer
  if floor == nil then return 1 end
  for decimals, scale in ipairs(SCALES) do
    local scaled = floor * scale
    if math.abs(scaled - math.floor(scaled + 0.5)) < 1e-6 then return decimals end
  end
  return MOST_DECIMALS
end

--- `hit` of `lines` as a percentage to `decimals` decimals (1 to
--- [`MOST_DECIMALS`]), rounded down: a figure the check found under a floor
--- never prints as reaching it (1599/2000 is 79.9%, not 80.0%). Worked in
--- integers, so no figure rounds up in its printing.
local function shown(hit: integer, lines: integer, decimals: integer): string
  local scale = assert(SCALES[decimals], "a figure prints with 1 to MOST_DECIMALS decimals")
  local scaled = if lines == 0 then 0 else hit * 100 * scale // lines end
  return tostring(scaled // scale) .. "." .. string.format("%0" .. tostring(decimals) .. "d", scaled % scale)
end

--- The coverage line. Coverage is informational unless the run asked for a
--- floor (`floors`, `--min` or `--min-file`), which [`test_report.floor`]
--- holds it to; the runner separately enforces C-function entry. Its figure
--- is the one a failure under `--min` prints ([`shown`]): rounded down, to
--- as many decimals as that floor has, one at least. A figure that left out
--- the standing hits of the modules `stale` names says so: it is at most what the
--- tests reach.
function test_report.coverage(hit: integer, total: integer, floors?: test_report.Floors,
                              stale?: {string:string}): string
  local note = if floors == nil then "; informational, never a failure" elseif total == 0 then
    "; no lines to cover, so a floor holds vacuously" else "" end
  if stale ~= nil and next(stale) ~= nil then note = note .. "; " .. partial_note(stale) end
  return string.format("test: coverage %s%% (%d/%d %s%s)",
    shown(hit, total, places(if floors ~= nil then floors.min else nil end)), hit, total, plural.noun(total, "line"), note)
end

--- What fell short of `floors` for a run that hit `hit` of `total` executable
--- lines, `files` among them: the total under `--min`, and each file of
--- `files` that has lines under `--min-file`, by path. Each is a failure
--- line, and the clause is what the summary carries.
---
--- `stale` names the modules whose standing hits the run dropped, each with
--- why (most numbered in another text): a figure without them is at most the true one, so one at a
--- floor is met, and one under it fails all the same, its line and clause
--- saying the figure is partial, since only a run of those tests (`--all`)
--- has the figure a floor can pass or fail on.
function test_report.floor(hit: integer, total: integer, files: {test_report.FileLines},
                           floors: test_report.Floors, stale?: {string:string}): test_report.Shortfall
  local lines: mut {string} = {}
  local clauses: mut {string} = {}
  local dropped = stale or {}
  local partial = modules_left_out(dropped)
  local min = floors.min
  if min ~= nil and under(hit, total, min) then
    local note = if partial > 0 then "; " .. partial_note(dropped) else "" end
    lines[#lines + 1] = string.format("test: FAIL  coverage: %s%% (%d/%d %s%s) is under --min %g%%",
      shown(hit, total, places(min)), hit, total, plural.noun(total, "line"), note, min)
    clauses[#clauses + 1] = string.format("%s%% under --min %g%%%s", shown(hit, total, places(min)), min,
      if partial > 0 then " on a partial figure" else "" end)
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
    local partial_files = 0
    for _, file in ipairs(sorted) do
      local note = ""
      local why = dropped[file.path]
      if why ~= nil then
        partial_files = partial_files + 1
        note = "; partial: its hits " .. why .. "; `--all` reruns them"
      end
      lines[#lines + 1] = string.format("test: FAIL  coverage: %s %s%% (%d/%d %s%s) is under --min-file %g%%",
        file.path, shown(file.hit, file.lines, places(least)), file.hit, file.lines, plural.noun(file.lines, "line"), note, least)
    end
    if #sorted > 0 then
      clauses[#clauses + 1] = string.format("%s under --min-file %g%%%s", plural.count(#sorted, "file"), least,
        if partial_files > 0 then " (" .. tostring(partial_files) .. " on a partial figure)" else "" end)
    end
  end
  if #clauses == 0 then return { lines = lines, clause = "" } end
  return { lines = lines, clause = "coverage floor not met: " .. table.concat(clauses, ", ") }
end

--- A [`test_report.Spent`] with nothing spent.
function test_report.unspent(): test_report.Spent
  return { building_ns = 0, keying_ns = 0, running_ns = 0, settling_ns = 0, starting_ns = 0, recording_ns = 0,
    tests_ns = 0, ran = 0, workers = 0 }
end

--- `ns` as seconds to a tenth, as the `time` line says each of its figures.
local function seconds(ns: integer): string
  return string.format("%.1f s", ns / 1e9)
end

--- A run's `time` line, after `test: `: where its time went, in the order it went there, so that the time of the
--- tests is told from the time around them. A run that ran none says nothing of workers.
function test_report.time(spent: test_report.Spent): string
  local running = "running " .. seconds(spent.running_ns)
  if spent.ran > 0 then
    running = running .. " (" .. seconds(spent.tests_ns) .. " in " .. plural.count(spent.ran, "test") .. ", up to " ..
      tostring(spent.workers) .. " at a time; the runner " .. seconds(spent.starting_ns) .. " starting their workers and " ..
      seconds(spent.recording_ns) .. " recording them)"
  end
  return "time: building " .. seconds(spent.building_ns) .. ", keying " .. seconds(spent.keying_ns) .. ", " .. running ..
    ", settling coverage and records " .. seconds(spent.settling_ns)
end

--- A passing run's summary, after `test: `: an outcome a reader sees
--- at a glance, then the figures. A figure the summary adds goes after
--- `stood`: CI's driver reads the figures before it by their places
--- (ci/cosmic_ci/suite_output.tl). A run where none ran and some stood
--- says why, and how to run them, last of the figures.
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
    (if counts.ran == 0 and counts.cached > 0 then (if counts.cached == 1 then
      "none ran, as nothing the test that stood is keyed on changed since its verdict (--all runs it), " else
      "none ran, as nothing the tests that stood are keyed on changed since their verdicts (--all runs them), " end)
      else "" end) ..
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
    (if not_run ~= nil and not_run > 0 then ("; " .. tostring(not_run) .. " not run after the first failure") else "" end)
end

return test_report
