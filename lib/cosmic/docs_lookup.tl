--- Symbol lookup and suggestion helpers for the docs module.
--- Locates symbols across modules and builds not-found error messages.

local types = require("cosmic.doc_types")
local ModuleDoc = types.ModuleDoc
local DocIndex = types.DocIndex

--- Calculate match score for a search result.
--- @param name_lower string Lowercased candidate name
--- @param desc string Candidate description (may be nil)
--- @param query_lower string Lowercased query
--- @param base_exact integer Score for an exact name match
--- @param base_partial integer Score for a partial name match
--- @param base_desc integer Score for a description match
--- @return integer The match score, 0 for no match
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

--- Find where a symbol lives across all modules (for "did you mean" suggestions).
--- @param symbol string The symbol name to locate
--- @param index DocIndex The documentation index
--- @return {string} Qualified locations (module.symbol) where the name exists
local function find_symbol_locations(symbol: string, index: DocIndex): {string}
  local out: {string} = {}
  local sym_lower = symbol:lower()
  for mod_name, mod_doc in pairs(index.modules) do
    if mod_doc.functions then
      for _, func in ipairs(mod_doc.functions) do
        if func.name:lower() == sym_lower then table.insert(out, mod_name .. "." .. func.name) end
      end
    end
    if mod_doc.records then
      for _, rec in ipairs(mod_doc.records) do
        if rec.name:lower() == sym_lower then
          table.insert(out, mod_name .. "." .. rec.name)
        end
        if rec.fields then
          for _, field in ipairs(rec.fields) do
            if field[1]:lower() == sym_lower and field[2]:match("^function") then
              table.insert(out, mod_name .. "." .. field[1])
            end
          end
        end
      end
    end
  end
  return out
end

--- List a module's addressable symbols (functions, records, record methods).
--- @param doc ModuleDoc The module documentation
--- @return {string} Symbol names, deduplicated, in definition order
local function list_symbols(doc: ModuleDoc): {string}
  local out: {string} = {}
  local seen: {string: boolean} = {}
  local function add(name: string)
    if not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  if doc.functions then
    for _, func in ipairs(doc.functions) do add(func.name) end
  end
  if doc.records then
    for _, rec in ipairs(doc.records) do
      add(rec.name)
      if rec.fields then
        for _, field in ipairs(rec.fields) do
          if field[2]:match("^function") then add(field[1]) end
        end
      end
    end
  end
  return out
end

--- Build the error message for a symbol that was not found in a module.
--- Suggests other locations for the name, or lists the module's available
--- symbols so the caller does not need a second lookup.
--- @param symbol string The symbol that was not found
--- @param matched_mod string The module that was searched
--- @param index DocIndex The documentation index
--- @return string Multi-line error message
local function symbol_not_found(symbol: string, matched_mod: string, index: DocIndex): string
  local locations = find_symbol_locations(symbol, index)
  local lines: {string} = {"error: symbol '" .. symbol .. "' not found in '" .. matched_mod .. "'"}
  if #locations > 0 then
    table.insert(lines, "")
    table.insert(lines, "Did you mean?")
    for i = 1, math.min(3, #locations) do table.insert(lines, "  cosmic --docs " .. locations[i]) end
  else
    local available = list_symbols(index.modules[matched_mod])
    if #available > 0 then
      table.insert(lines, "")
      table.insert(lines, "Available symbols in " .. matched_mod .. ":")
      for i = 1, math.min(20, #available) do
        table.insert(lines, "  " .. available[i])
      end
      if #available > 20 then
        table.insert(lines, "  ... and " .. (#available - 20) .. " more")
      end
    else
      table.insert(lines, "Use 'cosmic --docs " .. matched_mod .. "' to see available symbols.")
    end
  end
  return table.concat(lines, "\n")
end

local record DocsLookupModule
  calc_score: function(name_lower: string, desc: string, query_lower: string, base_exact: integer, base_partial: integer, base_desc: integer): integer
  find_symbol_locations: function(symbol: string, index: DocIndex): {string}
  list_symbols: function(doc: ModuleDoc): {string}
  symbol_not_found: function(symbol: string, matched_mod: string, index: DocIndex): string
end

local M: DocsLookupModule = {
  calc_score = calc_score,
  find_symbol_locations = find_symbol_locations,
  list_symbols = list_symbols,
  symbol_not_found = symbol_not_found,
}

return M
