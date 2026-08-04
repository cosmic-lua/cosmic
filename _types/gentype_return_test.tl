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

-- A union-typed vararg (`@return string|number? ... desc`) must render as a
-- Teal variadic return, not a single scalar entry that silently drops the
-- "..." (the old bare-identifier vararg pattern only matched a single word
-- before "..."). Found via lsqlite3.Statement/VM:get_uvalues,
-- whilp/cosmopolitan definitions.lua:1088,1252.
local function test_union_vararg_return()
  local source = [==[
lsqlite3 = {}

--- Gets all column values.
---@return string|number? ... the values of all columns
---@nodiscard
function lsqlite3.Statement:get_uvalues() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "lsqlite3"))
  assert(dtl:match("get_uvalues: function%(self: Statement%): string | number | nil %.%.%."),
    "a union-typed vararg should render as a variadic return:\n" .. dtl)
  assert(not dtl:match("get_uvalues[^\n]*values of all columns"),
    "the vararg description must not leak into the type list:\n" .. dtl)
end
test_union_vararg_return()

-- A vararg return is only meaningful as the true LAST return: Teal forbids
-- anything after one. Upstream documents unix.fcntl this way (`@return
-- any|nil ...` followed by `@return string? error` and `@return
-- unix.Errno? errno` on separate lines) — the leading vararg there is not
-- actually final, so it must demote to a plain type instead of rendering
-- syntax Teal rejects.
local function test_non_last_vararg_demotes_to_plain_type()
  local source = [==[
unix = {}

--- Manipulates file descriptor.
---@param fd integer
---@return any|nil ...
---@return string? error
---@return unix.Errno? errno
function unix.fcntl(fd) end
]==]
  local module = gentype.parse_module(source, "unix")
  local output, err = gentype.render_module(module)
  assert(output, "a non-last vararg must demote instead of failing to render: "
    .. tostring(err))
  assert(output:match("fcntl: function%(fd: integer%): any | nil, string, Errno"),
    "a non-last vararg should demote to a plain type:\n" .. output)
end
test_non_last_vararg_demotes_to_plain_type()

-- A class method's iterator return spells "the receiver again" as a bare
-- `self` token (`fun(...) iterator, self`) — the same role the module's
-- constructor-style variants spell out with the full class name (`iterator,
-- lsqlite3.VM vm`). The comma-continuation heuristic must recognize `self`
-- as a genuine return-type token, not swallow it into the description.
-- Found via lsqlite3.VM:nrows/rows/urows,
-- whilp/cosmopolitan definitions.lua:1279,1293,1301.
local function test_self_return_token()
  local source = [==[
lsqlite3 = {}

--- Iterates named rows.
---@param sql string
---@return fun(self: lsqlite3.VM): table<string, string|number> iterator, self
---@nodiscard
function lsqlite3.VM:nrows(sql) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "lsqlite3"))
  assert(dtl:match("nrows: function%(self: VM, sql: string%): function, VM"),
    "self should resolve to the enclosing class and gain a second return:\n" .. dtl)
end
test_self_return_token()

-- `@return table <word>` must not reinterpret the lowercase word as the
-- actual type: a heuristic that fires on zero cases in the corpus today
-- (confirmed by grep) and is a silent hazard for a future annotation like
-- `@return table result the returned value`, where "result" would wrongly
-- become the rendered type.
local function test_table_return_word_not_reinterpreted()
  local source = [==[
unix = {}

--- Something.
---@return table result the returned value
function unix.something() end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "unix"))
  assert(dtl:match("something: function%(%): table\n"),
    "a table return must stay 'table', not the first description word:\n" .. dtl)
end
test_table_return_word_not_reinterpreted()
