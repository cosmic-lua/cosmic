--- `check-islands`, which type-checks the bootstrap scripts, the files of `build/` that `bin/cosmic-bootstrap` runs
--- on the release ci/cosmic-driver.pin names, in the new checker's grammar (it sets COSMIC_GRAMMAR=new), on that
--- release, the one running this driver:
---
---     cosmic-driver cosmic_ci/driver.tl check-islands [ROOT]
---
--- ROOT is the checkout (default `..`, as CI runs the driver from `ci/`). The scripts are the ones [`Islands.scripts`]
--- finds by reading the checkout for what runs a file `--standalone` on `bin/cosmic-bootstrap`, and the standalone runs
--- of `build/zig.tl`, so a new runner is checked with no list to edit. Each is run
--- standalone as the bootstrap runs it, with `--help`, so that the release reads it in the new grammar and holds it to
--- its checker with the standard library it carries and no ceiling: a script that has a finding is refused before
--- it runs and says so on standard error as `file:line:column: message`, and one that has none prints its usage.
--- `compile --grammar new` is not used: a lone file has no `cosmic.*` module to read (each is typed `invalid`), and the
--- globals come from declaration files the release's own standalone does not read, so what it finds is not what the
--- scripts meet.
--
-- TODO: stop running the scripts, once ci/cosmic-driver.pin names a release whose `compile --grammar new` types the
-- `cosmic.*` modules it carries: `build/zig.tl --help` is zig's own, which needs zig installed, where a compile would
-- need nothing.
local BuildPaths = require("cosmic_ci.build_paths")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")
local String = require("cosmic.string")

local record Islands
  --- What `check` found: the complaints, and how many files were checked.
  record Report
    complaints: {string}
    checked: integer
  end

  --- A Teal file the pinned release runs standalone, by its path from the root of the checkout, and the files that
  --- run it: the wrappers of `bin/` and `eval/`, or `build/zig.tl`.
  record Script
    path: string
    wrappers: {string}
  end

  --- The exit status of `--help` for each script that does not give 0.
  mut help_exits: {string:integer}

  --- The directories [`Islands.scripts`] does not read.
  mut left_out: {string:boolean}
end

--- The exit status each script gives `--help`, where it is not 0: the scripts that answer a usage error (`patch`,
--- `zig_fetch`, and the scripts of `eval/`, which take arguments) and those that print usage and fail (`paths`, `perf`,
--- and `summarize`, which takes it for a file). Any other status is a crash the check must not take for a clean script.
Islands.help_exits = {
  ["build/patch.tl"] = 2, ["build/paths.tl"] = 1, ["build/perf.tl"] = 1, ["build/zig_fetch.tl"] = 2,
  ["eval/arena.tl"] = 2, ["eval/check/grade.tl"] = 2, ["eval/result.tl"] = 2, ["eval/round.tl"] = 2,
  ["eval/solve.tl"] = 2, ["eval/summarize.tl"] = 1,
}

--- The directories the scan of [`Islands.scripts`] leaves out, by path from the root, with why: `.git` and `vendor/`
--- (third-party trees, edited only by patch records), `o/` (a stale build directory, never read) and `ci/`, a
--- project of its own that `cosmic-driver test cosmic_ci` compiles on the pinned release, as ci/README.md says, so
--- ci/run-local's `ci/run_local.tl` is held to it there, where a run with `--help` would start the platform job.
Islands.left_out = { [".git"] = true, vendor = true, o = true, ci = true }

--- Where a file is `--standalone` run on the bootstrap, in the text after `--standalone`: a shell word
--- `"$root/<file>.tl"`, or Teal `root .. "/<file>.tl"`.
local function standalone_file(after: string): string?
  return after:match('"%$root/([%w_/%.%-]+%.tl)"') or after:match('root %.%. "/([%w_/%.%-]+%.tl)"')
end

--- Whether `line` is a comment of a shell, YAML, Lua or Teal file.
local function is_comment(line: string): boolean
  return line:find("^%s*#") ~= nil or line:find("^%s*%-%-") ~= nil
end

--- The `standalone(root, "<file>.tl", ...)` calls of build/zig.tl, which run `<file>` on the pinned release's binary,
--- by path. Nil with why where a call is not one this reads: its file not a string literal on the call's
--- own line, which would leave the file unchecked. Every call site is counted, not only the ones that match.
local function zig_runs(zig: string): {string}?, string
  local runs: mut {string} = {}
  local number = 0
  for line in (zig .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    if not is_comment(line) and line:find("function standalone%(") == nil then
      local calls = select(2, (" " .. line):gsub("[^%w_]standalone%(", ""))
      local found = 0
      for file in line:gmatch('standalone%(root, "([%w_/%.%-]+%.tl)"') do
        runs[#runs + 1] = file
        found = found + 1
      end
      if calls ~= found then
        return nil, "build/zig.tl:" .. tostring(number) .. ": calls standalone( with a file that is not a string literal " ..
          "on that line, which would leave it unchecked; write it as standalone(root, \"build/<file>.tl\", ...)"
      end
    end
  end
  return runs, ""
end

--- The scripts the pinned release runs, found where they say so. Every file of the checkout (but [`Islands.left_out`],
--- binary files and Markdown, which only describes) is read for a line, other than a comment, that names
--- `bin/cosmic-bootstrap`: where it and the two lines after it have `--standalone` it must give the file run there
--- (`"$root/<file>.tl"` in a shell script, `root .. "/<file>.tl"` in Teal), and one that does not is refused. A file of
--- `bin/` or `eval/` that names the bootstrap with no `--standalone` is refused too, whatever its first line says, so
--- that no wrapper escapes the check; elsewhere such a line is a verb that runs no file (`compile`), a cache key or a
--- sparse checkout. `build/zig.tl` runs `build/patch.tl` and `build/zig_fetch.tl` on that release's binary, which
--- zig_runs reads. The scripts are in the order of their paths. Nil with why where a file cannot be read, a line
--- is of a form this cannot read, or none is found.
function Islands.scripts(root: string): {Islands.Script}?, string
  local found: mut {string:mut {string}} = {}
  local function add(path: string, wrapper: string)
    local known = found[path]
    if known ~= nil then
      known[#known + 1] = wrapper
    else
      found[path] = { wrapper }
    end
  end
  local files, walk_why = Fs.walk(root, function(relative: string, _: string, kind: Fs.Kind): boolean
    return kind == "dir" and Islands.left_out[relative] == true
  end)
  if files == nil then return nil, walk_why end
  for _, file in ipairs(files) do
    local text, read_why = Fs.read(root .. "/" .. file)
    if text == nil then return nil, file .. ": " .. tostring(read_why) end
    -- bin/cosmic-bootstrap is the script they all exec, not a wrapper of one.
    if file ~= "bin/cosmic-bootstrap" and file:sub(-3) ~= ".md" and text:find("\0", 1, true) == nil and
        text:find("cosmic-bootstrap", 1, true) ~= nil then
      local lines: mut {string} = {}
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
      for number, line in ipairs(lines) do
        if line:find("cosmic-bootstrap", 1, true) ~= nil and not is_comment(line) then
          local window = line .. "\n" .. (lines[number + 1] or "") .. "\n" .. (lines[number + 2] or "")
          local at = window:find("--standalone", 1, true)
          if at ~= nil then
            local path = standalone_file(window:sub(at))
            if path == nil then
              return nil, file .. ":" .. tostring(number) .. ": runs a file standalone on bin/cosmic-bootstrap in a " ..
                "form check-islands cannot read, which would leave it unchecked; write it as `exec " ..
                "\"$root/bin/cosmic-bootstrap\" --standalone \"$root/<file>.tl\" ...` in a shell script, or " ..
                "`root .. \"/<file>.tl\"` after `--standalone` in Teal: " .. String.trim(line)
            end
            add(path, file)
          elseif file:find("^bin/") ~= nil or file:find("^eval/") ~= nil then
            return nil, file .. ":" .. tostring(number) .. ": names bin/cosmic-bootstrap without --standalone, " ..
              "so check-islands cannot tell which file it runs on the pinned release; write it as `exec " ..
              "\"$root/bin/cosmic-bootstrap\" --standalone \"$root/<file>.tl\" ...`: " .. String.trim(line)
          end
        end
      end
    end
  end
  local zig, zig_why = Fs.read(root .. "/build/zig.tl")
  if zig == nil then return nil, "build/zig.tl: " .. tostring(zig_why) end
  local runs, runs_why = zig_runs(zig)
  if runs == nil then return nil, runs_why end
  for _, run in ipairs(runs) do add(run, "build/zig.tl") end
  local scripts: mut {Islands.Script} = {}
  for path, wrappers in pairs(found) do
    scripts[#scripts + 1] = { path = path, wrappers = wrappers }
  end
  if #scripts == 0 then
    return nil, "no file of the checkout runs a file standalone on bin/cosmic-bootstrap"
  end
  table.sort(scripts, function(a: Islands.Script, b: Islands.Script): boolean
    return a.path < b.path
  end)
  return scripts, ""
end

--- The scripts of `scripts` that `listed`, the paths ci/strict-files.txt holds, leaves out: the pinned release runs
--- them with no ceiling, so they are listed there to be held to none.
function Islands.unlisted(scripts: {Islands.Script}, listed: {string}): {string}
  local known: mut {string:boolean} = {}
  for _, path in ipairs(listed) do known[path] = true end
  local missing: mut {string} = {}
  for _, script in ipairs(scripts) do
    if known[script.path] ~= true then
      missing[#missing + 1] = script.path .. " (run by " .. table.concat(script.wrappers, ", ") .. ")"
    end
  end
  return missing
end

--- The paths `text`, the list ci/islands.txt holds, names: one a line, with
--- what a `#` starts and blank lines left out. The list holds none now: the pinned release
--- reads a file it lists as Teal, which these are not.
function Islands.paths(text: string): {string}
  local paths: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then paths[#paths + 1] = path end
  end
  return paths
end

--- What is wrong with `path`, a script of the checkout `root`, as the running driver reads it in the new grammar: nil
--- where it says no `file:line:column:` of a finding or a syntax error and exits as its `--help` does
--- ([`Islands.help_exits`]) when run standalone with `--help`, else what it said or why it did not run.
function Islands.complaint(root: string, path: string, env: {string:string}): string?
  local there, _ = Fs.exists(root .. "/" .. path)
  if there ~= true then return "is not there" end
  local values: mut {string:string} = {}
  for name, value in pairs(env) do values[name] = value end
  values["COSMIC_GRAMMAR"] = "new"
  local driver = BuildPaths.driver({ "--standalone", path, "--help" }, values)
  local answer, why = Child.run(driver.argv, { env = driver.env, fds = driver.fds, cwd = root, stdin = "null",
    stdout = "null", stderr = "capture", timeout_ns = Clock.seconds(60) })
  if answer == nil then return "could not run the driver: " .. why end
  if answer.timed_out then return "the driver's standalone run did not finish in 60 s" end
  local said: mut {string} = {}
  for line in (answer.stderr or ""):gmatch("[^\n]+") do
    if line:find("^[^%s]+:%d+:%d+: ") ~= nil or line:find("^[^%s]+: %d+ errors? of ") ~= nil then
      said[#said + 1] = line
    end
  end
  if #said > 0 then
    return table.concat(said, "\n") .. "\nbin/cosmic-bootstrap runs this file on the pinned release, not on the tree: " ..
      "use only APIs of the pinned release, or move the pin (doc/contributing.md, \"moving the driver pin\")"
  end
  -- A script that stopped for another reason (a module it cannot load, an error in its `--help`) said no finding.
  local expected = Islands.help_exits[path] or 0
  if answer.code ~= expected then
    local first = String.trim(tostring(answer.stderr or ""):match("^[^\n]*") or "")
    return "exited " .. tostring(answer.code) .. " with --help, not " .. tostring(expected) ..
      (if first ~= "" then ": " .. first else "" end) .. "; if --help is meant to exit " .. tostring(answer.code) ..
      ", add it to Islands.help_exits (ci/cosmic_ci/islands.tl)"
  end
  return nil
end

--- The complaints about `scripts` under `root`, each naming the script and the files that run it, and how many files
--- were checked.
function Islands.check(root: string, scripts: {Islands.Script}, env: {string:string}): Islands.Report
  local complaints: mut {string} = {}
  local checked = 0
  for _, script in ipairs(scripts) do
    local name = script.path .. " (run by " .. table.concat(script.wrappers, ", ") .. ")"
    checked = checked + 1
    local complaint = Islands.complaint(root, script.path, env)
    if complaint ~= nil then complaints[#complaints + 1] = name .. ": " .. complaint end
  end
  return { complaints = complaints, checked = checked }
end

--- `driver.tl check-islands [ROOT]`: the scripts [`Islands.scripts`] finds under ROOT, and that
--- ci/islands.txt lists none, since the pinned release would read a file it lists as Teal.
function Islands.command(argv: {string}): integer
  local root = argv[1] or ".."
  local list = root .. "/ci/islands.txt"
  local text, trouble = Fs.read(list)
  if text == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. list .. ": " .. tostring(trouble) .. "\n")
    return 2
  end
  local listed = Islands.paths(text)
  if #listed > 0 then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. list .. " lists " .. table.concat(listed, ", ") ..
        ", which the pinned release would read as Teal; the list is empty now\n")
    return 1
  end
  local scripts, why = Islands.scripts(root)
  if scripts == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. why .. "\n")
    return 2
  end
  local pin, pin_trouble = Fs.read(root .. "/ci/cosmic-driver.pin")
  if pin == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. root .. "/ci/cosmic-driver.pin: " .. tostring(pin_trouble) .. "\n")
    return 2
  end
  local strict, strict_trouble = Fs.read(root .. "/ci/strict-files.txt")
  if strict == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. root .. "/ci/strict-files.txt: " .. tostring(strict_trouble) .. "\n")
    return 2
  end
  local unlisted = Islands.unlisted(scripts, Islands.paths(strict))
  if #unlisted > 0 then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. Plural.count(#unlisted, "file") .. " run on the pinned release " ..
        "and not in ci/strict-files.txt, which holds the files run with no ceiling; add " ..
        table.concat(unlisted, ", ") .. "\n")
    return 1
  end
  local report = Islands.check(root, scripts, Env.all())
  local complaints, checked = report.complaints, report.checked
  if #complaints > 0 then
    -- A complaint holds the compiler's lines: each is indented under its file.
    local indented = table.concat(complaints, "\n"):gsub("\n", "\n  ")
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. Plural.count(#complaints, "island") ..
        " not clean under the pinned cosmic-driver (ci/cosmic-driver.pin, release " .. pin:sub(1, 12) ..
        "):\n  " .. indented .. "\n")
    return 1
  end
  local _, _ = Fs.put(Fs.stdout, "check-islands: " .. Plural.count(checked, "file") ..
      " type-check under the pinned cosmic-driver\n")
  return 0
end

return Islands
