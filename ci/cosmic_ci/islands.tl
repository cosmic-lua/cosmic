--- `check-islands`, which type-checks the bootstrap scripts, the files of `build/` that `bin/cosmic-bootstrap` runs
--- on the release ci/cosmic-driver.pin names, in the new checker's grammar (it sets COSMIC_GRAMMAR=new), on that
--- release, the one running this driver:
---
---     cosmic-driver cosmic_ci/driver.tl check-islands [ROOT]
---
--- ROOT is the checkout (default `..`, as CI runs the driver from `ci/`). The scripts are [`Islands.scripts`], held to
--- the scripts of `bin/` and the two standalone runs of `build/zig.tl` by build/islands_test.tl. Each is run
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

  --- The scripts the pinned release runs in the new grammar, each by its path from the root of the checkout, in the
  --- order of their bytes: those of `bin/` and the two runs of build/zig.tl.
  mut scripts: {string}

  --- The exit status of `--help` for each script that does not give 0.
  mut help_exits: {string:integer}
end

Islands.scripts = {
  "build/patch.tl", "build/paths.tl", "build/perf.tl", "build/vendor.tl", "build/verify_codesign.tl",
  "build/zig.tl", "build/zig_fetch.tl",
}

--- The exit status each script of [`Islands.scripts`] gives `--help`, where it is not 0: the scripts that answer a usage
--- error (`patch`, `zig_fetch`, which take arguments) and those that print usage and fail (`paths`, `perf`). Any other
--- status is a crash the check must not take for a clean script.
Islands.help_exits = {
  ["build/patch.tl"] = 2, ["build/paths.tl"] = 1, ["build/perf.tl"] = 1, ["build/zig_fetch.tl"] = 2,
}

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
  if #said > 0 then return table.concat(said, "\n") end
  -- A script that stopped for another reason (a module it cannot load, an error in its `--help`) said no finding.
  local expected = Islands.help_exits[path] or 0
  if answer.code ~= expected then
    local first = String.trim(tostring(answer.stderr or ""):match("^[^\n]*") or "")
    return "exited " .. tostring(answer.code) .. " with --help, not " .. tostring(expected) ..
      (if first ~= "" then ": " .. first else "" end)
  end
  return nil
end

--- The complaints about the files of `paths` under `root`, each named, and
--- how many files were checked. A path that is not a `.tl` file is a
--- complaint too.
function Islands.check(root: string, paths: {string}, env: {string:string}): Islands.Report
  local complaints: mut {string} = {}
  local checked = 0
  for _, path in ipairs(paths) do
    if path:sub(-3) ~= ".tl" then
      complaints[#complaints + 1] = path .. ": not a .tl file"
    else
      checked = checked + 1
      local complaint = Islands.complaint(root, path, env)
      if complaint ~= nil then complaints[#complaints + 1] = path .. ": " .. complaint end
    end
  end
  return { complaints = complaints, checked = checked }
end

--- `driver.tl check-islands [ROOT]`: the scripts of [`Islands.scripts`] under ROOT, and that
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
  local report = Islands.check(root, Islands.scripts, Env.all())
  local complaints, checked = report.complaints, report.checked
  if #complaints > 0 then
    -- A complaint holds the compiler's lines: each is indented under its file.
    local indented = table.concat(complaints, "\n"):gsub("\n", "\n  ")
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. Plural.count(#complaints, "island") ..
        " not clean under the pinned cosmic-driver (ci/cosmic-driver.pin):\n  " .. indented .. "\n")
    return 1
  end
  local _, _ = Fs.put(Fs.stdout, "check-islands: " .. Plural.count(checked, "file") ..
      " type-check under the pinned cosmic-driver\n")
  return 0
end

return Islands
