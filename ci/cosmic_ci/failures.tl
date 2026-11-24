--- The lines of a failed command that say what failed, said again where a
--- reader of the job finds them: as `::error::` annotations on the run's
--- page, on the job's summary page, and kept in
--- `$RUNNER_TEMP/cosmic-ci/failures.txt` for a step near the job's end
--- (`driver.tl failures`), which prints them there. The
--- log of a failed step is followed by those of the steps that clean up
--- after it, so its own last lines are far from the log's end. A command whose output
--- is kept in files and said once it ends is named while it runs
--- ([`Failures.begin`]), so that step says the end of what it said where the
--- job was ended under it (its time limit, a cancel).
local Context = require("cosmic_ci.context")
local Fs = require("cosmic.fs")
local Seams = require("cosmic_ci.seams")

local record Failures
end

--- At most this many lines are kept of one command, the first ones.
local limit <const> = 40

--- At most this many of them become annotations: GitHub shows 10 errors
--- of a step.
local annotated <const> = 10

--- A line longer than this is cut, so that one long line cannot fill the
--- summary page.
local width <const> = 400

--- Patterns of a line that says what failed: a test's or the tree
--- check's verdict (build/test_report.tl, build/fix/init.tl), a finding
--- of the checker or of a C compiler (`file:line:column: ...`), of the
--- linker or of git, and a refusal of the tool itself.
local patterns <const>: {string} = {
  "^test: FAIL  ",
  "^test: ERROR  ",
  "^fix: FAIL  ",
  "^error: ",
  "^[^%s:]+:%d+:%d+: error: ",
  "^[^%s:]+:%d+:%d+: fatal error: ",
  "^ld%.lld: error: ",
  "^fatal: ",
  "^[^%s:]+%.tl:%d+:%d+: .-%(%l[%l%d_]*%)",
  "a C function no test enters",
  "^cosmic: .*refused",
  "^cosmic: .*did not compile",
  "^cosmic: boot: ",
}

local function failing(line: string): boolean
  for _, pattern in ipairs(patterns) do
    if line:find(pattern) then return true end
  end
  return false
end

--- The lines of `text` that say what failed, in order, each once, up to
--- `limit` of them, each cut at `width`.
function Failures.pick(text: string): {string}
  local picked: mut {string} = {}
  local seen: mut {string:boolean} = {}
  for line in text:gmatch("[^\n]+") do
    local plain = line:gsub("\r$", "")
    if failing(plain) and seen[plain] == nil then
      seen[plain] = true
      if #plain > width then
        -- Cut before a continuation byte, so no UTF-8 character is cut in half.
        local cut = width
        while cut > 0 and (plain:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
        plain = plain:sub(1, cut) .. "..."
      end
      picked[#picked + 1] = plain
      if #picked == limit then break end
    end
  end
  return picked
end

--- Where the job keeps the lines, beside the operations database.
function Failures.path(): string
  return (Context.database():gsub("operations%.db$", "failures.txt"))
end

--- An annotation's text: GitHub ends one at a newline, and reads `%` as
--- the start of an escape.
local function escaped(text: string): string
  return (text:gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A"))
end

--- An annotation's property: escaped, and its `:` and `,` too, which
--- end a property.
local function property(text: string): string
  return (escaped(text):gsub(":", "%%3A"):gsub(",", "%%2C"))
end

--- Says again the lines of `text` that say why `phase` failed: as
--- annotations on stdout and on the summary page, in a job of GitHub
--- Actions, and in [`Failures.path`]. Says nothing when no line
--- matches. A line that cannot be said fails nothing: the command's own
--- status decides the step.
function Failures.keep(phase: string, text: string)
  local lines = Failures.pick(text)
  if #lines == 0 then return end
  local seams = Seams.calls()
  local actions = seams.env_get("GITHUB_ACTIONS") == "true"
  local said = "\n" .. phase .. " failed; what it said of that:\n"
  for index, line in ipairs(lines) do
    said = said .. line .. "\n"
    if actions and index <= annotated then
      local _, _ = seams.fs_put(Fs.stdout, "::error title=" .. property(phase) .. "::" .. escaped(line) .. "\n")
    end
  end
  if actions then
    -- A fence longer than any run of backticks a kept line holds.
    local fence = "```"
    for _, line in ipairs(lines) do
      for run in line:gmatch("`+") do
        if #run >= #fence then fence = string.rep("`", #run + 1) end
      end
    end
    local _, _ = pcall(Context.summarize, "\n**" .. phase .. " failed:**\n\n" .. fence .. "\n" ..
        table.concat(lines, "\n") .. "\n" .. fence .. "\n")
  end
  local _, _ = pcall(function()
    assert(seams.fs_append(Failures.path(), said))
  end)
end

--- Where the job names the commands that are running with their output
--- in files, one file each, beside the operations database.
local function running_directory(): string
  return (Context.database():gsub("operations%.db$", "running"))
end

--- How many commands this process has named as running, which names the
--- next one's file.
local record Named
  mut count: integer
end
local named: Named = { count = 0 }

--- Names `phase` as running, its output going to the files `out` and
--- `err`, until [`Failures.done`] is given what this returns. Several
--- can run at once (the fixtures' lanes). A name that cannot be written
--- fails nothing, and returns a name `done` ignores.
function Failures.begin(phase: string, out: string, err: string): string
  named.count = named.count + 1
  local directory = running_directory()
  local name = directory .. "/" .. tostring(named.count)
  local _, _ = pcall(function()
    assert(Fs.mkdirs(directory))
    assert(Fs.write(name, phase .. "\n" .. out .. "\n" .. err .. "\n"))
  end)
  return name
end

--- Says the command [`Failures.begin`] named `name` for is not running any more.
function Failures.done(name: string)
  local _, _ = Fs.remove(name)
end

--- Runs `run` with `phase` named as running ([`Failures.begin`]), and
--- names it no more once `run` returns or raises.
function Failures.during(phase: string, out: string, err: string, run: function())
  local name = Failures.begin(phase, out, err)
  local ran, why = pcall(run)
  Failures.done(name)
  if not ran then error(why, 0) end
end

--- How many of the last lines of a running command's files
--- [`Failures.command`] says, and the most bytes of them.
local tail_lines <const> = 100
local tail_bytes <const> = 16384

--- The last `tail_lines` lines of `text`, of at most `tail_bytes` bytes.
local function tail(text: string): string
  local cut = text:sub(-tail_bytes)
  local starts: mut {integer} = {}
  local at = 1
  while at <= #cut do
    starts[#starts + 1] = at
    local newline = cut:find("\n", at, true)
    if newline == nil then break end
    at = newline + 1
  end
  local from = math.max(1, #starts - tail_lines + 1)
  -- A window cut from a longer text starts mid-line: it starts at its
  -- second line where it has one.
  if from == 1 and #cut < #text and #starts > 1 then from = 2 end
  return cut:sub(starts[from] or 1)
end

--- `driver.tl failures`: prints what [`Failures.keep`] kept, in a step
--- near the job's end, so a reader of the log's end finds why the job failed, and
--- the end of what a command said where the job was ended while it ran.
function Failures.command(_words: {string}): integer
  local seams = Seams.calls()
  local text, _ = seams.fs_read(Failures.path())
  local said: string
  if text == nil or text == "" then
    said = "failures: no step kept a line that says what failed; read the failed step's log\n"
  else
    said = "failures: what the failed steps said of it, again:\n" .. text
  end
  local names, _ = Fs.list(running_directory())
  local numbered: mut {integer} = {}
  for _, name in ipairs(names or {}) do
    local n = math.tointeger(tonumber(name))
    if n ~= nil then numbered[#numbered + 1] = n end
  end
  table.sort(numbered)
  for _, n in ipairs(numbered) do
    local running, _ = seams.fs_read(running_directory() .. "/" .. tostring(n))
    local phase, out, err = (running or ""):match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n$")
    if phase ~= nil and out ~= nil and err ~= nil then
      said = said .. "failures: the job was ended while " .. phase .. " ran; the end of what it said:\n"
      for _, path in ipairs({ out, err }) do
        local kept, _ = seams.fs_read(path)
        if kept ~= nil and kept ~= "" then
          said = said .. tail(kept) .. (if kept:sub(-1) == "\n" then "" else "\n" end)
        end
      end
    end
  end
  local _, _ = seams.fs_put(Fs.stdout, said)
  return 0
end

return Failures
