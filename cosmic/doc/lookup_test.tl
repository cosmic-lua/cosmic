#!/usr/bin/env cosmic
-- test cosmic.doc.lookup: scoring, symbol location, and not-found messages

local lookup = require("cosmic.doc.lookup")
local types = require("cosmic.doc.types")
local ModuleDoc = types.ModuleDoc
local DocIndex = types.DocIndex

local function make_index(): DocIndex
  local net: ModuleDoc = {
    file = "net.tl",
    functions = {
      {name = "listen_tcp", description = "Listen on a TCP port",
        params = {}, returns = {}, signature = "()", line = 1, is_local = false},
    },
    records = {
      {name = "Socket", description = "A socket", line = 10, fields = {
          {"fd", "integer", "descriptor"},
          {"accept", "function(self: Socket): Socket | nil, string", "accept one"},
          {"recv", "function(self: Socket): string | nil, string", "receive"},
        }},
    },
    examples = {},
  }
  local empty: ModuleDoc = {
    file = "empty.tl", functions = {}, records = {}, examples = {},
  }
  return {modules = {net = net, empty = empty}}
end

local function test_calc_score_ranks_exact_partial_desc()
  assert(lookup.calc_score("accept", nil, "accept", 9, 5, 2) == 9, "exact name")
  assert(lookup.calc_score("accept_load", nil, "accept", 9, 5, 2) == 5, "partial name")
  assert(lookup.calc_score("other", "will accept peers", "accept", 9, 5, 2) == 2, "desc")
  assert(lookup.calc_score("other", "unrelated", "accept", 9, 5, 2) == 0, "no match")
end
test_calc_score_ranks_exact_partial_desc()

local function test_find_symbol_locations_sees_functions_and_methods()
  local index = make_index()
  local funcs = lookup.find_symbol_locations("listen_tcp", index)
  assert(#funcs == 1 and funcs[1] == "net.listen_tcp", "function location")
  local recs = lookup.find_symbol_locations("Socket", index)
  assert(#recs == 1 and recs[1] == "net.Socket", "record location")
  local methods = lookup.find_symbol_locations("accept", index)
  assert(#methods == 1 and methods[1] == "net.accept", "method field location")
  local none = lookup.find_symbol_locations("fd", index)
  assert(#none == 0, "non-function fields are not addressable")
end
test_find_symbol_locations_sees_functions_and_methods()

local function test_list_symbols_includes_record_methods()
  local index = make_index()
  local symbols = lookup.list_symbols(index.modules["net"])
  local seen: {string: boolean} = {}
  for _, s in ipairs(symbols) do seen[s] = true end
  assert(seen["listen_tcp"], "functions listed")
  assert(seen["Socket"], "records listed")
  assert(seen["accept"] and seen["recv"], "record methods listed")
  assert(not seen["fd"], "plain fields not listed")
end
test_list_symbols_includes_record_methods()

local function test_symbol_not_found_suggests_locations()
  local index = make_index()
  local msg = lookup.symbol_not_found("accept", "empty", index)
  assert(msg:find("not found in 'empty'", 1, true), "names the module searched")
  assert(msg:find("Did you mean?", 1, true), "suggests other locations")
  assert(msg:find("cosmic --docs net.accept", 1, true), "points at the real home")
end
test_symbol_not_found_suggests_locations()

local function test_symbol_not_found_lists_available_symbols()
  local index = make_index()
  local msg = lookup.symbol_not_found("nosuchname", "net", index)
  assert(msg:find("Available symbols in net", 1, true), "lists the module's symbols")
  assert(msg:find("accept", 1, true), "record methods appear in the listing")
end
test_symbol_not_found_lists_available_symbols()

local function test_symbol_not_found_empty_module_points_at_docs()
  local index = make_index()
  local msg = lookup.symbol_not_found("nosuchname", "empty", index)
  assert(msg:find("cosmic --docs empty", 1, true), "empty module points at its doc page")
end
test_symbol_not_found_empty_module_points_at_docs()
