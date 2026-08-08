--- Help text generation for cosmic CLI.
--- Produces the complete --help output including static option descriptions
--- and dynamic module list from embedded docs.

local fs = require("cosmic.fs")

--- Generate help text for cosmic CLI.
--- @return string The complete help text
local function generate(): string
  local lines: {string} = {}

  -- Load static help text from embedded file
  local static_help, err = fs.read("/zip/sys/help.md")
  assert(static_help, "failed to load embedded help: " .. (err or "unknown error"))
  table.insert(lines, static_help)

  -- Show module list with descriptions (only cosmic.* modules, not cosmo.* bindings)
  local docs = require("_cli.doc_compat")
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

  -- Show guides list
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
