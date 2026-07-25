--- Extraction of one module's annotation content from definitions.lua.
--- Split from gentype_render.tl to respect the 500-line file cap.

--- Extract a module's content from definitions.lua.
--- Selects, line-based: (1) the `<mod> = { ... }` table section, with brace
--- depth counted only outside comments (a stray `}` in a doc comment must not
--- terminate the table early); (2) every annotation block followed by a
--- `function <mod>.<name>(` or `function <mod>.<Class>:<method>(` declaration,
--- wherever it appears in the file; (3) every standalone `---@class <mod>.*`
--- data-class block. Blocks belonging to other modules never leak in, so no
--- boundary heuristics are needed.
local function extract_module_content(source: string, module_name: string): string
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  -- 1) module table section
  local start_idx: integer = nil
  for idx, line in ipairs(lines) do
    if line:match("^" .. module_name .. "%s*=%s*{") then
      start_idx = idx
      break
    end
  end
  if not start_idx then return nil end

  local out: {string} = {}
  local depth = 0
  local table_end = start_idx
  for idx = start_idx, #lines do
    local code = lines[idx]:gsub("%-%-.*$", "")
    for brace in code:gmatch("[{}]") do
      depth = depth + (brace == "{" and 1 or -1)
    end
    table.insert(out, lines[idx])
    table_end = idx
    if depth <= 0 then break end
  end

  -- 2) + 3) annotation blocks and declarations for this module
  local fn_pattern = "^function%s+" .. module_name .. "%."
  local class_pattern = "^%-%-%-@class%s+" .. module_name .. "%."
  local alias_pattern = "^%-%-%-@alias%s+" .. module_name .. "%."
  local pending: {string} = {}
  local function flush_standalone_class()
    local is_class = false
    for _, a in ipairs(pending) do
      if a:match(class_pattern) or a:match(alias_pattern) then
        is_class = true
        break
      end
    end
    if is_class then
      for _, a in ipairs(pending) do table.insert(out, a) end
      table.insert(out, "")
    end
    pending = {}
  end

  for idx = 1, #lines do
    if idx >= start_idx and idx <= table_end then
      pending = {}
    else
      local line = lines[idx]
      if line:match("^%-%-%-") then
        table.insert(pending, line)
      elseif line:match(fn_pattern) then
        for _, a in ipairs(pending) do table.insert(out, a) end
        table.insert(out, line)
        pending = {}
      else
        flush_standalone_class()
      end
    end
  end
  flush_standalone_class()

  return table.concat(out, "\n")
end

local record GentypeExtractModule
  extract_module_content: function(source: string, module_name: string): string
end

local M: GentypeExtractModule = {
  extract_module_content = extract_module_content,
}

return M
