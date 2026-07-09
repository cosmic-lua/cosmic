#!/usr/bin/env cosmic
--- Tests for gentype.tl type definition generator.
---
--- The drift tests compare generator output byte-for-byte against the
--- committed .d.tl files, so any change to the generator or to the pinned
--- cosmos definitions.lua fails here until `bin/make regen-types` is run and
--- the regenerated files are committed. GENTYPE_DEFS overrides the
--- definitions.lua source (default: the copy embedded in this binary) for
--- validating against a cosmopolitan checkout before a release is cut.

local fs = require("cosmic.fs")
local gentype = require("types.gentype")
local teal = require("cosmic.teal")

local function defs_source(): string
  local path = os.getenv("GENTYPE_DEFS") or "/zip/.lua/definitions.lua"
  local source = fs.read(path)
  assert(source, "Failed to read definitions.lua from " .. path)
  return source
end

--- Committed location for a generated module's type declarations.
local function committed_path(module_name: string): string
  if module_name == "cosmo" then
    return "lib/types/cosmo.d.tl"
  end
  return "lib/types/cosmo/" .. module_name .. ".d.tl"
end

-- Test type conversion from LuaLS to Teal
local function test_convert_type()
  -- Simple types
  assert(gentype.convert_type("string") == "string", "string type")
  assert(gentype.convert_type("integer") == "number", "integer -> number (Teal compat)")
  assert(gentype.convert_type("number") == "number", "number type")
  assert(gentype.convert_type("boolean") == "boolean", "boolean type")
  assert(gentype.convert_type("any") == "any", "any type")

  -- Alias types
  assert(gentype.convert_type("uint32") == "number", "uint32 -> number (Teal compat)")
  assert(gentype.convert_type("uint16") == "number", "uint16 -> number (Teal compat)")

  -- Array types
  assert(gentype.convert_type("string[]") == "{string}", "string[] -> {string}")
  assert(gentype.convert_type("integer[]") == "{number}", "integer[] -> {number}")

  -- Table types
  assert(gentype.convert_type("table<string,any>") == "{string: any}", "table<K,V> -> {K: V}")
  assert(gentype.convert_type("table<string, any>") == "{string: any}", "table<K, V> with space")

  -- Nullable types render as a Teal union with nil.
  assert(gentype.convert_type("string?") == "string | nil", "string? -> string | nil")
  assert(gentype.convert_type("integer?") == "number | nil", "integer? -> number | nil")

  -- Parenthesized union types are unwrapped and converted (LuaLS grouping).
  assert(gentype.convert_type("(true | string)") == "boolean | string", "(true | string) union")
  assert(gentype.convert_type("(integer | string)?") == "number | string | nil", "optional paren union")

  -- Variadic types keep the ellipsis with a converted base.
  assert(gentype.convert_type("string...") == "string...", "string... passthrough")
  assert(gentype.convert_type("integer...") == "number...", "integer... -> number...")

  -- Function types convert their argument and return types. A function type
  -- with a return is parenthesized so a following `, next` in a type list
  -- cannot parse as another return of the nested function.
  assert(gentype.convert_type("fun(udata: integer, tries: integer)")
    == "function(udata: number, tries: number)", "fun arg types convert")
  assert(gentype.convert_type("fun(x: integer): integer")
    == "(function(x: number): number)", "fun return type converts, parenthesized")

  -- Module-prefixed types
  assert(gentype.convert_type("lsqlite3.Database") == "Database", "lsqlite3.Database -> Database")
  assert(gentype.convert_type("unix.Errno") == "Errno", "unix.Errno -> Errno")

  print("test_convert_type: PASS")
end

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
  assert(dtl:match("getpid: function%(%): number"),
    "getpid should still render its number return:\n" .. dtl)
  assert(not dtl:match("getpid[^\n]*Errno"),
    "non-fallible getpid must NOT gain an Errno return:\n" .. dtl)
  assert(not dtl:match("getpid[^\n]*| nil"),
    "non-fallible getpid must NOT gain a nil union:\n" .. dtl)
  assert(dtl:match("dup: function%([^\n]*%): number | nil, Errno"),
    "dup should render 'number | nil' and a single trailing Errno:\n" .. dtl)
  assert(not dtl:match("dup:[^\n]*Errno, Errno"),
    "dup must not gain a duplicate Errno:\n" .. dtl)

  print("test_errno_overload_render: PASS")
end

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
  assert(dtl:match("ioctl: function%(fd: number, request: number, arg%?: number | string%): boolean | string | nil, Errno"),
    "parenthesized union types should render as Teal unions with a nil success:\n" .. dtl)
  print("test_paren_union_types: PASS")
end

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
  assert(dtl:match("search: function%(regex: string, text: string%): string | nil, string%.%.%."),
    "vararg return should render as `string | nil, string...`:\n" .. dtl)
  assert(not dtl:match("search[^\n]*followed"),
    "return description must not leak into the type list:\n" .. dtl)
  assert(not dtl:match("search[^\n]*%.%.%., Errno"),
    "no Errno fold after a vararg return:\n" .. dtl)
  print("test_vararg_return: PASS")
end

-- LuaLS generics (`---@generic T`) have no Teal record-field equivalent; each
-- generic name degrades to `any` wherever it appears.
local function test_generic_degrades_to_any()
  local source = [==[
lsqlite3 = {}
--- Sets a busy handler.
---@generic Udata
---@param func fun(udata: Udata, tries: integer)? handler
---@param udata? Udata
function lsqlite3.busy_handler(func, udata) end
]==]
  local dtl = gentype.generate_dtl(gentype.parse_module(source, "lsqlite3"))
  assert(dtl:match("busy_handler: function%(func%?: function%(udata: any, tries: number%), udata%?: any%)"),
    "generic types should degrade to any:\n" .. dtl)
  print("test_generic_degrades_to_any: PASS")
end

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
  assert(dtl:match("%-%-%- Missing }\n  EBRACE: number"),
    "constant doc comments should render above the constant:\n" .. dtl)
  assert(dtl:match("BADBR: number"),
    "constants after a stray `}` in a comment must still parse:\n" .. dtl)
  print("test_constant_docs_and_comment_braces: PASS")
end

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
  assert(dtl:match("m_cost: number"), "Config fields should render:\n" .. dtl)
  print("test_data_class_and_type_export: PASS")
end

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
  assert(dtl:match("changes: function%(self: Database%): number"),
    "qualified class method should attach to its class:\n" .. dtl)
  assert(dtl:match("open: function%(filename: string%): Database"),
    "module function should reference the class type:\n" .. dtl)
  print("test_qualified_class_methods: PASS")
end

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

-- Drift: generator output must match the committed .d.tl byte-for-byte for
-- every module. Fails after a cosmos bump or generator change until
-- `bin/make regen-types` is run and the result committed.
local function test_drift_all_modules()
  for _, m in ipairs(gentype.get_modules()) do
    local result = gentype.run(m)
    assert(result.success, "generator failed for " .. m .. ": " .. (result.error or ""))
    local path = committed_path(m)
    local committed = fs.read(path)
    assert(committed, "missing committed type file " .. path
      .. " -- run `bin/make regen-types` and commit the result")
    if committed ~= result.output then
      -- Locate the first differing line for a readable failure.
      local cl: {string} = {}
      for line in (committed .. "\n"):gmatch("([^\n]*)\n") do table.insert(cl, line) end
      local gl: {string} = {}
      for line in (result.output .. "\n"):gmatch("([^\n]*)\n") do table.insert(gl, line) end
      local at = 1
      while cl[at] == gl[at] and at <= math.max(#cl, #gl) do at = at + 1 end
      error(path .. " drifted from generator output at line " .. at
        .. "\n  committed: " .. tostring(cl[at])
        .. "\n  generated: " .. tostring(gl[at])
        .. "\nRun `bin/make regen-types` and commit the result.")
    end
  end
  print("test_drift_all_modules: PASS (" .. #gentype.get_modules() .. " modules)")
end

-- Every committed .d.tl must itself be valid, type-checkable Teal. The drift
-- test guarantees the committed files equal generator output, so this doubles
-- as a permanent tripwire: a renderer change that emits malformed Teal (a bad
-- union, an unbalanced paren, a dangling return) is caught here even after the
-- broken output is regenerated and committed.
local function test_generated_valid_teal()
  for _, m in ipairs(gentype.get_modules()) do
    local path = committed_path(m)
    local result = teal.check(path, {include_dirs = {"lib/types"}})
    assert(result.ok, "generated " .. path .. " is not valid Teal:\n"
      .. teal.format_issues(result.errors)
      .. "\nFix the renderer in lib/types/gentype_render.tl.")
  end
  print("test_generated_valid_teal: PASS (" .. #gentype.get_modules() .. " modules)")
end

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
      .. "\nUpdate lib/types/gentype.tl MODULES and cook.mk type_modules")
  end
  if #extra > 0 then
    error("Extra modules in gentype.tl MODULES list (no section in definitions.lua): "
      .. table.concat(extra, ", "))
  end

  print("test_module_list_completeness: PASS (found: " .. table.concat(found_modules, ", ") .. ")")
end

-- Run all tests
local function run_tests()
  test_convert_type()
  test_parse_path_module()
  test_parse_unix_module()
  test_errno_overload_render()
  test_paren_union_types()
  test_vararg_return()
  test_generic_degrades_to_any()
  test_constant_docs_and_comment_braces()
  test_data_class_and_type_export()
  test_qualified_class_methods()
  test_malformed_annotation_fails_loudly()
  test_valid_types_pass_validation()
  test_module_list_completeness()
  test_drift_all_modules()
  test_generated_valid_teal()

  print("\nAll tests passed!")
end

run_tests()
