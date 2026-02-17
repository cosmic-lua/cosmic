--- Access embedded documentation from the cosmic binary.
--- Provides a CLI interface similar to Go's `go doc` command.
--- Documentation is parsed at build time and embedded as a serialized Lua index.
---
--- Two access paths:
---   - Non-interactive: `cosmic --docs <query>` from the command line
---   - Interactive: `help(<query>)` in the REPL (`cosmic -i`)

local cio = require("cosmic.io")
local fuzzy = require("cosmic.fuzzy")

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
  fields: {{string, string, string}} -- name, type, description
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
  modules: {string: ModuleDoc}
end

--- Result from a docs operation.
local record DocsResult
  ok: boolean
  output: string
end

local INDEX_PATH = "/zip/.docs/index.lua"

-- Map low-level cosmo modules to their high-level cosmic equivalents
local COSMIC_EQUIVALENTS: {string: string} = {
  ["cosmo.lsqlite3"] = "cosmic.sqlite",
}

-- Cached index
local cached_index: DocIndex = nil

--- Load the embedded documentation index.
--- @return DocIndex The documentation index, or nil if not available
--- @return string Error message if loading failed
local function load_index(): DocIndex, string
  if cached_index then
    return cached_index, nil
  end

  local source = cio.slurp(INDEX_PATH)
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

--- Check if a module name is a low-level cosmo module.
--- @param name string Module name to check
--- @return boolean True if this is a cosmo.* module
local function is_cosmo_module(name: string): boolean
  return name:match("^cosmo%.") ~= nil
end

--- List all available documentation topics.
--- @param include_cosmo boolean Include low-level cosmo.* modules (default: false)
--- @return {{string, string}} List of {name, description} pairs, sorted by name
local function list_topics(include_cosmo?: boolean): {{string, string}}
  local index, err = load_index()
  if not index then
    return {}
  end

  local topics: {{string, string}} = {}
  for name, doc in pairs(index.modules) do
    -- Skip cosmo.* modules unless explicitly requested
    if include_cosmo or not is_cosmo_module(name) then
      local desc = first_paragraph(doc.module_doc)
      table.insert(topics, {name, desc})
    end
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

  -- Show tip if this cosmo module has a cosmic equivalent
  local equivalent = COSMIC_EQUIVALENTS[name]
  if equivalent then
    table.insert(lines, "**Tip:** For a high-level API, see `" .. equivalent .. "`.")
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

--- Find examples that match a function name.
--- Looks for Example_<name> patterns in the examples list.
--- @param examples {ExampleDoc} List of examples to search
--- @param func_name string Function name to match
--- @return {ExampleDoc} Matching examples
local function find_matching_examples(examples: {ExampleDoc}, func_name: string): {ExampleDoc}
  local matches: {ExampleDoc} = {}
  if not examples then return matches end

  local func_lower = func_name:lower()
  for _, example in ipairs(examples) do
    -- Extract the base name from Example_foo or Example_foo_bar
    local example_base = example.name:gsub("^Example_?", "")
    local base_lower = example_base:lower()

    -- Match if example starts with the function name
    -- Example_open matches "open", Example_open_memory matches "open"
    if base_lower == func_lower or base_lower:match("^" .. func_lower .. "_") then
      table.insert(matches, example)
    end
  end
  return matches
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
        local output = render_function(func)

        -- Find and append matching examples
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
  symbol_type: string -- "function", "record", "example", "module"
  description: string
  match_score: integer
end

--- Calculate match score for a search result.
--- Scoring tiers (highest to lowest):
---   1. Exact name match: 100 (module), 95 (function/record), 90 (method)
---   2. Partial name match: 80 (module), 75 (function/record), 70 (method)
---   3. Module path contains query: +15 bonus for symbols
---   4. Description match only: 30 (module), 25 (function/record), 20 (method/example)
--- @param name_lower string Lowercase name to match
--- @param desc string Description text (may be nil)
--- @param query_lower string Lowercase query
--- @param base_exact integer Score for exact name match
--- @param base_partial integer Score for partial name match
--- @param base_desc integer Score for description-only match
--- @return integer Score, or 0 if no match
local function calc_score(
    name_lower: string,
    desc: string,
    query_lower: string,
    base_exact: integer,
    base_partial: integer,
    base_desc: integer
  ): integer
  -- Check for name match first (higher priority)
  if name_lower == query_lower then
    return base_exact
  elseif name_lower:find(query_lower, 1, true) then
    return base_partial
  end

  -- Fall back to description match (lower priority)
  if desc and desc:lower():find(query_lower, 1, true) then
    return base_desc
  end

  return 0
end

--- Search documentation for a query string.
--- By default, excludes low-level cosmo.* modules from results.
--- @param query string The search query
--- @param include_cosmo boolean Include low-level cosmo.* modules (default: false)
--- @return {SearchResult} List of search results, sorted by relevance
local function search(query: string, include_cosmo?: boolean): {SearchResult}
  local index, _ = load_index()
  if not index then
    return {}
  end

  local results: {SearchResult} = {}
  local query_lower = query:lower()

  -- Search through all modules
  for mod_name, mod_doc in pairs(index.modules) do
    -- Skip cosmo.* modules unless explicitly requested
    if not include_cosmo and is_cosmo_module(mod_name) then
      goto continue
    end
    local simple_name = mod_name:match("([^%.]+)$") or mod_name
    local simple_lower = simple_name:lower()

    -- Check if module path contains query (for boosting child symbols)
    local module_contains_query = mod_name:lower():find(query_lower, 1, true) ~= nil
    local module_boost = module_contains_query and 15 or 0

    -- Check module name and description
    local mod_score = calc_score(simple_lower, mod_doc.module_doc, query_lower, 100, 80, 30)
    if mod_score > 0 then
      table.insert(results, {
          module_name = mod_name,
          symbol_name = nil,
          symbol_type = "module",
          description = first_paragraph(mod_doc.module_doc),
          match_score = mod_score,
        })
    end

    -- Search functions
    if mod_doc.functions then
      for _, func in ipairs(mod_doc.functions) do
        local score = calc_score(func.name:lower(), func.description, query_lower, 95, 75, 25)
        if score > 0 then
          -- Add module boost for description-only matches
          if score <= 25 and module_boost > 0 then
            score = score + module_boost
          end
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
        local score = calc_score(rec.name:lower(), rec.description, query_lower, 95, 75, 25)
        if score > 0 then
          if score <= 25 and module_boost > 0 then
            score = score + module_boost
          end
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
              local method_score = calc_score(fname:lower(), fdesc, query_lower, 90, 70, 20)
              if method_score > 0 then
                if method_score <= 20 and module_boost > 0 then
                  method_score = method_score + module_boost
                end
                table.insert(results, {
                    module_name = mod_name,
                    symbol_name = rec.name .. "." .. fname,
                    symbol_type = "method",
                    description = first_paragraph(fdesc or ""),
                    match_score = method_score,
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
        local score = calc_score(example_name:lower(), example.description, query_lower, 85, 65, 20)
        if score > 0 then
          if score <= 20 and module_boost > 0 then
            score = score + module_boost
          end
          table.insert(results, {
              module_name = mod_name,
              symbol_name = example_name,
              symbol_type = "example",
              description = first_paragraph(example.description or ""),
              match_score = score,
            })
        end
      end
    end
    ::continue::
  end

  -- Sort by match score (highest first), then by module name for stability
  table.sort(results, function(a: SearchResult, b: SearchResult): boolean
      if a.match_score ~= b.match_score then
        return a.match_score > b.match_score
      end
      return a.module_name < b.module_name
    end)

  return results
end

--- Entry for examples list.
local record ExampleEntry
  module_name: string
  example_name: string
  description: string
end

--- List all examples across all modules.
--- By default, excludes low-level cosmo.* modules.
--- @param include_cosmo boolean Include low-level cosmo.* modules (default: false)
--- @return {ExampleEntry} List of examples sorted by module then name
local function list_all_examples(include_cosmo?: boolean): {ExampleEntry}
  local index, _ = load_index()
  if not index then
    return {}
  end

  local examples: {ExampleEntry} = {}
  for mod_name, mod_doc in pairs(index.modules) do
    -- Skip cosmo.* modules unless explicitly requested
    if not include_cosmo and is_cosmo_module(mod_name) then
      goto continue
    end
    if mod_doc.examples then
      for _, ex in ipairs(mod_doc.examples) do
        local display_name = ex.name:gsub("^Example_?", "")
        table.insert(examples, {
            module_name = mod_name,
            example_name = display_name,
            description = first_paragraph(ex.description or ""),
          })
      end
    end
    ::continue::
  end

  table.sort(examples, function(a: ExampleEntry, b: ExampleEntry): boolean
      if a.module_name ~= b.module_name then
        return a.module_name < b.module_name
      end
      return a.example_name < b.example_name
    end)

  return examples
end

--- Render examples list as CLI output.
--- @param examples {ExampleEntry} List of examples
--- @return string Formatted output
local function render_examples_list(examples: {ExampleEntry}): string
  local lines: {string} = {}

  table.insert(lines, "All examples")
  table.insert(lines, "")

  if #examples == 0 then
    table.insert(lines, "No examples found.")
    return table.concat(lines, "\n")
  end

  -- Group by module
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

--- Find suggestions for a query that didn't match.
--- Builds candidates from module names, records, and methods.
--- @param query string The search query that didn't match
--- @param index DocIndex The documentation index
--- @return {string} List of suggestions, sorted by similarity
local function find_suggestions(query: string, index: DocIndex): {string}
  local candidates: {string} = {}
  local name_to_full: {string: {string}} = {} -- simple name -> list of full paths

  local function add_candidate(simple: string, full: string)
    if not name_to_full[simple] then
      name_to_full[simple] = {}
      table.insert(candidates, simple)
    end
    table.insert(name_to_full[simple], full)
  end

  for mod_name, mod_doc in pairs(index.modules) do
    -- Add module simple name -> full name
    local simple = mod_name:match("([^%.]+)$") or mod_name
    add_candidate(simple, mod_name)

    -- Add record names
    if mod_doc.records then
      for _, rec in ipairs(mod_doc.records) do
        local full_name = mod_name .. "." .. rec.name
        add_candidate(rec.name, full_name)

        -- Add method names from record fields
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

    -- Add function names
    if mod_doc.functions then
      for _, func in ipairs(mod_doc.functions) do
        local full_name = mod_name .. "." .. func.name
        add_candidate(func.name, full_name)
      end
    end
  end

  -- Find similar simple names
  local similar = fuzzy.find_similar(query, candidates, 3)

  -- Map back to full paths
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

--- Show examples for a specific module, optionally filtered by function name.
--- Supports queries like "cosmic.fetch" (all examples) or "cosmic.fetch.get"
--- (only examples matching the "get" function).
--- @param query string The query (e.g., "cosmic.sqlite" or "cosmic.fetch.get")
--- @return DocsResult Result with examples content
local function show_module_examples(query: string): DocsResult
  local index, err = load_index()
  if not index then
    return {
      ok = false,
      output = "error: " .. (err or "no documentation embedded"),
    }
  end

  -- Try exact module match first
  local doc = index.modules[query]
  if doc then
    if not doc.examples or #doc.examples == 0 then
      return {
        ok = false,
        output = "No examples for " .. query,
      }
    end
    local simple_name = query:match("([^%.]+)$") or query
    local lines: {string} = {"# " .. simple_name .. " examples", ""}
    for _, example in ipairs(doc.examples) do
      table.insert(lines, render_example(example))
    end
    return {ok = true, output = table.concat(lines, "\n")}
  end

  -- Try splitting into module + function filter
  -- For "cosmic.fetch.get", try module="cosmic.fetch", func="get"
  -- Walk backwards through dots to find a valid module name
  local parts: {string} = {}
  for part in query:gmatch("[^%.]+") do
    table.insert(parts, part)
  end

  local mod_name: string = nil
  local func_filter: string = nil
  for i = #parts - 1, 1, -1 do
    local candidate = table.concat(parts, ".", 1, i)
    if index.modules[candidate] then
      mod_name = candidate
      func_filter = table.concat(parts, ".", i + 1, #parts)
      break
    end
  end

  if mod_name and func_filter then
    doc = index.modules[mod_name]
    if not doc.examples or #doc.examples == 0 then
      return {
        ok = false,
        output = "No examples for " .. query,
      }
    end

    local matching = find_matching_examples(doc.examples, func_filter)
    if #matching == 0 then
      return {
        ok = false,
        output = "No examples for " .. query,
      }
    end

    local simple_mod = mod_name:match("([^%.]+)$") or mod_name
    local lines: {string} = {"# " .. simple_mod .. "." .. func_filter .. " examples", ""}
    for _, example in ipairs(matching) do
      table.insert(lines, render_example(example))
    end
    return {ok = true, output = table.concat(lines, "\n")}
  end

  -- Nothing found — try suggestions
  local suggestions = find_suggestions(query, index)
  if #suggestions > 0 then
    local lines: {string} = {"error: module not found: " .. query, ""}
    table.insert(lines, "Did you mean?")
    for i = 1, math.min(3, #suggestions) do
      table.insert(lines, "  " .. suggestions[i])
    end
    return {ok = false, output = table.concat(lines, "\n")}
  end
  return {
    ok = false,
    output = "error: module not found: " .. query,
  }
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

  -- Special query: list all examples
  if query == "examples" then
    local examples = list_all_examples()
    return {
      ok = true,
      output = render_examples_list(examples),
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

  -- Nothing found - try to provide suggestions
  local suggestions = find_suggestions(query, index)
  if #suggestions > 0 then
    local lines: {string} = {"error: documentation not found for '" .. query .. "'", ""}
    table.insert(lines, "Did you mean?")
    -- Show up to 5 suggestions
    for i = 1, math.min(5, #suggestions) do
      table.insert(lines, "  " .. suggestions[i])
    end
    table.insert(lines, "")
    table.insert(lines, "Try: cosmic --docs " .. suggestions[1])
    return {ok = false, output = table.concat(lines, "\n")}
  end

  return {
    ok = false,
    output = "error: documentation not found for '" .. query .. "'\n" ..
    "Use 'cosmic --docs' to see available modules.",
  }
end

local record DocsModule
  run: function(query?: string): DocsResult
  has_docs: function(): boolean
  list_topics: function(include_cosmo?: boolean): {{string, string}}
  load_index: function(): DocIndex, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string, include_cosmo?: boolean): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
  show_module_examples: function(query: string): DocsResult
end

local M: DocsModule = {
  run = run,
  has_docs = has_docs,
  list_topics = list_topics,
  load_index = load_index,
  render_module = render_module,
  search = search,
  render_search_results = render_search_results,
  show_module_examples = show_module_examples,
}

return M
