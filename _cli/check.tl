--- `--check <kind> <file>` — the per-file half of a gate stage.
---
--- One kind per gate, and **the kind IS the verb**: `--check fmt` is
--- what `--make fmt` runs over one file, `--check lint` what `--make
--- lint` runs, `--check example` what `--make example` runs. The verbs
--- take a project and the flag takes a file, so a rule can check one
--- file without re-scanning the tree for every one of them.
---
--- The flag names ARE the verb names, not synonyms for them. Arbitrary
--- pairs — `format`/`fmt`, `style`/`lint`, `examples`/`example` — cost
--- a translation table in this file and a second copy of it in the
--- argument parser, purely so an error message can tell you the other
--- name for the thing you just typed. Two names for one concept is a
--- tax on every reader.
---
--- `types` is the deliberate exception, because the identity would be
--- `--check check`, which is not a sentence. One exception you can see
--- beats four you have to look up.

local handlers = require("_cli.main_handlers")

--- The kinds, and the project-wide verb each one belongs to.
local KINDS < const >: {string: string} = {
  types = "check",
  fmt = "fmt",
  lint = "lint",
  example = "example",
}

--- Kinds that were renamed, and what they are called now. Refused by
--- name rather than accepted as aliases: an alias keeps both spellings
--- alive, which is the thing being removed.
local RETIRED < const >: {string: string} = {
  format = "fmt",
  style = "lint",
  examples = "example",
}

--- Run one check over one file.
--- @param kind string Which check: types, fmt, lint or example
--- @param file string The file to check
--- @param include_dirs {string} Include path, for the type check
--- @return integer Exit code
local function run_one(kind: string, file: string,
    include_dirs: {string}): integer
  if RETIRED[kind] then
    io.stderr:write("cosmic-lua: --check " .. kind .. " is now `--check " ..
      RETIRED[kind] .. "` (the kind and the verb are one word now)\n")
    return 1
  end
  if not KINDS[kind] then
    local names: {string} = {}
    for k in pairs(KINDS) do
      names[#names + 1] = k
    end
    table.sort(names)
    io.stderr:write("cosmic-lua: unknown check '" .. kind .. "': " ..
      table.concat(names, ", ") .. "\n")
    return 1
  end
  if not file or file == "" then
    io.stderr:write("cosmic-lua: --check " .. kind .. " needs a file " ..
      "(the whole project is `cosmic --make " .. KINDS[kind] .. "`)\n")
    return 1
  end
  if kind == "types" then
    return handlers.handle_check_types(file, include_dirs)
  elseif kind == "fmt" then
    return handlers.handle_check_format(file)
  elseif kind == "lint" then
    return handlers.handle_check_style(file)
  end
  return handlers.handle_check_examples(file)
end

--- Run one check over every file named, and fail if ANY of them fails.
---
--- Every path is checked, every failure is printed, and the exit code
--- is the worst of them. A gate that reports PASS over a file it never
--- read is worse than no gate, which is why the fan-out lives here
--- rather than in each caller.
--- @param kind string Which check: types, fmt, lint or example
--- @param files {string} The files to check, in order
--- @param include_dirs {string} Include path, for the type check
--- @return integer Exit code
local function run(kind: string, files: {string},
    include_dirs: {string}): integer
  if #files == 0 then
    return run_one(kind, "", include_dirs)
  end
  local worst = 0
  for _, file in ipairs(files) do
    local code = run_one(kind, file, include_dirs)
    if code > worst then
      worst = code
    end
  end
  return worst
end

local record CheckModule
  KINDS: {string: string}
  RETIRED: {string: string}
  run: function(kind: string, files: {string}, include_dirs: {string}): integer
end

local M: CheckModule = {
  KINDS = KINDS,
  RETIRED = RETIRED,
  run = run,
}

return M
