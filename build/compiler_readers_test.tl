--- [`build.tree_checks`]' `compiler_readers` on a fixture tree: which
--- lines read the compiler's identity through [`Store.meta`], and which
--- modules the list misses or names in vain. The tree's own readers are
--- held to [`build.key_parts`]' `compiler_readers` by `cosmic fix
--- --check .`, not here.

local fixture = require("build.docs_fixture")
local tree_checks = require("build.tree_checks")

--- A module of one line, `line`, after its require.
local function module_of(line: string): string
  return "local Store = require(\"cosmic.store\")\n" .. line .. "\nreturn {}\n"
end

--- Spelled apart, so this module's own source reads nothing: a read by
--- a quoted name of either identity, or by any name not a string, is
--- seen; a function's declaration, and a read of another row, are not.
local function test_a_read_of_the_compiler_is_seen(dir: string)
  local call = "Store.meta"
  local db = fixture.database(dir, {
    ["build/tool.tl"] = module_of("local tool = " .. call .. '("compiler") or ""'),
    ["build/by.tl"] = module_of("local by = " .. call .. "( 'compiled_by' )"),
    ["build/keyed.tl"] = module_of("local key = 'x'\nlocal value = " .. call .. "(key)"),
    ["build/declares.tl"] = module_of("function " .. call .. "(key: string): string | nil end"),
    ["build/runtime.tl"] = module_of("local runtime = " .. call .. '("runtime")'),
  })
  local found = tree_checks.compiler_readers(db, { "build.tool", "build.by", "build.gone" })
  assert(#found == 2, table.concat(found, "\n"))
  assert(found[1]:find("^build%.keyed reads the compiler's identity, but") ~= nil, found[1])
  assert(found[2]:find("^build%.gone is named in") ~= nil, found[2])
  assert(#tree_checks.compiler_readers(db, { "build.tool", "build.by", "build.keyed" }) == 0)
end
