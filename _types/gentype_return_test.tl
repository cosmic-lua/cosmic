#!/usr/bin/env cosmic
--- Tests for gentype's @return comma handling: a top-level comma continues
--- the return list only when followed by a genuine type token. Literal
--- types (true/false/nil) never legitimately continue a return list in
--- definitions.lua, but boolean descriptions routinely say ", false when
--- ..." — treating those words as types generated phantom returns
--- (found via unix.Memory:unmap, whilp/cosmopolitan#198).
--- Split from gentype_test.tl to respect the 500-line file cap.

local gentype = require("_types.gentype")

-- A comma inside a description whose next word is a boolean literal stays
-- description: one return, not a phantom second boolean.
local function test_boolean_description_comma_is_not_a_return()
  local source = [==[
shm = {}

--- Releases the mapping.
---@return boolean unmapped true when this call released the mapping, false when it was already unmapped
function shm.unmap() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "shm"))
  assert(dtl:match("unmap: function%(%): boolean\n"),
    "description comma before 'false' must not grow a second return:\n" .. dtl)
end
test_boolean_description_comma_is_not_a_return()

-- The same shape with 'nil' prose ("..., nil on failure") stays one return.
local function test_nil_prose_comma_is_not_a_return()
  local source = [==[
shm = {}

--- Opens a thing.
---@return integer fd the descriptor on success, nil on failure
function shm.open() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "shm"))
  assert(dtl:match("open: function%(%): integer\n"),
    "description comma before 'nil' must not grow a second return:\n" .. dtl)
end
test_nil_prose_comma_is_not_a_return()

-- Regression pin: genuine multi-returns keep splitting, including a
-- trailing description on the final segment (the corpus does this:
-- "integer seconds, integer nanos amount of CPU consumed").
local function test_genuine_multi_return_still_splits()
  local source = [==[
shm = {}

--- Reports CPU time.
---@return integer seconds, integer nanos amount of CPU consumed in userspace.
function shm.cputime() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "shm"))
  assert(dtl:match("cputime: function%(%): integer, integer\n"),
    "a real type token after the comma must still split:\n" .. dtl)
end
test_genuine_multi_return_still_splits()

-- Single-segment literal returns are not continuations and stay typed.
local function test_single_segment_literal_return_unaffected()
  local source = [==[
shm = {}

--- Always fails.
---@return nil
---@return string errmsg
function shm.fail() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "shm"))
  assert(dtl:match("fail: function%(%): nil, string\n"),
    "leading literal types on their own @return lines keep working:\n" .. dtl)
end
test_single_segment_literal_return_unaffected()
