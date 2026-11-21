--- [`build.tree_checks`]' `meta_readers` on a fixture tree: which lines
--- read the compiler's identity or `image_hash` through [`Store.meta`],
--- and which modules the lists miss or name in vain. The tree's own
--- readers are held to [`build.key_parts`]' `meta_readers` by `cosmic fix
--- --check .`, not here.

local fixture = require("build.docs_fixture")
local tree_checks = require("build.tree_checks")
local support = require("build.test_support_fixture")

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
--- function that passes the name on, is seen; so is one by a name that is
--- no string literal, one by a name joined to more, and [`Store.meta`] taken
--- as a value (an alias). A module the group's lists name, as a reader or a
--- carrier, is not refused, and one they name that reads none is stale. A
--- read of the compiler's identity by its name is no read of the image.
local function test_a_read_of_the_image_hash_is_seen(dir: string)
  local call = "Store.meta"
  local db = fixture.database(dir, {
    ["build/reader.tl"] = module_of("local image = " .. call .. '("image_hash") or ""'),
    ["build/quoted.tl"] = module_of("local image = " .. call .. "( 'image_hash' )"),
    ["build/passed.tl"] = module_of("local image = meta_of" .. '("image_hash", seen)'),
    ["build/keyed.tl"] = module_of("local key = 'x'\nlocal value = " .. call .. "(key)"),
    ["build/joined.tl"] = module_of("local value = " .. call .. '("image_" .. rest)'),
    ["build/aliased.tl"] = module_of("local meta = " .. call .. "\nlocal value = meta(\"x\")"),
    ["build/compiler.tl"] = module_of("local tool = " .. call .. '("compiler")'),
    ["build/declares.tl"] = module_of("function " .. call .. "(key: string): string? end"),
    ["build/quiet.tl"] = module_of("-- " .. call .. " is the store's, and " .. call .. "(x) in a comment"),
  })
  local named = { "build.reader", "build.quoted", "build.passed", "build.gone" }
  local found = tree_checks.meta_readers(db, "image_hash", named)
  assert(#found == 5, table.concat(found, "\n"))
  local wanted = { "aliased", "joined", "keyed" }
  for i, name in ipairs(wanted) do
    assert(support.nth(found, i):find("^build%." .. name .. " reads the meta row image_hash, but") ~= nil,
      table.concat(found, "\n"))
  end
  assert(support.nth(found, 5):find("^build%.gone is named in") ~= nil, table.concat(found, "\n"))
  assert(support.nth(found, 4):find("^build%.quiet reads") ~= nil, table.concat(found, "\n"))
  local all = { "build.reader", "build.quoted", "build.passed", "build.keyed", "build.joined", "build.aliased",
    "build.quiet" }
  assert(#tree_checks.meta_readers(db, "image_hash", all) == 0)
  local compiler = tree_checks.meta_readers(db, "compiler", { "build.compiler", "build.keyed", "build.joined",
    "build.aliased", "build.quiet" })
  assert(#compiler == 0, table.concat(compiler, "\n"))
end

--- A group the map does not have is reported, not read as empty.
local function test_a_group_the_map_lacks_is_reported(dir: string)
  local db = fixture.database(dir, { ["build/reader.tl"] = module_of("local x = 1") })
  local found = tree_checks.meta_readers(db, "no_such_group")
  assert(#found == 1 and found[1]:find("^no_such_group is no group of") ~= nil, table.concat(found, "\n"))
end
