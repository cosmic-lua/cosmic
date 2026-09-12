#!/usr/bin/env cosmic
--- Tests for gentype's `@field` type parsing: the type capture must keep a
--- generic type's internal comma-and-whitespace intact (`table<K, V>`) the
--- same way `@param` already does via `split_type_desc`, instead of
--- truncating at the first whitespace and dumping the remainder into the
--- description. `table<string, string|string[]>` is the exact shape
--- upstream's `http.Message.headers` annotation uses.
--- Kept separate from gentype_test.tl to respect the 500-line file cap.

local gentype = require("_types.gentype")

-- A `@field` type with an internal comma (a generic whose value type is
-- itself a union) must not be split at that comma: the type stays one
-- whole token and the trailing prose stays the description, not the other
-- way around.
local function test_generic_field_type_keeps_internal_comma()
  local source = [==[
http = {}

---@class http.Message
---@field headers table<string, string|string[]> Header values by canonical name (case-normalized).
--- An HTTP message.

---@return http.Message
function http.get() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "http"))
  assert(not dtl:match("table<string,%s*\n"),
    "the generic type must not be truncated at its internal comma:\n" .. dtl)
  assert(dtl:match("%-%-%- Header values by canonical name %(case%-normalized%)%.\n%s*headers:"),
    "the trailing prose must stay the field's description, not leak into the type:\n" .. dtl)
  assert(dtl:match("headers: {string:"),
    "the field must still render as a string-keyed map, not a malformed fragment:\n" .. dtl)
end
