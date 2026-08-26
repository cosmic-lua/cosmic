--- Access embedded documentation — a `go doc`-style CLI over the binary.

local docs_render = require("cosmic.doc.show")
local docs_lookup = require("cosmic.doc.lookup")
local types = require("cosmic.doc.types")
local ModuleDoc = types.ModuleDoc
local DocIndex = types.DocIndex
local SearchResult = types.SearchResult
local ExampleEntry = types.ExampleEntry

local INDEX_PATH = "/zip/.docs/index.lua"
local GUIDES_DIR = "/zip/docs/guides"

local cached_index: DocIndex = nil

--- Load the embedded documentation index.
--- @return DocIndex | nil The documentation index, or nil if not available
--- @return string Error message if loading failed
local function embedded_index(): DocIndex | nil, string
  if cached_index then
    return cached_index, nil
  end

  local source = require("cosmic.fs").read(INDEX_PATH)
  if not source then
    return nil, "no documentation index embedded"
  end

  local chunk, err = load("return " .. source, "=docindex", "t", {})
  if not chunk then
    return nil, "failed to parse index: " .. (err or "unknown")
  end

  local ok, result = pcall(chunk)
  if not ok then
    return nil, "failed to load index: " .. tostring(result)
  end

  if not (result is DocIndex) then
    return nil, "index is not a doc index"
  end

  cached_index = result
  return cached_index, nil
end

--- Check if embedded docs are available.
--- @return boolean True if docs are embedded
local function is_available(): boolean
  local index, _ = embedded_index()
  return index ~= nil
end

--- List available guide topics from the embedded guides directory.
local function guide_topics(): {string}
  local fs = require("cosmic.fs")
  local dir = fs.open_dir(GUIDES_DIR)
  if not dir then return {} end
  local topics: {string} = {}
  while true do
    local name = dir:read()
    if not name then break end
    if name ~= "index.md" and string.match(name, "%.md$") then
      topics[#topics + 1] = string.sub(name, 1, #name - 3)
    end
  end
  dir:close()
  table.sort(topics)
  return topics
end

--- List guides with descriptions from each file's heading.
local function guides(): {{string, string}}
  local names = guide_topics()
  local out: {{string, string}} = {}
  for _, name in ipairs(names) do
    local content = require("cosmic.fs").read(GUIDES_DIR .. "/" .. name .. ".md")
    local desc = name
    if content then
      local heading = string.match(content, "^#%s+(.-)%s*\n")
      if heading then desc = heading end
    end
    table.insert(out, {name, desc})
  end
  return out
end

--- Show a guide topic or list all guides.
local function guide(topic: string): string | nil, string
  local fs = require("cosmic.fs")
  if topic == "" then
    local content, err = fs.read(GUIDES_DIR .. "/index.md")
    if not content then
      return nil, "error: " .. (err or "no guides available")
    end
    return content
  end
  local topics = guide_topics()
  local valid = false
  for _, t in ipairs(topics) do
    if t == topic then valid = true; break end
  end
  if not valid then
    local lines: {string} = {"error: unknown guide '" .. topic .. "'", ""}
    table.insert(lines, "Available guides:")
    for _, t in ipairs(topics) do
      table.insert(lines, "  " .. t)
    end
    return nil, table.concat(lines, "\n")
  end
  local path = GUIDES_DIR .. "/" .. topic .. ".md"
  local content, err = fs.read(path)
  if not content then
    return nil, "error: " .. (err or "failed to load " .. path)
  end
  return content
end

--- Check if a module name is a low-level cosmo module.
-- Bare `cosmo` counts: it is the top-level binding surface, the same
-- kind of thing as `cosmo.unix`. Matching only the dotted form listed it
-- as if it were a `cosmic.*` module.
local function is_cosmo_module(name: string): boolean
  return name == "cosmo" or name:match("^cosmo%.") ~= nil
end

--- List all available documentation topics. Internal modules (per
--- the `_` rule) are excluded: they are not API. They remain
--- searchable and directly addressable by name.
--- @param include_cosmo boolean Include low-level cosmo.* modules (default: false)
--- @return {{string, string}} List of {name, description} pairs, sorted by name
local function topics(include_cosmo?: boolean): {{string, string}}
  local index, _ = embedded_index()
  if not index then return {} end
  local idx = index

  local out: {{string, string}} = {}
  for name, doc in pairs(idx.modules) do
    if not doc.internal and (include_cosmo or not is_cosmo_module(name)) then
      local desc = docs_render.first_paragraph(doc.module_doc)
      table.insert(out, {name, desc})
    end
  end

  table.sort(out, function(a: {string, string}, b: {string, string}): boolean
      return a[1] < b[1]
    end)

  return out
end

local calc_score = docs_lookup.calc_score

--- Search documentation for a query string. Internal modules are
--- included; their results carry internal = true so the renderer can
--- badge them.
--- @param query string The search query
--- @param include_cosmo boolean Include low-level cosmo.* modules (default: false)
--- @return {SearchResult} List of search results, sorted by relevance
local function search(query: string, include_cosmo?: boolean): {SearchResult}
  local index, _ = embedded_index()
  if not index then return {} end
  local idx = index
  local results: {SearchResult} = {}
  local query_lower = query:lower()

  for mod_name, mod_doc in pairs(idx.modules) do
    if not include_cosmo and is_cosmo_module(mod_name) then goto continue end
    local simple_name = mod_name:match("([^%.]+)$") or mod_name
    local simple_lower = simple_name:lower()
    local module_contains_query = mod_name:lower():find(query_lower, 1, true) ~= nil
    local module_boost = module_contains_query and 15 or 0

    -- Score against both the simple name ("io") and the full dotted name
    -- ("cosmic.child.io") so directory-module shards stay reachable by
    -- their dotted suffix (e.g. a search for "child.io").
    local mod_score = math.max(
      calc_score(simple_lower, mod_doc.module_doc, query_lower, 100, 80, 30),
      calc_score(mod_name:lower(), mod_doc.module_doc, query_lower, 100, 80, 30))
    if mod_score > 0 then
      table.insert(results, {
          module_name = mod_name, symbol_name = nil, symbol_type = "module", internal = mod_doc.internal,
          description = docs_render.first_paragraph(mod_doc.module_doc), match_score = mod_score,
        })
    end
    if mod_doc.functions then
      for _, func in ipairs(mod_doc.functions) do
        local score = calc_score(func.name:lower(), func.description, query_lower, 95, 75, 25)
        if score > 0 then
          if score <= 25 and module_boost > 0 then score = score + module_boost end
          table.insert(results, {
              module_name = mod_name, symbol_name = func.name, symbol_type = "function", internal = mod_doc.internal,
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
              module_name = mod_name, symbol_name = rec.name, symbol_type = "record", internal = mod_doc.internal,
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
                    match_score = ms, internal = mod_doc.internal,
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
              module_name = mod_name, symbol_name = example_name, symbol_type = "example", internal = mod_doc.internal,
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
  local index, _ = embedded_index()
  if not index then return {} end
  local idx = index

  local examples: {ExampleEntry} = {}
  for mod_name, mod_doc in pairs(idx.modules) do
    if mod_doc.internal or (not include_cosmo and is_cosmo_module(mod_name)) then
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
--- @param query string Module name (full, bare, or module.function)
--- @return string | nil The rendered examples, or nil when not found
--- @return string? The not-found message
local function module_examples(query: string): string | nil, string
  local index, err = embedded_index()
  if not index then
    return nil, "error: " .. (err or "no documentation embedded")
  end
  local idx = index
  -- Resolve bare name (e.g. "child" -> "cosmic.child")
  local resolved = idx.modules[query] and query or (idx.modules["cosmic." .. query] and "cosmic." .. query or nil)
  if resolved then
    local doc = idx.modules[resolved]
    if doc.examples and #doc.examples > 0 then
      local simple_name = resolved:match("([^%.]+)$") or resolved
      local lines: {string} = {"# " .. simple_name .. " examples", ""}
      for _, example in ipairs(doc.examples) do
        table.insert(lines, docs_render.render_example(example))
      end
      return table.concat(lines, "\n")
    end
    -- The resolved module has no examples, but the query may also read as
    -- module.function — cosmic.quicksand.box.run is both the (example-less)
    -- run submodule and box's run() function. Fall through and try the
    -- function-filter interpretation before reporting no examples.
  end

  local parts: {string} = {}
  for part in query:gmatch("[^%.]+") do table.insert(parts, part) end

  local mod_name: string = nil
  local func_filter: string = nil
  for i = #parts - 1, 1, -1 do
    local candidate = table.concat(parts, ".", 1, i)
    if idx.modules[candidate] then
      mod_name = candidate
      func_filter = table.concat(parts, ".", i + 1, #parts)
      break
    end
  end

  if mod_name and func_filter then
    local doc = idx.modules[mod_name]
    if doc.examples and #doc.examples > 0 then
      local matching = docs_render.find_matching_examples(doc.examples, func_filter)
      if #matching > 0 then
        local simple_mod = mod_name:match("([^%.]+)$") or mod_name
        local lines: {string} = {"# " .. simple_mod .. "." .. func_filter .. " examples", ""}
        for _, example in ipairs(matching) do
          table.insert(lines, docs_render.render_example(example))
        end
        return table.concat(lines, "\n")
      end
    end
    return nil, "No examples for " .. query
  end

  if resolved then
    return nil, "No examples for " .. resolved
  end

  local suggestions = docs_render.find_example_suggestions(query, idx)
  if #suggestions > 0 then
    local lines: {string} = {"error: module not found: " .. query, "", "Did you mean?"}
    for i = 1, math.min(3, #suggestions) do table.insert(lines, "  " .. suggestions[i]) end
    return nil, table.concat(lines, "\n")
  end
  return nil, "error: module not found: " .. query
end

--- Main entry point for the docs command.
--- @param query string Optional query string (module or module.symbol)
--- @return string | nil The rendered documentation, or nil when not found
--- @return string? The not-found message
local function run(query?: string): string | nil, string
  local index, err = embedded_index()
  if not index then
    return nil, "error: " .. (err or "no documentation embedded") .. "\n"
    .. "Build with 'make cosmic' to include documentation."
  end
  local idx = index

  if not query or query == "" then
    local topic_list = topics()
    if #topic_list == 0 then
      return nil, "error: no documentation found"
    end
    return docs_render.render_topic_list(topic_list)
  end

  if query == "examples" then
    local examples = list_all_examples()
    return docs_render.render_examples_list(examples)
  end

  if query == "guide" then
    return guide("")
  end
  if query:sub(1, 6) == "guide." then
    return guide(query:sub(7))
  end

  if idx.modules[query] then
    return docs_render.render_module(query, idx.modules[query])
  end

  -- Bare module names short-circuit to their cosmic.* page, not fuzzy search
  if idx.modules["cosmic." .. query] then
    local full = "cosmic." .. query
    return docs_render.render_module(full, idx.modules[full])
  end

  -- Try splitting query into module + remainder by iterating splits longest-to-shortest
  local parts: {string} = {}
  for part in query:gmatch("[^%.]+") do
    table.insert(parts, part)
  end

  local matched_mod: string = nil
  local remainder: {string} = {}
  for i = #parts - 1, 1, -1 do
    local candidate = table.concat(parts, ".", 1, i)
    if not idx.modules[candidate] and idx.modules["cosmic." .. candidate] then
      candidate = "cosmic." .. candidate
    end
    if idx.modules[candidate] then
      matched_mod = candidate
      for j = i + 1, #parts do
        table.insert(remainder, parts[j])
      end
      break
    end
  end

  if matched_mod and #remainder > 0 then
    local doc = idx.modules[matched_mod]
    local symbol = remainder[1]
    local method = remainder[2]
    local rendered = docs_render.find_symbol(doc, symbol, method)
    if rendered then
      return rendered
    else
      if method then
        return nil, "error: method '" .. method .. "' not found in '"
        .. matched_mod .. "." .. symbol .. "'\n"
        .. "Use 'cosmic --docs " .. matched_mod .. "." .. symbol
        .. "' to see available methods."
      else
        return nil, docs_lookup.symbol_not_found(symbol, matched_mod, idx)
      end
    end
  end

  local suggestions = docs_render.find_suggestions(query, idx)
  if #suggestions > 0 then
    local lines: {string} = {"error: documentation not found for '" .. query .. "'", ""}
    table.insert(lines, "Did you mean?")
    for i = 1, math.min(5, #suggestions) do
      table.insert(lines, "  " .. suggestions[i])
    end
    table.insert(lines, "")
    table.insert(lines, "Try: cosmic --docs " .. suggestions[1])
    return nil, table.concat(lines, "\n")
  end

  return nil, "error: documentation not found for '" .. query .. "'\n"
  .. "Use 'cosmic --docs' to see available modules."
end

local record DocsModule
  run: function(query?: string): string | nil, string
  is_available: function(): boolean
  topics: function(include_cosmo?: boolean): {{string, string}}
  embedded_index: function(): DocIndex | nil, string
  render_module: function(name: string, doc: ModuleDoc): string
  search: function(query: string, include_cosmo?: boolean): {SearchResult}
  render_search_results: function(results: {SearchResult}, query: string): string
  module_examples: function(query: string): string | nil, string
  guide: function(topic: string): string | nil, string
  guide_topics: function(): {string}
  guides: function(): {{string, string}}
end

local M: DocsModule = {
  run = run,
  is_available = is_available,
  topics = topics,
  embedded_index = embedded_index,
  render_module = docs_render.render_module,
  search = search,
  render_search_results = docs_render.render_search_results,
  module_examples = module_examples,
  guide = guide,
  guide_topics = guide_topics,
  guides = guides,
}

return M
