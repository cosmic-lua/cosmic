#!/usr/bin/env cosmic
-- The export surface's alias half: `debug = debug_msg` exports the
-- local under another name, and the doc pipeline must publish the
-- local's doc under the name a caller can actually write. Split from
-- init_test.tl by the 500-line file limit.

local doc = require("_tool.doc")
local check = require("cosmic.check")

-- An aliased export (`debug = debug_msg`) is callable API: the local's
-- doc must survive publishable, re-keyed to the exported name.
local function test_aliased_export_keeps_doc_under_exported_name()
  local source = [[
--- A module with an aliased export.
local record M
  debug: function(message: string)
end

--- Log a debug message.
--- @param message string The message
local function debug_msg(message: string)
  print(message)
end

--- Never exported; must be dropped.
local function helper()
end

local M_impl: M = {
  debug = debug_msg,
}

return M_impl
]]
  local parsed = doc.parse(source, "aliased.tl")
  local pub = doc.publishable(parsed, source)
  local names: {string} = {}
  for _, f in ipairs(pub.functions) do
    table.insert(names, f.name)
  end
  local names_str = table.concat(names, ",")
  assert(names_str:find("debug", 1, true),
    "the aliased export must be published under its exported name (got: "
    .. names_str .. ")")
  assert(not names_str:find("debug_msg", 1, true),
    "the local spelling must not leak to the page (got: " .. names_str .. ")")
  assert(not names_str:find("helper", 1, true),
    "an unexported local is still dropped (got: " .. names_str .. ")")
end
test_aliased_export_keeps_doc_under_exported_name()

-- The real module the alias rule was found on: cosmic.log exports
-- debug/error as renamed locals, and their docs must reach the page.
local function test_log_page_documents_debug_and_error()
  local md = check.must(doc.render_file("cosmic/log.tl"), "should read log.tl")
  assert(md:find("### debug\n", 1, true),
    "log's page must document debug (aliased from debug_msg)")
  assert(md:find("### error\n", 1, true),
    "log's page must document error (aliased from error_msg)")
end
test_log_page_documents_debug_and_error()
