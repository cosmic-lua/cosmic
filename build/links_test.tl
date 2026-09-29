local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local docs = require("build.docs")
local fixture = require("build.docs_fixture")
local link_resolve = require("build.link_resolve")
local link_text = require("build.link_text")
local links = require("build.links")
local teal = require("build.teal")

--- The docs fixture builds its database with the tree's own code.
Test.needs{ reads = { "core" } }

local built = assert(teal.load())

--- Lines as one text.
local function lines(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The links `text` holds, each as `line form target`.
local function parsed(text: string): {string}
  local out: {string} = {}
  for _, link in ipairs(link_text.parse(text)) do
    out[#out + 1] = link.line .. " " .. link.form .. " " .. link.target
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

--- CommonMark shows a reference whose label nothing defines as it is
--- written, so it is prose: an index, a pattern's sets.
local function test_a_reference_with_no_definition_is_prose()
  same(parsed(lines(
    "see [the guide][guide], [i][j], [row][col], [a-z][0-9] and [x][]",
    "a name matches %f[%w_] and [%a_][%w_]*")), {})
end

--- A definition's label may be a code span, and a shortcut that is the
--- same code span is a reference to it, not a name.
local function test_a_code_span_label_reads_its_definition()
  same(parsed(lines("See [`widget`].", "", "[`widget`]: https://example.com/widget")), {
    "1 reference https://example.com/widget",
    "3 definition https://example.com/widget",
  })
end

local function test_a_footnote_is_no_link()
  same(parsed(lines("A claim.[^1] And [^note].", "", "[^1]: A note.", "[^note]: Another.")), {})
end

--- An inline link's destination is a URL or a path, with at most a
--- title after it; what cannot be one is prose.
local function test_an_inline_link_needs_a_destination()
  same(parsed(lines(
    "captures [%a](%d+), [a](b c), [p]((x)), [q](a*b), [r](%zz)",
    "[titled](a.md \"The title\") [angled](<my file.md>) [escaped](my%20file.md)")), {
    "2 inline a.md",
    "2 inline my file.md",
    "2 inline my%20file.md",
  })
end

--- A code span ends with its paragraph: a stray backtick hides no link
--- past a blank line.
local function test_a_code_span_does_not_cross_a_paragraph()
  same(parsed(lines("a stray ` here", "", "then [`y`] and `z`")), { "3 shortcut y" })
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

--- Symbols spelled in full, each split at its first `.`: the module a
--- message names is the whole spelling either way.
local function symbols_of(spelled: {string}): {link_resolve.Symbol}
  local out: {link_resolve.Symbol} = {}
  for _, name in ipairs(spelled) do
    local module, symbol = name:match("^([^.]+)%.(.+)$")
    out[#out + 1] = { module = module or name, symbol = symbol or "" }
  end
  return out
end

--- A world for `links.check`: the files at their absolute paths under
--- `/p`, every directory above them, and what each query names.
local function world(files: {string: string}, symbols?: {string: {string}},
                     members?: {string: {string}}, links_to?: {string: string},
                     unbuilt?: string): link_resolve.Context
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
    real = function(path: string): string | nil
      for from, to in pairs(links_to or {}) do
        if path == from or path:sub(1, #from + 1) == from .. "/" then
          return to .. path:sub(#from + 1)
        end
      end
      return path
    end,
    unbuilt = function(): string | nil return unbuilt end,
    symbols = function(query: string): {link_resolve.Symbol} | nil, string
      return symbols_of((symbols or {})[query] or {}), ""
    end,
    member = function(module: string, member: string): {link_resolve.Symbol} | nil, string
      return symbols_of((members or {})[module .. "." .. member] or {}), ""
    end,
  }
end

--- What `links.check` finds in `source`, a file of `kind` at `path`.
local function checked(context: link_resolve.Context, path: string, kind: string, source: string): {string}
  return links.check(link_resolve.resolver(context), path, path, kind, source, built)
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
    "/p/doc/a.md:2: link: ../../q/z.md does not resolve (it lies outside the project's root)",
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

--- A shortcut that names a symbol and a file fails, saying how to name
--- either; an inline link names the file, as a Markdown path does.
local function test_a_shortcut_to_a_symbol_and_a_file_is_ambiguous()
  local context = world({ ["/p/build.zig"] = "" }, { ["build.zig"] = { "zig.build.zig" } })
  same(checked(context, "/p/a.md", "markdown", "[`build.zig`] [build script](build.zig)\n"), {
    "/p/a.md:1: link: build.zig does not resolve (it names 2: the file build.zig, " ..
      "zig.build.zig; write ./build.zig for the file, or the symbol in full)",
  })
end

--- An inline link to no file is a name next, as a shortcut is.
local function test_an_inline_link_to_no_file_is_a_name()
  local context = world({}, { thing = { "m.thing" } })
  same(checked(context, "/p/a.md", "markdown", "[the thing](thing) [none](none)\n"), {
    "/p/a.md:1: link: none does not resolve (no declaration, symbol or file by that name)",
  })
end

--- Where the project has no database of its own, a shortcut that names
--- no symbol it has is not failed, but counted; a path is still checked.
local function test_symbols_go_unchecked_in_a_project_not_built()
  local context = world({}, {}, {}, {}, "not built")
  local resolver = link_resolve.resolver(context)
  local source = lines("local x = 1", "-- [`x`], [`thing`] and [gone](gone.md)", "return x")
  same(links.check(resolver, "/p/a.tl", "/p/a.tl", "teal", source, built), {
    "/p/a.tl:2: link: gone.md does not resolve (no declaration, symbol or file by that name)",
  })
  assert(resolver.unchecked == 1, tostring(resolver.unchecked))
end

--- The Lua standard library this program carries resolves by its own
--- names; what cosmic leaves out (`io`) does not.
local function test_the_standard_library_resolves()
  same(checked(world({}), "/p/a.md", "markdown",
    "[`string.format`] [`table.concat`] [`print`] [`io.open`]\n"), {
    "/p/a.md:1: link: io.open does not resolve (no declaration, symbol or file by that name)",
  })
end

local function test_a_path_is_unescaped_and_its_query_dropped()
  local context = world({ ["/p/my file.md"] = "", ["/p/README.md"] = "" })
  same(checked(context, "/p/a.md", "markdown", "[a](my%20file.md) [b](README.md?plain=1)\n"), {})
end

--- Only the root's `o/` is the build's output; a link that leads out of
--- the root is refused, and so is a path that climbs out of it.
local function test_only_the_roots_output_and_the_outside_are_refused()
  local context = world({
    ["/p/sub/o/x.md"] = "",
    ["/p/o/y.md"] = "",
    ["/p/out/z.md"] = "",
    ["/elsewhere/z.md"] = "",
  }, {}, {}, { ["/p/out"] = "/elsewhere" })
  same(checked(context, "/p/a.md", "markdown",
    "[x](sub/o/x.md) [y](o/y.md) [z](out/z.md) [up](../)\n"), {
    "/p/a.md:1: link: o/y.md does not resolve (it is under o/, the build's output)",
    "/p/a.md:1: link: out/z.md does not resolve (a symbolic link leads it out of the project)",
    "/p/a.md:1: link: ../ does not resolve (it lies outside the project's root)",
  })
end

--- Underlined headings, `<a id>` and `<a name>` give anchors too, and
--- a pictograph drops out of one as GitHub drops it.
local function test_every_kind_of_heading_gives_an_anchor()
  local context = world({
    ["/p/a.md"] = lines("Setext", "======", "", "Second", "---", "",
      "## Emoji \u{1F680} heading", "<a id=\"custom\"></a> <a name='named'></a>"),
  })
  same(checked(context, "/p/c.md", "markdown",
    "[a](a.md#setext) [b](a.md#second) [c](a.md#emoji--heading) [d](a.md#custom) [e](a.md#named)\n"), {})
end

--- A definition holds in its own comment block: in another, its label
--- is prose.
local function test_a_definition_holds_in_its_own_comment_block()
  local source = lines(
    "-- See [the guide][guide].",
    "-- [guide]: doc/missing.md",
    "",
    "-- And [again][guide].",
    "local x = 1",
    "return x")
  same(checked(world({}), "/p/a.tl", "teal", source), {
    "/p/a.tl:2: link: doc/missing.md does not resolve (no declaration, symbol or file by that name)",
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

--- A long comment holds code set aside, not prose: none of it is read.
local function test_a_long_comment_is_not_read()
  local source = lines("--[[ see [`nothing`]", "]]", "--[==[ [`nor`] ]==]", "local x = 1", "return x")
  same(checked(world({}), "/p/a.tl", "teal", source), {})
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
    ["cosmic/internal/raw.tl"] = lines(
      "--- Raw things.",
      "local record raw",
      "  --- One box.",
      "  record Box",
      "    --- Grows the box.",
      "    grow: function(Box, n: integer): boolean",
      "  end",
      "end",
      "",
      "return raw"),
    ["cosmic/thing.tl"] = lines(
      "--- Things.",
      "local type raw = require(\"cosmic.internal.raw\")",
      "",
      "local record Thing",
      "  --- A box.",
      "  type Box = raw.Box",
      "end",
      "",
      "return Thing"),
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
  end, function(): string | nil return nil end)
  same(checked(context, dir .. "/a.md", "markdown", lines(
    "[`Fs.read`] [`cosmic.fs.read`] [`cosmic.fs.Fs.read`] [`cosmic.fs`] [`read`]",
    "[`Thing.Box.grow`] [`cosmic.thing.Box.grow`] [`Thing.Box.shrink`]")), {
    dir .. "/a.md:1: link: read does not resolve " ..
      "(it names 2: build.other.read, cosmic.fs.read; link the one meant in full)",
    dir .. "/a.md:2: link: Thing.Box.shrink does not resolve " ..
      "(no declaration, symbol or file by that name)",
  })
  same(checked(context, dir .. "/b.tl", "teal", lines(
    "local Thing = require(\"cosmic.thing\")",
    "-- [`Thing.Box.grow`] grows; [`Thing.Box.shrink`] does not.",
    "return Thing")), {
    dir .. "/b.tl:2: link: Thing.Box.shrink does not resolve (cosmic.thing has no Box.shrink)",
  })
end
