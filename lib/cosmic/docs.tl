--- Access embedded documentation from the cosmic binary.
--- Provides a CLI interface similar to Go's `go doc` command.
--- Documentation is parsed at build time and embedded as a serialized Lua index.
---
--- Two access paths:
---   - Non-interactive: `cosmic --docs <query>` from the command line
---   - Interactive: `help(<query>)` in the REPL (`cosmic -i`)

local cio = require("cosmic.io")
local docs_render = require("cosmic.docs_render")
local types = require("cosmic.doc_types")
local ModuleDoc = types.ModuleDoc
local DocIndex = types.DocIndex
local DocsResult = types.DocsResult
local SearchResult = types.SearchResult
local ExampleEntry = types.ExampleEntry

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
  local index, _ = load_index()
  if not index then
    return {}
  end

  local topics: {{string, string}} = {}
  for name, doc in pairs(index.modules) do
    if include_cosmo or not is_cosmo_module(name) then
      local desc = docs_render.first_paragraph(doc.module_doc)
      table.insert(topics, {name, desc})
    end
  end

  table.sort(topics, function(a: {string, string}, b: {string, string}): boolean
      return a[1] < b[1]
    end)

  return topics
end

--- Calculate match score for a search result.
local function calc_score(
    name_lower: string,
    desc: string,
    query_lower: string,
    base_exact: integer,
    base_partial: integer,
    base_desc: integer
  ): integer
  if name_lower == query_lower then
    return base_exact
  elseif name_lower:find(query_lower, 1, true) then
    return base_partial
  end
  if desc and desc:lower():find(query_lower, 1, true) then
    return base_desc
  end
  return 0
end

--- Search documentation for a query string.
--- @param query string The search query
--- @param include_cosmo boolean Include low-level cosmo.* modules (default: false)
--- @return {SearchResult} List of search results, sorted by relevance
local function search(query: string, include_cosmo?: boolean): {SearchResult}
  local index, _ = load_index()
  if not index then return {} end
  local results: {SearchResult} = {}
  local query_lower = query:lower()

  for mod_name, mod_doc in pairs(index.modules) do
    if not include_cosmo and is_cosmo_module(mod_name) then goto continue end
    local simple_name = mod_name:match("([^%.]+)$") or mod_name
    local simple_lower = simple_name:lower()
    local module_contains_query = mod_name:lower():find(query_lower, 1, true) ~= nil
    local module_boost = module_contains_query and 15 or 0

    local mod_score = calc_score(simple_lower, mod_doc.module_doc, query_lower, 100, 80, 30)
    if mod_score > 0 then
      table.insert(results, {
          module_name = mod_name, symbol_name = nil, symbol_type = "module",
          description = docs_render.first_paragraph(mod_doc.module_doc), match_score = mod_score,
        })
    end
    if mod_doc.functions then
      for _, func in ipairs(mod_doc.functions) do
        local score = calc_score(func.name:lower(), func.description, query_lower, 95, 75, 25)
        if score > 0 then
          if score <= 25 and module_boost > 0 then score = score + module_boost end
          table.insert(results, {
              module_name = mod_name, symbol_name = func.name, symbol_type = "function",
              description = docs_render.first_paragraph(func.description or ""), match_score = score,
            })
        end
      end
    end
    if mod_doc.records then
      for _, rec in ipairs(mod_doc.records) do
        local score = calc_score(rec.name:lower(), rec.description, query_lower, 95, 75, 25)
        if score > 0 then
          if score <= 25 and module_boost > 0 then score = score + module_boost end
          table.insert(results, {
              module_name = mod_name, symbol_name = rec.name, symbol_type = "record",
              description = docs_render.first_paragraph(rec.description or ""), match_score = score,
            })
        end
        if rec.fields then
          for _, field in ipairs(rec.fields) do
            local fname, ftype, fdesc = field[1], field[2], field[3]
            if ftype:match("^function") then
              local ms = calc_score(fname:lower(), fdesc, query_lower, 90, 70, 20)
              if ms > 0 then
                if ms <= 20 and module_boost > 0 then ms = ms + module_boost end
                table.insert(results, {
                    module_name = mod_name, symbol_name = rec.name .. "." .. fname,
                    symbol_type = "method", description = docs_render.first_paragraph(fdesc or ""),
                    match_score = ms,
                  })
              end
            end
          end
        end
      end
    end
    if mod_doc.examples then
      for _, example in ipairs(mod_doc.examples) do
        local example_name = example.name:gsub("^Example_?", "")
        local score = calc_score(example_name:lower(), example.description, query_lower, 85, 65, 20)
        if score > 0 then
          if score <= 20 and module_boost > 0 then score = score + module_boost end
          table.insert(results, {
              module_name = mod_name, symbol_name = example_name, symbol_type = "example",
              description = docs_render.first_paragraph(example.description or ""), match_score = score,
            })
        end
      end
    end
    ::continue::
  end

  table.sort(results, function(a: SearchResult, b: SearchResult): boolean
      if a.match_score ~= b.match_score then return a.match_score > b.match_score end
      return a.module_name < b.module_name
    end)
  return results
end

--- List all examples across all modules.
--- @param include_cosmo boolean Include low-level cosmo.* modules (default: false)
--- @return {ExampleEntry} List of examples sorted by module then name
local function list_all_examples(include_cosmo?: boolean): {ExampleEntry}
  local index, _ = load_index()
  if not index then
    return {}
  end

  local examples: {ExampleEntry} = {}
  for mod_name, mod_doc in pairs(index.modules) do
    if not include_cosmo and is_cosmo_module(mod_name) then
      goto continue
    end
    if mod_doc.examples then
      for _, ex in ipairs(mod_doc.examples) do
        local display_name = ex.name:gsub("^Example_?", "")
        table.insert(examples, {
            module_name = mod_name,
            example_name = display_name,
            description = docs_render.first_paragraph(ex.description or ""),
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

--- Show examples for a specific module, optionally filtered by function name.
--- @param query string The query (e.g., "cosmic.sqlite" or "cosmic.fetch.get")
--- @return DocsResult Result with examples content
local function show_module_examples(query: string): DocsResult
  local index, err = load_index()
  if not index then
    return {ok = false, output = "error: " .. (err or "no documentation embedded")}
  end

  local doc = index.modules[query]
  if doc then
    if not doc.examples or #doc.examples == 0 then
      return {ok = false, output = "No examples for " .. query}
    end
    local simple_name = query:match("([^%.]+)$") or query
    local lines: {string} = {"# " .. simple_name .. " examples", ""}
    for _, example in ipairs(doc.examples) do
      table.insert(lines, docs_render.render_example(example))
    end
    return {ok = true, output = table.concat(lines, "\n")}
  end

  -- Try splitting into module + function filter
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
      return {ok = false, output = "No examples for " .. query}
    end
    local matching = docs_render.find_matching_examples(doc.examples, func_filter)
    if #matching == 0 then
      return {ok = false, output = "No examples for " .. query}
    end
    local simple_mod = mod_name:match("([^%.]+)$") or mod_name
    local lines: {string} = {"# " .. simple_mod .. "." .. func_filter .. " examples", ""}
    for _, example in ipairs(matching) do
      table.insert(lines, docs_render.render_example(example))
    end
    return {ok = true, output = table.concat(lines, "\n")}
  end

  local suggestions = docs_render.find_suggestions(query, index)
  if #suggestions > 0 then
    local lines: {string} = {"error: module not found: " .. query, ""}
    table.insert(lines, "Did you mean?")
    for i = 1, math.min(3, #suggestions) do
      table.insert(lines, "  " .. suggestions[i])
    end
    return {ok = false, output = table.concat(lines, "\n")}
  end
  return {ok = false, output = "error: module not found: " .. query}
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

  if not query or query == "" then
    local topics = list_topics()
    if #topics == 0 then
      return {ok = false, output = "error: no documentation found"}
    end
    return {ok = true, output = docs_render.render_topic_list(topics)}
  end

  if query == "examples" then
    local examples = list_all_examples()
    return {ok = true, output = docs_render.render_examples_list(examples)}
  end

  if index.modules[query] then
    return {ok = true, output = docs_render.render_module(query, index.modules[query])}
  end

  -- Walk backwards to find the longest valid module prefix
  local parts: {string} = {}
  for part in query:gmatch("[^%.]+") do
    table.insert(parts, part)
  end

  if #parts >= 2 then
    local mod_name: string = nil
    local suffix_parts: {string} = {}
    for i = #parts - 1, 1, -1 do
      local candidate = table.concat(parts, ".", 1, i)
      if index.modules[candidate] then
        mod_name = candidate
        for j = i + 1, #parts do
          table.insert(suffix_parts, parts[j])
        end
        break
      end
    end

    if mod_name then
      local doc = index.modules[mod_name]
      if #suffix_parts == 1 then
        local symbol = suffix_parts[1]
        local rendered = docs_render.find_symbol(doc, symbol)
        if rendered then
          return {ok = true, output = rendered}
        else
          return {
            ok = false,
            output = "error: symbol '" .. symbol .. "' not found in '" .. mod_name .. "'\n" ..
            "Use 'cosmic --docs " .. mod_name .. "' to see available symbols.",
          }
        end
      elseif #suffix_parts >= 2 then
        local record_name = suffix_parts[#suffix_parts - 1]
        local method = suffix_parts[#suffix_parts]
        local rendered = docs_render.find_symbol(doc, record_name, method)
        if rendered then
          return {ok = true, output = rendered}
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

  local suggestions = docs_render.find_suggestions(query, index)
  if #suggestions > 0 then
    local lines: {string} = {"error: documentation not found for '" .. query .. "'", ""}
    table.insert(lines, "Did you mean?")
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
  render_module = docs_render.render_module,
  search = search,
  render_search_results = docs_render.render_search_results,
  show_module_examples = show_module_examples,
}

return M
