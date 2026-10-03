--- Presentation for the test runner. Inputs are fresh snapshots of strings
--- and counts; no job, verdict, database or cache is handed to this module.
--- The runner decides outcomes and exit codes independently of these strings.

local String = require("cosmic.string")
local plural = require("build.plural")

local record test_report
  record Failure
    message: string
    rerun: string | nil
    printed: string | nil
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

--- Each skipped test with its reason, sorted as the failure list is.
function test_report.skips(skips: {string}): {string}
  table.sort(skips)
  local lines: {string} = {}
  for _, skip in ipairs(skips) do lines[#lines + 1] = "test: SKIP  " .. skip end
  return lines
end

--- Each failure with its rerun selector and the tail of what it printed.
--- The `<module> <name>: <message>` line keeps the shape CI reads.
function test_report.failures(failures: {test_report.Failure}, prefix: string): {string}
  table.sort(failures, function(a: test_report.Failure, b: test_report.Failure): boolean
    return a.message < b.message
  end)
  local lines: {string} = {}
  for _, failure in ipairs(failures) do
    lines[#lines + 1] = "test: FAIL  " .. failure.message
    if failure.rerun ~= nil then
      lines[#lines + 1] = "  rerun: " .. prefix .. "cosmic test " ..
        shell_word(failure.rerun)
    end
    local printed = failure.printed
    if printed ~= nil then
      if #printed > 4096 then printed = "..." .. printed:sub(-4096) end
      for line in String.lines((printed:gsub("\n$", ""))) do
        lines[#lines + 1] = "  | " .. line
      end
    end
  end
  return lines
end

--- Compilation and staging counts, including reuse from another checkout.
function test_report.build(counts: test_report.Build, elapsed: string): string
  return "build: " .. plural.count(counts.modules, "module") .. " (" .. counts.compiled ..
    " compiled, " .. counts.cached .. " cached" ..
    (counts.shared > 0 and ", " .. counts.shared .. " of them taken from another checkout" or "") ..
    ((counts.parsed > 0 or counts.shared_parses > 0) and "; " ..
      plural.count(counts.parsed, "source") .. " parsed" ..
      (counts.shared_parses > 0 and ", " .. counts.shared_parses .. " taken from another checkout" or "") or "") ..
    "; " .. plural.count(counts.files, "file") .. " staged, " .. counts.read .. " read) in " ..
    elapsed
end

--- Coverage is informational; the runner separately enforces C-function entry.
function test_report.coverage(hit: integer, total: integer): string
  local percentage = total > 0 and (hit * 100.0 / total) or 0.0
  return string.format("test: coverage %.1f%% (%d/%d %s; informational, never a failure)",
    percentage, hit, total, plural.noun(total, "line"))
end

--- A figure the summary adds goes after `stood`: CI's driver reads the
--- figures before it by their places (ci/cosmic_ci/suite_output.tl).
function test_report.passed(counts: test_report.Passed, elapsed: string): string
  return plural.count(counts.total, "test") .. ", " ..
    plural.count(counts.modules, "module") .. "; " ..
    counts.ran .. " ran, " .. counts.cached .. " stood, " ..
    (counts.skipped > 0 and (counts.skipped .. " skipped (this host could not check " ..
      (counts.skipped == 1 and "it" or "them") .. "), ") or "") ..
    (counts.every > 0 and (counts.every .. " run every time (no key holds them), ") or "") ..
    (counts.shared > 0 and (counts.shared .. " of them on another checkout's verdict, ") or "") ..
    elapsed
end

--- The runner has already decided failure before asking for its summary.
function test_report.failed(failures: integer, total: integer, errors: integer,
                            elapsed: string): string
  return failures .. " of " .. total .. " failed, " ..
    plural.count(errors, "infrastructure error") .. ", " .. elapsed
end

return test_report
