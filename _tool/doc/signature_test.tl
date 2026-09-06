#!/usr/bin/env cosmic
-- `function_signatures` reads name, position, and declared return slot
-- count off a module's own AST instead of scanning its text -- so a
-- signature split across several lines counts correctly, and a
-- carried-patch data file whose STRING payload happens to contain
-- `function Owner:name(...)` text is never mistaken for a real
-- definition.

local sig = require("_tool.doc.signature")
local check = require("cosmic.check")

-- The regression case a string scan cannot see: the return type spills
-- onto its own line, past the closing `)` of the parameter list. The
-- old `exports.return_slots(f.signature)` path counted commas in the
-- TEXT it captured, which only ever reached the end of the closing
-- paren's own line -- missing a continuation line entirely and
-- undercounting. Reading `#rets.tuple` off the AST is immune: the
-- parser already resolved the whole type list regardless of line
-- breaks.
local function test_multiline_return_type_counts_all_slots()
  local source = [[
local function multiline_ret(
    a: integer,
    b: string
  ): boolean,
    string
  return true, "ok"
end
]]
  local sigs = check.must(sig.function_signatures(source, "multiline_ret.tl"))
  assert(#sigs == 1, "one function found")
  assert(sigs[1].name == "multiline_ret", "got: " .. sigs[1].name)
  assert(sigs[1].return_slots == 2,
    "the split return type still counts as 2 slots, got " ..
    tostring(sigs[1].return_slots))
end

-- A `function(...)` parameter whose OWN return type is a union
-- (`T | nil`) must not be mistaken for the outer function's return
-- list -- the outer function's own `rets` is a distinct AST node from
-- any callback parameter's type, so nesting depth never confuses the
-- count the way a text scan's paren/brace tracking has to work to get
-- right.
local function test_union_return_with_callback_param_counts_two()
  local source = [[
local function with_callback(
    visitor: function(integer): (boolean, string)
  ): string | nil, string
  return nil, "e"
end
]]
  local sigs = check.must(sig.function_signatures(source, "with_callback.tl"))
  assert(#sigs == 1, "one function found")
  assert(sigs[1].return_slots == 2,
    "a union first slot plus a second slot is still 2, got " ..
    tostring(sigs[1].return_slots))
end

-- The real-world case this item exists for: `3p/tl/tl_patch/closure.tl`
-- is a `return { ... }` data table whose `find`/`replace` fields are
-- long-bracket STRINGS containing patch source text -- including lines
-- that read `function TypeChecker:add_global(...)` at the start of
-- their own line. The old text-based extractor could not tell a string
-- literal's contents from real code and phantom-matched these as
-- function definitions; the AST reader parses the file for what it
-- actually is (a table of records, no function statement at all) and
-- correctly finds none.
local function test_function_text_inside_a_string_literal_is_not_a_definition()
  local source = [[
return {
  ["closure-global-function"] = {
    file = "tl.lua",
    find = [=====[      ["global_function"] = {
         before = function(self, node)
            self:widen_all_unions()
         end,]=====],
    replace = [=====[      ["global_function"] = {
         before = function(self, node)
            self:widen_all_unions(self.chunk_body)
         end,]=====],
  },
  ["closure-continuation-carry"] = {
    file = "tl.lua",
    find = [=====[   function TypeChecker:add_global(node, varname, valtype, is_assigning)]=====],
    replace = [=====[   function TypeChecker:widen_for_closure(node)
      return nil
   end

   function TypeChecker:add_global(node, varname, valtype, is_assigning)]=====],
  },
}
]]
  local sigs = check.must(sig.function_signatures(source, "closure.tl"))
  assert(#sigs == 0,
    "a `function Owner:name(...)` line inside a string literal is " ..
    "not a real definition, found " .. tostring(#sigs))
end

-- Owner qualification: bare for a dot-defined record function (the
-- owner segment is dropped, matching the old text extractor's own
-- rule), the full `Owner:name` for the colon (method) form.
local function test_record_function_name_qualification()
  local source = [[
local record M
end
function M.bar(x: integer): M
end
function M:baz(x: integer): M
end
]]
  local sigs = check.must(sig.function_signatures(source, "record_fns.tl"))
  assert(#sigs == 2, "two functions found, got " .. #sigs)
  assert(sigs[1].name == "bar", "dot form drops the owner, got: " .. sigs[1].name)
  assert(sigs[1].is_local == false, "a record function is never local")
  assert(sigs[2].name == "M:baz", "colon form keeps Owner:name, got: " .. sigs[2].name)
end

-- `Example*` functions are excluded here too: `init.tl`'s own separate
-- Examples loop extracts their body and expected output, and a second
-- entry from this shard would duplicate them as ordinary functions.
local function test_example_functions_are_excluded()
  local source = [[
local function Example_basic()
  print("hi")
end

local function real_helper()
end
]]
  local sigs = check.must(sig.function_signatures(source, "examples.tl"))
  assert(#sigs == 1, "only the non-Example function, got " .. #sigs)
  assert(sigs[1].name == "real_helper", "got: " .. sigs[1].name)
end

print("all doc-signature tests passed")
