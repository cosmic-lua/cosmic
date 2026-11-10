--- How a boot names the analyzer ([`build.importer`]) against the rows
--- the running binary carries. It declares `store` for the binary's
--- `boot_hash` meta row, whose presence tells a tool from a boot
--- ([`build.importer`]'s `booting`): the row moves with every file of
--- the tree, so no key can hold it, and a worker on a sealed database
--- carries none. build/importer_test.tl holds the importer's other cases.
local Array = require("cosmic.array")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local analysis_schema = require("build.analysis_schema")
local identity = require("build.identity")
local importer = require("build.importer")
local pipeline = require("build.pipeline")
local work = require("build.work")
local writer = require("build.writer")
local support = require("build.test_support_fixture")

Test.policy{ grants = { { path = "core", letters = "r" }, { path = "o/cosmic.db", letters = "r" },
  { path = "lang/prelude.d.tl", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" },
  { path = "build/pipeline.tl", letters = "r" } } }

--- A boot carries no database and runs the tree's own code, so it names
--- the analyzer by the tree ([`importer.tree_code`]). It must name it as
--- the tool it writes will name its own, from what that tool carries;
--- otherwise the first build the booted tool runs forgets every row the
--- boot derived and parses every source again (about 11 s at release
--- speed on cosmic's own tree, 30 s or more under the checked core).
--- The tree is read as the binary is: a name only a declaration holds
--- is never followed, since the binary records no module requiring
--- one. Before a parse, what the last one found names it already; an
--- edit to an analyzer module moves it and parses every source again, and
--- an edit elsewhere, the checker included, parses what it edited.
local function test_a_boot_names_its_analyzer_as_the_tool_it_writes()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-boot-analyzer-"))
  for _, dir in ipairs({ "build", "core" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  --- A module named `name` holding one integer, set from each of `uses`.
  local function module_of(name: string, uses: {string}): string
    local lines: mut {string} = {}
    for _, used in ipairs(uses) do
      lines[#lines + 1] = "local " .. used .. " = require(\"build." .. used .. "\")"
    end
    lines[#lines + 1] = "local record " .. name .. "\n  mut n: integer\nend"
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
    ["build/derivation.tl"] = module_of("derivation", { "ast", "thing" }),
    ["build/ast.tl"] = module_of("ast", { "raw" }),
    ["build/thing.tl"] = module_of("thing", {}),
    ["build/raw.d.tl"] = "--- @kind binding\nlocal record raw\n  n: integer\nend\nreturn raw\n",
    ["build/other.tl"] = module_of("other", {}),
    -- The checker of the tree, which no analyzer module requires.
    ["build/pipeline.tl"] = module_of("pipeline", { "helper" }),
  }
  for name, source in pairs(files) do
    assert(Fs.write(root .. "/" .. name, source))
  end
  -- A tree that is cosmic's own is checked against the declarations of the standard library it holds.
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/lang/prelude.d.tl", (assert(Fs.read("lang/prelude.d.tl")))))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", (assert(Fs.read("lang/stdlib.d.tl")))))

  -- The tool: what a build of the tree writes, read as the binary reads
  -- its own database (core/store.c's `requires` and `source`).
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = true }))
  assert(importer.derive(handle))
  local identities = assert(identity.record_identities(handle.db))
  local result = assert(importer.compile(handle, identities.compiler))
  assert(writer.write_result(handle, support.build_dir(root) .. "/cosmic.db", result))
  work.close(handle)
  local out = assert(Sqlite.open(support.build_dir(root) .. "/cosmic.db"))
  local based_on = assert(Sqlite.text_rows(out,
    "SELECT value FROM meta WHERE key = 'runtime_basis'"))
  local binary: importer.Code = {
    basis = Array.at(based_on, 1):text(1), -- the boot wrote one `runtime_basis` row
    requires = function(name: string): {string}?, string
      local rows, trouble = Sqlite.text_rows(out,
        "SELECT requires FROM imports WHERE path = ?1 ORDER BY requires",
        { { text = name } })
      if rows == nil then return nil, trouble end
      local names: mut {string} = {}
      for _, row in ipairs(rows) do names[#names + 1] = row:text(1) end
      return names, ""
    end,
    source = function(name: string): string?, string
      for _, table_name in ipairs({ "decls", "modules" }) do
        local rows, trouble = Sqlite.text_rows(out,
          "SELECT CAST(inflate(source) AS TEXT) FROM " .. table_name ..
            " WHERE path = ?1", { { text = name } })
        if rows == nil then return nil, trouble end
        if #rows > 0 then return rows[1]:text(1), "" end
      end
      return nil, "no module '" .. name .. "' in the binary"
    end,
  }
  local modules = assert(importer.analyzer_modules(binary))
  assert(table.concat(modules, " ") == "build.ast build.derivation build.thing",
    table.concat(modules, " "))
  local tool = importer.analyzer_identity(binary)
  assert(not tool:find("^binary "), tool)

  -- The next boot: what it names the analyzer before and after it
  -- parses, what it leaves `meta` naming it, and whether a row planted
  -- under build.other's source (which only forgetting every parse
  -- removes) survived. Run as a boot runs, with no `boot_hash`: the
  -- suite's binary carries one, so [`Store.meta`] is stood in for across
  -- the derive. `before_derive` changes the working database first.
  local function boot(before_derive?: function(work.Handle)): string, string, string, boolean, integer
    local again = assert(work.open(root))
    assert(work.stage(again, { own = true }))
    assert(Sqlite.run(again.db,
      "INSERT OR REPLACE INTO docs (source_hash, ordinal, symbol, source_symbol, " ..
        "exported, kind, signature, text, line) SELECT source_hash, 99, " ..
        "'Planted', 'Planted', 0, 'record', '', '', 1 " ..
        "FROM inputs WHERE path = 'build.other'"))
    if before_derive ~= nil then before_derive(again) end
    local before = importer.analyzer_identity((assert(importer.tree_code(again))))
    local meta = Store.meta
    Store.meta = function(key: string): string? -- checked: field_fixed
      if key == "boot_hash" then return nil end
      return meta(key)
    end
    local tallies: mut {importer.Parses} = {}
    local ok, failure = pcall(function()
      tallies[1] = assert(importer.derive(again))
    end)
    Store.meta = meta -- checked: field_fixed
    assert(ok, tostring(failure))
    local parses = Array.at(tallies, 1)
    local after = importer.analyzer_identity((assert(importer.tree_code(again))))
    local recorded = assert(Sqlite.text_rows(again.db,
      "SELECT value FROM meta WHERE key = 'analyzer'"))
    local planted = assert(Sqlite.text_rows(again.db,
      "SELECT count(*) FROM docs WHERE symbol = 'Planted'"))
    work.close(again)
    -- `meta` keys `analyzer` once, and `count(*)` answers one row.
    return before, after, Array.at(recorded, 1):text(1), Array.at(planted, 1):text(1) == "1", parses.parsed
  end
  -- The first boot after the suite's own binary derived: that binary's
  -- rows go, and the boot names its own as the tool does.
  local before, after, recorded, kept, parsed = boot()
  assert(before == tool, "a boot names the analyzer otherwise than the tool it wrote")
  assert(after == tool, "a boot's parse moved the analyzer's name")
  -- The name is the analyzer's alone: the tool the boot writes names its own the same way, whatever checker either
  -- carries, and finds the boot's rows its own.
  assert(recorded == tool, "a boot recorded another name than the tool's")
  assert(not kept, "rows another analyzer derived were kept")
  local every = parsed
  assert(every > 1, "the first boot parsed " .. tostring(every) .. " sources")
  before, after, recorded, kept, parsed = boot()
  assert(recorded == tool and kept and parsed == 0, "a boot forgot what a boot of the same tree derived")

  local other = files["build/other.tl"]
  assert(other ~= nil, "the tree holds build/other.tl")
  assert(Fs.write(root .. "/build/other.tl", other .. "-- edited\n"))
  before, after, recorded, kept, parsed = boot()
  assert(before == tool and after == tool and recorded == tool,
    "an edit outside the analyzer moved its name")
  assert(parsed == 1, "an edit outside the analyzer parsed " .. tostring(parsed) .. " sources, want the one edited")
  -- An edit to the checker, which no analyzer module requires, parses the checker's own source and nothing else: no
  -- parse was made by its code, though it requires an analyzer module now.
  assert(Fs.write(root .. "/build/pipeline.tl", module_of("pipeline", { "helper", "thing" })))
  before, after, recorded, kept, parsed = boot()
  assert(before == tool and after == tool and recorded == tool, "an edit to the checker moved the analyzer's name")
  assert(kept and parsed == 1, "an edit to the checker parsed " .. tostring(parsed) .. " sources, want the one edited")
  -- An edit to an analyzer module, its text alone, parses every source again.
  assert(Fs.write(root .. "/build/thing.tl", module_of("thing", {}) .. "-- edited\n"))
  before, after, recorded, kept, parsed = boot()
  assert(before ~= tool and after == before and recorded == after, "an edit to an analyzer module did not move its name")
  assert(not kept and parsed == every, "an edit to an analyzer module parsed " .. tostring(parsed) .. " sources of " ..
      tostring(every))
  tool = after
  -- A new require of an analyzer module is found only by the parse: the
  -- edit alone moves the name, the parse settles it, and the boot
  -- records it, so the next boot forgets nothing.
  assert(Fs.write(root .. "/build/ast.tl", module_of("ast", { "raw", "other" })))
  before, after, recorded, kept, parsed = boot()
  assert(before ~= tool and after ~= tool and after ~= before,
    "an edit to an analyzer module did not move its name")
  assert(recorded == after, "a boot recorded the name before its parse")
  local settled = after
  before, after, recorded, kept, parsed = boot()
  assert(before == settled and recorded == settled and kept,
    "a boot forgot what the boot before it derived of the same tree")
  -- Rows that are not the whole of a parse -- build.ast's missing, and
  -- the analyzer named by what is left -- move the name when the parse
  -- mends them, though nothing was forgotten: every row is forgotten
  -- and the tree parsed again.
  before, after, recorded, kept, parsed = boot(function(cut: work.Handle)
    for _, table_name in ipairs(analysis_schema.tables) do
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

--- The code that reads ([`build.pipeline`]'s `coded`) is named by the modules build.pipeline runs, not by build.plans,
--- which it requires for a type alone and which every key `coded` names holds through the compiler's identity. An edit
--- to a module it runs moves it.
local function test_the_code_that_reads_leaves_out_what_build_pipeline_names_for_a_type()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-coded-"))
  for _, dir in ipairs({ "build", "core" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/lang/prelude.d.tl", (assert(Fs.read("lang/prelude.d.tl")))))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", (assert(Fs.read("lang/stdlib.d.tl")))))
  local function record_of(name: string): string
    return "local record " .. name .. "\n  mut n: integer\nend\n" .. name .. ".n = 0\nreturn " .. name .. "\n"
  end
  assert(Fs.write(root .. "/build/helper.tl", record_of("helper")))
  assert(Fs.write(root .. "/build/plans.tl", record_of("plans")))
  assert(Fs.write(root .. "/build/pipeline.tl", "local helper = require(\"build.helper\")\n" ..
      "local type Plans = require(\"build.plans\")\nlocal record pipeline\n  mut n: integer\nend\n" ..
      "local function count(p: Plans): integer return p.n + helper.n end\npipeline.n = count({ n = 0 })\n" ..
      "return pipeline\n"))
  local function named(): string
    local handle = assert(work.open(root))
    assert(work.stage(handle, { own = true }))
    assert(importer.derive(handle))
    local name = assert(pipeline.coded_of("a tool", handle.db))
    work.close(handle)
    return name
  end
  local original = named()
  assert(Fs.write(root .. "/build/plans.tl", record_of("plans") .. "-- edited\n"))
  assert(named() == original, "an edit to build.plans, which build.pipeline names for a type alone, moved its name")
  assert(Fs.write(root .. "/build/helper.tl", record_of("helper") .. "-- edited\n"))
  assert(named() ~= original, "an edit to a module build.pipeline runs did not move its name")
end

--- build.pipeline's code identity leaves out build.plans as what build.pipeline requires for a type alone
--- ([`build.code_walk`]'s `type_only`): a require of it that runs its code would be code the identity does not hold.
--- So the require of it in build/pipeline.tl is a `local type`.
local function test_build_pipeline_requires_what_its_identity_leaves_out_for_a_type_alone()
  local source = assert(Fs.read("build/pipeline.tl"))
  for _, name in ipairs({ "build.plans" }) do
    local quoted = "require(\"" .. name .. "\")"
    local found = 0
    for line in source:gmatch("[^\n]+") do
      if line:find(quoted, 1, true) ~= nil then
        found = found + 1
        assert(line:match("^local type [%w_]+ = require%(") ~= nil,
          "build/pipeline.tl requires " .. name .. " for more than a type: " .. line)
      end
    end
    assert(found == 1, "build/pipeline.tl requires " .. name .. " " .. tostring(found) .. " times, want 1")
  end
end
