--- Tests of the build's compile with the new checker (`COSMIC_GRAMMAR=new`, [`build.importer`]'s `grammar`): a source is
--- read through the syntax tree of the new grammar and its rows are the fork's, under an analyzer of their own; a module the
--- new checker refuses does not stop the run, but is told with the words of [`build.error_render`], as is each module that
--- requires it; a pin that falls judges its module again.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local analysis_schema = require("build.analysis_schema")
local derivation = require("build.derivation")
local importer = require("build.importer")
local Pipeline = require("build.pipeline")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = {
  { path = "core", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
  { path = "build/ceilings.txt", letters = "r" }, { path = "build/importer.tl", letters = "r" },
  { path = "build/plural.tl", letters = "r" }, { path = "build/bind.tl", letters = "r" },
  { path = "build/digest.tl", letters = "r" }, { path = "build/clock.tl", letters = "r" },
  { path = "build/assertions.tl", letters = "r" }, { path = "build/exit_status.tl", letters = "r" },
  { path = "build/key_parts.tl", letters = "r" }, { path = "build/positions.tl", letters = "r" },
} }

local built = assert(teal.load())

--- A module of things, with documents, a test of its own and a require, as a project writes them.
local MODULE <const> = table.concat({
  "--- A module of things.",
  "---",
  "--- See [`Things.open`].",
  "local record Things",
  "  --- The size.",
  "  size: integer",
  "end",
  "",
  "--- Opens a thing.",
  "function Things.open(path: string): Things, string",
  "  if path == \"\" then",
  "    return nil, \"path is empty: \" .. path",
  "  end",
  "  return { size = #path }, \"\"",
  "end",
  "",
  "return Things",
  "",
}, "\n")

local TEST <const> = table.concat({
  'local Things = require("things")',
  "",
  "local function test_it_opens()",
  "  local thing = Things.open(\"x\")",
  "  assert(thing ~= nil and thing.size == 1)",
  "end",
  "",
}, "\n")

--- The rows of every analysis table of `db`, one string each.
local function tables_of(db: Sqlite.Handle): {string: string}
  local out: {string: string} = {}
  for _, name in ipairs(analysis_schema.tables) do
    local found, why = Sqlite.rows(db, "SELECT * FROM " .. name .. " ORDER BY 1, 2")
    assert(found ~= nil, why)
    local lines: {string} = {}
    for _, row in ipairs(found) do
      local cells: {string} = {}
      for index = 2, row:count() do
        local kind = row:kind(index)
        if kind == "integer" then
          cells[#cells + 1] = tostring(row:integer(index))
        elseif kind == "text" then
          cells[#cells + 1] = row:text(index)
        else
          cells[#cells + 1] = "null"
        end
      end
      lines[#lines + 1] = table.concat(cells, "\1")
    end
    out[name] = table.concat(lines, "\n")
  end
  return out
end

--- A project of `files` staged in `root`, its working database open, and the `late` files written after it is staged (the
--- fork's own checker, which the new checker reads for its prelude and the stage would take for a module).
local function staged(root: string, files: {string: string}, late?: {string: string}): work.Handle
  for path, text in pairs(files) do
    assert(Fs.mkdirs(Fs.dirname(root .. "/" .. path)))
    assert(Fs.write(root .. "/" .. path, text))
  end
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  for path, text in pairs(late or {}) do
    assert(Fs.mkdirs(Fs.dirname(root .. "/" .. path)))
    assert(Fs.write(root .. "/" .. path, text))
  end
  return handle
end

local function test_the_rows_of_a_source_read_with_the_new_checker_are_the_forks_under_another_analyzer(tmp: string)
  local files = { ["things.tl"] = MODULE, ["things_test.tl"] = TEST }
  local fork = staged(tmp .. "/fork", files)
  local parses = assert(importer.derive(fork, false, built))
  assert(parses.parsed == 2)
  local port = staged(tmp .. "/port", files)
  local made = assert(importer.derive(port, false, built, nil, nil, nil, "new"))
  assert(made.parsed == 2)
  local old, new = tables_of(fork.db), tables_of(port.db)
  for _, name in ipairs(analysis_schema.tables) do
    local was, now = old[name] or "", new[name] or ""
    assert(was == now, name .. ":\n" .. was .. "\nagainst\n" .. now)
  end
  for _, name in ipairs({ "parsed", "requires", "docs", "tests", "stubs", "links", "refs" }) do
    assert(#(new[name] or "") > 0, "the rows of " .. name .. " are empty")
  end
  local function analyzer(handle: work.Handle): string
    local rows = assert(Sqlite.text_rows(handle.db, "SELECT value FROM meta WHERE key = 'analyzer'"))
    local first = assert(rows[1])
    return first:text(1)
  end
  assert(analyzer(fork) ~= analyzer(port), "the two analyzers carry one name")
  assert(work.close(fork) and work.close(port))
end

local function test_a_database_read_in_one_mode_is_read_again_in_the_other_and_not_again_in_the_same(tmp: string)
  local handle = staged(tmp .. "/p", { ["things.tl"] = MODULE, ["things_test.tl"] = TEST })
  local first = assert(importer.derive(handle, false, built))
  local again = assert(importer.derive(handle, false, built))
  assert(first.parsed == 2 and again.parsed == 0)
  local new = assert(importer.derive(handle, false, built, nil, nil, nil, "new"))
  local newer = assert(importer.derive(handle, false, built, nil, nil, nil, "new"))
  assert(new.parsed == 2 and newer.parsed == 0)
  local back = assert(importer.derive(handle, false, built))
  assert(back.parsed == 2)
  assert(work.close(handle))
end

local function test_a_source_the_new_grammar_cannot_read_is_told_in_its_words_or_listed(tmp: string)
  local tuple = "local x: {string, integer} = { \"age\", 9 }\nassert(x[1] == \"age\")\n"
  local handle = staged(tmp .. "/p", { ["tuple.tl"] = tuple, ["things.tl"] = MODULE })
  local broken: {derivation.Broken} = {}
  local parses = assert(importer.derive(handle, false, built, nil, nil, broken, "new"))
  local told = assert(broken[1])
  assert(parses.parsed == 1 and #broken == 1 and told.file == "tuple.tl", tostring(#broken))
  assert(told.message:find("tuple.tl:1:", 1, true) == 1 and told.message:find("(tuple_type)", 1, true) ~= nil, told.message)
  -- listed, it leaves the source with no row; unlisted, it stops the derive
  local other = staged(tmp .. "/q", { ["tuple.tl"] = tuple })
  local stopped, why = importer.derive(other, false, built, nil, nil, nil, "new")
  assert(stopped == nil and why == told.message, tostring(why))
  assert(work.close(handle) and work.close(other))
end

local function lua_of(result: importer.Result, path: string): string
  for _, m in ipairs(result.modules) do
    if m.path == path then
      return m.lua or ""
    end
  end
  return ""
end

--- The files of a tree that is cosmic's own as far as the build asks: the directories and the importer, and ceilings of its own;
--- and stand-ins for the standard library's declarations and the prelude it reads, which come late: the real ones
--- take seconds to lower, and what these tests ask of the build does not read them.
local function own_tree(files: {string: string}, ceilings: string): {string: string}
  local out: {string: string} = {}
  for path, text in pairs(files) do
    out[path] = text
  end
  out["core/.keep"] = ""
  out["build/ceilings.txt"] = ceilings
  return out
end

local function late_files(): {string: string}
  return {
    ["lang/stdlib.d.tl"] = "",
    ["lang/prelude.d.tl"] = "",
    ["build/importer.tl"] = "return {}\n",
  }
end

--- A tree of a good module, a module the new checker refuses, one that requires it and one it cannot read, staged under `tmp`.
local function refusing_tree(tmp: string, ceilings: string): work.Handle
  return staged(tmp .. "/own", own_tree({
    ["good.tl"] = "local function twice(n: integer): integer\n  return n * 2\nend\nreturn twice\n",
    ["bad.tl"] = "local n: string = 1\nreturn n\n",
    ["after.tl"] = "local bad = require(\"bad\")\nreturn bad\n",
    ["tuple.tl"] = "local x: {string, integer} = { \"age\", 9 }\nreturn x\n",
  }, ceilings), late_files())
end

local function test_a_refused_module_is_told_with_the_checkers_words_and_the_run_goes_on(tmp: string)
  local handle = refusing_tree(tmp, "[checked]\ngood.tl export_not_declared 1\n")
  local result = assert(importer.compile(handle, built, "tool", false, nil, nil, false, "new"))
  local compiled: {string: boolean} = {}
  for _, m in ipairs(result.modules) do
    compiled[m.path] = true
  end
  assert(compiled["good"] == true and compiled["bad"] == nil and compiled["after"] == nil and compiled["tuple"] == nil)
  local said = table.concat(result.refused, "\n")
  assert(#result.refused == 3, said)
  assert(said:find("bad.tl: the compiler refused it\nbad.tl:1:", 1, true) ~= nil and said:find("(not_assignable)", 1, true) ~= nil, said)
  assert(said:find("after.tl: not compiled: it requires bad, which the new checker refused", 1, true) ~= nil, said)
  assert(said:find("tuple.tl:1:", 1, true) ~= nil and said:find("(tuple_type)", 1, true) ~= nil, said)
  assert(result.catalog ~= nil, "the rows of the checker's codes are not offered")
  assert(work.close(handle))
end

--- A function that reads a parameter after a test took nil out of it: the new checker narrows it, and a checked run asks the
--- read to be checked.
local NARROWED <const> = table.concat({
  "local function name_of(x: string | nil): string",
  "  if x == nil then",
  "    return \"none\"",
  "  end",
  "  return x",
  "end",
  "return name_of",
  "",
}, "\n")

local function test_a_checked_compile_wraps_the_reads_a_test_narrowed_and_is_keyed_apart(tmp: string)
  local handle = staged(tmp .. "/own", own_tree({ ["narrowed.tl"] = NARROWED }, "[checked]\nnarrowed.tl export_not_declared 1\n"),
    late_files())
  local plain = assert(importer.compile(handle, built, "tool", false, nil, nil, false, "new"))
  local checked = assert(importer.compile(handle, built, "tool", false, nil, nil, true, "new"))
  local plain_lua, checked_lua = lua_of(plain, "narrowed"), lua_of(checked, "narrowed")
  assert(plain_lua ~= "" and not plain_lua:find("__fact", 1, true), plain_lua)
  local _, wraps = checked_lua:gsub("__fact%(", "")
  assert(wraps == 1, tostring(wraps) .. " wraps in\n" .. checked_lua)
  -- the place read is named as the checker found it
  assert(checked_lua:find("\"x\"", 1, true) ~= nil and checked_lua:find("narrowed.tl:5:10", 1, true) ~= nil, checked_lua)
  -- each is a compile of its own, under a key of its own, and neither is the fork's checks
  assert(checked.compiled == 1 and plain.tool ~= checked.tool)
  assert(checked.tool == importer.checked_tool(Pipeline.coded("tool"), true))
  assert(checked.tool ~= importer.checked_tool(Pipeline.coded("tool")))
  -- the compile before it stands for neither
  local again = assert(importer.compile(handle, built, "tool", false, nil, nil, true, "new"))
  assert(again.compiled == 0 and again.cached == 1)
  assert(work.close(handle))
end

local function test_the_same_tree_again_stands(tmp: string)
  local handle = refusing_tree(tmp, "[checked]\ngood.tl export_not_declared 1\n")
  assert(importer.compile(handle, built, "tool", false, nil, nil, false, "new"))
  local again = assert(importer.compile(handle, built, "tool", false, nil, nil, false, "new"))
  assert(again.compiled == 0 and again.cached == 1, tostring(again.compiled) .. " compiled, " .. tostring(again.cached) .. " cached")
  assert(work.close(handle))
end

local function test_a_pin_that_falls_on_a_module_judges_it_again_and_no_other(tmp: string)
  local handle = refusing_tree(tmp, "[checked]\ngood.tl export_not_declared 1\n")
  assert(importer.compile(handle, built, "tool", false, nil, nil, false, "new"))
  assert(Fs.write(tmp .. "/own/build/ceilings.txt", "[checked]\ngood.tl export_not_declared 2\n"))
  assert(work.stage(handle, false))
  local lowered = assert(importer.compile(handle, built, "tool", false, nil, nil, false, "new"))
  assert(lowered.compiled == 1, tostring(lowered.compiled) .. " compiled")
  assert(work.close(handle))
end

--- `cosmic boot` compiles what the tool requires at load with the bootstrap release, whose checker refuses code the tree's
--- accepts (a parameter named `io`): requiring the importer must not load the pipeline, whatever the importer calls it, and
--- a build in the new grammar loads it where it asks.
local function test_requiring_the_importer_loads_the_pipeline_only_where_a_build_in_the_new_grammar_asks()
  local loaded = package.loaded as {string: any}
  local importer_before, pipeline_before = loaded["build.importer"], loaded["build.pipeline"]
  loaded["build.importer"], loaded["build.pipeline"] = nil, nil
  local ok, again = pcall(require, "build.importer")
  local pipeline_at_load = loaded["build.pipeline"]
  loaded["build.importer"], loaded["build.pipeline"] = importer_before, pipeline_before
  assert(ok, tostring(again))
  assert(pipeline_at_load == nil, "requiring build.importer loaded build.pipeline")
  assert(importer_before ~= nil)
end
