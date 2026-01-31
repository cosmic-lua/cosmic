--- Access embedded documentation from the cosmic binary.
--- Provides a CLI interface similar to Go's `go doc` command.
--- Documentation is parsed at build time and embedded as a serialized Lua index.

local cosmo = require("cosmo")

--- A function parameter.
local record Param
  name: string
  param_type: string
  description: string
end

--- A function return value.
local record Return
  return_type: string
  description: string
end

--- Documentation for a function.
local record FunctionDoc
  name: string
  description: string
  params: {Param}
  returns: {Return}
  signature: string
  line: integer
  is_local: boolean
end

--- Documentation for a record type.
local record RecordDoc
  name: string
  description: string
  fields: {{string, string, string}}  -- name, type, description
  line: integer
end

--- Documentation for an example function.
local record ExampleDoc
  name: string
  description: string
  body: string
  expected_output: string
  line: integer
end

--- Complete documentation for a module.
local record ModuleDoc
  file: string
  module_doc: string
  functions: {FunctionDoc}
  records: {RecordDoc}
  examples: {ExampleDoc}
end

--- A documentation index containing all modules.
local record DocIndex
  modules: {string:ModuleDoc}
end

--- Result from a docs operation.
local record DocsResult
  ok: boolean
  output: string
end

local INDEX_PATH = "/zip/.docs/index.lua"

-- Cached index
local cached_index: DocIndex = nil

--- Load the embedded documentation index.
--- @return DocIndex The documentation index, or nil if not available
--- @return string Error message if loading failed
local function load_index(): DocIndex, string
  if cached_index then
    return cached_index, nil
  end

  local source = cosmo.Slurp(INDEX_PATH)
  if not source then
    return nil, "no documentation index embedded"
  end

  local chunk, err = load("return " .. source)
  if not chunk then
    return nil, "failed to parse index: " .. (err or "unknown")
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, "failed to load index: " .. tostring(result)
  end

  cached_index = result as DocIndex
  return cached_index, nil
end

--- Check if embedded docs are available.
--- @return boolean True if docs are embedded
local function has_docs(): boolean
  local index, _ = load_index()
  return index ~= nil
end

--- Extract first paragraph from module description.
--- @param text string Full description text
--- @return string First paragraph, truncated if needed
local function first_paragraph(text: string): string
  if not text then return "" end

  -- Take first line or up to first blank line
  local para = text:match("^([^\n]+)")
  if not para then return "" end

  para = para:gsub("^%s+", ""):gsub("%s+$", "")

  if #para > 80 then
    para = para:sub(1, 77) .. "..."
  end

  return para
end

--- List all available documentation topics.
--- @return {{string, string}} List of {name, description} pairs, sorted by name
local function list_topics(): {{string, string}}
  local index, err = load_index()
  if not index then
    return {}
  end

  local topics: {{string, string}} = {}
  for name, doc in pairs(index.modules) do
    local desc = first_paragraph(doc.module_doc)
    table.insert(topics, {name, desc})
  end

  table.sort(topics, function(a: {string, string}, b: {string, string}): boolean
    return a[1] < b[1]
  end)

  return topics
end

--- Render topic list as CLI output.
--- @param topics {{string, string}} List of {name, description} pairs
--- @return string Formatted output
local function render_topic_list(topics: {{string, string}}): string
  local lines: {string} = {}

  table.insert(lines, "cosmic documentation")
  table.insert(lines, "")
  table.insert(lines, "Modules:")

  -- Find max name length for alignment
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
    -- Clean up body - remove Output: section
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

  -- Extract simple name from path
  local simple_name = name:match("([^%.]+)$") or name
  table.insert(lines, "# " .. simple_name)
  table.insert(lines, "")

  if doc.module_doc then
    table.insert(lines, doc.module_doc)
    table.insert(lines, "")
  end

  -- Types/Records
  if doc.records and #doc.records > 0 then
    table.insert(lines, "## Types")
    table.insert(lines, "")
    for _, rec in ipairs(doc.records) do
      table.insert(lines, render_record(rec))
    end
  end

  -- Functions
  if doc.functions and #doc.functions > 0 then
    table.insert(lines, "## Functions")
    table.insert(lines, "")
    for _, func in ipairs(doc.functions) do
      table.insert(lines, render_function(func))
    end
  end

  -- Examples
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
--- @param rec RecordDoc The record to search
--- @param method_name string Name of the method to find
--- @return string Rendered method documentation, or nil if not found
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

--- Find a symbol in a module's documentation.
--- @param doc ModuleDoc Module documentation
--- @param symbol string Symbol name to find
--- @param method string Optional method name within a record
--- @return string Rendered symbol documentation, or nil if not found
local function find_symbol(doc: ModuleDoc, symbol: string, method?: string): string
  -- Check functions
  if doc.functions then
    for _, func in ipairs(doc.functions) do
      if func.name == symbol or func.name:lower() == symbol:lower() then
        return render_function(func)
      end
    end
  end

  -- Check records
  if doc.records then
    for _, rec in ipairs(doc.records) do
      if rec.name == symbol or rec.name:lower() == symbol:lower() then
        -- If method specified, find within the record
        if method then
          return find_method(rec, method)
        end
        return render_record(rec)
      end
    end
  end

  -- Check examples
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

--- Search result entry.
local record SearchResult
  module_name: string
  symbol_name: string
  symbol_type: string  -- "function", "record", "example", "module"
  description: string
  match_score: integer
end

--- Search documentation for a query string.
--- @param query string The search query
--- @return {SearchResult} List of search results, sorted by relevance
local function search(query: string): {SearchResult}
  local index, _ = load_index()
  if not index then
    return {}
  end

  local results: {SearchResult} = {}
  local query_lower = query:lower()

  -- Search through all modules
  for mod_name, mod_doc in pairs(index.modules) do
    local simple_name = mod_name:match("([^%.]+)$") or mod_name

    -- Check module name and description
    if simple_name:lower():find(query_lower, 1, true) or
       (mod_doc.module_doc and mod_doc.module_doc:lower():find(query_lower, 1, true)) then
      local score = simple_name:lower() == query_lower and 100 or 50
      table.insert(results, {
        module_name = mod_name,
        symbol_name = nil,
        symbol_type = "module",
        description = first_paragraph(mod_doc.module_doc),
        match_score = score,
      })
    end

    -- Search functions
    if mod_doc.functions then
      for _, func in ipairs(mod_doc.functions) do
        if func.name:lower():find(query_lower, 1, true) or
           (func.description and func.description:lower():find(query_lower, 1, true)) then
          local score = func.name:lower() == query_lower and 90 or 40
          table.insert(results, {
            module_name = mod_name,
            symbol_name = func.name,
            symbol_type = "function",
            description = first_paragraph(func.description or ""),
            match_score = score,
          })
        end
      end
    end

    -- Search records
    if mod_doc.records then
      for _, rec in ipairs(mod_doc.records) do
        if rec.name:lower():find(query_lower, 1, true) or
           (rec.description and rec.description:lower():find(query_lower, 1, true)) then
          local score = rec.name:lower() == query_lower and 90 or 40
          table.insert(results, {
            module_name = mod_name,
            symbol_name = rec.name,
            symbol_type = "record",
            description = first_paragraph(rec.description or ""),
            match_score = score,
          })
        end

        -- Search record methods (fields with function types)
        if rec.fields then
          for _, field in ipairs(rec.fields) do
            local fname, ftype, fdesc = field[1], field[2], field[3]
            if ftype:match("^function") then
              if fname:lower():find(query_lower, 1, true) or
                 (fdesc and fdesc:lower():find(query_lower, 1, true)) then
                local score = fname:lower() == query_lower and 85 or 35
                table.insert(results, {
                  module_name = mod_name,
                  symbol_name = rec.name .. "." .. fname,
                  symbol_type = "method",
                  description = first_paragraph(fdesc or ""),
                  match_score = score,
                })
              end
            end
          end
        end
      end
    end

    -- Search examples
    if mod_doc.examples then
      for _, example in ipairs(mod_doc.examples) do
        local example_name = example.name:gsub("^Example_?", "")
        if example_name:lower():find(query_lower, 1, true) or
           (example.description and example.description:lower():find(query_lower, 1, true)) then
          table.insert(results, {
            module_name = mod_name,
            symbol_name = example_name,
            symbol_type = "example",
            description = first_paragraph(example.description or ""),
            match_score = 30,
          })
        end
      end
    end
  end

  -- Sort by match score (highest first)
  table.sort(results, function(a: SearchResult, b: SearchResult): boolean
    return a.match_score > b.match_score
  end)

  return results
end

--- Render search results as CLI output.
--- @param results {SearchResult} List of search results
--- @param query string The original search query
--- @return string Formatted output
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

--- Main entry point for the docs command.
--- @param query string Optional query string (module or module.symbol)
--- @return DocsResult Result with documentation content
local function run(query?: string): DocsResult
  local index, err = load_index()
  if not index then
    return {
      ok = false,
      output = "error: " .. (err or "no documentation embedded") .. "\n" ..
               "Build with 'make cosmic' to include documentation.",
    }
  end

  -- No query: list all topics
  if not query or query == "" then
    local topics = list_topics()
    if #topics == 0 then
      return {
        ok = false,
        output = "error: no documentation found",
      }
    end
    return {
      ok = true,
      output = render_topic_list(topics),
    }
  end

  -- Try exact module match first
  if index.modules[query] then
    return {
      ok = true,
      output = render_module(query, index.modules[query]),
    }
  end

  -- Try module.symbol pattern
  local parts: {string} = {}
  for part in query:gmatch("[^%.]+") do
    table.insert(parts, part)
  end

  if #parts >= 2 then
    local symbol = parts[#parts]
    local module_parts: {string} = {}
    for i = 1, #parts - 1 do
      table.insert(module_parts, parts[i])
    end
    local module_name = table.concat(module_parts, ".")

    local doc = index.modules[module_name]
    if doc then
      local rendered = find_symbol(doc, symbol)
      if rendered then
        return {
          ok = true,
          output = rendered,
        }
      else
        return {
          ok = false,
          output = "error: symbol '" .. symbol .. "' not found in '" .. module_name .. "'\n" ..
                   "Use 'cosmic --docs " .. module_name .. "' to see available symbols.",
        }
      end
    end

    -- Try module.Record.method pattern (3+ parts)
    if #parts >= 3 then
      local method = parts[#parts]
      local record_name = parts[#parts - 1]
      local mod_parts: {string} = {}
      for i = 1, #parts - 2 do
        table.insert(mod_parts, parts[i])
      end
      local mod_name = table.concat(mod_parts, ".")

      doc = index.modules[mod_name]
      if doc then
        local rendered = find_symbol(doc, record_name, method)
        if rendered then
          return {
            ok = true,
            output = rendered,
          }
        else
          return {
            ok = false,
            output = "error: method '" .. method .. "' not found in '" .. mod_name .. "." .. record_name .. "'\n" ..
                     "Use 'cosmic --docs " .. mod_name .. "." .. record_name .. "' to see available methods.",
          }
        end
      end
    end
  end

  -- Nothing found
  return {
    ok = false,
    output = "error: documentation not found for '" .. query .. "'\n" ..
             "Use 'cosmic --docs' to see available modules.",
  }
end

local record DocsModule
  run: function(query?: string): DocsResult
  has_docs: function(): boolean
  list_topics: function(): {{string, string}}
  load_index: function(): DocIndex, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
end

local M: DocsModule = {
  run = run,
  has_docs = has_docs,
  list_topics = list_topics,
  load_index = load_index,
  render_module = render_module,
  search = search,
  render_search_results = render_search_results,
}

return M
