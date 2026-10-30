--- `check-islands`, which type-checks the files `bin/cosmic-bootstrap` runs standalone on the release
--- ci/cosmic-driver.pin names, in the new checker's grammar (it sets COSMIC_GRAMMAR=new), on that release, the one
--- running this driver:
---
---     cosmic-driver cosmic_ci/driver.tl check-islands [ROOT]
---
--- ROOT is the checkout (default `..`, as CI runs the driver from `ci/`). The files are those ci/bootstrap-files.txt
--- lists. The list is enforced where the run happens: bin/cosmic-bootstrap refuses `--standalone` on a file of its
--- checkout that is not listed, so a file cannot run on the pinned release unlisted, however its caller spells the
--- command, and every listed file is run here. Each is run
--- standalone as the bootstrap runs it, with `--help`, so that the release reads it in the new grammar and holds it to
--- its checker with the standard library it carries and no ceiling: a script that has a finding is refused before
--- it runs and says so on standard error as `file:line:column: message`, and one that has none prints its usage.
--- `compile --grammar new` is not used: a lone file has no `cosmic.*` module to read (each is typed `invalid`), and the
--- globals come from declaration files the release's own standalone does not read, so what it finds is not what the
--- scripts meet.
---
--- What the wrapper cannot see is the pinned binary run directly (the CI driver, `$driver --standalone ...`). The
--- tracked files of `.github/` and `ci/` that spell `--standalone` outside the wrapper are held to
--- [`Islands.driver_uses`], so a new one fails here until it is named. A file of those directories that spells the
--- flag through a variable (`flag="--standalone"`, or a list built a word at a time) is not seen, and a test's own
--- fixtures are exempt: the escape is accepted because it takes deliberate indirection in a directory CI owns, review
--- sees it, and the wrapper, where the tree's own scripts run, is not subject to it.
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
local Proc = require("cosmic.proc")
local String = require("cosmic.string")

local record Islands
  --- What `check` found: the complaints, and how many files were checked.
  record Report
    complaints: {string}
    checked: integer
  end

  --- The exit status of `--help` for each script that does not give 0.
  mut help_exits: {string:integer}

  --- The tracked files of `.github/` and `ci/` that run a file standalone on the pinned binary other than through
  --- bin/cosmic-bootstrap, each with why it is allowed.
  mut driver_uses: {string:string}
end

--- The exit status each script gives `--help`, where it is not 0: the scripts that answer a usage error (`patch`,
--- `zig_fetch`, and the scripts of `eval/`, which take arguments) and those that print usage and fail (`paths`, `perf`,
--- `summarize`, which takes it for a file, and `run_local_proof`, whose assertion on its arguments is that failure).
--- Any other status is a crash the check must not take for a clean script.
Islands.help_exits = {
  ["build/patch.tl"] = 2, ["build/paths.tl"] = 1, ["build/perf.tl"] = 1, ["build/zig_fetch.tl"] = 2,
  ["eval/arena.tl"] = 2, ["eval/check/grade.tl"] = 2, ["eval/result.tl"] = 2, ["eval/round.tl"] = 2,
  ["eval/solve.tl"] = 2, ["eval/summarize.tl"] = 1, ["ci/run_local_proof.tl"] = 1,
}

Islands.driver_uses = {
  [".github/scripts/run-local-proof.sh"] = "runs ci/run_local_proof.tl, which ci/bootstrap-files.txt lists",
  ["ci/run_local_proof.tl"] = "starts ci/run_local.tl, which the driver's own tests compile (run_local_test.tl requires " ..
    "it) and which `--help` would not stop: it would start the platform job",
  ["ci/run_local.tl"] = "starts build/paths.tl, which ci/bootstrap-files.txt lists",
  ["ci/cosmic_ci/build_paths.tl"] = "starts build/paths.tl, which ci/bootstrap-files.txt lists",
  ["ci/cosmic_ci/islands.tl"] = "starts each file ci/bootstrap-files.txt lists",
  ["ci/cosmic_ci/driver.tl"] = "names the flag in the help of check-islands",
}

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

--- The paths `text`, a list such as ci/bootstrap-files.txt, names: one a line, with what a `#` starts and blank lines
--- left out.
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
  for _, path in ipairs(runs) do
    if known[path] ~= true then
      return nil, "build/zig.tl runs " .. path .. " on the pinned release's binary and ci/bootstrap-files.txt does not " ..
        "list it: add it, so it is type-checked there"
    end
  end
  return listed, ""
end

--- The tracked files of `root`, by path, from git; nil with why where git cannot list them.
local function tracked(root: string): {string}?, string
  local git, git_why = Proc.find("git")
  if git == nil then return nil, "git: " .. git_why end
  local answer, why = Child.run({ git, "-C", root, "ls-files", "-z" }, { stdout = "capture", stderr = "capture",
    stdin = "null", timeout_ns = Clock.seconds(30) })
  if answer == nil then return nil, "git ls-files: " .. why end
  if answer.code ~= 0 then
    return nil, "git ls-files failed in " .. root .. ": " .. String.trim(answer.stderr or "")
  end
  local files: mut {string} = {}
  for file in (answer.stdout or ""):gmatch("[^%z]+") do files[#files + 1] = file end
  return files, ""
end

--- Nil where every file of `files`, the tracked ones, of `.github/` and `ci/` that spells `--standalone` on a line that is no comment and does
--- not run it through bin/cosmic-bootstrap is a test (`_test.tl`, whose fixtures it runs) or named in
--- [`Islands.driver_uses`]; else why not, naming the file and line. Markdown only describes and is not read.
function Islands.driver_use_refusal(root: string, files: {string}): string?
  for _, file in ipairs(files) do
    if (file:find("^%.github/") ~= nil or file:find("^ci/") ~= nil) and file:sub(-3) ~= ".md" and
        file:sub(-8) ~= "_test.tl" and Islands.driver_uses[file] == nil then
      local text, read_why = Fs.read(root .. "/" .. file)
      if text == nil then return file .. ": " .. tostring(read_why) end
      if text:find("\0", 1, true) == nil and text:find("--standalone", 1, true) ~= nil then
        local number = 0
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          number = number + 1
          if line:find("--standalone", 1, true) ~= nil and not is_comment(line) and
              line:find("bin/cosmic-bootstrap", 1, true) == nil then
            return file .. ":" .. tostring(number) .. ": runs a file standalone on the pinned binary without " ..
              "bin/cosmic-bootstrap, which refuses unlisted files; name the file in Islands.driver_uses " ..
              "(ci/cosmic_ci/islands.tl) with why it is allowed, and list what it runs in ci/bootstrap-files.txt: " ..
              String.trim(line)
          end
        end
      end
    end
  end
  return nil
end

--- What is wrong with `path`, a script of the checkout `root`, as the running driver reads it in the new grammar: nil
--- where it says no `file:line:column:` of a finding or a syntax error and exits as its `--help` does
--- ([`Islands.help_exits`]) when run standalone with `--help`, else what it said or why it did not run.
function Islands.complaint(root: string, path: string, env: {string:string}): string?
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

--- `driver.tl check-islands [ROOT]`: the files ci/bootstrap-files.txt lists under ROOT, and that
--- ci/islands.txt lists none, since the pinned release would read a file it lists as Teal.
function Islands.command(argv: {string}): integer
  local root = argv[1] or ".."
  local files, why = tracked(root)
  if files == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. why .. "\n")
    return 2
  end
  return Islands.verdict(root, files)
end

--- What [`Islands.command`] answers for the checkout `root` whose tracked files are `tracked_files`.
function Islands.verdict(root: string, tracked_files: {string}): integer
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
  local refusal = Islands.driver_use_refusal(root, tracked_files)
  if refusal ~= nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. refusal .. "\n")
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
