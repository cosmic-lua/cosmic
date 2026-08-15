--- Help text generation for cosmic CLI.
--- Produces the complete --help output: static option descriptions from
--- sys/help.md with its derived lists filled in from the registries
--- that own them -- a hand-typed copy of a registry drifts -- and
--- the dynamic module list from the embedded docs.

local fs = require("cosmic.fs")
local str = require("cosmic.string")

--- Greedy-wrap a name list into help-width lines.
--- @param names_list {string} The names, in the order they should read
--- @param first string The first line's prefix (indentation included)
--- @param indent string Every continuation line's prefix
--- @param suffix string Appended to the last name (e.g. a closing paren)
--- @return string The wrapped lines, newline-joined
local function wrap_names(names_list: {string}, first: string,
    indent: string, suffix: string): string
  local lines: {string} = {}
  local line = first
  for i, name in ipairs(names_list) do
    local piece = name .. (i < #names_list and "," or suffix)
    if line == first or line == indent then
      line = line .. piece
    elseif #line + 1 + #piece <= 78 then
      line = line .. " " .. piece
    else
      lines[#lines + 1] = line
      line = indent .. piece
    end
  end
  lines[#lines + 1] = line
  return table.concat(lines, "\n")
end

--- The `-c` vocabulary, from the step registry itself.
--- @return {string} The verb names, sorted
local function recipe_verbs(): {string}
  local modes = require("_cli.build.steps")
  local out: {string} = {}
  for name in pairs(modes) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- The `--make` verbs, from the verb registry, in registry order.
--- @return {string} The active (unplanned) verb names
local function make_verbs(): {string}
  require("_make.init")
  return require("_make.help").names(false)
end

--- Generate help text for cosmic CLI.
--- @return string The complete help text
local function generate(): string
  local lines: {string} = {}

  local static_help, err = fs.read("/zip/sys/help.md")
  assert(static_help, "failed to load embedded help: " .. (err or "unknown error"))

  -- Fill the derived lists in. The tokens sit on their own lines in
  -- help.md; each renders from the registry that owns the names, so
  -- adding a verb or a public variable updates --help by itself.
  local pad33 = string.rep(" ", 33)
  static_help = str.replace(static_help, "{{recipe_verbs}}",
    wrap_names(recipe_verbs(), pad33 .. "vocabulary: ", pad33, ")"), 1)
  static_help = str.replace(static_help, "{{make_verbs}}",
    wrap_names(make_verbs(), string.rep(" ", 32) .. "(", pad33,
      "; `--make help` lists them)"), 1)
  static_help = str.replace(static_help, "{{env_vars}}",
    table.concat(require("_cli.env_vars").help_lines(), "\n"), 1)
  table.insert(lines, static_help)

  -- Show module list with descriptions (only cosmic.* modules, not cosmo.* bindings)
  local docs = require("cosmic.doc")
  if docs.is_available() then
    local topics = docs.topics() -- excludes cosmo.* by default
    if #topics > 0 then
      local cosmic_topics: {{string, string}} = {}

      for _, topic in ipairs(topics) do
        local name: string = topic[1]
        if name:match("^cosmic%.") then
          local short_name = name:gsub("^cosmic%.", "")
          local desc: string = topic[2]
          table.insert(cosmic_topics, {short_name, desc})
        end
      end

      if #cosmic_topics > 0 then
        table.sort(cosmic_topics, function(a: {string}, b: {string}): boolean
            return a[1] < b[1]
          end)

        -- Find max name length for alignment
        local max_len = 0
        for _, t in ipairs(cosmic_topics) do
          if #t[1] > max_len then
            max_len = #t[1]
          end
        end

        table.insert(lines, "")
        table.insert(lines, "Available modules:")
        for _, t in ipairs(cosmic_topics) do
          local padding = string.rep(" ", max_len - #t[1] + 2)
          local line = "  " .. t[1] .. padding .. t[2]
          table.insert(lines, line)
        end
      end
    end
  end

  local guides = docs.guides()
  if #guides > 0 then
    local max_len = 0
    for _, g in ipairs(guides) do
      if #g[1] > max_len then
        max_len = #g[1]
      end
    end
    table.insert(lines, "")
    table.insert(lines, "Guides (cosmic --docs guide.<name>):")
    for _, g in ipairs(guides) do
      local padding = string.rep(" ", max_len - #g[1] + 2)
      table.insert(lines, "  " .. g[1] .. padding .. g[2])
    end
  end

  return table.concat(lines, "\n")
end

return {generate = generate}
