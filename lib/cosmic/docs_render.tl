--- Rendering functions for the docs module.
--- Formats documentation records into human-readable CLI output.

local types = require("cosmic.doc_types")
local Param = types.Param
local Return = types.Return
local FunctionDoc = types.FunctionDoc
local RecordDoc = types.RecordDoc
local ExampleDoc = types.ExampleDoc
local ModuleDoc = types.ModuleDoc
local SearchResult = types.SearchResult
local ExampleEntry = types.ExampleEntry
local DocIndex = types.DocIndex

-- Map low-level cosmo modules to their high-level cosmic equivalents
local COSMIC_EQUIVALENTS: {string: string} = {
  ["cosmo.lsqlite3"] = "cosmic.sqlite",
}

local fuzzy = require("cosmic.fuzzy")

--- Extract first paragraph from module description.
--- @param text string Full description text
--- @return string First paragraph, truncated if needed
local function first_paragraph(text: string): string
  if not text then return "" end
  local para = text:match("^([^\n]+)")
  if not para then return "" end
  para = para:gsub("^%s+", ""):gsub("%s+$", "")
  if #para > 80 then
    para = para:sub(1, 77) .. "..."
  end
  return para
end

--- Render topic list as CLI output.
--- @param topics {{string, string}} List of {name, description} pairs
--- @return string Formatted output
local function render_topic_list(topics: {{string, string}}): string
  local lines: {string} = {}
  table.insert(lines, "cosmic documentation")
  table.insert(lines, "")
  table.insert(lines, "Modules:")
  local max_len = 0
  for _, topic in ipairs(topics) do
    if #topic[1] > max_len then
      max_len = #topic[1]
    end
  end
  for _, topic in ipairs(topics) do
    local padding = string.rep(" ", max_len - #topic[1] + 2)
    table.insert(lines, "  " .. topic[1] .. padding .. topic[2])
  end
  table.insert(lines, "")
  table.insert(lines, "Use 'cosmic --docs <module>' for more information.")
  table.insert(lines, "Use 'cosmic --docs <module>.<symbol>' for a specific symbol.")
  table.insert(lines, "Use 'cosmic --docs guide' for guides on testing, formatting, etc.")
  return table.concat(lines, "\n")
end

--- Render a function as CLI output.
--- @param func FunctionDoc Function documentation
--- @return string Formatted output
local function render_function(func: FunctionDoc): string
  local lines: {string} = {}
  table.insert(lines, "### " .. func.name)
  table.insert(lines, "")
  if func.signature then
    table.insert(lines, "```teal")
    table.insert(lines, "function " .. func.name .. func.signature)
    table.insert(lines, "```")
    table.insert(lines, "")
  end
  if func.description then
    table.insert(lines, func.description)
    table.insert(lines, "")
  end
  if func.params and #func.params > 0 then
    table.insert(lines, "**Parameters:**")
    table.insert(lines, "")
    for _, param in ipairs(func.params) do
      local line = "- `" .. param.name .. "` (" .. param.param_type .. ")"
      if param.description then
        line = line .. " - " .. param.description
      end
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end
  if func.returns and #func.returns > 0 then
    table.insert(lines, "**Returns:**")
    table.insert(lines, "")
    for _, ret in ipairs(func.returns) do
      local line = "- " .. ret.return_type
      if ret.description then
        line = line .. " - " .. ret.description
      end
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

--- Render a record/type as CLI output.
--- @param rec RecordDoc Record documentation
--- @return string Formatted output
local function render_record(rec: RecordDoc): string
  local lines: {string} = {}
  table.insert(lines, "### " .. rec.name)
  table.insert(lines, "")
  if rec.description then
    table.insert(lines, rec.description)
    table.insert(lines, "")
  end
  if rec.fields and #rec.fields > 0 then
    table.insert(lines, "```teal")
    table.insert(lines, "local record " .. rec.name)
    for _, field in ipairs(rec.fields) do
      local fname, ftype, fdesc = field[1], field[2], field[3]
      if fdesc and fdesc ~= "" then
        for desc_line in fdesc:gmatch("[^\n]+") do
          table.insert(lines, "  -- " .. desc_line)
        end
      end
      table.insert(lines, "  " .. fname .. ": " .. ftype)
    end
    table.insert(lines, "end")
    table.insert(lines, "```")
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

--- Render an example as CLI output.
--- @param example ExampleDoc Example documentation
--- @return string Formatted output
local function render_example(example: ExampleDoc): string
  local lines: {string} = {}
  local title = example.name:gsub("^Example_?", ""):gsub("_", " ")
  if title == "" then
    title = "Basic usage"
  end
  table.insert(lines, "### " .. title)
  table.insert(lines, "")
  if example.description then
    table.insert(lines, example.description)
    table.insert(lines, "")
  end
  if example.body then
    table.insert(lines, "```teal")
    local body = example.body
    local output_start = body:find("%-%-%s*Output:")
    if output_start then
      body = body:sub(1, output_start - 1)
    end
    body = body:gsub("^%s*\n", ""):gsub("\n%s*$", "")
    table.insert(lines, body)
    table.insert(lines, "```")
    table.insert(lines, "")
  end
  if example.expected_output then
    table.insert(lines, "Output:")
    table.insert(lines, "```")
    table.insert(lines, example.expected_output)
    table.insert(lines, "```")
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

--- Render a full module as CLI output.
--- @param name string Module name
--- @param doc ModuleDoc Module documentation
--- @return string Formatted output
local function render_module(name: string, doc: ModuleDoc): string
  local lines: {string} = {}
  local simple_name = name:match("([^%.]+)$") or name
  table.insert(lines, "# " .. simple_name)
  table.insert(lines, "")
  if doc.module_doc then
    table.insert(lines, doc.module_doc)
    table.insert(lines, "")
  end
  local equivalent = COSMIC_EQUIVALENTS[name]
  if equivalent then
    table.insert(lines, "**Tip:** For a high-level API, see `" .. equivalent .. "`.")
    table.insert(lines, "")
  end
  -- Hoist quick example near the top, right after the summary
  if doc.examples and #doc.examples > 0 then
    table.insert(lines, "Run `cosmic --examples " .. simple_name .. "` for runnable examples.")
    table.insert(lines, "")
    table.insert(lines, "## Quick example")
    table.insert(lines, "")
    table.insert(lines, render_example(doc.examples[1]))
  end
  if doc.records and #doc.records > 0 then
    table.insert(lines, "## Types")
    table.insert(lines, "")
    for _, rec in ipairs(doc.records) do
      table.insert(lines, render_record(rec))
    end
  end
  if doc.functions and #doc.functions > 0 then
    table.insert(lines, "## Functions")
    table.insert(lines, "")
    for _, func in ipairs(doc.functions) do
      table.insert(lines, render_function(func))
    end
  end
  if doc.examples and #doc.examples > 0 then
    table.insert(lines, "## Examples")
    table.insert(lines, "")
    for _, example in ipairs(doc.examples) do
      table.insert(lines, render_example(example))
    end
  end
  return table.concat(lines, "\n")
end

--- Find a method within a record.
local function find_method(rec: RecordDoc, method_name: string): string
  if rec.fields then
    for _, field in ipairs(rec.fields) do
      local fname, ftype, fdesc = field[1], field[2], field[3]
      if fname:lower() == method_name:lower() and ftype:match("^function") then
        local lines: {string} = {}
        table.insert(lines, "### " .. rec.name .. "." .. fname)
        table.insert(lines, "")
        table.insert(lines, "```teal")
        table.insert(lines, fname .. ": " .. ftype)
        table.insert(lines, "```")
        table.insert(lines, "")
        if fdesc then
          table.insert(lines, fdesc)
          table.insert(lines, "")
        end
        return table.concat(lines, "\n")
      end
    end
  end
  return nil
end

--- Find examples that match a function name.
local function find_matching_examples(examples: {ExampleDoc}, func_name: string): {ExampleDoc}
  local matches: {ExampleDoc} = {}
  if not examples then return matches end
  local func_lower = func_name:lower()
  for _, example in ipairs(examples) do
    local example_base = example.name:gsub("^Example_?", "")
    local base_lower = example_base:lower()
    if base_lower == func_lower or base_lower:match("^" .. func_lower .. "_") then
      table.insert(matches, example)
    end
  end
  return matches
end

--- Find a symbol in a module's documentation.
--- Also searches record fields for re-exported function symbols.
local function find_symbol(doc: ModuleDoc, symbol: string, method?: string): string
  if doc.functions then
    for _, func in ipairs(doc.functions) do
      if func.name == symbol or func.name:lower() == symbol:lower() then
        local output = render_function(func)
        local matching_examples = find_matching_examples(doc.examples, func.name)
        if #matching_examples > 0 then
          output = output .. "**Examples:**\n\n"
          for _, example in ipairs(matching_examples) do
            output = output .. render_example(example)
          end
        end
        return output
      end
    end
  end
  if doc.records then
    for _, rec in ipairs(doc.records) do
      if rec.name == symbol or rec.name:lower() == symbol:lower() then
        if method then return find_method(rec, method) end
        return render_record(rec)
      end
    end
    -- Also search record fields for re-exported function symbols
    for _, rec in ipairs(doc.records) do
      local found = find_method(rec, symbol)
      if found then
        local matching_examples = find_matching_examples(doc.examples, symbol)
        if #matching_examples > 0 then
          found = found .. "**Examples:**\n\n"
          for _, example in ipairs(matching_examples) do found = found .. render_example(example) end
        end
        return found
      end
    end
  end
  if doc.examples then
    for _, example in ipairs(doc.examples) do
      local example_name = example.name:gsub("^Example_?", "")
      if example_name == symbol or example_name:lower() == symbol:lower() then
        return render_example(example)
      end
    end
  end
  return nil
end

--- Render examples list as CLI output.
local function render_examples_list(examples: {ExampleEntry}): string
  local lines: {string} = {}
  table.insert(lines, "All examples")
  table.insert(lines, "")
  if #examples == 0 then
    table.insert(lines, "No examples found.")
    return table.concat(lines, "\n")
  end
  local current_module: string = nil
  for _, ex in ipairs(examples) do
    if ex.module_name ~= current_module then
      current_module = ex.module_name
      if #lines > 2 then
        table.insert(lines, "")
      end
      local simple_name = current_module:match("([^%.]+)$") or current_module
      table.insert(lines, simple_name .. ":")
    end
    local line = "  " .. ex.example_name
    if ex.description and ex.description ~= "" then
      line = line .. " - " .. ex.description
    end
    table.insert(lines, line)
  end
  table.insert(lines, "")
  table.insert(lines, "Run examples with: cosmic --check-examples <file.tl>")
  table.insert(lines, "View module docs with: cosmic --docs <module>")
  return table.concat(lines, "\n")
end

--- Render search results as CLI output.
local function render_search_results(results: {SearchResult}, query: string): string
  if #results == 0 then
    return "No results found for '" .. query .. "'"
  end
  local lines: {string} = {}
  table.insert(lines, "Search results for '" .. query .. "':")
  table.insert(lines, "")
  for _, result in ipairs(results) do
    local symbol_ref = result.module_name
    if result.symbol_name then
      symbol_ref = symbol_ref .. "." .. result.symbol_name
    end
    local type_label = result.symbol_type
    local line = "  " .. symbol_ref .. " (" .. type_label .. ")"
    table.insert(lines, line)
    if result.description and result.description ~= "" then
      table.insert(lines, "    " .. result.description)
    end
    table.insert(lines, "")
  end
  table.insert(lines, "Use 'cosmic --docs <symbol>' for more information.")
  return table.concat(lines, "\n")
end

--- Find suggestions for a query that didn't match.
local function find_suggestions(query: string, index: DocIndex): {string}
  local candidates: {string} = {}
  local name_to_full: {string: {string}} = {}
  local function add_candidate(simple: string, full: string)
    if not name_to_full[simple] then
      name_to_full[simple] = {}
      table.insert(candidates, simple)
    end
    table.insert(name_to_full[simple], full)
  end
  for mod_name, mod_doc in pairs(index.modules) do
    local simple = mod_name:match("([^%.]+)$") or mod_name
    add_candidate(simple, mod_name)
    if mod_doc.records then
      for _, rec in ipairs(mod_doc.records) do
        local full_name = mod_name .. "." .. rec.name
        add_candidate(rec.name, full_name)
        if rec.fields then
          for _, field in ipairs(rec.fields) do
            local fname, ftype = field[1], field[2]
            if ftype:match("^function") then
              local method_full = mod_name .. "." .. rec.name .. "." .. fname
              add_candidate(fname, method_full)
            end
          end
        end
      end
    end
    if mod_doc.functions then
      for _, func in ipairs(mod_doc.functions) do
        local full_name = mod_name .. "." .. func.name
        add_candidate(func.name, full_name)
      end
    end
  end
  local similar = fuzzy.find_similar(query, candidates, 3)
  local results: {string} = {}
  local seen: {string: boolean} = {}
  for _, simple in ipairs(similar) do
    local fulls = name_to_full[simple]
    if fulls then
      for _, full in ipairs(fulls) do
        if not seen[full] then
          seen[full] = true
          table.insert(results, full)
        end
      end
    end
  end
  return results
end

--- Find suggestions for examples lookup (only modules with examples).
local function find_example_suggestions(query: string, index: DocIndex): {string}
  local candidates: {string} = {}
  local name_to_full: {string: string} = {}
  for mod_name, mod_doc in pairs(index.modules) do
    if mod_doc.examples and #mod_doc.examples > 0 then
      local simple = mod_name:match("([^%.]+)$") or mod_name
      if not name_to_full[simple] then
        table.insert(candidates, simple)
        name_to_full[simple] = mod_name
      end
    end
  end
  local similar = fuzzy.find_similar(query, candidates, 3)
  local results: {string} = {}
  for _, simple in ipairs(similar) do
    if name_to_full[simple] then table.insert(results, name_to_full[simple]) end
  end
  return results
end

local record DocsRenderModule
  first_paragraph: function(text: string): string
  render_topic_list: function(topics: {{string, string}}): string
  render_function: function(func: FunctionDoc): string
  render_record: function(rec: RecordDoc): string
  render_example: function(example: ExampleDoc): string
  render_module: function(name: string, doc: ModuleDoc): string
  find_method: function(rec: RecordDoc, method_name: string): string
  find_matching_examples: function(examples: {ExampleDoc}, func_name: string): {ExampleDoc}
  find_symbol: function(doc: ModuleDoc, symbol: string, method?: string): string
  render_examples_list: function(examples: {ExampleEntry}): string
  render_search_results: function(results: {SearchResult}, query: string): string
  find_suggestions: function(query: string, index: DocIndex): {string}
  find_example_suggestions: function(query: string, index: DocIndex): {string}
end

local M: DocsRenderModule = {
  first_paragraph = first_paragraph,
  render_topic_list = render_topic_list,
  render_function = render_function,
  render_record = render_record,
  render_example = render_example,
  render_module = render_module,
  find_method = find_method,
  find_matching_examples = find_matching_examples,
  find_symbol = find_symbol,
  render_examples_list = render_examples_list,
  render_search_results = render_search_results,
  find_suggestions = find_suggestions,
  find_example_suggestions = find_example_suggestions,
}

return M
