--- How a boot names the analyzer ([`build.importer`]) against the rows
--- the running binary carries. It declares `store` for the binary's
--- `boot_hash` meta row, whose presence tells a tool from a boot
--- ([`build.compilation`]'s `booting`): the row moves with every file of
--- the tree, so no key can hold it, and a worker on a sealed database
--- carries none. build/importer_test.tl holds the importer's other cases.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local identity = require("build.identity")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

Test.policy{ grants = { { path = "core", letters = "r" }, { path = "o/cosmic.db", letters = "r" } } }

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- A boot carries no database and runs the tree's own code, so it names
--- the analyzer by the tree ([`importer.tree_code`]). It must name it as
--- the tool it writes will name its own, from what that tool carries;
--- otherwise the first build the booted tool runs forgets every row the
--- boot derived and parses every source again (about 11 s at release
--- speed on cosmic's own tree, 30 s or more under the checked core).
--- The tree is read as the binary is: a name only a declaration holds
--- is never followed, since the binary records no module requiring
--- one. Before a parse, what the last one found names it already; an
--- edit to an analyzer module moves it, and an edit elsewhere does not.
local function test_a_boot_names_its_analyzer_as_the_tool_it_writes()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-boot-analyzer-"))
  for _, dir in ipairs({ "build", "core" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  --- A module named `name` holding one integer, set from each of `uses`.
  local function module_of(name: string, uses: {string}): string
    local lines: {string} = {}
    for _, used in ipairs(uses) do
      lines[#lines + 1] = "local " .. used .. " = require(\"build." .. used .. "\")"
    end
    lines[#lines + 1] = "local record " .. name .. "\n  n: integer\nend"
    lines[#lines + 1] = name .. ".n = 0"
    for _, used in ipairs(uses) do
      lines[#lines + 1] = name .. ".n = " .. name .. ".n + " .. used .. ".n"
    end
    lines[#lines + 1] = "return " .. name
    return table.concat(lines, "\n") .. "\n"
  end
  local files: {string:string} = {
    ["build/helper.tl"] = module_of("helper", {}),
    ["build/importer.tl"] = module_of("importer", { "helper" }),
    ["build/analyzer.tl"] = module_of("analyzer", { "ast", "thing" }),
    ["build/ast.tl"] = module_of("ast", { "raw" }),
    ["build/thing.tl"] = module_of("thing", {}),
    ["build/raw.d.tl"] = "local record raw\n  n: integer\nend\nreturn raw\n",
    ["build/other.tl"] = module_of("other", {}),
  }
  for name, source in pairs(files) do
    assert(Fs.write(root .. "/" .. name, source))
  end

  -- The tool: what a build of the tree writes, read as the binary reads
  -- its own database (core/store.c's `requires` and `source`).
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  assert(importer.derive(handle, true, built))
  local identities = assert(identity.record_identities(handle.db))
  local result = assert(importer.compile(handle, built, identities.compiler))
  assert(writer.write_result(handle, root .. "/o/cosmic.db", result))
  work.close(handle)
  local out = assert(Sqlite.open(root .. "/o/cosmic.db"))
  local compiled_by = assert(Sqlite.text_rows(out,
    "SELECT value FROM meta WHERE key = 'compiler'"))
  local binary: importer.Code = {
    compiler = compiled_by[1][1],
    requires = function(name: string): {string} | nil, string
      local rows, trouble = Sqlite.text_rows(out,
        "SELECT requires FROM imports WHERE path = ?1 ORDER BY requires",
        { { text = name } })
      if rows == nil then return nil, trouble end
      local names: {string} = {}
      for _, row in ipairs(rows) do names[#names + 1] = row[1] end
      return names, ""
    end,
    source = function(name: string): string | nil, string
      for _, table_name in ipairs({ "decls", "modules" }) do
        local rows, trouble = Sqlite.text_rows(out,
          "SELECT CAST(inflate(source) AS TEXT) FROM " .. table_name ..
            " WHERE path = ?1", { { text = name } })
        if rows == nil then return nil, trouble end
        if #rows > 0 then return rows[1][1], "" end
      end
      return nil, "no module '" .. name .. "' in the binary"
    end,
  }
  local modules = assert(importer.analyzer_modules(binary))
  assert(table.concat(modules, " ") == "build.analyzer build.ast build.thing",
    table.concat(modules, " "))
  local tool = importer.analyzer_identity(binary)
  assert(not tool:find("^binary "), tool)

  -- The next boot: what it names the analyzer before and after it
  -- parses, what it leaves `meta` naming it, and whether a row planted
  -- under build.other's source (which only forgetting every parse
  -- removes) survived. Run as a boot runs, with no `boot_hash`: the
  -- suite's binary carries one, so [`Store.meta`] is stood in for across
  -- the derive. `before_derive` changes the working database first.
  local function boot(before_derive?: function(work.Handle)): string, string, string, boolean
    local again = assert(work.open(root))
    assert(work.stage(again, true))
    assert(Sqlite.run(again.db,
      "INSERT OR REPLACE INTO docs (source_hash, ordinal, symbol, source_symbol, " ..
        "exported, kind, signature, text, line) SELECT source_hash, 99, " ..
        "'Planted', 'Planted', 0, 'record', '', '', 1 " ..
        "FROM inputs WHERE path = 'build.other'"))
    if before_derive ~= nil then before_derive(again) end
    local before = importer.analyzer_identity((assert(importer.tree_code(again))))
    local meta = Store.meta
    Store.meta = function(key: string): string | nil
      if key == "boot_hash" then return nil end
      return meta(key)
    end
    local ok, derived, trouble = pcall(importer.derive, again, true, built)
    Store.meta = meta
    assert(ok, tostring(derived))
    assert(derived, trouble)
    local after = importer.analyzer_identity((assert(importer.tree_code(again))))
    local recorded = assert(Sqlite.text_rows(again.db,
      "SELECT value FROM meta WHERE key = 'analyzer'"))
    local planted = assert(Sqlite.text_rows(again.db,
      "SELECT count(*) FROM docs WHERE symbol = 'Planted'"))
    work.close(again)
    return before, after, recorded[1][1], planted[1][1] == "1"
  end
  -- The first boot after the suite's own binary derived: that binary's
  -- rows go, and the boot names its own as the tool does.
  local before, after, recorded, kept = boot()
  assert(before == tool, "a boot names the analyzer otherwise than the tool it wrote")
  assert(after == tool, "a boot's parse moved the analyzer's name")
  assert(recorded == tool, "a boot recorded another name than the tool's")
  assert(not kept, "rows another analyzer derived were kept")
  before, after, recorded, kept = boot()
  assert(recorded == tool and kept, "a boot forgot what a boot of the same tree derived")

  assert(Fs.write(root .. "/build/other.tl", files["build/other.tl"] .. "-- edited\n"))
  before, after, recorded, kept = boot()
  assert(before == tool and after == tool and recorded == tool,
    "an edit outside the analyzer moved its name")
  -- A new require of an analyzer module is found only by the parse: the
  -- edit alone moves the name, the parse settles it, and the boot
  -- records it, so the next boot forgets nothing.
  assert(Fs.write(root .. "/build/ast.tl", module_of("ast", { "raw", "other" })))
  before, after, recorded, kept = boot()
  assert(before ~= tool and after ~= tool and after ~= before,
    "an edit to an analyzer module did not move its name")
  assert(recorded == after, "a boot recorded the name before its parse")
  local settled = after
  before, after, recorded, kept = boot()
  assert(before == settled and recorded == settled and kept,
    "a boot forgot what the boot before it derived of the same tree")
  -- Rows that are not the whole of a parse -- build.ast's missing, and
  -- the analyzer named by what is left -- move the name when the parse
  -- mends them, though nothing was forgotten: every row is forgotten
  -- and the tree parsed again.
  before, after, recorded, kept = boot(function(cut: work.Handle)
    for _, table_name in ipairs({ "parsed", "requires", "tests", "catalog", "docs",
        "refs", "bound", "examples", "test_inputs" }) do
      assert(cut.db:exec("DELETE FROM " .. table_name .. " WHERE source_hash IN " ..
          "(SELECT source_hash FROM inputs WHERE path = 'build.ast')"))
    end
    assert(Sqlite.run(cut.db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('analyzer', ?1)",
      { { text = importer.analyzer_identity((assert(importer.tree_code(cut)))) } }))
  end)
  assert(before ~= settled and after == settled and recorded == settled,
    "a cut parse was named otherwise than the whole one")
  assert(not kept, "rows a cut parse left were kept under the mended name")
  assert(out:close())
end
