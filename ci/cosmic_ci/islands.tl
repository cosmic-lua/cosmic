--- `check-islands`, which type-checks the files that stay Teal until the pin
--- moves past the switch (ci/islands.txt) on the release ci/cosmic-driver.pin
--- names, the one running this driver:
---
---     cosmic-driver cosmic_ci/driver.tl check-islands [ROOT]
---
--- ROOT is the checkout (default `..`, as CI runs the driver from `ci/`).
--- bin/cosmic-bootstrap runs the files of `build/` on that release, whose
--- Teal the tree's may be ahead of. Each is given to the running driver's
--- `compile`, which parses and type-checks a file and never runs it, alone,
--- as the bootstrap runs it: a `require` of a module of the tree is not
--- found, and says so. `compile` writes its Lua despite a type error and
--- exits 0 then, so a file passes only if it exits 0 and says nothing: a
--- syntax error exits 2, and a type error is a line on standard error.
--- A directory of the list (`ci/`) is not given to it: the driver's own
--- tests compile that (`cosmic-driver test cosmic_ci`).
local BuildPaths = require("cosmic_ci.build_paths")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")
local String = require("cosmic.string")

local record Islands
end

--- The paths `text`, the list ci/islands.txt holds, names: one a line, with
--- what a `#` starts and blank lines left out.
function Islands.paths(text: string): {string}
  local paths: {string} = {}
  for line in text:gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then paths[#paths + 1] = path end
  end
  return paths
end

--- What is wrong with `path`, a file of the checkout `root`, as the running
--- driver reads it: nil where its `compile` takes it without a word, else
--- what it said or why it did not.
function Islands.complaint(root: string, path: string, env: {string:string}): string | nil
  local argv, values, fds = BuildPaths.driver({ "compile", "--errors", path }, env)
  local answer, why = Child.run(argv, { env = values, fds = fds, cwd = root, stdin = "null",
    stdout = "null", stderr = "capture", timeout_ns = Clock.seconds(60) })
  if answer == nil then return "could not run the driver: " .. why end
  if answer.timed_out then return "the driver's compile did not finish in 60 s" end
  local said = String.trim(answer.stderr or "")
  if not answer.ok then
    return "the driver's compile exited " .. tostring(answer.code) .. ": " .. said
  end
  if said ~= "" then return said end
  return nil
end

--- The complaints about the files of `paths` under `root`, each named, and
--- how many files were checked. A path that is neither a directory (a `/`
--- ends it) nor a `.tl` file is a complaint too.
function Islands.check(root: string, paths: {string}, env: {string:string}): {string}, integer
  local complaints: {string} = {}
  local checked = 0
  for _, path in ipairs(paths) do
    if path:sub(-1) == "/" then
      -- compiled by the driver's own tests
    elseif path:sub(-3) ~= ".tl" then
      complaints[#complaints + 1] = path .. ": neither a directory nor a .tl file"
    else
      checked = checked + 1
      local complaint = Islands.complaint(root, path, env)
      if complaint ~= nil then complaints[#complaints + 1] = path .. ": " .. complaint end
    end
  end
  return complaints, checked
end

--- `driver.tl check-islands [ROOT]`.
function Islands.command(argv: {string}): integer
  local root = argv[1] or ".."
  local list = root .. "/ci/islands.txt"
  local text, trouble = Fs.read(list)
  if text == nil then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. list .. ": " .. tostring(trouble) .. "\n")
    return 2
  end
  local paths = Islands.paths(text)
  if #paths == 0 then
    local _, _ = Fs.put(Fs.stderr, "check-islands: " .. list .. " names no island\n")
    return 1
  end
  local complaints, checked = Islands.check(root, paths, Env.all())
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
