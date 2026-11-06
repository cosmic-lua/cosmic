--- [`build.tree_checks`]' `meta_readers` on a fixture tree: which lines
--- read the compiler's identity or `image_hash` through [`Store.meta`],
--- and which modules the lists miss or name in vain. The tree's own
--- readers are held to [`build.key_parts`]' `meta_readers` by `cosmic fix
--- --check .`, not here.

local fixture = require("build.docs_fixture")
local tree_checks = require("build.tree_checks")

--- A module of one line, `line`, after its require.
local function module_of(line: string): string
  return "local Store = require(\"cosmic.store\")\n" .. line .. "\nreturn {}\n"
end

--- A read by a quoted name of either identity (`compiler`,
--- `compiled_by`), or by a name that is no string literal, is seen. A
--- function's declaration, and a read of another row, are not.
local function test_a_read_of_the_compiler_is_seen(dir: string)
  -- Spelled apart, so this module's own source reads nothing.
  local call = "Store.meta"
  local db = fixture.database(dir, {
    ["build/tool.tl"] = module_of("local tool = " .. call .. '("compiler") or ""'),
    ["build/by.tl"] = module_of("local by = " .. call .. "( 'compiled_by' )"),
    ["build/keyed.tl"] = module_of("local key = 'x'\nlocal value = " .. call .. "(key)"),
    ["build/declares.tl"] = module_of("function " .. call .. "(key: string): string? end"),
    ["build/runtime.tl"] = module_of("local runtime = " .. call .. '("runtime")'),
  })
  local found = tree_checks.meta_readers(db, "compiler", { "build.tool", "build.by", "build.gone" })
  assert(#found == 2, table.concat(found, "\n"))
  assert(found[1]:find("^build%.keyed reads the meta row compiler/compiled_by, but") ~= nil, found[1])
  assert(found[2]:find("^build%.gone is named in") ~= nil, found[2])
  assert(#tree_checks.meta_readers(db, "compiler", { "build.tool", "build.by", "build.keyed" }) == 0)
end

--- A read of `image_hash` by a quoted name, through [`Store.meta`] or a
--- function that passes the name on, is seen; one by a name that is no
--- string literal is not (a worker without the row is answered nil, where
--- the compiler's identity would be answered by the tool). A module the
--- group's lists name, as a reader or a carrier, is not refused, and one
--- they name that reads none is stale. A read of the compiler's identity
--- is no read of it.
local function test_a_read_of_the_image_hash_is_seen(dir: string)
  local call = "Store.meta"
  local db = fixture.database(dir, {
    ["build/reader.tl"] = module_of("local image = " .. call .. '("image_hash") or ""'),
    ["build/quoted.tl"] = module_of("local image = " .. call .. "( 'image_hash' )"),
    ["build/passed.tl"] = module_of("local image = meta_of" .. '("image_hash", seen)'),
    ["build/keyed.tl"] = module_of("local key = 'x'\nlocal value = " .. call .. "(key)"),
    ["build/compiler.tl"] = module_of("local tool = " .. call .. '("compiler")'),
    ["build/declares.tl"] = module_of("function " .. call .. "(key: string): string? end"),
  })
  local found = tree_checks.meta_readers(db, "image_hash", { "build.reader", "build.gone" })
  assert(#found == 3, table.concat(found, "\n"))
  assert(found[1]:find("^build%.passed reads the meta row image_hash, but") ~= nil, found[1])
  assert(found[2]:find("^build%.quoted reads the meta row image_hash, but") ~= nil, found[2])
  assert(found[3]:find("^build%.gone is named in") ~= nil, found[3])
  assert(#tree_checks.meta_readers(db, "image_hash", { "build.reader", "build.quoted", "build.passed" }) == 0)
  local compiler = tree_checks.meta_readers(db, "compiler", { "build.compiler", "build.keyed" })
  assert(#compiler == 0, table.concat(compiler, "\n"))
end

--- A group the map does not have is reported, not read as empty.
local function test_a_group_the_map_lacks_is_reported(dir: string)
  local db = fixture.database(dir, { ["build/reader.tl"] = module_of("local x = 1") })
  local found = tree_checks.meta_readers(db, "no_such_group")
  assert(#found == 1 and found[1]:find("^no_such_group is no group of") ~= nil, table.concat(found, "\n"))
end
