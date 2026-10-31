--- `check-islands`, which type-checks the files `bin/cosmic-bootstrap` runs standalone on the release
--- ci/cosmic-driver.pin names, in the new checker's grammar (it sets COSMIC_GRAMMAR=new), on that release, the one
--- running this driver:
---
---     cosmic-driver cosmic_ci/driver.tl check-islands [ROOT]
---
--- ROOT is the checkout (default `..`, as CI runs the driver from `ci/`). The files are those ci/bootstrap-files.txt
--- lists. The list is enforced where the run happens: bin/cosmic-bootstrap refuses `--standalone` on a file of its
--- checkout that is not listed, and the entry point it hands out (what `$(bin/cosmic-bootstrap)` prints) applies the
--- same check, so a file cannot run on the pinned release unlisted by either; every listed file is checked here. Each is
--- given to the release as `--standalone --check`, the check of a script as the bootstrap's `--standalone` reads it: the
--- release reads it in the new grammar and holds it to its checker with the standard library it carries and no ceiling,
--- and it type-checks without running the file, so no script needs its `--help` to be safe or its tools (zig) installed.
--- A file that has a finding says so on standard error as `file:line:column: message` and exits 1. `compile --grammar
--- new --errors` is not used: it reads a project from a root, where the check reads the lone file as the bootstrap runs
--- it, with the globals the standalone run meets.
---
--- All of `ci/` also runs on that release, and the driver's own tests compile only the modules they require, so the
--- release's `fix --check` is run over `ci/` as well ([`Islands.project`]): a file nothing requires is held to its
--- checker too.
---
--- The users of the pinned binary's own path, which bin/cosmic-bootstrap's check does not see (a process running on the
--- release can always run its own binary), as found by reading the [`Proc.executable`] and [`Proc.relaunch`] of ci/ (the
--- list is in ci/README.md; a new one is the residual): this command ([`Islands.complaint`]), build/zig.tl (its
--- `standalone(` calls, each counted here and named in the list), [`BuildPaths.directory`] of ci/cosmic_ci/build_paths.tl,
--- which runs build/paths.tl that way (checked to be listed), and ci/run_local.tl, which runs only build/paths.tl that
--- way and cannot use ci/'s modules: it runs standalone. [`BuildPaths.driver`] refuses a `--standalone` of its own. A new
--- site in ci/ that relaunches the driver on a file is not caught by anything; code review holds it.
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
end

--- Whether `line` is a comment of a shell, YAML, Lua or Teal file.
local function is_comment(line: string): boolean
  return line:find("^%s*#") ~= nil or line:find("^%s*%-%-") ~= nil
end

--- The `standalone(root, "<file>.tl", ...)` calls of build/zig.tl, which run `<file>` on the pinned release's binary,
--- by path. Nil with why where a call is not one this reads: its file not a string literal on the call's own line,
--- which would leave the file unchecked. Every call site is counted, not only the ones that match.
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

--- The paths `text`, a list such as ci/bootstrap-files.txt, names: one a line, with what a `#` starts dropped, blank
--- lines left out and white space (a CR too) trimmed from both ends of each. bin/cosmic-bootstrap reads the list the
--- same way in shell, and build/ci_tree_test.tl, which cannot require ci/, copies this.
function Islands.paths(text: string): {string}
  local paths: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then paths[#paths + 1] = path end
  end
  return paths
end

--- The files ci/bootstrap-files.txt of `root` lists, each checked to be there (build/ci_tree_test.tl holds them to
--- ci/strict-files.txt, since the pinned release runs them with no ceiling), and the files build/zig.tl runs on that release's binary,
--- each checked to be listed. Nil with why where the lists cannot be read or one disagrees.
function Islands.files(root: string): {string}?, string
  local text, trouble = Fs.read(root .. "/ci/bootstrap-files.txt")
  if text == nil then return nil, "ci/bootstrap-files.txt: " .. tostring(trouble) end
  local listed = Islands.paths(text)
  local known: mut {string:boolean} = {}
  for _, path in ipairs(listed) do
    known[path] = true
    local there, _ = Fs.exists(root .. "/" .. path)
    if there ~= true then
      return nil, "ci/bootstrap-files.txt lists " .. path .. ", which is not in the checkout: remove the stale entry"
    end
  end
  local zig, zig_trouble = Fs.read(root .. "/build/zig.tl")
  if zig == nil then return nil, "build/zig.tl: " .. tostring(zig_trouble) end
  local runs, runs_why = zig_runs(zig)
  if runs == nil then return nil, runs_why end
  -- ci/cosmic_ci/build_paths.tl runs it by the driver's own path, as the resolver of the build directory.
  local run_paths: mut {string} = { "build/paths.tl" }
  for _, path in ipairs(runs) do run_paths[#run_paths + 1] = path end
  for _, path in ipairs(run_paths) do
    if known[path] ~= true then
      return nil, path .. " is run on the pinned release's binary (by build/zig.tl, or as the build directory's resolver " ..
        "by ci/cosmic_ci/build_paths.tl) and ci/bootstrap-files.txt does not list it: add it, so it is type-checked there"
    end
  end
  return listed, ""
end

--- What is wrong with `path`, a script of the checkout `root`, as the running driver reads it in the new grammar: nil
--- where `--standalone --check` says no `file:line:column:` of a finding or a syntax error and exits 0, else what it said
--- or why it did not run.
function Islands.complaint(root: string, path: string, env: {string:string}): string?
  local values: mut {string:string} = {}
  for name, value in pairs(env) do values[name] = value end
  values["COSMIC_GRAMMAR"] = "new"
  local driver = BuildPaths.driver({}, values)
  local argv: mut {string} = {}
  for _, word in ipairs(driver.argv) do argv[#argv + 1] = word end
  for _, word in ipairs({ "--standalone", "--check", path }) do argv[#argv + 1] = word end
  local answer, why = Child.run(argv, { env = driver.env, fds = driver.fds, cwd = root, stdin = "null",
    stdout = "null", stderr = "capture", timeout_ns = Clock.seconds(60) })
  if answer == nil then return "could not run the driver: " .. why end
  if answer.timed_out then return "the driver's standalone check did not finish in 60 s" end
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
  -- A check that stopped for another reason (a file it cannot read) said no finding.
  if answer.code ~= 0 then
    local first = String.trim(tostring(answer.stderr or ""):match("^[^\n]*") or "")
    return "exited " .. tostring(answer.code) .. " with --check, not 0" .. (if first ~= "" then ": " .. first else "" end)
  end
  return nil
end

--- The complaints about the files of `paths` under `root`, each named, and how many were checked.
function Islands.check(root: string, paths: {string}, env: {string:string}): Islands.Report
  local complaints: mut {string} = {}
  local checked = 0
  for _, path in ipairs(paths) do
    checked = checked + 1
    local complaint = Islands.complaint(root, path, env)
    if complaint ~= nil then
      complaints[#complaints + 1] = path .. " (listed in ci/bootstrap-files.txt): " .. complaint
    end
  end
  return { complaints = complaints, checked = checked }
end

--- What the running release's `fix --check` says about `ci/` of the checkout `root`, as that release lays out and checks
--- it, or nil where it finds nothing. The driver's tests compile what they require, so a file nothing requires is
--- reached only here.
function Islands.project(root: string, env: {string:string}): string?
  local values: mut {string:string} = {}
  for name, value in pairs(env) do values[name] = value end
  local driver = BuildPaths.driver({ "fix", "--check" }, values)
  local answer, why = Child.run(driver.argv, { env = driver.env, fds = driver.fds, cwd = root .. "/ci", stdin = "null",
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(120) })
  if answer == nil then return "could not run the driver: " .. why end
  if answer.timed_out then return "the driver's `fix --check` of ci/ did not finish in 120 s" end
  if answer.code ~= 0 then
    return "the pinned release's `fix --check` refuses ci/ (ci/cosmic-driver.pin, which these files run on):\n" ..
      String.trim((answer.stdout or "") .. (answer.stderr or ""))
  end
  return nil
end

--- `driver.tl check-islands [ROOT]`: the files ci/bootstrap-files.txt lists under ROOT, ci/ as a whole, and that
--- ci/islands.txt lists none, since the pinned release would read a file it lists as Teal.
function Islands.command(argv: {string}): integer
  local root = argv[1] or ".."
  local code = Islands.verdict(root)
  if code ~= 0 then return code end
  local refusal = Islands.project(root, Env.all())
  if refusal ~= nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. refusal .. "\n")
    return 1
  end
  return 0
end

--- What [`Islands.command`] answers for the listed files of the checkout `root`, before the check of `ci/` as a whole.
function Islands.verdict(root: string): integer
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
  local files, why = Islands.files(root)
  if files == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. why .. "\n")
    return 1
  end
  local pin, pin_trouble = Fs.read(root .. "/ci/cosmic-driver.pin")
  if pin == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. root .. "/ci/cosmic-driver.pin: " .. tostring(pin_trouble) .. "\n")
    return 2
  end
  local report = Islands.check(root, files, Env.all())
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
