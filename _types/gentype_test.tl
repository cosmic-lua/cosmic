#!/usr/bin/env cosmic
--- Tests for gentype.tl type definition generator.
---
--- The declarations are GENERATED, into `o/_types/types_gen/`, and not committed —
--- so there is no drift to test for. What is tested is the generator:
--- that it parses the pinned definitions.lua, renders the shapes the
--- bindings actually have, and emits valid Teal. GENTYPE_DEFS overrides
--- the source, for validating against a cosmopolitan checkout before a
--- release.

local check = require("cosmic.check")
local defs = require("_types.gentype_defs")
local fs = require("cosmic.fs")
local gentype = require("_types.gentype")
local teal = require("cosmic.teal")

--- The same annotations the generator itself reads, so these tests
--- exercise the generator's real input rather than a second resolution
--- of it that can disagree.
--- @return string The definitions.lua source
local function defs_source(): string
  local source = check.must(defs.read())
  return source
end

--- Where the generator writes a module's declarations. They are not
--- committed: `_types/types_gen.tl` produces them into the unit's output
--- directory before any graph verb runs.
local function generated_path(module_name: string): string
  if module_name == "cosmo" then
    return "o/_types/types_gen/cosmo.d.tl"
  end
  return "o/_types/types_gen/cosmo/" .. module_name .. ".d.tl"
end

-- Test type conversion from LuaLS to Teal
local function test_convert_type()
  -- Simple types
  assert(gentype.convert_type("string") == "string", "string type")
  assert(gentype.convert_type("integer") == "integer", "integer stays integer")
  assert(gentype.convert_type("number") == "number", "number type")
  assert(gentype.convert_type("boolean") == "boolean", "boolean type")
  assert(gentype.convert_type("any") == "any", "any type")

  -- Alias types
  assert(gentype.convert_type("uint32") == "integer", "uint32 -> integer")
  assert(gentype.convert_type("uint16") == "integer", "uint16 -> integer")

  -- Array types
  assert(gentype.convert_type("string[]") == "{string}", "string[] -> {string}")
  assert(gentype.convert_type("integer[]") == "{integer}", "integer[] -> {integer}")

  -- Table types
  assert(gentype.convert_type("table<string,any>") == "{string: any}", "table<K,V> -> {K: V}")
  assert(gentype.convert_type("table<string, any>") == "{string: any}", "table<K, V> with space")

  -- Nullable types render as a Teal union with nil.
  assert(gentype.convert_type("string?") == "string | nil", "string? -> string | nil")
  assert(gentype.convert_type("integer?") == "integer | nil", "integer? -> integer | nil")

  -- Parenthesized union types are unwrapped and converted (LuaLS grouping).
  assert(gentype.convert_type("(true | string)") == "boolean | string", "(true | string) union")
  assert(gentype.convert_type("(integer | string)?") == "integer | string | nil", "optional paren union")

  -- Variadic types keep the ellipsis with a converted base, spelled with
  -- the space the formatter would put there.
  assert(gentype.convert_type("string...") == "string ...", "string... converts")
  assert(gentype.convert_type("integer...") == "integer ...", "integer... converts")

  -- Function types convert their argument and return types. A function type
  -- with a return is parenthesized so a following `, next` in a type list
  -- cannot parse as another return of the nested function.
  assert(gentype.convert_type("fun(udata: integer, tries: integer)")
    == "function(udata: integer, tries: integer)", "fun arg types convert")
  assert(gentype.convert_type("fun(x: integer): integer")
    == "(function(x: integer): integer)", "fun return type converts, parenthesized")

  -- Module-prefixed types
  assert(gentype.convert_type("lsqlite3.Database") == "Database", "lsqlite3.Database -> Database")
  assert(gentype.convert_type("unix.Errno") == "Errno", "unix.Errno -> Errno")

  print("test_convert_type: PASS")
end
test_convert_type()

-- Test module parsing against the real definitions.lua
local function test_parse_path_module()
  local module = gentype.parse_module(defs_source(), "path")
  assert(module, "Failed to parse path module")
  assert(module.name == "path", "module name should be path")
  assert(#module.functions > 0, "path should have functions")

  local found: {string: boolean} = {}
  for _, f in ipairs(module.functions) do
    found[f.name] = true
  end
  assert(found["dirname"], "path.dirname should exist")
  assert(found["basename"], "path.basename should exist")
  assert(found["join"], "path.join should exist")

  print("test_parse_path_module: PASS")
end
test_parse_path_module()

-- Test unix module parsing (more complex with constants)
local function test_parse_unix_module()
  local module = gentype.parse_module(defs_source(), "unix")
  assert(module, "Failed to parse unix module")
  assert(#module.constants > 0, "unix should have constants, got " .. #module.constants)

  local found_eacces = false
  local found_af_unix = false
  for _, c in ipairs(module.constants) do
    if c.name == "EACCES" then found_eacces = true end
    if c.name == "AF_UNIX" then found_af_unix = true end
  end
  assert(found_eacces, "unix.EACCES should exist")
  assert(found_af_unix, "unix.AF_UNIX should exist")

  print("test_parse_unix_module: PASS")
end
test_parse_unix_module()

-- A fallible unix.* function expresses its failure return upstream as an
-- `@overload fun(...): nil, <error> unix.Errno`. The generator folds that into
-- a trailing `, Errno` on the success signature so callers see `value, Errno`.
local function test_errno_overload_render()
  local source = [==[
unix = {}

--- Makes a directory.
---@param path string
---@return true
---@overload fun(path: string): nil, error: unix.Errno
function unix.mkdir(path) end

--- Gets the current working directory.
---@return string path
---@overload fun(): nil, unix.Errno
function unix.getcwd() end

--- Never fails, so must not gain an Errno return.
---@return integer pid
function unix.getpid() end

--- Already declares Errno via @return AND carries a failure overload; the
--- generator must not append a second Errno.
---@param fd integer
---@return integer newfd
---@return unix.Errno err
---@overload fun(fd: integer): nil, unix.Errno
function unix.dup(fd) end
]==]

  local module = gentype.parse_module(source, "unix")
  local dtl = gentype.generate_dtl(module)

  assert(dtl:match("mkdir: function%(path: string%): boolean | nil, Errno"),
    "fallible mkdir should render 'T | nil, Errno':\n" .. dtl)
  assert(dtl:match("getcwd: function%(%): string | nil, Errno"),
    "fallible getcwd should render 'T | nil, Errno':\n" .. dtl)
  assert(dtl:match("getpid: function%(%): integer"),
    "getpid should still render its integer return:\n" .. dtl)
  assert(not dtl:match("getpid[^\n]*Errno"),
    "non-fallible getpid must NOT gain an Errno return:\n" .. dtl)
  assert(not dtl:match("getpid[^\n]*| nil"),
    "non-fallible getpid must NOT gain a nil union:\n" .. dtl)
  assert(dtl:match("dup: function%([^\n]*%): integer | nil, Errno"),
    "dup should render 'integer | nil' and a single trailing Errno:\n" .. dtl)
  assert(not dtl:match("dup:[^\n]*Errno, Errno"),
    "dup must not gain a duplicate Errno:\n" .. dtl)

  print("test_errno_overload_render: PASS")
end
test_errno_overload_render()

-- Parenthesized union types (LuaLS groups unions this way, e.g. `ioctl`'s
-- `(integer | string)?` param and `(true | string)` return) must parse into
-- valid Teal unions instead of truncating the type at the first space.
local function test_paren_union_types()
  local source = [==[
unix = {}
---@param fd integer
---@param request integer
---@param arg (integer | string)?
---@return (true | string) result
---@overload fun(fd: integer, request: integer, arg?: integer | string): nil, error: unix.Errno
function unix.ioctl(fd, request, arg) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "unix"))
  assert(dtl:match("ioctl: function%(fd: integer, request: integer, arg%?: integer | string%): boolean | string | nil, Errno"),
    "parenthesized union types should render unions with a nil success:\n" .. dtl)
  print("test_paren_union_types: PASS")
end
test_paren_union_types()

-- A variadic return (`@return string match, string ... captures`) renders as
-- a Teal vararg return type. Nothing can follow a vararg, so the Errno fold
-- from a failure overload must be skipped.
local function test_vararg_return()
  local source = [==[
re = {}
--- Searches a string.
---@param regex string
---@param text string
---@return string match, string ... the match, followed by any captured groups
---@overload fun(regex: string, text: string): nil, re.Errno
function re.search(regex, text) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "re"))
  assert(dtl:match("search: function%(regex: string, text: string%): string | nil, string %.%.%."),
    "vararg return should render as `string | nil, string ...`:\n" .. dtl)
  assert(not dtl:match("search[^\n]*followed"),
    "return description must not leak into the type list:\n" .. dtl)
  assert(not dtl:match("search[^\n]*%.%.%., Errno"),
    "no Errno fold after a vararg return:\n" .. dtl)
  print("test_vararg_return: PASS")
end
test_vararg_return()

-- LuaLS function-level generics (`---@generic T`) render as real Teal
-- generic type parameters (`function<T>(...)`), with the generic name
-- kept in the params/returns that reference it.
local function test_generics_emitted()
  local source = [==[
lsqlite3 = {}
--- Sets a busy handler.
---@generic Udata
---@param func fun(udata: Udata, tries: integer)? handler
---@param udata? Udata
function lsqlite3.busy_handler(func, udata) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "lsqlite3"))
  assert(dtl:match("busy_handler: function<Udata>%(func%?: function%(udata: Udata, tries: integer%), udata%?: Udata%)"),
    "generics should render type parameters:\n" .. dtl)
  print("test_generics_emitted: PASS")
end
test_generics_emitted()

-- Constants inside the module table are indented, and so are their doc
-- comments; both must survive into the rendered record. A stray `}` inside a
-- doc comment must not terminate the module table extraction.
local function test_constant_docs_and_comment_braces()
  local source = [==[
re = {
    --- Missing }
    EBRACE = 9,
    --- Invalid contents of {}
    BADBR = 10,
}
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "re"))
  assert(dtl:match("%-%-%- Missing }\n  EBRACE: integer"),
    "constant doc comments should render above the constant:\n" .. dtl)
  assert(dtl:match("BADBR: integer"),
    "constants after a stray `}` in a comment must still parse:\n" .. dtl)
  print("test_constant_docs_and_comment_braces: PASS")
end
test_constant_docs_and_comment_braces()

-- A module's surface includes VALUES, not only functions, and the
-- definitions write those qualified: `cosmo.null = {}` under a
-- `---@type` block, outside the module table. Both halves used to miss
-- it — the extractor dropped the line as neither a function nor a
-- class, so the parser never saw it — and the value was absent from
-- the generated types, forcing callers through an erasure cast.
local function test_qualified_value_field_is_generated()
  local source = [==[
cosmo = {
}

--- The null sentinel.
---@type JsonValue
cosmo.null = {}
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "cosmo"))
  assert(dtl:match("null: any"),
    "a qualified `<module>.name = …` value field belongs on the module " ..
    "record:\n" .. dtl)
  assert(dtl:match("%-%-%- The null sentinel%.\n%s*null:"),
    "and it carries its doc comment:\n" .. dtl)
  print("test_qualified_value_field_is_generated: PASS")
end
test_qualified_value_field_is_generated()

-- A standalone data class (`---@class mod.Name` + `---@field ...`) renders as
-- a record even when empty (opaque userdata handles), and every class type is
-- exported on the module record unless a function shares its name.
local function test_data_class_and_type_export()
  local source = [==[
argon2 = {
    --- Argon2 algorithm variants.
    ---@type argon2.Variants
    variants = {},
}

---@class argon2.Variant: userdata
--- Opaque variant handle.

---@class argon2.Variants
---@field argon2_id argon2.Variant blend of the other two methods
---@field argon2_i argon2.Variant side-channel resistant
---@field argon2_d argon2.Variant gpu-cracking resistant

--- Hashes a password.
---@param pass string
---@param config argon2.Config
---@class argon2.Config
---@field m_cost integer? memory cost in kibibytes
---@field variant argon2.Variant? algorithm variant
---@return string encoded
---@overload fun(pass: string, config?: argon2.Config): nil, error: string
function argon2.hash_encoded(pass, config) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "argon2"))
  assert(dtl:match("local record Variant"), "opaque Variant class should render:\n" .. dtl)
  assert(dtl:match("local record Variants"), "Variants class should render:\n" .. dtl)
  assert(dtl:match("argon2_id: Variant"), "@field entries should render:\n" .. dtl)
  assert(dtl:match("type Variant = Variant"), "class types should be exported:\n" .. dtl)
  assert(dtl:match("variants: Variants"),
    "@type-annotated module field should render on the record:\n" .. dtl)
  assert(dtl:match("m_cost: integer"), "Config fields should render:\n" .. dtl)
  print("test_data_class_and_type_export: PASS")
end
test_data_class_and_type_export()

-- Module-qualified class methods (`function mod.Class:method()`) attach to
-- their class wherever they appear in the file.
local function test_qualified_class_methods()
  local source = [==[
lsqlite3 = {}

---@class lsqlite3.Database: userdata
--- A database handle.

---@return integer # rows changed
---@nodiscard
function lsqlite3.Database:changes() end

--- Opens a database.
---@param filename string
---@return lsqlite3.Database
function lsqlite3.open(filename) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "lsqlite3"))
  assert(dtl:match("local record Database"), "Database class should render:\n" .. dtl)
  assert(dtl:match("changes: function%(self: Database%): integer"),
    "qualified class method should attach to its class:\n" .. dtl)
  assert(dtl:match("open: function%(filename: string%): Database"),
    "module function should reference the class type:\n" .. dtl)
  print("test_qualified_class_methods: PASS")
end
test_qualified_class_methods()

-- A malformed upstream annotation (the real-world `---@return nil,|nil ...`
-- left by a definitions.lua rewrite) must fail loudly at generation time,
-- naming the offending declaration and pointing upstream, instead of
-- rendering invalid Teal that surfaces as baffling downstream type errors.
local function test_malformed_annotation_fails_loudly()
  local source = [==[
unix = {}

--- Replaces current process with program.
---@param prog string
---@param args string[]
---@param env string[]
---@return nil,|nil string, integer error
---@return string? error
---@return integer? errno
function unix.execve(prog, args, env) end
]==]
  local module = gentype.parse_module(source, "unix")
  local output, err = gentype.render_module(module)
  assert(not output, "malformed annotation must not render, got:\n" .. tostring(output))
  assert(err, "expected an error message")
  assert(err:find("unix.execve", 1, true),
    "error must name the offending declaration: " .. err)
  assert(err:find("nil,|nil", 1, true),
    "error must quote the offending type text: " .. err)
  assert(err:find("tool/net/definitions.lua", 1, true),
    "error must point at the upstream fix location: " .. err)
  print("test_malformed_annotation_fails_loudly: PASS")
end
test_malformed_annotation_fails_loudly()

-- Valid annotations of every supported grammar shape (unions, optionals,
-- arrays, fun types, table types, inline maps, grouped unions, literals,
-- varargs, generic instantiation) must pass validation and render.
local function test_valid_types_pass_validation()
  local source = [==[
unix = {}
--- Exercises the whole type grammar.
---@param a string
---@param b integer|string?
---@param c fun(x: integer, ...): string?
---@param d table<string, any>
---@param e string[][]
---@param f { [string]: integer }
---@param g (true | string)
---@param h "MD5"|'SHA256'
---@param i unix.Sigset?
---@return string? value
---@return string? error
---@return integer? errno
function unix.frob(a, b, c, d, e, f, g, h, i) end

--- Variadic return.
---@param fd integer
---@return string match, string ... captures
function unix.grab(fd) end
]==]
  local module = gentype.parse_module(source, "unix")
  local output, err = gentype.render_module(module)
  assert(output, "valid annotations must render, got error: " .. tostring(err))
  assert(output:match("frob: function%("), "frob should render:\n" .. output)
  print("test_valid_types_pass_validation: PASS")
end
test_valid_types_pass_validation()

-- Every generated .d.tl must itself be valid, type-checkable Teal: a
-- renderer change that emits a bad union, an unbalanced paren or a
-- dangling return is caught here rather than as a confusing failure in
-- whatever first tries to resolve `cosmo.*`. There is no drift test any
-- more — nothing is committed to drift from — so this is the renderer's
-- only tripwire, and it reads what the build just produced.
local function test_generated_valid_teal()
  for _, m in ipairs(gentype.get_modules()) do
    local path = generated_path(m)
    assert(fs.is_file(path), path .. " was not generated — the graph runs "
      .. "_types/types_gen.tl before anything reads cosmo.*")
    local result = teal.check_file(path, {include_dirs = {"o/_types/types_gen"}})
    assert(result.ok, "generated " .. path .. " is not valid Teal:\n"
      .. teal.format_issues(result.errors)
      .. "\nFix the renderer in _types/gentype_render.tl.")
  end
  print("test_generated_valid_teal: PASS (" .. #gentype.get_modules() .. " modules)")
end
test_generated_valid_teal()

-- MODULES must cover definitions.lua: every module section upstream is either
-- generated or explicitly skipped, and nothing in MODULES is missing upstream.
local function test_module_list_completeness()
  local source = defs_source()

  local found_modules: {string} = {}
  for line in source:gmatch("[^\n]+") do
    local module_name = line:match("^([a-z0-9_]+)%s*=%s*%{")
    if module_name then
      table.insert(found_modules, module_name)
    end
  end
  table.sort(found_modules)

  -- Modules in definitions.lua that we intentionally skip generating types
  -- for because the cosmos lua binary does not expose them.
  local skip_modules: {string: boolean} = {
    ["finger"] = true,
    ["goodsocket"] = true,
    ["maxmind"] = true,
  }

  local have: {string: boolean} = {}
  for _, h in ipairs(gentype.get_modules()) do have[h] = true end
  local found: {string: boolean} = {}
  for _, m in ipairs(found_modules) do found[m] = true end

  local missing: {string} = {}
  for _, m in ipairs(found_modules) do
    if not skip_modules[m] and not have[m] then
      table.insert(missing, m)
    end
  end
  local extra: {string} = {}
  for _, h in ipairs(gentype.get_modules()) do
    if not found[h] then
      table.insert(extra, h)
    end
  end

  if #missing > 0 then
    error("Missing modules in gentype.tl MODULES list: " .. table.concat(missing, ", ")
      .. "\nUpdate the MODULES list in _types/gentype.tl")
  end
  if #extra > 0 then
    error("Extra modules in gentype.tl MODULES list (no section in definitions.lua): "
      .. table.concat(extra, ", "))
  end

  print("test_module_list_completeness: PASS (found: " .. table.concat(found_modules, ", ") .. ")")
end
test_module_list_completeness()

-- Run all tests
print("\nAll gentype tests passed!")
