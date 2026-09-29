--- The properties `cosmic fix` has to hold whatever it is given.
---
--- Three of them, each for a reason. Idempotency, because a fix that
--- keeps finding something to fix never converges, and one run of the
--- verb has to be enough. Determinism, because the renderer walks
--- tables whose key order Lua does not fix, so a traversal that leaked
--- into the output would give two different files from one input. And
--- a semantic round-trip, because neither of the first two can tell a
--- consistently wrong renderer from a right one.
---
--- Self-hosting is not checked here: that every Teal source in the tree
--- renders, is canonical, and stays at the fixed point on a second
--- pass. `fix.source` runs the second pass itself (`build.fix.init`)
--- and refuses a file that is not a fixed point, so `cosmic fix
--- --check .`, which CI runs over the whole tree as its format-check
--- step, holds the tree to it. A copy of that walk here would cost
--- about half the suite's wall time.

local Fs = require("cosmic.fs")
local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local fix = require("build.fix")
local type links = require("build.links")
local render_mod = require("build.fix.render")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- A fixture broad enough to reach most of the grammar at once, in one
--- string, so the properties below are checked over something with
--- real shape rather than over a one-liner.
local fixture = table.concat({
  "--- A doc comment on the module.",
  "local Mod = {}",
  "",
  "-- why this is here",
  "local counts <const>: {string:integer} = {",
  "  first = 1,",
  "  second = 2,",
  "}",
  "",
  "--- What this does.",
  "--- @param name string",
  "local function look_up(name: string, fallback?: integer): integer | nil, string",
  "  if counts[name] == nil then",
  "    return fallback, \"no such name: \" .. name -- give back what we can",
  "  end",
  "  for key, value in pairs(counts) do",
  "    if key == name then return value end",
  "  end",
  "  local total = 0",
  "  for i = 1, #name, 2 do",
  "    total = total + i",
  "  end",
  "  while total > 100 do",
  "    total = total // 2",
  "  end",
  "  return total, \"\"",
  "end",
  "",
  "function Mod.run(argv: {integer:string}): integer",
  "  local first = argv[1] as string",
  "  local found, trouble = look_up(first,",
  "    3)",
  "  return found ~= nil and found or #trouble",
  "end",
  "",
  "return Mod",
  "",
}, "\n")

--- Run the whole pipeline, asserting it succeeded.
local function fixed(source: string, name: string): string
  local result, trouble = fix.source(built, source, name)
  assert(result ~= nil, name .. ": fix refused it: " .. tostring(trouble))
  return result.source
end

--- Fixing what was already fixed changes nothing further.
local function test_fixing_twice_is_the_same_as_fixing_once()
  local once = fixed(fixture, "fixture.tl")
  local twice = fixed(once, "fixture.tl")
  assert(twice == once, "second pass differs:\n" .. twice .. "\nfirst:\n" .. once)
end

--- A type alias of a function whose last return is variadic keeps its
--- `...`: the alias is written from its tokens, and the list of returns
--- ends at the `...`, not before it.
local function test_a_variadic_return_in_a_type_alias_is_kept()
  local source = table.concat({
    "local type Call = function(...: any): any...",
    "local type Pair = function(): string, integer...",
    "local f: Call = nil",
    "local g: Pair = nil",
    "return { f = f, g = g }",
    "",
  }, "\n")
  local result = fixed(source, "variadic.tl")
  assert(result == source, "changed:\n" .. result)
end

--- Rendering an already-canonical source leaves it byte for byte.
local function test_a_canonical_source_is_left_alone()
  local once = fixed(fixture, "fixture.tl")
  local result, trouble = fix.source(built, once, "fixture.tl")
  assert(result ~= nil, "fix refused it: " .. tostring(trouble))
  assert(not result.changed, "a second pass reported a change")
end

--- The same input gives the same bytes, run after run: nothing in the
--- renderer depends on the order Lua visits a table's keys.
local function test_the_same_input_renders_the_same_bytes_every_time()
  local first = fixed(fixture, "fixture.tl")
  for round = 2, 8 do
    local again = fixed(fixture, "fixture.tl")
    assert(again == first, "round " .. round .. " differs from the first")
  end
end

--- What was rendered parses to the same tree, and carries the same
--- comments, as what it was rendered from. The verb checks this too;
--- it is checked here directly because golden strings alone cannot
--- establish it.
local function test_rendering_keeps_the_tree_and_the_comments()
  local before, before_trouble = ast.parse(built, fixture, "fixture.tl")
  assert(before ~= nil, "parse failed: " .. tostring(before_trouble))
  local after, after_trouble = ast.parse(built, fixed(fixture, "fixture.tl"),
                                         "fixture.tl")
  assert(after ~= nil, "reparse failed: " .. tostring(after_trouble))
  local same, difference = equiv.same_tree(before.node, after.node)
  assert(same, "the tree changed: " .. difference)
  local kept, lost = equiv.same_comments(before.tokens, after.tokens)
  assert(kept, "the comments changed: " .. lost)
  assert(#equiv.comments(before.tokens) > 0, "the fixture carries no comments")
end

--- Mangled spacing and indentation come back canonical, and still mean
--- the same thing. The properties above would all hold for a renderer
--- that changed nothing, and this shows that it does change things.
local function test_mangled_spacing_and_indentation_are_repaired()
  local mangled = "local   x <const>   = 5\nlocal t = {1,2}\nif  x  then\n" ..
                  "        print( x )\nend\n"
  local want = "local x <const> = 5\nlocal t = { 1, 2 }\nif x then\n" ..
               "  print(x)\nend\n"
  local got = fixed(mangled, "mangled.tl")
  assert(got == want, "got:\n" .. got .. "\nwant:\n" .. want)
end

--- A named path the verb will not take is a refusal among the files the
--- run covers, not an end to the run: it comes back in `refused` with
--- the others still listed, so the verb can report it and still end in
--- its verdict line.
---
--- What a path is decided before what it is named. A path with nothing
--- at it is missing, whatever its suffix: answering `nope` with a
--- remark about Teal would say the wrong thing about a file the caller
--- may only have mistyped.
local function test_a_path_that_is_not_there_is_missing_before_it_is_judged(tmp: string)
  assert(Fs.write(tmp .. "/real.tl", "local x = 1\nprint(x)\n"))
  assert(Fs.write(tmp .. "/notes.txt", "not Teal at all\n"))
  local picked, trouble = fix.chosen(tmp, {
    tmp .. "/real.tl",
    tmp .. "/nope",
    tmp .. "/nosuchdir/",
    tmp .. "/notes.txt",
  })
  assert(picked ~= nil, "naming a missing path should not end the run: " ..
    tostring(trouble))
  assert(#picked.files == 1 and picked.files[1] == tmp .. "/real.tl",
    "the real source should still be listed")
  assert(#picked.refused == 3, "expected three refusals, got " .. #picked.refused)
  for i, what in ipairs({ "nope", "nosuchdir/" }) do
    assert(picked.refused[i]:find("No such file", 1, true) ~= nil,
      what .. " should be reported as missing, not judged on its suffix: " ..
      picked.refused[i])
  end
  assert(picked.refused[3]:find("not a Teal or C source, YAML, Markdown or Zig", 1, true) ~= nil,
    "a file that is there but is not Teal should be said so: " ..
    picked.refused[3])
end

--- C is checked only where the rules it is checked against belong:
--- cosmic's own tree, whose headers and compiler they assume.
local function test_c_is_taken_only_in_cosmics_own_tree(tmp: string)
  assert(Fs.write(tmp .. "/a.c", "int a;\n"))
  local picked = assert(fix.chosen(tmp, { tmp .. "/a.c", tmp }))
  assert(#picked.c_files == 0, "a tree of another's has no C checked")
  assert(picked.refused[1]:find("only in cosmic's own tree", 1, true) ~= nil,
    picked.refused[1])

  assert(Fs.mkdirs(tmp .. "/own/core"))
  assert(Fs.mkdirs(tmp .. "/own/build"))
  assert(Fs.mkdirs(tmp .. "/own/vendor/lua"))
  assert(Fs.write(tmp .. "/own/build/importer.tl", "return {}\n"))
  assert(Fs.write(tmp .. "/own/core/a.c", "int a;\n"))
  assert(Fs.write(tmp .. "/own/core/a.h", "int a;\n"))
  assert(Fs.write(tmp .. "/own/vendor/lua/b.c", "int b;\n"))
  local all = assert(fix.chosen(tmp .. "/own", {}))
  assert(#all.c_files == 2 and all.c_files[1] == "core/a.c" and all.c_files[2] == "core/a.h",
    "the whole tree covers its own C and not the vendored: " .. table.concat(all.c_files, ", "))
  local named = assert(fix.chosen(tmp .. "/own", { tmp .. "/own/core/a.h" }))
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
  assert(assert(fix.chosen(own, {})).whole, "no path named covers the whole tree")
  assert(assert(fix.chosen(own, { own })).whole, "the root named covers the whole tree")
  assert(not assert(fix.chosen(own, { own .. "/build" })).whole, "build/ is a part of it")
  local other = tmp .. "/other"
  assert(Fs.mkdirs(other))
  assert(Fs.write(other .. "/thing.tl", "return {}\n"))
  assert(not assert(fix.chosen(other, {})).whole, "a tree of another's is never whole")
  assert(not assert(fix.chosen(other, { other })).whole, "a tree of another's is never whole")
end

--- Changed output still has to parse and preserve both syntax and comments.
local function test_changed_rendering_is_checked_before_it_is_accepted()
  local original = render_mod.rendered
  local ok, trouble = pcall(function(): (any...)
    local source = "-- keep this\nlocal x = 1\n"
    local outputs = {
      "-- keep this\nlocal x = 2\n",
      "local x = 1\n",
      "local local\n",
    }
    local errors = {
      "rendering changed the program:",
      "rendering changed the comments:",
      "what was rendered does not parse:",
    }
    for i, output in ipairs(outputs) do
      render_mod.rendered = function(): string | nil, string
        return output
      end
      local result, why = fix.source(built, source, "probe.tl")
      assert(result == nil, "corrupt rendering was accepted")
      assert(why:find(errors[i], 1, true) ~= nil, why)
    end
  end)
  render_mod.rendered = original
  assert(ok, tostring(trouble))
end

--- A renderer whose output is not a fixed point is refused, even when
--- its first pass looks fine on its own: `fix.source` renders what it
--- produced a second time and requires the same bytes back.
local function test_a_renderer_that_is_not_a_fixed_point_is_refused()
  local original = render_mod.rendered
  local ok, trouble = pcall(function(): (any...)
    local source = "local x = 1\n"
    local calls = 0
    render_mod.rendered = function(_: ast.Parsed, src: string): string | nil, string
      calls = calls + 1
      if calls == 1 then
        return src
      end
      return src .. "-- a second pass added this\n"
    end
    local result, why = fix.source(built, source, "probe.tl")
    assert(result == nil, "a renderer that is not a fixed point was accepted")
    assert(why:find("not a fixed point", 1, true) ~= nil, why)
  end)
  render_mod.rendered = original
  assert(ok, tostring(trouble))
end

--- A YAML file named is laid out by `build.flow`, in any tree; one
--- under `.github/` is found only in cosmic's own tree, and only when it
--- is in flow style.
local function test_yaml_in_flow_style_is_taken(tmp: string)
  assert(Fs.mkdirs(tmp .. "/.github/workflows"))
  assert(Fs.write(tmp .. "/.github/workflows/a.yml", "{a: 1}\n"))
  assert(Fs.write(tmp .. "/.github/workflows/b.yml", "a: 1\n"))
  local picked = assert(fix.chosen(tmp, { tmp .. "/.github/workflows/b.yml", tmp }))
  assert(#picked.flow_files == 1 and picked.flow_files[1] == tmp .. "/.github/workflows/b.yml",
    table.concat(picked.flow_files, " "))

  assert(Fs.mkdirs(tmp .. "/own/core"))
  assert(Fs.mkdirs(tmp .. "/own/build"))
  assert(Fs.mkdirs(tmp .. "/own/vendor/lua"))
  assert(Fs.mkdirs(tmp .. "/own/.github/actions/x"))
  assert(Fs.write(tmp .. "/own/build/importer.tl", "return {}\n"))
  assert(Fs.write(tmp .. "/own/.github/actions/x/action.yml", "# c\n{a: 1}\n"))
  assert(Fs.write(tmp .. "/own/.github/block.yml", "a: 1\n"))
  picked = assert(fix.chosen(tmp .. "/own", { tmp .. "/own" }))
  assert(#picked.flow_files == 1 and picked.flow_files[1] == tmp .. "/own/.github/actions/x/action.yml",
    table.concat(picked.flow_files, " "))
  -- `.github/` named, or a directory under it, covers what it holds.
  for _, dir in ipairs({ tmp .. "/own/.github", tmp .. "/own/.github/actions", tmp .. "/own/.github/actions/" }) do
    picked = assert(fix.chosen(tmp .. "/own", { dir }))
    assert(#picked.flow_files == 1 and picked.flow_files[1]:match("/%.github/actions/x/action%.yml$"),
      dir .. ": " .. table.concat(picked.flow_files, " "))
    assert(not picked.flow_files[1]:find("//", 1, true), picked.flow_files[1])
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
    picked = assert(fix.chosen(nested, named))
    local got = table.concat(picked.flow_files, " ")
    assert(#picked.flow_files == 1 and got:match("%.github/workflows/w%.yml$"), got)
  end
  for _, dir in ipairs({ nested .. "/vendor/lua", nested .. "/docs" }) do
    picked = assert(fix.chosen(nested, { dir }))
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
  assert(#failures == 1 and failures[1]:find("not in flow style", 1, true), failures[1])
  assert(Fs.read(tmp .. "/b.yml") == "a: 1\n")
  changed = {}
  fix.lay_out({ path }, true, changed, {})
  assert(#changed == 0, "a laid-out file is left alone")
end

--- Markdown and Zig are taken to have their links checked, named or
--- under a directory named, past the build's output; they are not Teal
--- to render.
local function test_markdown_and_zig_are_taken_to_be_checked(tmp: string)
  assert(Fs.mkdirs(tmp .. "/doc"))
  assert(Fs.mkdirs(tmp .. "/o"))
  assert(Fs.write(tmp .. "/build.zig", "const x = 1;\n"))
  assert(Fs.write(tmp .. "/doc/a.md", "# A\n"))
  assert(Fs.write(tmp .. "/o/b.md", "# B\n"))
  local all = assert(fix.chosen(tmp, {}))
  assert(table.concat(all.checked, " ") == "build.zig doc/a.md", table.concat(all.checked, " "))
  assert(#all.files == 0, "Markdown is no Teal source")
  local named = assert(fix.chosen(tmp, { tmp .. "/doc/a.md", tmp .. "/doc" }))
  assert(#named.refused == 0, table.concat(named.refused, "\n"))
  assert(#named.checked == 2 and named.checked[1] == tmp .. "/doc/a.md", table.concat(named.checked, " "))
end

--- A world on disk under `root`, where no symbol is known but `known`.
local function on_disk(root: string, known: {string: {string}}): links.Context
  return {
    root = root,
    kind = function(path: string): string | nil
      local st, _ = Fs.stat(path)
      if st == nil then return nil end
      return st.kind == "dir" and "dir" or "file"
    end,
    read = function(path: string): string | nil
      local text, _ = Fs.read(path)
      return text
    end,
    symbols = function(query: string): {string} | nil, string
      return known[query] or {}, ""
    end,
    member = function(_: string, _: string): {string} | nil, string
      return {}, ""
    end,
  }
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
    "// But [`no_step`].",
    "",
  }, "\n")))
  local context = on_disk(root, { ["Known.thing"] = { "known.Known.thing" } })
  local files = { root .. "/doc/guide.md", root .. "/a.tl", root .. "/b.c", root .. "/build.zig" }
  local found = table.concat(fix.links(context, built, files), "\n")
  local want = table.concat({
    root .. "/doc/guide.md:4: link: #nowhere does not resolve (no heading of guide.md has the anchor #nowhere)",
    root .. "/doc/guide.md:4: link: missing.md does not resolve (no declaration, symbol or file by that name)",
    root .. "/a.tl:5: link: nothing does not resolve (no declaration, symbol or file by that name)",
    root .. "/b.c:1: link: uncounted does not resolve (no declaration, symbol or file by that name)",
    root .. "/build.zig:3: link: no_step does not resolve (no declaration, symbol or file by that name)",
  }, "\n")
  assert(found == want, "got:\n" .. found .. "\nwant:\n" .. want)
end
