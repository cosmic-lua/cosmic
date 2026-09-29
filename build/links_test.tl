local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local docs = require("build.docs")
local fixture = require("build.docs_fixture")
local links = require("build.links")
local teal = require("build.teal")

--- The docs fixture builds its database with the tree's own code.
Test.needs{ reads = { "core" } }

local built = assert(teal.load())

--- Lines as one text.
local function lines(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The links `text` holds, each as `line form target`, or `line form
--- [label] -` for a reference nothing defines.
local function parsed(text: string): {string}
  local out: {string} = {}
  for _, link in ipairs(links.parse(text)) do
    local target = link.target
    out[#out + 1] = link.line .. " " .. link.form .. " " ..
      (target ~= nil and target or "[" .. tostring(link.label) .. "] -")
  end
  return out
end

local function same(got: {string}, want: {string})
  local a, b = table.concat(got, "\n"), table.concat(want, "\n")
  assert(a == b, "got:\n" .. a .. "\nwant:\n" .. b)
end

local function test_each_form_is_a_link()
  same(parsed(lines(
    "A [`Fs.read`] shortcut,",
    "an [inline](doc/a.md) one, an [`Fs.write`](cosmic/fs.tl#L3) one,",
    "a [reference][ref], a [collapsed][] one and a bare [defined].",
    "",
    "[ref]: build/links.tl",
    "[Collapsed]: <doc/b.md>",
    "[defined]: https://example.com")), {
    "1 shortcut Fs.read",
    "2 inline doc/a.md",
    "2 inline cosmic/fs.tl#L3",
    "3 reference build/links.tl",
    "3 reference doc/b.md",
    "3 reference https://example.com",
    "5 definition build/links.tl",
    "6 definition doc/b.md",
    "7 definition https://example.com",
  })
end

local function test_a_reference_with_no_definition_has_no_target()
  same(parsed("see [the guide][guide]\n"), { "1 reference [guide] -" })
end

local function test_brackets_that_are_no_link_are_prose()
  same(parsed(lines(
    "Takes [options] and a zone like [America/New_York].",
    "An index t[k] or rows[1][2], a call f[x](y), a pattern %f[%w] or %[.",
    "A long bracket --[[ and [=[ open no link.",
    "An unclosed [bracket, and ]one closed alone.")), {})
end

local function test_code_spans_and_fences_hide_links()
  same(parsed(lines(
    "A span `[`x`]` and ``[a](b)`` is code, but [`y`] is a link.",
    "```teal",
    "local t = [`z`]",
    "-- [c](d)",
    "```",
    "~~~",
    "[e](f)",
    "~~~",
    "[g](h)")), { "1 shortcut y", "9 inline h" })
end

local function test_a_link_may_wrap_but_not_cross_a_paragraph()
  same(parsed(lines("the [long", "text](a.md) and [cut", "", "off](b.md)")), { "1 inline a.md" })
end

local function test_an_escaped_bracket_is_text()
  same(parsed("not \\[`x`] a link\n"), {})
end

--- A world for `links.check`: the files at their absolute paths under
--- `/p`, every directory above them, and what each query names.
local function world(files: {string: string}, symbols?: {string: {string}},
                     members?: {string: {string}}): links.Context
  local dirs: {string: boolean} = { ["/p"] = true }
  for path in pairs(files) do
    local dir = Fs.dirname(path)
    while dir ~= "/" and dir ~= "" do
      dirs[dir] = true
      dir = Fs.dirname(dir)
    end
  end
  return {
    root = "/p",
    kind = function(path: string): string | nil
      if files[path] ~= nil then return "file" end
      if dirs[path] then return "dir" end
      return nil
    end,
    read = function(path: string): string | nil return files[path] end,
    symbols = function(query: string): {string} | nil, string
      local found = (symbols or {})[query] or {}
      local copy: {string} = {}
      for index, name in ipairs(found) do copy[index] = name end
      return copy, ""
    end,
    member = function(module: string, member: string): {string} | nil, string
      local found = (members or {})[module .. "." .. member] or {}
      local copy: {string} = {}
      for index, name in ipairs(found) do copy[index] = name end
      return copy, ""
    end,
  }
end

--- What `links.check` finds in `source`, a file of `kind` at `path`.
local function checked(context: links.Context, path: string, kind: string, source: string): {string}
  return links.check(links.resolver(context), path, path, kind, source, built)
end

local function test_a_name_the_file_declares_resolves_and_shadows_a_symbol()
  local source = lines(
    "local record Box",
    "  width: integer",
    "end",
    "",
    "--- Grows [`Box.width`] by [`step`]; see [`helper`] and [`Box.grow`].",
    "function Box.grow(step: integer)",
    "end",
    "",
    "local function helper()",
    "end",
    "",
    "return Box")
  local context = world({}, { helper = { "a.helper", "b.helper" } })
  same(checked(context, "/p/box.tl", "teal", source), {})
end

local function test_a_required_alias_names_its_modules_members()
  local source = lines(
    "local Fs = require(\"cosmic.fs\")",
    "-- [`Fs.read`] reads, [`Fs.nope`] does not.",
    "return Fs.read")
  local context = world({}, {}, { ["cosmic.fs.read"] = { "cosmic.fs.read" } })
  same(checked(context, "/p/a.tl", "teal", source), {
    "/p/a.tl:2: link: Fs.nope does not resolve (cosmic.fs has no nope)",
  })
end

local function test_a_symbol_resolves_once_and_fails_twice_or_never()
  local context = world({}, { one = { "m.one" }, two = { "m.two", "n.two" } })
  same(checked(context, "/p/a.md", "markdown", "[`one`], [`two`] and [`none`]\n"), {
    "/p/a.md:1: link: two does not resolve (it names 2: m.two, n.two; link the one meant in full)",
    "/p/a.md:1: link: none does not resolve (no declaration, symbol or file by that name)",
  })
end

local function test_a_file_resolves_from_its_directory_then_the_root()
  local context = world({
    ["/p/doc/a.md"] = "",
    ["/p/doc/b.md"] = "",
    ["/p/build/x.tl"] = "",
    ["/p/o/bin/y"] = "",
    ["/q/z.md"] = "",
  })
  same(checked(context, "/p/doc/a.md", "markdown", lines(
    "[b](b.md) [x](build/x.tl) [up](../build/x.tl) [dir](../build/) [top](/doc/b.md)",
    "[out](../o/bin/y) [gone](c.md) [far](../../q/z.md)")), {
    "/p/doc/a.md:2: link: ../o/bin/y does not resolve (it is under o/, the build's output)",
    "/p/doc/a.md:2: link: c.md does not resolve (no declaration, symbol or file by that name)",
    "/p/doc/a.md:2: link: ../../q/z.md does not resolve (it is outside the project)",
  })
end

local function test_an_anchor_names_a_heading()
  local context = world({
    ["/p/a.md"] = lines("# Top", "", "## Links: the `x` form", "## Links: the `x` form"),
    ["/p/b.tl"] = "",
  })
  same(checked(context, "/p/c.md", "markdown", lines(
    "# Here",
    "[a](a.md#top) [b](a.md#links-the-x-form) [c](a.md#links-the-x-form-1) [d](#here)",
    "[e](a.md#missing) [f](#nowhere) [g](b.tl#L3) [h](b.tl#top) [i](/p#x)")), {
    "/p/c.md:3: link: a.md#missing does not resolve (no heading of a.md has the anchor #missing)",
    "/p/c.md:3: link: #nowhere does not resolve (no heading of c.md has the anchor #nowhere)",
    "/p/c.md:3: link: b.tl#top does not resolve (only a Markdown file's headings take an anchor)",
    "/p/c.md:3: link: /p#x does not resolve (no declaration, symbol or file by that name)",
  })
end

local function test_a_symbol_and_a_file_of_one_name_are_ambiguous()
  local context = world({ ["/p/build.zig"] = "" }, { ["build.zig"] = { "build.zig" } })
  same(checked(context, "/p/a.md", "markdown", "[`build.zig`]\n"), {
    "/p/a.md:1: link: build.zig does not resolve (it names 2: build.zig, the file build.zig; " ..
      "link the one meant in full)",
  })
end

local function test_a_definition_holds_in_its_own_comment_block()
  local source = lines(
    "-- See [the guide][guide].",
    "-- [guide]: doc/a.md",
    "",
    "-- And [again][guide].",
    "local x = 1",
    "return x")
  local context = world({ ["/p/doc/a.md"] = "" })
  same(checked(context, "/p/a.tl", "teal", source), {
    "/p/a.tl:4: link: [guide] does not resolve (no [guide]: line defines it in its comment block)",
  })
end

local function test_a_definitions_target_is_checked_where_it_is()
  same(checked(world({}), "/p/a.md", "markdown", "[x][y]\n\n[y]: nowhere.md\n"), {
    "/p/a.md:3: link: nowhere.md does not resolve (no declaration, symbol or file by that name)",
  })
end

local function test_a_url_is_not_checked()
  same(checked(world({}), "/p/a.md", "markdown",
    "[a](https://example.com/x) [b](http://x) [c](mailto:a@b)\n"), {})
end

local function test_a_long_comment_is_read_past_its_brackets()
  local source = lines("--[[ see [`nothing`]", "]]", "local x = 1", "return x")
  same(checked(world({}), "/p/a.tl", "teal", source), {
    "/p/a.tl:1: link: nothing does not resolve (no declaration, symbol or file by that name)",
  })
end

local function test_code_is_not_comment()
  local source = lines("local t = { [\"[`x`]\"] = 1 }", "return t")
  same(checked(world({}), "/p/a.tl", "teal", source), {})
end

--- A world whose symbols come from a database the docs fixture builds.
local function test_the_databases_answer_a_symbol_and_a_member_in_full(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/fs.tl"] = lines(
      "--- Files.",
      "local record Fs",
      "end",
      "",
      "--- The whole of a file.",
      "function Fs.read(path: string): string",
      "  return path",
      "end",
      "",
      "return Fs"),
    ["build/other.tl"] = lines(
      "local record other",
      "end",
      "",
      "--- Reads.",
      "function other.read(): string",
      "  return \"\"",
      "end",
      "",
      "return other"),
  })
  local context = links.context(dir, function(): docs.View | nil, string
    return docs.view({ db })
  end)
  same(checked(context, dir .. "/a.md", "markdown", lines(
    "[`Fs.read`] [`cosmic.fs.read`] [`cosmic.fs.Fs.read`] [`cosmic.fs`] [`read`]")), {
    dir .. "/a.md:1: link: read does not resolve " ..
      "(it names 2: build.other.read, cosmic.fs.read; link the one meant in full)",
  })
end
