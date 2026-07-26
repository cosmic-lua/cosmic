--- `--check <kind> <file>` — the per-file half of a gate stage.
---
--- One kind per gate, and the kinds line up with the verbs: `types` is
--- what `--make check` runs, `format` what `--make fmt` runs, `style`
--- what `--make lint` runs, `examples` what `--make example` runs. The
--- verbs take a project and the flag takes a file, so a rule can check
--- one file without re-scanning the tree for every one of them.
---
--- Four flags used to spell these, one per kind. One flag and a kind
--- reads the same way `--make <verb>` does, and it leaves one place to
--- add the next check.

local handlers = require("_cli.main_handlers")

--- The kinds, and what each one runs.
local KINDS < const >: {string: string} = {
  types = "check",
  format = "fmt",
  style = "lint",
  examples = "example",
}

--- Run one check over one file.
--- @param kind string Which check: types, format, style or examples
--- @param file string The file to check
--- @param include_dirs {string} Include path, for the type check
--- @return integer Exit code
local function run(kind: string, file: string,
    include_dirs: {string}): integer
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
  elseif kind == "format" then
    return handlers.handle_check_format(file)
  elseif kind == "style" then
    return handlers.handle_check_style(file)
  end
  return handlers.handle_check_examples(file)
end

local record CheckModule
  KINDS: {string: string}
  run: function(kind: string, file: string, include_dirs: {string}): integer
end

local M: CheckModule = {
  KINDS = KINDS,
  run = run,
}

return M
