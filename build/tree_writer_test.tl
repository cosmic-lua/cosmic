--- The writer of the translated tree ([`build.tree_writer`]): what it writes, what it refuses, that translating its output
--- changes nothing, and that the Lua of a translated module is the original's.

local CompileGrammar = require("build.compile_grammar")
local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local TreeProgram = require("build.tree_program")
local TreeWriter = require("build.tree_writer")

Test.policy{ grants = {
  { path = "build/ceilings.txt", letters = "r" }, { path = "lang/", letters = "r" }, { path = "cosmic/", letters = "r" },
} }

--- A module that uses many of the rows the translator rewrites, in the fork's Teal.
local MODULE <const> = table.concat({
  "local record Box",
  "  size: integer",
  "  note: string | nil",
  "  fill: function(integer...): integer",
  "  pad: function(? integer): integer",
  "end",
  "",
  "local function pick(a: integer | nil, b: integer): integer",
  "  return a and a + 1 or b",
  "end",
  "",
  "local function kind(n: integer): string",
  "  return n < 0 and \"negative\" or n == 0 and \"zero\" or \"positive\"",
  "end",
  "",
  "local function total(values: {integer}, skip: integer): integer",
  "  local sum = 0",
  "  for _, v in ipairs(values) do",
  "    if v == skip then goto continue end",
  "    sum = sum + v",
  "    ::continue::",
  "  end",
  "  return sum;",
  "end",
  "",
  "--[[ a long comment",
  "     over two lines ]]",
  "local function grow(box: Box, by: integer): Box",
  "  box.size = box.size + by",
  "  return box",
  "end",
  "",
  "return { pick = pick, kind = kind, total = total, grow = grow }",
  "",
}, "\n")

--- A declaration file in the fork's Teal.
local DECLARATION <const> = table.concat({
  "local record decl",
  "  lookup: function(name: string): string | nil",
  "end",
  "return decl",
  "",
}, "\n")

--- A guide: prose, an example of two blocks that continue, a lua block, a shebang block, a skipped block that does not
--- translate, a project of two files, and a file that is no Teal.
local GUIDE <const> = table.concat({
  "# A guide",
  "",
  "Some prose with `a and b or c` in it.",
  "",
  "```teal",
  "local maybe: string | nil = nil",
  "```",
  "",
  "More prose.",
  "",
  "```teal continue",
  "local size = maybe and 1 or 2",
  "print(size)",
  "```",
  "",
  "```output",
  "2",
  "```",
  "",
  "```lua",
  "local t = maybe and 1 or 2",
  "```",
  "",
  "```teal skip=intended",
  "local x = (nothing",
  "```",
  "",
  "```teal file=lib.tl",
  "local function name(): string | nil",
  "  return nil",
  "end",
  "return name",
  "```",
  "",
  "```teal",
  "local name = require(\"lib\")",
  "print(name())",
  "```",
  "",
  "```teal file=page.tmpl",
  "{{type Page from lib}}",
  "```",
  "",
  "The end.",
  "",
}, "\n")

--- The allow-list that lets nothing through.
local function strict(): TreeWriter.Allowance
  return { paths = {}, pins = {} }
end

local function options(again: boolean, translator?: TreeWriter.Translator): TreeWriter.Options
  return { allowance = strict(), again = again, translator = translator, raw = nil }
end

local function put(root: string, path: string, text: string)
  assert(Fs.mkdirs(Fs.dirname(root .. "/" .. path)))
  assert(Fs.write(root .. "/" .. path, text))
end

local function sample(tmp: string): string
  local root = tmp .. "/tree"
  put(root, "m.tl", MODULE)
  put(root, "sub/decl.d.tl", DECLARATION)
  put(root, "doc/guides/g.md", GUIDE)
  return root
end

--- The rows of `counts` as `row=n` words, in order.
local function show(counts: {string: integer}): string
  local words: {string} = {}
  for row, n in pairs(counts) do
    words[#words + 1] = row .. "=" .. tostring(n)
  end
  table.sort(words, function(a: string, b: string): boolean
    return a < b
  end)
  return table.concat(words, " ")
end

local function has(text: string, part: string): boolean
  return text:find(part, 1, true) ~= nil
end

local function test_a_tree_is_written_translated_and_translating_the_output_changes_nothing(tmp: string)
  local root = sample(tmp)
  local paths = { "doc/guides/g.md", "m.tl", "sub/decl.d.tl" }
  local report = assert(TreeWriter.write(root, paths, tmp .. "/out", options(true)))
  assert(report.files == 3 and #report.clean == 3 and #report.refused == 0 and #report.allowed == 0,
    table.concat(TreeWriter.summary(report), "\n"))
  assert(report.changed == 3, "every file had a form to translate: " .. tostring(report.changed))
  assert(#report.unstable == 0, table.concat(report.unstable, ","))
  assert(report.left == 1, "the skipped block that does not translate is counted: " .. tostring(report.left))
  -- Compared per row, in order: each row the sample was made to exercise made its rewrites, and the counts are not zero.
  assert(report.counts["nil_union"] == 5 and report.counts["ternary"] == 3 and report.counts["continue"] == 1 and
      report.counts["variadic_type"] == 1 and report.counts["optional_type"] == 1 and report.counts["semicolon"] == 1 and
      report.counts["long_comment"] == 1 and report.counts["mut_field"] == 1, "rewrites: " .. show(report.counts))
  for _, path in ipairs(paths) do
    local written = assert(Fs.read(tmp .. "/out/" .. path))
    -- The output is its own fixed point, found by translating it here and not only by the writer's own `again`.
    local again = TreeWriter.write(tmp .. "/out", { path }, tmp .. "/again", options(false))
    assert(again ~= nil and again.changed == 0, path .. " changes when translated again")
    assert(assert(Fs.read(tmp .. "/again/" .. path)) == written, path)
  end
  local module = assert(Fs.read(tmp .. "/out/m.tl"))
  assert(module == Translate.translate(MODULE, "m.tl").text, "the file is the translator's text")
  assert(has(module, "note: string?") and has(module, "size: integer") and has(module, "return if a then a + 1 else b end"),
    module)
  assert(not has(module, "goto") and not has(module, "::continue::") and not has(module, "--[["), module)
end

local function test_a_guide_has_its_examples_translated_and_its_prose_kept()
  local made = TreeWriter.guide(GUIDE, "g.md")
  assert(#made.errors == 0, table.concat(made.errors, "\n"))
  local before: {string} = {}
  for line in GUIDE:gmatch("([^\n]*)\n") do
    before[#before + 1] = line
  end
  local after: {string} = {}
  for line in made.text:gmatch("([^\n]*)\n") do
    after[#after + 1] = line
  end
  -- Nothing moves in a guide with no class, so the guide is compared line by line, and only the example lines differ.
  assert(#before == #after and #before > 30, tostring(#before) .. " lines before, " .. tostring(#after) .. " after")
  local differing: {integer} = {}
  for i = 1, #before do
    if before[i] ~= after[i] then
      differing[#differing + 1] = i
    end
  end
  -- The `string | nil` of the first block, the ternary of its continuation, the function of `lib.tl`.
  assert(table.concat(differing, ",") == "6,12,29", table.concat(differing, ","))
  assert(after[6] == "local maybe: string? = nil", after[6])
  assert(after[12] == "local size = if maybe then 1 else 2 end", after[12])
  assert(after[29] == "local function name(): string?", after[29])
  assert(has(made.text, "local t = maybe and 1 or 2\n"), "a lua block is left")
  assert(has(made.text, "{{type Page from lib}}"), "a template is left")
  assert(has(made.text, "local x = (nothing\n"), "a skipped block that does not translate is left")
  assert(made.left == 1 and not has(made.text, "tree_writer"), "the boundary of a block is gone")
  assert(made.counts["nil_union"] == 2 and made.counts["ternary"] == 1, show(made.counts))
  assert(TreeWriter.guide(made.text, "g.md").text == made.text, "translating the guide again changes it")
end

local function test_an_example_of_a_class_moves_the_lines_after_it_and_leaves_the_prose()
  local guide = table.concat({
    "Before.",
    "",
    "```teal",
    "local record Stack",
    "  items: {integer}",
    "end",
    "local Stack_mt: metatable<Stack> = { __index = Stack }",
    "",
    "function Stack:push(n: integer)",
    "  self.items[#self.items + 1] = n",
    "end",
    "```",
    "",
    "After.",
    "",
  }, "\n")
  local made = TreeWriter.guide(guide, "stack.md")
  assert(#made.errors == 0 and made.counts["class"] == 1, table.concat(made.errors, "\n") .. show(made.counts))
  assert(made.text:sub(1, 8) == "Before.\n" and made.text:sub(-8) == "\nAfter.\n", made.text)
  assert(has(made.text, "class Stack"), made.text)
  assert(TreeWriter.guide(made.text, "stack.md").text == made.text, "a class is written again as it is")
end

local function test_a_guide_whose_example_does_not_translate_is_refused_with_the_example_named()
  local guide = table.concat({ "Text.", "", "```teal", "local x = (nothing", "```", "" }, "\n")
  local made = TreeWriter.guide(guide, "bad.md")
  assert(#made.errors > 0 and (made.errors[1] or ""):find("bad.md:3: example", 1, true) == 1, table.concat(made.errors, "\n"))
  assert(made.text:sub(1, 6) == "Text.\n", "the guide is still answered")
  local fences = TreeWriter.guide("```teal\nlocal x = 1\n", "open.md")
  assert(#fences.errors == 1 and fences.codes["fences"] == 1 and fences.text == "```teal\nlocal x = 1\n", table.concat(fences.errors))
end

--- A translator that answers what the real one does with `text` set to what `change` makes of it.
local function planting(change: function(string): string): TreeWriter.Translator
  return function(source: string, name: string): Translate.Result
    local real = Translate.translate(source, name)
    return {
      text = change(real.text), counts = real.counts, errors = real.errors, hazards = real.hazards,
      interfaces = real.interfaces, metatables = real.metatables, reads = real.reads,
    }
  end
end

local function test_a_translation_that_changes_when_translated_again_is_reported_as_unstable(tmp: string)
  local root = tmp .. "/tree"
  put(root, "a.tl", "local x: string | nil = nil\nreturn x\n")
  put(root, "b.tl", "return 1\n")
  -- A translator that is not its own fixed point: every pass adds a line.
  local drifting = planting(function(text: string): string
    return text .. "-- again\n"
  end)
  local report = assert(TreeWriter.write(root, { "a.tl", "b.tl" }, tmp .. "/out", options(true, drifting)))
  assert(table.concat(report.unstable, ",") == "a.tl,b.tl", table.concat(report.unstable, ","))
  local without = assert(TreeWriter.write(root, { "a.tl" }, tmp .. "/out2", options(false, drifting)))
  assert(#without.unstable == 0, "the second translation is made only where asked")
end

local function test_an_example_that_loses_its_block_boundary_is_an_error_and_is_left_as_written()
  local guide = table.concat({
    "```teal",
    "local a: string | nil = nil",
    "```",
    "",
    "```teal continue",
    "local b: string | nil = nil",
    "```",
    "",
    "```teal skip=intended",
    "local c: string | nil = nil",
    "```",
    "",
  }, "\n")
  local losing = planting(function(text: string): string
    return (text:gsub("%-%- tree_writer: end of block\n", ""))
  end)
  local made = TreeWriter.guide(guide, "lost.md", losing)
  assert(#made.errors == 1 and (made.errors[1] or ""):find("lost.md:1: the translation of the example lost a block boundary", 1, true) == 1,
    table.concat(made.errors, "\n"))
  assert(made.codes["boundary"] == 1 and made.left == 0, "the skipped block has one block and no boundary to lose")
  assert(has(made.text, "local a: string | nil = nil\n```") and has(made.text, "local b: string | nil = nil\n```"),
    "an example that cannot be split is left as written")
  assert(has(made.text, "local c: string? = nil\n```"), "the skipped block alone is translated")
end

local function test_a_shebang_block_a_lua_block_and_the_blocks_that_continue_a_lua_block_are_left()
  local guide = table.concat({
    "```teal",
    "#!/usr/bin/env cosmic",
    "local a: string | nil = nil",
    "```",
    "",
    "```lua",
    "local b = nil",
    "```",
    "",
    "```teal continue",
    "local c: string | nil = nil",
    "```",
    "",
    "```teal",
    "local d: string | nil = nil",
    "```",
    "",
  }, "\n")
  local made = TreeWriter.guide(guide, "left.md")
  assert(#made.errors == 0, table.concat(made.errors, "\n"))
  assert(has(made.text, "local a: string | nil = nil\n```"), "a shebang block is left")
  assert(has(made.text, "local c: string | nil = nil\n```"), "the continuation of a lua block is left")
  assert(has(made.text, "local d: string? = nil\n```"), "an example after them is translated")
  assert(made.counts["nil_union"] == 1, show(made.counts))
end

local function test_a_file_whose_translation_has_errors_is_refused_unless_it_is_allowed(tmp: string)
  local root = tmp .. "/tree"
  put(root, "fine.tl", "local x: string | nil = nil\nreturn x\n")
  -- A tuple type is a form the translator does not handle.
  put(root, "bad/tuple.tl", "local pair: {integer, string} = {1, \"a\"}\nreturn pair\n")
  put(root, "bad/other.tl", "local pair: {integer, string} = {1, \"a\"}\nreturn pair\n")
  local paths = { "bad/other.tl", "bad/tuple.tl", "fine.tl" }
  local function run(allowance: TreeWriter.Allowance, name: string): TreeWriter.Report
    return (assert(TreeWriter.write(root, paths, tmp .. "/" .. name, { allowance = allowance, again = true, translator = nil, raw = nil })))
  end
  local refused = run(strict(), "strict")
  local first = assert(refused.refused[1])
  assert(#refused.refused == 2 and first.path == "bad/other.tl" and #refused.clean == 1, table.concat(TreeWriter.summary(refused), "\n"))
  assert(first.codes["tuple_type"] == 1 and (first.errors[1] or ""):find("bad/other.tl:1:", 1, true) == 1,
    table.concat(first.errors))
  assert(Fs.exists(tmp .. "/strict/fine.tl") == true and Fs.exists(tmp .. "/strict/bad/tuple.tl") ~= true, "a refused file is not written")
  -- Named, and by the directory.
  local named = run({ paths = { "bad/tuple.tl" }, pins = {} }, "named")
  local allowed = assert(named.allowed[1])
  assert(#named.allowed == 1 and allowed.path == "bad/tuple.tl" and #named.refused == 1, table.concat(TreeWriter.summary(named), "\n"))
  assert(Fs.exists(tmp .. "/named/bad/tuple.tl") == true, "an allowed file is written")
  local by_directory = run({ paths = { "bad/*" }, pins = {} }, "directory")
  assert(#by_directory.allowed == 2 and #by_directory.refused == 0, table.concat(TreeWriter.summary(by_directory), "\n"))
  -- Pinned in [translated]: up to the pin and no more.
  local pinned = run({ paths = {}, pins = { ["bad/tuple.tl tuple_type"] = 1, ["bad/other.tl tuple_type"] = 0 } }, "pinned")
  local within = assert(pinned.allowed[1])
  assert(#pinned.allowed == 1 and within.path == "bad/tuple.tl" and #pinned.refused == 1, table.concat(TreeWriter.summary(pinned), "\n"))
  -- A path that merely begins like the directory is not in it.
  assert(not TreeWriter.permits({ paths = { "bad/*" }, pins = {} }, "badly/x.tl", { tuple_type = 1 }))
  assert(TreeWriter.permits({ paths = { "bad/*" }, pins = {} }, "bad/x.tl", { tuple_type = 1 }))
end

local function test_a_file_in_the_new_grammar_is_written_as_it_is(tmp: string)
  local root = tmp .. "/tree"
  -- The translator reads the fork's Teal, so a file already in the new grammar is not given to it.
  local text = "do\n  global record Seen\n    userdata\n    mut n: {integer}\n  end\nend\n"
  put(root, "lang/stdlib.d.tl", text)
  put(root, "lang/prelude.d.tl", text)
  -- the same text under another name goes through the translator, which refuses a tuple type
  put(root, "lang/other.d.tl", "local pair: {integer, string} = {1, \"a\"}\nreturn pair\n")
  local nothing_allowed: TreeWriter.Allowance = { paths = {}, pins = {} }
  local report = assert(TreeWriter.write(root, { "lang/other.d.tl", "lang/prelude.d.tl", "lang/stdlib.d.tl" }, tmp .. "/out",
    { allowance = nothing_allowed, again = true, translator = nil, raw = nil }))
  assert(#report.clean == 2 and report.clean[1] == "lang/prelude.d.tl" and report.clean[2] == "lang/stdlib.d.tl",
    table.concat(TreeWriter.summary(report), "\n"))
  assert(report.changed == 0 and #report.unstable == 0 and #report.refused == 1 and assert(report.refused[1]).path == "lang/other.d.tl")
  assert(Fs.read(tmp .. "/out/lang/stdlib.d.tl") == text)
end

local function test_the_allow_list_is_the_decided_files_and_what_the_ceilings_still_pin()
  local allowance = assert(TreeWriter.allowance("."))
  local decided = { "cosmic/removed_example.tl", "doc/guides/project.md" }
  assert(#allowance.paths == #decided, table.concat(allowance.paths, ","))
  for _, path in ipairs(decided) do
    assert(TreeWriter.permits(allowance, path, { expected_name = 1000 }), path)
  end
  -- Neither the checker's own modules nor the fork's files are let through: the first are written as the pipeline reads
  -- them, the others are kept.
  assert(not TreeWriter.permits(allowance, "lang/ast.tl", { expected_name = 1000 }))
  assert(not TreeWriter.permits(allowance, "testdata/rehearsal/fork_only/anything.tl", { function_path = 4 }))
  assert(not TreeWriter.permits(allowance, "cosmic/fs.tl", { tuple_type = 1 }), "a file nobody named")
  local pinned = 0
  local by_name: TreeWriter.Allowance = { paths = allowance.paths, pins = {} }
  for key, count in pairs(allowance.pins) do
    pinned = pinned + 1
    local path, code = key:match("^(%S+) (%S+)$")
    assert(path ~= nil and code ~= nil and count > 0, key)
    assert(TreeWriter.permits(allowance, path, { [code] = count }), key)
    if not TreeWriter.permits(by_name, path, { [code] = 1 }) then
      assert(not TreeWriter.permits(allowance, path, { [code] = count + 1 }), key .. " allows more than it pins")
    end
  end
  assert(pinned > 0, "the ceilings pin nothing under [translated]")
end

local function test_the_files_to_write_are_the_tl_files_and_the_guides_outside_vendor_and_hidden_directories(tmp: string)
  local root = tmp .. "/tree"
  for _, path in ipairs({ "a.tl", "b.d.tl", "sub/c_test.tl", "vendor/v.tl", ".hidden/h.tl", "o/x.tl", "doc/guides/g.md",
      "doc/other.md", "doc/guides/nested/n.md", "readme.txt" }) do
    put(root, path, "x\n")
  end
  local listed = assert(TreeWriter.tracked(root))
  assert(table.concat(listed, ",") == "a.tl,b.d.tl,doc/guides/g.md,sub/c_test.tl", table.concat(listed, ","))
end

local function test_the_files_selected_are_the_tl_files_and_the_guides_outside_vendor_sorted()
  local selected = TreeWriter.selected({ "z.tl", "vendor/v.tl", "doc/guides/g.md", "doc/other.md", "doc/guides/nested/n.md",
    "b.d.tl", "readme.txt", "vendor/doc/guides/g.md", "a.tl" })
  assert(table.concat(selected, ",") == "a.tl,b.d.tl,doc/guides/g.md,z.tl", table.concat(selected, ","))
  assert(#TreeWriter.selected({}) == 0)
end

--- The Lua of `text`, one module called `m`, as the tree compiles it: read as the fork's Teal and translated first
--- (`translate`), or written in the new grammar already.
local function lua_of(text: string, translate: boolean): string
  local index = Driver.index({ { "m.tl", text } }, translate, function(_path: string): boolean
    return false
  end)
  local globals = Driver.declarations("globals", "globals.d.tl", "global function print(...: any)\nglobal function ipairs(t: any): any, any, any\n",
    false, {})
  local build = Driver.new({ globals = { globals }, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(index))
  build:lower({ "m" })
  local result = assert(build:result("m", true))
  local emitted = CompileGrammar.emit(build, result)
  return (assert(emitted.code, emitted.trouble))
end

local function test_the_lua_of_a_translated_module_is_the_lua_of_the_original(tmp: string)
  local root = sample(tmp)
  local report = assert(TreeWriter.write(root, { "m.tl" }, tmp .. "/out", options(true)))
  assert(#report.clean == 1)
  local written = assert(Fs.read(tmp .. "/out/m.tl"))
  assert(written ~= MODULE, "the module was not translated")
  local original = lua_of(MODULE, true)
  local after = lua_of(written, false)
  -- Not a comparison of nothing: both sides are the module's code, with the ternaries and the loop in it.
  assert(#original > 300 and has(original, "return a and a + 1 or b") and has(original, "sum = sum + v"), original)
  assert(after == original, "the Lua moved:\n" .. original .. "\n---\n" .. after)
  -- A difference the comparison would have to see.
  local planted = written:gsub("sum = sum %+ v", "sum = sum + v + 1")
  assert(lua_of(planted, false) ~= original, "a changed module has the same Lua")
end

local function test_the_lua_of_a_module_is_the_same_before_and_after_the_translation_of_each_row(tmp: string)
  -- One program for each rewrite whose Lua could move: a ternary of a chain, a respelled loop jump, a nested one.
  local programs = {
    "local function f(a: integer | nil): integer\n  return a and 1 or 2\nend\nreturn f\n",
    "local function f(n: integer): string\n  return n < 0 and \"a\" or n == 0 and \"b\" or \"c\"\nend\nreturn f\n",
    table.concat({
      "local function f(xs: {{integer}}): integer",
      "  local n = 0",
      "  for _, row in ipairs(xs) do",
      "    for _, v in ipairs(row) do",
      "      if v < 0 then goto continue end",
      "      n = n + v",
      "      ::continue::",
      "    end",
      "  end",
      "  return n",
      "end",
      "return f",
      "",
    }, "\n"),
    "local function f(): integer\n  local t = {1, 2; 3}\n  return #t\nend\nreturn f\n",
  }
  local compared = 0
  for i, program in ipairs(programs) do
    local root = tmp .. "/p" .. tostring(i)
    put(root, "m.tl", program)
    local report = assert(TreeWriter.write(root, { "m.tl" }, root .. "/out", options(true)))
    assert(#report.clean == 1 and #report.unstable == 0, table.concat(TreeWriter.summary(report), "\n"))
    local original = lua_of(program, true)
    assert(#original > 20, original)
    assert(lua_of(assert(Fs.read(root .. "/out/m.tl")), false) == original, "program " .. tostring(i) .. " has other Lua")
    compared = compared + 1
  end
  assert(compared == #programs)
end

local function test_the_forks_checker_and_the_fork_only_fixtures_are_kept_unread_and_unwritten(tmp: string)
  local root = tmp .. "/tree"
  put(root, "checker/tl.tl", "local pair: {integer, string} = {1, \"a\"}\nreturn pair\n")
  put(root, "testdata/rehearsal/fork_only/f.tl", "local x: string | nil = nil\nreturn x\n")
  put(root, "testdata/rehearsal/other.tl", "local x: string | nil = nil\nreturn x\n")
  put(root, "checkers/m.tl", "local x: string | nil = nil\nreturn x\n")
  local paths = { "checker/tl.tl", "checkers/m.tl", "testdata/rehearsal/fork_only/f.tl", "testdata/rehearsal/other.tl" }
  local report = assert(TreeWriter.write(root, paths, tmp .. "/out", options(true)))
  assert(report.files == 2 and #report.clean == 2 and #report.refused == 0 and #report.allowed == 0,
    table.concat(TreeWriter.summary(report), "\n"))
  assert(report.kept == 2, table.concat(TreeWriter.summary(report), "\n"))
  assert(Fs.exists(tmp .. "/out/checker/tl.tl") ~= true and Fs.exists(tmp .. "/out/testdata/rehearsal/fork_only/f.tl") ~= true)
  assert(Fs.exists(tmp .. "/out/checkers/m.tl") == true and Fs.exists(tmp .. "/out/testdata/rehearsal/other.tl") == true)
end

--- The file `path` of the tree as an entry of the program [`TreeProgram.index`] makes.
local function entry(path: string): {string}
  return { path, (assert(Fs.read(path))) }
end

local function test_the_text_written_is_the_text_the_pipeline_reads_for_the_file(tmp: string)
  -- The two modules that hold the `where` clauses, a file that tests their records, the tour, files with edits of the new
  -- declarations, and a plain module: each takes another step.
  local entries = { entry("lang/ast.tl"), entry("lang/types.tl"), entry("lang/check.tl"), entry("cosmic/removed_example.tl"),
    entry("cosmic/json.tl"), entry("cosmic/web/init.tl"), entry("cosmic/fs.tl") }
  local paths = { "lang/ast.tl", "lang/types.tl", "lang/check.tl", "cosmic/removed_example.tl", "cosmic/json.tl",
    "cosmic/web/init.tl", "cosmic/fs.tl" }
  local report = assert(TreeWriter.write(".", paths, tmp .. "/out", { allowance = assert(TreeWriter.allowance(".")), again = true,
    translator = nil, raw = nil }))
  assert(report.files == #paths and #report.refused == 0 and #report.unstable == 0, table.concat(TreeWriter.summary(report), "\n"))
  local raw_report = assert(TreeWriter.write(".", paths, tmp .. "/raw", { allowance = assert(TreeWriter.allowance(".")),
    again = false, translator = nil, raw = true }))
  assert(raw_report.files == #paths)
  local index = TreeProgram.index(entries, true, {})
  assert(#index.sources == #paths, "a file of the sample is left out of the program")
  local stepped = 0
  for i, source in ipairs(index.sources) do
    local path = assert(paths[i])
    assert(source.filename == path, source.filename)
    local expected = Driver.parse(source).text
    local written = assert(Fs.read(tmp .. "/out/" .. path))
    assert(#written > 100, path)
    -- Read with the translation off, the written file is the text the pipeline reads: the same tokens to the checker.
    local alone = Driver.index({ { path, written } }, false, function(_file: string): boolean
      return false
    end)
    assert(Driver.parse(assert(alone.sources[1])).text == expected, path .. " is not what the pipeline reads")
    assert(written == expected, path .. " is not what the pipeline reads")
    -- Not a comparison of the translation with itself: the steps moved the files that need them.
    if assert(Fs.read(tmp .. "/raw/" .. path)) ~= written then
      stepped = stepped + 1
    end
  end
  assert(stepped >= 5, "the steps changed " .. tostring(stepped) .. " of " .. tostring(#paths) .. " files")
end
