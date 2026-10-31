--- What `cosmic fix` chooses to cover, and how it reads what it chooses: the files a run names and the files a walk
--- finds, which of them make the run whole, what `--changed` narrows to, and the links it checks in each kind of file.

local Fs = require("cosmic.fs")
local fix = require("build.fix")
local tree = require("build.tree")
local link_resolve = require("build.link_resolve")
local type docs = require("build.docs")
local Sqlite = require("cosmic.sqlite")
local Ast = require("lang.ast")
local Format = require("build.fix.format")
local laid = require("build.fix.laid")
local SyntaxNode = require("build.syntax_node")

--- The element of `list` at `index`, which the case knows is there.
--- [`fix.chosen`] for `root`, which a tool built from it holds to be cosmic's own where `own`, and which any other is a
--- project to.
local function chosen(root: string, paths: {string}, own?: boolean): fix.Chosen?, string
  local carried: string? = nil
  if own == true then carried = assert(tree.built_from(root)) end
  local standing, why = tree.standing(root, carried)
  assert(standing ~= nil, why)
  return fix.chosen(root, paths, standing)
end

local function nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

--- A named path the verb will not take is a refusal among the files the
--- run covers, not an end to the run: it comes back in `refused` with
--- the others still listed, so the verb can report it and still end in
--- its summary.
---
--- What a path is decided before what it is named. A path with nothing
--- at it is missing, whatever its suffix: answering `nope` with a
--- remark about Teal would say the wrong thing about a file the caller
--- may only have mistyped.
local function test_a_path_that_is_not_there_is_missing_before_it_is_judged(tmp: string)
  assert(Fs.write(tmp .. "/real.tl", "local x = 1\nprint(x)\n"))
  assert(Fs.write(tmp .. "/notes.txt", "not Teal at all\n"))
  local picked, trouble = chosen(tmp, {
    tmp .. "/real.tl",
    tmp .. "/nope",
    tmp .. "/nosuchdir/",
    tmp .. "/notes.txt",
  })
  assert(picked ~= nil, "naming a missing path should not end the run: " ..
      tostring(trouble))
  assert(#picked.files == 1 and picked.files[1] == tmp .. "/real.tl",
    "the real source should still be listed")
  assert(#picked.refused == 3, "expected three refusals, got " .. tostring(#picked.refused))
  for i, what in ipairs({ "nope", "nosuchdir/" }) do
    assert(nth(picked.refused, i):find("No such file", 1, true) ~= nil,
      what .. " should be reported as missing, not judged on its suffix: " ..
        nth(picked.refused, i))
  end
  assert(nth(picked.refused, 3):find("not a Teal, C or template source, YAML, Markdown or Zig", 1, true) ~= nil,
    "a file that is there but is not Teal should be said so: " ..
      nth(picked.refused, 3))
end

--- A template is parsed and never rewritten: it is chosen apart from the
--- Teal that is laid out, by name, by directory and by the whole tree.
local function test_a_template_is_chosen_to_be_parsed_not_laid_out(tmp: string)
  assert(Fs.mkdirs(tmp .. "/pages"))
  assert(Fs.write(tmp .. "/pages/init.tmpl", "{{type Page from pages.data}}\n"))
  assert(Fs.write(tmp .. "/pages/data.tl", "return {}\n"))
  local named = assert(chosen(tmp, { tmp .. "/pages/init.tmpl" }))
  assert(#named.files == 0 and #named.refused == 0, "a template is no Teal to lay out")
  assert(#named.templates == 1 and named.templates[1] == tmp .. "/pages/init.tmpl")
  local dir = assert(chosen(tmp, { tmp .. "/pages" }))
  assert(#dir.files == 1 and #dir.templates == 1 and dir.templates[1] == tmp .. "/pages/init.tmpl")
  local every = assert(chosen(tmp, {}))
  assert(#every.templates == 1 and every.templates[1] == "pages/init.tmpl", table.concat(every.templates, " "))
end

--- C is checked only where the rules it is checked against belong:
--- cosmic's own tree, whose headers and compiler they assume.
local function test_c_is_taken_only_in_cosmics_own_tree(tmp: string)
  assert(Fs.write(tmp .. "/a.c", "int a;\n"))
  local picked = assert(chosen(tmp, { tmp .. "/a.c", tmp }))
  assert(#picked.c_files == 0, "a tree of another's has no C checked")
  assert(nth(picked.refused, 1):find("only in cosmic's own tree", 1, true) ~= nil,
    picked.refused[1])

  assert(Fs.mkdirs(tmp .. "/own/core"))
  assert(Fs.mkdirs(tmp .. "/own/build"))
  assert(Fs.mkdirs(tmp .. "/own/vendor/lua"))
  assert(Fs.write(tmp .. "/own/build/importer.tl", "return {}\n"))
  assert(Fs.write(tmp .. "/own/core/a.c", "int a;\n"))
  assert(Fs.write(tmp .. "/own/core/a.h", "int a;\n"))
  assert(Fs.write(tmp .. "/own/vendor/lua/b.c", "int b;\n"))
  local all = assert(chosen(tmp .. "/own", {}, true))
  assert(#all.c_files == 2 and all.c_files[1] == "core/a.c" and all.c_files[2] == "core/a.h",
    "the whole tree covers its own C and not the vendored: " .. table.concat(all.c_files, ", "))
  local named = assert(chosen(tmp .. "/own", { tmp .. "/own/core/a.h" }, true))
  assert(#named.c_files == 1 and #named.refused == 0, "a header named is checked")
end

--- The tree-wide checks run only over every Teal source of cosmic's own
--- tree, however it is named: not over a part of it, nor over a tree
--- of another's.
local function test_only_the_whole_own_tree_is_whole(tmp: string)
  local own = tmp .. "/own"
  assert(Fs.mkdirs(own .. "/core"))
  assert(Fs.mkdirs(own .. "/build"))
  assert(Fs.mkdirs(own .. "/cosmic"))
  assert(Fs.mkdirs(own .. "/vendor/lua"))
  assert(Fs.write(own .. "/build/importer.tl", "return {}\n"))
  assert(Fs.write(own .. "/cosmic/thing.tl", "return {}\n"))
  assert(assert(chosen(own, {}, true)).whole, "no path named covers the whole tree")
  assert(assert(chosen(own, { own }, true)).whole, "the root named covers the whole tree")
  assert(not assert(chosen(own, { own .. "/build" }, true)).whole, "build/ is a part of it")
  local other = tmp .. "/other"
  assert(Fs.mkdirs(other))
  assert(Fs.write(other .. "/thing.tl", "return {}\n"))
  assert(not assert(chosen(other, {})).whole, "a tree of another's is never whole")
  assert(not assert(chosen(other, { other })).whole, "a tree of another's is never whole")
end

--- A program's modules, as its own database holds them, which
--- [`fix.narrowed`] reads: every module that checks each file alone,
--- the reading of Teal's requiring cosmic.string.
local function program_modules(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  assert(Sqlite.run(db, "CREATE TABLE modules (path TEXT, file TEXT)"))
  assert(Sqlite.run(db, "CREATE TABLE imports (path TEXT, requires TEXT)"))
  for _, module in ipairs({ "build.syntax_node", "build.syntax_links", "build.syntax_analyzer",
      "build.flow", "build.c", "build.fix.near", "build.fix.laid", "build.logger", "build.tree", "cosmic.flags",
      "cosmic.cli", "cosmic.template",
      "cosmic.string" }) do
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?1, ?2)",
      { { text = module }, { text = module:gsub("%.", "/") .. ".tl" } }))
  end
  assert(Sqlite.run(db, "INSERT INTO imports VALUES ('build.syntax_node', 'cosmic.string')"))
  return db
end

--- `--changed` lays out only the paths named, of those the whole tree's
--- run covers, and keeps that run's files for the checks spanning
--- files: every C file where one changed, and a note on every file of
--- the standard library. A path named that is part of what checks each
--- file alone -- a module of it or one it requires, the C core, this
--- verb -- lays out the whole tree, saying why, as does one outside the
--- tree, the tree itself, and a program whose modules cannot be read.
local function test_changed_lays_out_only_the_paths_named(tmp: string)
  local own = tmp .. "/own"
  for _, dir in ipairs({ "/core", "/build/fix", "/cosmic", "/ci", "/lib", "/vendor/lua" }) do
    assert(Fs.mkdirs(own .. dir))
  end
  for _, file in ipairs({ "/build/importer.tl", "/build/fix/init.tl", "/cosmic/thing.tl",
      "/cosmic/other.tl", "/cosmic/string.tl", "/ci/a.tl" }) do
    assert(Fs.write(own .. file, "return {}\n"))
  end
  assert(Fs.write(own .. "/core/a.c", "int a;\n"))
  assert(Fs.write(own .. "/lib/b.c", "int b;\n"))
  local every = assert(chosen(own, {}, true))
  assert(every.whole and #every.c_files == 2, "the fixture is no tree of cosmic's own")
  local db = program_modules()
  local function names(files: {string}): string
    local sorted: mut {string} = {}
    for _, file in ipairs(files) do sorted[#sorted + 1] = file end
    table.sort(sorted)
    return table.concat(sorted, " ")
  end

  local narrowed = fix.narrowed(own, every, { "ci/a.tl", "./cosmic/thing.tl", "gone/x.tl",
    own .. "/doc/r.md" }, { db })
  assert(narrowed.widened == nil, tostring(narrowed.widened))
  assert(narrowed.whole and narrowed.every == every, "a run of --changed is not whole")
  assert(names(narrowed.files) == "ci/a.tl cosmic/thing.tl", names(narrowed.files))
  assert(#narrowed.c_files == 0 and #narrowed.flow_files == 0, "it lays out C or YAML that did not change")
  local noted = assert(narrowed.noted)
  assert(names(noted) == "ci/a.tl cosmic/other.tl cosmic/string.tl cosmic/thing.tl",
    "it notes " .. names(noted))

  narrowed = fix.narrowed(own, every, { "ci/a.tl", "lib/b.c" }, { db })
  noted = assert(narrowed.noted)
  assert(narrowed.widened == nil and names(narrowed.files) == "ci/a.tl" and
      names(noted) == "ci/a.tl cosmic/other.tl cosmic/string.tl cosmic/thing.tl",
    "outside the standard library, it notes " .. names(noted))
  assert(names(narrowed.c_files) == "core/a.c lib/b.c", "one C file changed holds " ..
      names(narrowed.c_files) .. " to the rules")

  for _, case in ipairs({
      { "cosmic/string.tl", "it checks each file alone" }, { "cosmic", "it checks each file alone" },
      { "core/a.c", "core/" }, { "build/fix/init.tl", "this verb" }, { "vendor", "vendor/" },
      { "build/patch.tl", "patched" }, { "ci/cosmic-driver.pin", "clang" },
      { ".", "the whole tree" }, { "/elsewhere/x.tl", "outside the tree" },
  }) do
    local widened = fix.narrowed(own, every, { "ci/a.tl", nth(case, 1) }, { db })
    local widened_widened = widened.widened
    assert(widened_widened ~= nil and widened_widened:find(nth(case, 2), 1, true) ~= nil and
        #widened.files == #every.files and widened.noted == nil,
      nth(case, 1) .. ": " .. tostring(widened_widened))
  end
  -- A test of the core is not what the program runs on; its links are
  -- checked with every other file's, and it is not laid out.
  local tested = fix.narrowed(own, every, { "core/a_test.tl" }, { db })
  assert(tested.widened == nil and #tested.files == 0, tostring(tested.widened))
  local empty = assert(Sqlite.memory())
  local unknown = fix.narrowed(own, every, { "ci/a.tl" }, { empty })
  local unknown_widened = unknown.widened
  assert(unknown_widened ~= nil and unknown_widened:find("not among the program's modules", 1, true) ~= nil,
    tostring(unknown_widened))
  assert(db:close() and empty:close())
end

--- A YAML file named is laid out by [`build.flow`], in any tree; one
--- under `.github/` is found only in cosmic's own tree, and only when it
--- is in flow style.
local function test_yaml_in_flow_style_is_taken(tmp: string)
  assert(Fs.mkdirs(tmp .. "/.github/workflows"))
  assert(Fs.write(tmp .. "/.github/workflows/a.yml", "{a: 1}\n"))
  assert(Fs.write(tmp .. "/.github/workflows/b.yml", "a: 1\n"))
  local picked = assert(chosen(tmp, { tmp .. "/.github/workflows/b.yml", tmp }))
  assert(#picked.flow_files == 1 and picked.flow_files[1] == tmp .. "/.github/workflows/b.yml",
    table.concat(picked.flow_files, " "))

  assert(Fs.mkdirs(tmp .. "/own/core"))
  assert(Fs.mkdirs(tmp .. "/own/build"))
  assert(Fs.mkdirs(tmp .. "/own/vendor/lua"))
  assert(Fs.mkdirs(tmp .. "/own/.github/actions/x"))
  assert(Fs.write(tmp .. "/own/build/importer.tl", "return {}\n"))
  assert(Fs.write(tmp .. "/own/.github/actions/x/action.yml", "# c\n{a: 1}\n"))
  assert(Fs.write(tmp .. "/own/.github/block.yml", "a: 1\n"))
  picked = assert(chosen(tmp .. "/own", { tmp .. "/own" }, true))
  assert(#picked.flow_files == 1 and picked.flow_files[1] == tmp .. "/own/.github/actions/x/action.yml",
    table.concat(picked.flow_files, " "))
  -- `.github/` named, or a directory under it, covers what it holds.
  for _, dir in ipairs({ tmp .. "/own/.github", tmp .. "/own/.github/actions", tmp .. "/own/.github/actions/" }) do
    picked = assert(chosen(tmp .. "/own", { dir }, true))
    assert(#picked.flow_files == 1 and picked.flow_files[1]:match("/%.github/actions/x/action%.yml$") ~= nil,
      dir .. ": " .. table.concat(picked.flow_files, " "))
    assert(not nth(picked.flow_files, 1):find("//", 1, true), picked.flow_files[1])
  end
  -- Whether a directory lies under `.github/` is read off its path in
  -- the tree, not above it; and `vendor/` is never covered.
  assert(Fs.mkdirs(tmp .. "/.github/own/core"))
  assert(Fs.mkdirs(tmp .. "/.github/own/build"))
  assert(Fs.mkdirs(tmp .. "/.github/own/vendor/lua/.github"))
  assert(Fs.mkdirs(tmp .. "/.github/own/.github/workflows"))
  assert(Fs.mkdirs(tmp .. "/.github/own/docs"))
  assert(Fs.write(tmp .. "/.github/own/build/importer.tl", "return {}\n"))
  assert(Fs.write(tmp .. "/.github/own/.github/workflows/w.yml", "{a: 1}\n"))
  assert(Fs.write(tmp .. "/.github/own/docs/d.yml", "{a: 1}\n"))
  assert(Fs.write(tmp .. "/.github/own/vendor/lua/.github/v.yml", "{a: 1}\n"))
  local nested = tmp .. "/.github/own"
  for _, named in ipairs({ {}, { nested } }) do
    picked = assert(chosen(nested, named, true))
    local got = table.concat(picked.flow_files, " ")
    assert(#picked.flow_files == 1 and got:match("%.github/workflows/w%.yml$") ~= nil, got)
  end
  for _, dir in ipairs({ nested .. "/vendor/lua", nested .. "/docs" }) do
    picked = assert(chosen(nested, { dir }, true))
    assert(#picked.flow_files == 0, dir .. ": " .. table.concat(picked.flow_files, " "))
  end
end

--- A YAML file is laid out in place, not written under `--check`, and
--- refused in block style.
local function test_yaml_is_laid_out_in_place(tmp: string)
  local path = tmp .. "/a.yml"
  assert(Fs.write(path, "{a:  1,b: [1,2]}\n"))
  assert(Fs.write(tmp .. "/b.yml", "a: 1\n"))
  local changed, failures: {string}, {string} = {}, {}
  fix.lay_out({ path }, true, changed, failures)
  assert(#changed == 1 and #failures == 0 and Fs.read(path) == "{a:  1,b: [1,2]}\n", "--check writes nothing")
  changed = {}
  fix.lay_out({ path, tmp .. "/b.yml" }, false, changed, failures)
  assert(#changed == 1 and (Fs.read(path)) == "{a: 1, b: [1, 2]}\n", (Fs.read(path)))
  assert(#failures == 1 and failures[1]:find("not in flow style", 1, true) ~= nil, failures[1])
  assert(Fs.read(tmp .. "/b.yml") == "a: 1\n")
  changed = {}
  fix.lay_out({ path }, true, changed, {})
  assert(#changed == 0, "a laid-out file is left alone")
end

--- Markdown and Zig are taken to have their links checked, named or
--- under a directory named, past the build's output; they are not Teal
--- to render.
--- A whole run's links cover what a narrower one names: the core's
--- Teal and the skills' Markdown under `.claude/`, which nothing lays
--- out, and no other hidden directory.
local function test_the_core_and_the_skills_have_their_links_checked(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/.claude/skills/a"))
  assert(Fs.mkdirs(tmp .. "/.other"))
  assert(Fs.write(tmp .. "/core/a_test.tl", "local x = 1\n"))
  assert(Fs.write(tmp .. "/.claude/skills/a/SKILL.md", "# A\n"))
  assert(Fs.write(tmp .. "/.other/b.md", "# B\n"))
  local all = assert(chosen(tmp, {}))
  assert(table.concat(all.checked, " ") == ".claude/skills/a/SKILL.md core/a_test.tl",
    table.concat(all.checked, " "))
  assert(#all.files == 0, table.concat(all.files, " "))
end

local function test_markdown_and_zig_are_taken_to_be_checked(tmp: string)
  assert(Fs.mkdirs(tmp .. "/doc"))
  assert(Fs.mkdirs(tmp .. "/o"))
  assert(Fs.write(tmp .. "/build.zig", "const x = 1;\n"))
  assert(Fs.write(tmp .. "/doc/a.md", "# A\n"))
  assert(Fs.write(tmp .. "/o/b.md", "# B\n"))
  local all = assert(chosen(tmp, {}))
  assert(table.concat(all.checked, " ") == "build.zig doc/a.md", table.concat(all.checked, " "))
  assert(#all.files == 0, "Markdown is no Teal source")
  local named = assert(chosen(tmp, { tmp .. "/doc/a.md", tmp .. "/doc" }))
  assert(#named.refused == 0, table.concat(named.refused, "\n"))
  assert(#named.checked == 2 and named.checked[1] == tmp .. "/doc/a.md", table.concat(named.checked, " "))
end

--- A world on disk under `root`, where no symbol is known but `known`.
local function on_disk(root: string, known: {string: {link_resolve.Symbol}}): link_resolve.Context
  return link_resolve.on_disk(root,
    function(query: string): {link_resolve.Symbol}?, string
      return known[query] or {}, ""
    end,
    function(_: string, _: string): {link_resolve.Symbol}?, string
      return {}, ""
    end,
    function(): string? return nil end)
end

--- A link that resolves passes and one that does not fails, naming its
--- file, line and target, in each kind of file fix reads links in.
local function test_a_broken_link_fails_in_each_kind_of_file(tmp: string)
  local root = assert(Fs.absolute(tmp))
  assert(Fs.mkdirs(root .. "/doc"))
  assert(Fs.write(root .. "/doc/guide.md", table.concat({
    "# Guide",
    "",
    "See [the design](design.md), [`Known.thing`] and [`build.zig`].",
    "Not [here](#nowhere), nor [there](missing.md).",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/doc/design.md", "# Design\n"))
  assert(Fs.write(root .. "/a.tl", table.concat({
    "--- Calls [`helper`], documented in [the guide](doc/guide.md#guide).",
    "local function helper()",
    "end",
    "",
    "-- Not [`nothing`].",
    "return helper",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/b.c", table.concat({
    "/* [`count`] counts; [`uncounted`] is not here. */",
    "static int count (int n) {",
    "  return n;",
    "}",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/build.zig", table.concat({
    "/// Builds with [`step`]; see [the guide](doc/guide.md).",
    "const step = \"// [`not_a_comment`]\";",
    "const text = \\\\ a line // [`nor_this`]",
    "// But [`no_step`].",
    "",
  }, "\n")))
  local context = on_disk(root, { ["Known.thing"] = { { module = "known", symbol = "Known.thing" } } })
  local files = { root .. "/doc/guide.md", root .. "/a.tl", root .. "/b.c", root .. "/build.zig" }
  local found = table.concat(fix.links(context, files).broken, "\n")
  local want = table.concat({
    root .. "/doc/guide.md:4: link: #nowhere does not resolve (no heading of guide.md has the anchor #nowhere)",
    root .. "/doc/guide.md:4: link: missing.md does not resolve (no declaration, symbol or file by that name)",
    root .. "/a.tl:5: link: nothing does not resolve (a name alone links only to a declaration of its own file; write another module's symbol in full (`module.member`))",
    root .. "/b.c:1: link: uncounted does not resolve (a name alone links only to a declaration of its own file; write another module's symbol in full (`module.member`))",
    root .. "/build.zig:4: link: no_step does not resolve (a name alone links only to a declaration of its own file; write another module's symbol in full (`module.member`))",
  }, "\n")
  assert(found == want, "got:\n" .. found .. "\nwant:\n" .. want)
end

--- A run over part of the tree builds the project before it reads what
--- a link names, and only once; a whole run reads the projection it
--- just wrote; a run that meets no symbol link opens nothing.
local function test_links_read_symbols_from_a_build_made_when_needed(tmp: string)
  local root = assert(Fs.absolute(tmp))
  assert(Fs.write(root .. "/a.md", "[`m.one`] [`m.two`]\n"))
  assert(Fs.write(root .. "/b.md", "[b](b.md)\n"))
  for _, whole in ipairs({ false, true }) do
    local rebuilt = { value = 0 }
    local opened = { value = 0 }
    local source = fix.link_context(root, whole, true,
      function(_: string): boolean, string
        rebuilt.value = rebuilt.value + 1
        return true, ""
      end,
      function(): docs.Sources
        opened.value = opened.value + 1
        return { handles = {}, public = {}, opened = {} }
      end)
    fix.links(source.context, { root .. "/b.md" })
    assert(opened.value == 0 and rebuilt.value == 0, "a file with no symbol link opened the databases")
    local found = fix.links(source.context, { root .. "/a.md" })
    source.close()
    assert(#found.broken == 2, table.concat(found.broken, "\n"))
    assert(opened.value == 1, "opened " .. opened.value .. " times")
    assert(rebuilt.value == (if whole then 0 else 1 end), (if whole then "whole" else "part" end) .. ": rebuilt " .. rebuilt.value)
  end
end

--- A build made to resolve a link that fails is kept, for the run to
--- fail on; one that builds leaves nothing.
local function test_links_keep_why_their_build_failed(tmp: string)
  local root = assert(Fs.absolute(tmp))
  assert(Fs.write(root .. "/a.md", "[`m.one`]\n"))
  for _, case in ipairs({ { ok = false, want = "a.tl: the compiler refused it" }, { ok = true } }) do
    local source = fix.link_context(root, false, true,
      function(_: string): boolean, string
        return case.ok, if case.ok then "" else "a.tl: the compiler refused it" end
      end,
      function(): docs.Sources return { handles = {}, public = {}, opened = {} } end)
    assert(source.unbuilt == nil, "before a link named a symbol")
    fix.links(source.context, { root .. "/a.md" })
    source.close()
    assert(source.unbuilt == case.want, tostring(source.unbuilt))
  end
end

--- A project that has not been built checks no link against symbols,
--- and says so once as a note rather than failing each: a name in
--- full, and a member of a module through its alias alike.
local function test_links_to_symbols_wait_for_a_build(tmp: string)
  local root = assert(Fs.absolute(tmp))
  assert(Fs.write(root .. "/a.md", "[`m.one`] [`m.two`] [gone](gone.md)\n"))
  assert(Fs.write(root .. "/b.tl", 'local M = require("m")\n\n--- See [`M.three`].\n' ..
      "local function f(): integer return M.three() end\n\nreturn f\n"))
  local source = fix.link_context(root, false, false,
    function(_: string): boolean, string return true, "" end,
    function(): docs.Sources return { handles = {}, public = {}, opened = {} } end)
  local found = fix.links(source.context, { root .. "/a.md", root .. "/b.tl" })
  source.close()
  assert(#found.broken == 1 and found.broken[1]:find("gone.md", 1, true) ~= nil, table.concat(found.broken, "\n"))
  assert(#found.notes == 1 and found.notes[1]:find("3 links to a symbol not checked", 1, true) ~= nil,
    table.concat(found.notes, "\n"))
end

--- Unbuilt, a member through an alias to a module the symbols already
--- know (the standard library's) is still checked: one it lacks fails
--- rather than waiting for a build that would not add it.
local function test_an_unbuilt_project_still_checks_a_known_modules_members(tmp: string)
  local root = assert(Fs.absolute(tmp))
  assert(Fs.write(root .. "/a.tl", 'local Fs = require("cosmic.fs")\n\n--- See [`Fs.nosuch`].\n' ..
      'local function f(): string return (Fs.read("x")) end\n\nreturn f\n'))
  local context = link_resolve.on_disk(root,
    function(query: string): {link_resolve.Symbol}?, string
      if query == "cosmic.fs" then return { { module = "cosmic.fs", symbol = "" } }, "" end
      return {}, ""
    end,
    function(_: string, _: string): {link_resolve.Symbol}?, string return {}, "" end,
    function(): string? return "not built" end)
  local found = fix.links(context, { root .. "/a.tl" })
  assert(#found.broken == 1 and found.broken[1]:find("Fs.nosuch does not resolve (cosmic.fs has no nosuch)",
    1, true) ~= nil, table.concat(found.broken, "\n"))
  assert(#found.notes == 0, table.concat(found.notes, "\n"))
end

--- A Markdown or Zig file is never among what fix renders or lays out,
--- however it is named, so no run rewrites one.
local function test_markdown_and_zig_are_never_rewritten(tmp: string)
  assert(Fs.write(tmp .. "/a.md", "#  Messy   heading\n"))
  assert(Fs.write(tmp .. "/b.zig", "const   x = 1;\n"))
  for _, named in ipairs({ {}, { tmp }, { tmp .. "/a.md", tmp .. "/b.zig" } }) do
    local picked = assert(chosen(tmp, named))
    local rewritten = table.concat(picked.files, " ") .. table.concat(picked.c_files, " ") ..
      table.concat(picked.flow_files, " ")
    assert(rewritten == "", rewritten)
    assert(#picked.checked == 2, table.concat(picked.checked, " "))
  end
end

--- `--check` names each plain span that would link and writes
--- nothing; a fix links them, writes the file, and checks it as
--- written, and a second fix finds nothing more.
local function test_a_plain_span_would_link_and_a_fix_links_it(tmp: string)
  local root = assert(Fs.absolute(tmp))
  local text = "Use `Known.thing` here.\n"
  assert(Fs.write(root .. "/known.tl", ""))
  assert(Fs.write(root .. "/a.md", text))
  local context = on_disk(root, { ["Known.thing"] = { { module = "known", symbol = "Known.thing",
    file = "known.tl" } } })
  local checking = fix.links(context, { root .. "/a.md" }, "check")
  local said = table.concat(checking.would, "\n")
  assert(said == root .. "/a.md:1: link: `Known.thing` would link to known.Known.thing", said)
  assert(#checking.redefined == 1 and
      checking.redefined[1] == root .. "/a.md: link: its definitions would be rewritten",
    table.concat(checking.redefined, "\n"))
  assert(#checking.broken == 0 and #checking.rewritten == 0, table.concat(checking.broken, "\n"))
  assert(assert(Fs.read(root .. "/a.md")) == text, "a check wrote the file")
  local fixing = fix.links(context, { root .. "/a.md" }, "write")
  assert(#fixing.broken == 0 and #fixing.would == 0, table.concat(fixing.broken, "\n"))
  assert(#fixing.rewritten == 1, tostring(#fixing.rewritten))
  local written = assert(Fs.read(root .. "/a.md"))
  assert(written == "Use [`Known.thing`] here.\n\n[`Known.thing`]: known.tl\n", written)
  local again = fix.links(context, { root .. "/a.md" }, "check")
  assert(#again.would == 0 and #again.broken == 0, table.concat(again.would, "\n"))
end

--- A project's `static/` is carried verbatim: no Teal, template, Markdown
--- or other file under it is laid out, parsed or link-checked, whether the
--- run names it or the whole tree.
local function test_nothing_under_static_is_chosen(tmp: string)
  assert(Fs.mkdirs(tmp .. "/static/docs"))
  assert(Fs.write(tmp .. "/static/a.tl", "this is   not Teal {{\n"))
  assert(Fs.write(tmp .. "/static/p.tmpl", "{{ unclosed\n"))
  assert(Fs.write(tmp .. "/static/docs/readme.md", "[dead](nowhere.md)\n"))
  assert(Fs.write(tmp .. "/main.tl", "return 1\n"))
  local every = assert(chosen(tmp, {}))
  assert(#every.files == 1 and every.files[1] == "main.tl", table.concat(every.files, " "))
  assert(#every.templates == 0 and #every.checked == 0 and #every.refused == 0)
  for _, path in ipairs({ tmp .. "/static", tmp .. "/static/a.tl", tmp .. "/static/docs/readme.md" }) do
    local named = assert(chosen(tmp, { path }))
    assert(#named.files == 0 and #named.templates == 0 and #named.checked == 0, path)
    assert(#named.refused == 1 and named.refused[1]:find("carried verbatim", 1, true) ~= nil, path)
  end
end

--- A Teal file of `source` in `tmp`, laid out by [`fix.lay_out_source`] (`checking`, `kept` and `layout` as it takes
--- them), and what it did.
local function laid_in(tmp: string, name: string, source: string, checking: boolean, kept?: laid.Kept,
                       layout?: Format.Layouter): fix.Laid, string
  local file = tmp .. "/" .. name
  assert(Fs.write(file, source))
  local chunk = assert(SyntaxNode.parse(source, file))
  return fix.lay_out_source(file, source, chunk, checking, kept, layout), file
end

--- A layout that is `text`, whatever the source: a faulty formatter.
local function giving(text: string): Format.Layouter
  return function(_source: string, _name: string, _dialect?: Ast.Dialect): string?, string
    return text, ""
  end
end

--- A plain run writes the layout of a file and what it left is laid out: laying it out again writes nothing.
local function test_a_file_not_laid_out_is_written(tmp: string)
  local done, file = laid_in(tmp, "a.tl", "local   x=1\nprint( x )\n", false)
  assert(done.state == "written" and done.why == "", done.why)
  assert(Fs.read(file) == "local x = 1\nprint(x)\n", "the layout was not written")
  assert(done.text == "local x = 1\nprint(x)\n", "the later phases would read the text before")
  assert(Fs.read(file) == done.text)
  local again = fix.lay_out_source(file, done.text, done.chunk, false, nil)
  assert(again.state == "laid", again.state)
end

--- A check says the file is not laid out and writes nothing: the later phases read the file as it is.
local function test_a_check_leaves_a_file_not_laid_out_as_it_is(tmp: string)
  local source = "local   x=1\n"
  local done, file = laid_in(tmp, "a.tl", source, true)
  assert(done.state == "unlaid" and done.text == source, done.state)
  assert(Fs.read(file) == source, "a check wrote the file")
  local laid_out = laid_in(tmp, "b.tl", "local x = 1\n", true)
  assert(laid_out.state == "laid")
end

--- A faulty layout and why the formatter refuses it.
local record Refusal
  layout: string
  reason: string
end

--- A layout that is not the file, or not a fixed point, is a fault of the formatter: the file is left as it is, in a
--- plain run as in a check, with the formatter's reason.
local function test_a_refusal_never_writes_and_says_why(tmp: string)
  local source = "local x = 1 -- c\nlocal y = { 1, 2 }\n"
  local cases: {Refusal} = {
    { layout = "local x = 1\nlocal y = { 1, 2 }\n", reason = "the layout is not the same as the file" },
    { layout = "local x = 1 -- c\nlocal y = { 1 }\n", reason = "the layout is not the same as the file" },
    { layout = "local x = 1 -- c\nlocal y =  { 1, 2 }\n", reason = "not a fixed point" },
  }
  for _, case in ipairs(cases) do
    for _, checking in ipairs({ true, false }) do
      local done, file = laid_in(tmp, "r.tl", source, checking, nil, giving(case.layout))
      assert(done.state == "refused", done.state)
      assert(done.why:find(case.reason, 1, true) ~= nil and done.why:find("r.tl", 1, true) ~= nil, done.why)
      assert(Fs.read(file) == source, "a refused file was written")
      assert(done.text == source)
    end
  end
end

--- A file the memo holds as laid out is answered without the formatter, and one it does not is formatted: a memo that
--- holds the code of another formatter, or another text, misses.
local function test_the_memo_answers_a_file_it_holds_and_misses_one_it_does_not(tmp: string)
  local db = assert(Sqlite.memory())
  local kept = assert(laid.begin(db, "formatter one"))
  local source = "local x = 1\n"
  -- The faulty formatter would refuse a file laid out, if it were asked: the first run asks it.
  local refused = laid_in(tmp, "m.tl", source, false, kept, giving("local x = 2\n"))
  assert(refused.state == "refused", refused.state)
  -- Asked without the faulty one, the file is found laid out and kept.
  assert(laid_in(tmp, "m.tl", source, false, kept).state == "laid")
  -- A hit is not asked of any formatter.
  assert(laid_in(tmp, "m.tl", source, false, kept, giving("local x = 2\n")).state == "laid", "a hit asked the formatter")
  -- Another formatter, or another text, misses.
  laid.finish(kept, false)
  local other = assert(laid.begin(db, "formatter two"))
  assert(laid_in(tmp, "m.tl", source, false, other, giving("local x = 2\n")).state == "refused", "a formatter change hit")
  laid.finish(other, false)
  local again = assert(laid.begin(db, "formatter one"))
  assert(laid_in(tmp, "m.tl", source, false, again, giving("local x = 2\n")).state == "laid")
  assert(laid_in(tmp, "m.tl", "local x  =  1\n", false, again).state == "written", "a changed text hit")
  laid.finish(again, false)
end

--- A declaration file is laid out as one, a program as a program: the dialect is the name's.
local function test_a_declaration_file_is_laid_out_as_a_declaration_file(tmp: string)
  local source = "local  record R\n  x:   integer\n  yy:  string\nend\n\nreturn R\n"
  local done, file = laid_in(tmp, "r.d.tl", source, false)
  assert(done.state == "written", done.why)
  assert(Fs.read(file) == "local record R\n  x:   integer\n  yy:  string\nend\n\nreturn R\n", Fs.read(file))
  local kept = assert(laid.begin(assert(Sqlite.memory()), "s"))
  assert(laid_in(tmp, "r.d.tl", assert(Fs.read(file)), false, kept).state == "laid")
  -- Kept for a declaration file, not for a program of the same text.
  assert(laid_in(tmp, "r.tl", assert(Fs.read(file)), false, kept, giving("local record R\nend\n")).state == "refused")
end

--- A script that is executable stays so when its layout is written.
local function test_a_file_written_keeps_its_mode(tmp: string)
  local file = tmp .. "/script.tl"
  assert(Fs.write(file, "local   x=1\n"))
  assert(Fs.chmod(file, 0x1ed))
  local source = assert(Fs.read(file))
  local chunk = assert(SyntaxNode.parse(source, file))
  assert(fix.lay_out_source(file, source, chunk, false, nil).state == "written")
  assert(Fs.read(file) == "local x = 1\n")
  assert(assert(Fs.stat(file)).mode & 0xfff == 0x1ed, "the mode was lost")
end

--- A link is not written: a write would replace it with a copy and leave its target as it was.
local function test_a_link_is_not_written(tmp: string)
  local target = tmp .. "/real.tl"
  local link = tmp .. "/link.tl"
  assert(Fs.write(target, "local   x=1\n"))
  assert(Fs.symlink("real.tl", link))
  local source = assert(Fs.read(link))
  local chunk = assert(SyntaxNode.parse(source, link))
  local done = fix.lay_out_source(link, source, chunk, false, nil)
  assert(done.state == "linked" and done.why == "not written: " .. link .. " is a link; fix its target", done.why)
  assert(Fs.readlink(link) == "real.tl", "the link was replaced")
  assert(Fs.read(target) == "local   x=1\n")
  -- A check says only that it is not laid out.
  assert(fix.lay_out_source(link, source, chunk, true, nil).state == "unlaid")
  -- The target is laid out by naming it.
  assert(fix.lay_out_source(target, source, chunk, false, nil).state == "written")
  assert(Fs.read(target) == "local x = 1\n")
end

--- A file edited since it was read is not overwritten.
local function test_a_file_changed_while_being_laid_out_is_not_written(tmp: string)
  local file = tmp .. "/edited.tl"
  assert(Fs.write(file, "local   x=1\n"))
  local source = assert(Fs.read(file))
  local chunk = assert(SyntaxNode.parse(source, file))
  assert(Fs.write(file, "local   x=2\n"))
  local done = fix.lay_out_source(file, source, chunk, false, nil)
  assert(done.state == "changed" and done.why == "not written: " .. file .. " changed while being laid out", done.why)
  assert(Fs.read(file) == "local   x=2\n", "the edit was overwritten")
end

--- A named Teal file that identity rejects as an input is set apart for a check of its own, in a project that is not cosmic's:
--- the build never reads it. A file the build reads, or one inside cosmic's own tree, is not.
local function test_a_named_file_outside_the_build_is_set_apart_to_be_checked_alone(tmp: string)
  local dir = tmp .. "/project"
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.mkdirs(dir .. "/lib"))
  assert(Fs.write(dir .. "/bin/a.tl", "return 1\n"))
  assert(Fs.write(dir .. "/lib/b.tl", "return 2\n"))
  assert(Fs.write(tmp .. "/stray.tl", "return 3\n"))
  local picked = assert(fix.chosen(dir, { dir .. "/bin/a.tl", dir .. "/lib/b.tl", tmp .. "/stray.tl" }))
  local alone = assert(picked.alone)
  assert(#alone == 2 and alone[1] == dir .. "/bin/a.tl" and alone[2] == tmp .. "/stray.tl",
    "bin/a.tl and the file outside the root are checked alone, lib/b.tl is the build's: " .. table.concat(alone, ","))
  assert(#picked.files == 3, "each is laid out all the same")
end
