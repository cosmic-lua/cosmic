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

--- A line indented four columns past its container is code, unless it
--- goes on with a paragraph: after a blank line or a heading, a tab as
--- four; a list item's content is its container, so its indented
--- paragraph is text and only a line four past that is code.
local function test_an_indented_code_block_hides_links()
  same(parsed(lines(
    "Text.",
    "",
    "    [`a`] and [b](c.md)",
    "",
    "# Heading",
    "    [d](e.md)",
    "A paragraph",
    "    [f](g.md) goes on with it.",
    "",
    "- an item",
    "",
    "  [h](i.md) is the item's, as is",
    "  - a nested [j](k.md)",
    "",
    "        [l](m.md) is the nested item's code, and",
    "",
    "      [n](o.md) its paragraph.",
    "",
    "1.  counted",
    "",
    "    [p](q.md) is the item's,",
    "",
    "        [r](s.md) its code.",
    "",
    "Out of the list,",
    "",
    "\t[t](u.md) is code again.")), {
    "8 inline g.md", "12 inline i.md", "13 inline k.md", "17 inline o.md", "21 inline q.md",
  })
end

--- A fence closes only on a run of its own character; a run of
--- backticks with a backtick after it opens none.
local function test_a_fence_closes_on_its_own_run()
  same(parsed(lines("```", "`~~~", "[a](b.md)", "```", "``` [c](d.md) `x`")), { "5 inline d.md" })
end

--- An ordered item that is a sibling of an open one starts, whatever
--- it counts from: the paragraph before it is its sibling's, not one it
--- would go on with. So the line after the blank is its paragraph. In
--- an item's own paragraph, one not counting from 1 goes on with it,
--- and the line after the blank is that item's code.
local function test_a_sibling_item_starts_whatever_it_counts_from()
  same(parsed(lines("9. a", "10. b", "", "       [a](b.md)")), { "4 inline b.md" })
  same(parsed(lines("1. a", "2.    b", "", "       [c](d.md)")), { "4 inline d.md" })
  same(parsed(lines("- x", "  9. a", "  10. b", "", "         [e](f.md)")), {})
end

--- A tab after a list marker goes to the next stop from where the
--- marker ends, not from the start of the line.
local function test_a_tab_after_a_marker_counts_from_the_marker()
  same(parsed(lines("-\titem", "", "\t[a](b.md)")), { "3 inline b.md" })
  same(parsed(lines("1.\titem", "", "\t[c](d.md)")), { "3 inline d.md" })
end

--- An inline HTML comment ends with its paragraph, which a heading or
--- a list item ends as a blank line does.
local function test_an_inline_comment_ends_with_its_paragraph()
  same(parsed(lines("text <!-- note", "# Heading [a](b.md) -->")), { "2 inline b.md" })
  same(parsed(lines("text <!-- note", "- [c](d.md) -->")), { "2 inline d.md" })
  same(parsed(lines("text <!-- note", "goes on [e](f.md) -->")), {})
end

--- A code span ends with its paragraph, which a heading ends as a
--- blank line does; an underline out of a list item's paragraph makes
--- no heading of it, and the paragraph goes on.
local function test_a_code_span_ends_with_its_paragraph()
  same(parsed(lines("a `x", "# h [a](b.md) `")), { "2 inline b.md" })
  same(parsed(lines("a `x", "===", "[c](d.md) `")), { "3 inline d.md" })
  same(parsed(lines("9. a `x", "===", "[e](f.md) `")), {})
end

--- In a quote, a tab counts its stops from the line's start, a line
--- indented as code goes on with the quote's paragraph, and a fence's
--- `>` past the fence's quote is its code.
local function test_a_quote_is_read_past_its_marker()
  same(parsed(lines(">\t- a", "> \t- [a](b.md)")), { "2 inline b.md" })
  same(parsed(lines("> a", "\t> [c](d.md)")), { "2 inline d.md" })
  same(parsed(lines("```", "> ```", "[e](f.md)", "```")), {})
end

--- An HTML comment block no `-->` closes ends with its list item.
local function test_an_html_comment_ends_with_its_list_item()
  same(parsed(lines("- <!--", "", "  [a](b.md)", "", "[c](d.md)")), { "5 inline d.md" })
end

--- A comment's text is read past the space its lines start with.
local function test_a_comments_indented_code_hides_links()
  same(parsed(lines(" Text.", "", "     [a](b.md) is code;", "", "    [c](d.md) is not.")),
    { "5 inline d.md" })
end

--- An HTML comment hides a link, as a block or within a paragraph; a
--- code span or an escape that comes first holds `<!--` as text, and one
--- that no `-->` closes in its paragraph is text too.
local function test_an_html_comment_hides_links()
  same(parsed(lines(
    "<!-- [a](b.md)",
    "[c](d.md) -->",
    "[e](f.md) <!-- [g](h.md)",
    "[i](j.md) --> [k](l.md) <!----> [m](n.md)",
    "`<!--` [o](p.md) \\<!-- [q](r.md) `-->` -->",
    "",
    "text <!-- [s](t.md)",
    "",
    "[u](v.md) -->")), {
    "3 inline f.md", "4 inline l.md", "4 inline n.md", "5 inline p.md", "5 inline r.md",
    "7 inline t.md", "9 inline v.md",
  })
end

--- Symbols spelled in full, each split at its first `.`: the module a
--- message names is the whole spelling either way. A spelling may end
--- in `@` and the file that declares the symbol.
local function symbols_of(spelled: {string}): {link_resolve.Symbol}
  local out: {link_resolve.Symbol} = {}
  for _, written in ipairs(spelled) do
    local name, file = written:match("^(.-)@(.+)$")
    name = name or written
    local module, symbol = name:match("^([^.]+)%.(.+)$")
    out[#out + 1] = { module = module or name, symbol = symbol or "", file = file }
  end
  return out
end

--- A world for [`links.check`]: the files at their absolute paths under
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

--- What [`links.check`] finds in `source`, a file of `kind` at `path`.
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
  local context = world({}, { ["M.one"] = { "m.M.one" }, ["M.two"] = { "m.M.two", "n.M.two" },
    one = { "m.one" } })
  same(checked(context, "/p/a.md", "markdown", "[`M.one`], [`M.two`] and [`M.none`]\n"), {
    "/p/a.md:1: link: M.two does not resolve (it names 2: m.M.two, n.M.two; link the one meant in full)",
    "/p/a.md:1: link: M.none does not resolve (no declaration, symbol or file by that name)",
  })
  -- A name alone is its own file's, whatever symbol it spells.
  same(checked(context, "/p/a.md", "markdown", "[`one`]\n"), {
    "/p/a.md:1: link: one does not resolve (a name alone links only to a declaration of its own file; write another module's symbol in full (`module.member`))",
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
  local context = world({}, { ["M.thing"] = { "m.M.thing" } })
  same(checked(context, "/p/a.md", "markdown", "[the thing](M.thing) [none](M.none)\n"), {
    "/p/a.md:1: link: M.none does not resolve (no declaration, symbol or file by that name)",
  })
end

--- Where the project has no database of its own, a shortcut that names
--- no symbol it has is not failed, but counted; a path is still checked.
local function test_symbols_go_unchecked_in_a_project_not_built()
  local context = world({}, {}, {}, {}, "not built")
  local resolver = link_resolve.resolver(context)
  local source = lines("local x = 1", "-- [`x`], [`M.thing`] and [gone](gone.md)", "return x")
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

--- The root's `o/` is refused before anything is asked of it, so what
--- the build writes there never enters what a projection is signed by
--- ([`build.link_index`]), whether or not the path is there.
local function test_the_roots_output_is_never_looked_at()
  local context = world({ ["/p/o/y.md"] = "" })
  local kind = context.kind
  local asked: {string} = {}
  context.kind = function(path: string): string | nil
    asked[#asked + 1] = path
    return kind(path)
  end
  same(checked(context, "/p/a.md", "markdown", "[y](o/y.md) [z](o/z.md)\n"), {
    "/p/a.md:1: link: o/y.md does not resolve (it is under o/, the build's output)",
    "/p/a.md:1: link: o/z.md does not resolve (it is under o/, the build's output)",
  })
  for _, path in ipairs(asked) do
    assert(path:sub(1, 5) ~= "/p/o/", "asked after " .. path)
  end
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

--- A Markdown file's broken link in an indented code block or an HTML
--- comment is not checked; one in a list item's indented paragraph is.
local function test_a_link_in_code_or_a_comment_goes_unchecked()
  local source = lines(
    "Text.",
    "",
    "    [broken](nowhere.md)",
    "",
    "<!-- [broken](nowhere.md) -->",
    "",
    "- an item",
    "",
    "    [broken](still_nowhere.md)")
  same(checked(world({ ["/p/a.md"] = source }), "/p/a.md", "markdown", source), {
    "/p/a.md:9: link: still_nowhere.md does not resolve (no declaration, symbol or file by that name)",
  })
end

--- A C comment's lines with no `*` are read against its first line's
--- text, not the file's margin: its second paragraph is no code.
local function test_a_c_comments_starless_lines_are_read_against_its_first()
  local source = lines("int x;", "    /* First paragraph.", "", "       Second [x](broken.md). */")
  same(checked(world({ ["/p/a.c"] = source }), "/p/a.c", "c", source), {
    "/p/a.c:4: link: broken.md does not resolve (no declaration, symbol or file by that name)",
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
    dir .. "/a.md:1: link: read does not resolve (a name alone links only to a declaration of its own file; write another module's symbol in full (`module.member`))",
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

--- A module whose value is typed by a record of another name hands out
--- that record's fields as its own members: `Cli.order` through the
--- required alias, and [`cosmic.cli.order`] in full.
local function test_a_module_typed_by_another_record_answers_its_fields(dir: string)
  local db = fixture.database(dir, {
    ["cosmic/cli.tl"] = lines(
      "--- Verbs.",
      "local record Module",
      "  --- The order.",
      "  order: {string}",
      "end",
      "",
      "local module: Module = { order = {} }",
      "",
      "return module"),
  })
  local context = links.context(dir, function(): docs.View | nil, string
    return docs.view({ db })
  end, function(): string | nil return nil end)
  same(checked(context, dir .. "/b.tl", "teal", lines(
    "local Cli = require(\"cosmic.cli\")",
    "-- [`Cli.order`], [`cosmic.cli.order`], [`Module.order`]; not [`Cli.chaos`].",
    "return Cli")), {
    dir .. "/b.tl:2: link: Cli.chaos does not resolve (cosmic.cli has no chaos)",
  })
end

--- `source`, a file of `kind` at `path`, as [`links.rewrite`] links it,
--- and what it says it linked.
local function rewritten(context: link_resolve.Context, path: string, kind: string,
                         source: string): string, {string}
  local out = links.rewrite(link_resolve.resolver(context), path, path, kind, source, built)
  return out.source, out.linked
end

--- The world the rewriting tests share: a symbol declared in a file of
--- the tree, a name two symbols answer, a file, and a directory.
local function linking_world(): link_resolve.Context
  return world({
    ["/p/known.tl"] = "",
    ["/p/build/x.tl"] = "",
    ["/p/doc/guide.md"] = "",
    ["/p/dir/inner.tl"] = "",
  }, {
    ["Known.thing"] = { "known.Known.thing@known.tl" },
    ["Two.names"] = { "a.Two.names", "b.Two.names" },
    ["Loose.name"] = { "loose.Loose.name@elsewhere/loose.tl" },
  })
end

--- Each kind of span the rule links, and each it leaves as written.
local function test_a_plain_span_links_only_when_it_names_one_thing()
  local source = lines(
    "local record Box",
    "  width: integer",
    "end",
    "",
    "local a_local = 1",
    "",
    "--- Links `Box`, `Box.width`, `top_level`, `Known.thing` and `build/x.tl`;",
    "--- not `a_local`, `a_param`, `each_item`, `width`, `Two.names`, `nowhere.tl`,",
    "--- `dir`, `dir/`, `cosmic fix`, `COSMIC_X=0`, `--check`, `x = 1`, `%a+`, `path`,",
    "--- `print` or `string.format`; nor [`Known.thing`] again, nor f`Known.thing`,",
    "--- `Known.thing`(x) or ![`Known.thing`].",
    "---",
    "--- ```",
    "--- `Known.thing`",
    "--- ```",
    "local function top_level(a_param: integer): integer",
    "  for each_item = 1, a_param do a_local = a_local + each_item end",
    "  return a_local",
    "end",
    "",
    "-- The same in a plain comment: `Known.thing`.",
    "return { Box = Box, top_level = top_level }")
  local got, linked = rewritten(linking_world(), "/p/a.tl", "teal", source)
  local want = source:gsub("`Box`, `Box.width`, `top_level`, `Known.thing` and `build/x.tl`",
    "[`Box`], [`Box.width`], [`top_level`], [`Known.thing`] and [`build/x.tl`]"):
     gsub("plain comment: `Known.thing`", "plain comment: [`Known.thing`]")
  same({ got }, { want })
  same(linked, {
    "/p/a.tl:7: link: `Box` would link to Box",
    "/p/a.tl:7: link: `Box.width` would link to Box.width",
    "/p/a.tl:7: link: `top_level` would link to top_level",
    "/p/a.tl:7: link: `Known.thing` would link to known.Known.thing",
    "/p/a.tl:7: link: `build/x.tl` would link to build/x.tl",
    "/p/a.tl:21: link: `Known.thing` would link to known.Known.thing",
  })
  -- What it linked resolves, and nothing more is left to link.
  same(checked(linking_world(), "/p/a.tl", "teal", got), {})
  local again, more = rewritten(linking_world(), "/p/a.tl", "teal", got)
  same({ again }, { got })
  same(more, {})
end

--- Where the file's scopes are not read, a bare name links only to
--- what the file declares; a name in full or a path still links.
local function test_c_and_zig_link_a_bare_name_only_to_their_own()
  local c = lines(
    "/* `helper_fn` helps; `Known_thing` and `Known.thing` are elsewhere,",
    " * and `build/x.tl` is a file. */",
    "static int helper_fn (int n) {",
    "  return n; // `n_count` is no name of the file",
    "}")
  local context = world({ ["/p/build/x.tl"] = "" },
    { ["Known.thing"] = { "known.Known.thing" }, Known_thing = { "known.Known_thing" } })
  local got = rewritten(context, "/p/a.c", "c", c)
  same({ got }, { lines(
    "/* [`helper_fn`] helps; `Known_thing` and [`Known.thing`] are elsewhere,",
    " * and [`build/x.tl`] is a file. */",
    "static int helper_fn (int n) {",
    "  return n; // `n_count` is no name of the file",
    "}") })
  local zig = lines(
    "/// `Top_step` is declared, `inner_name` only in a block.",
    "const Top_step = struct {",
    "    const inner_name = 1;",
    "};")
  same({ (rewritten(context, "/p/build.zig", "zig", zig)) }, { (zig:gsub("`Top_step`", "[`Top_step`]")) })
end

--- A span that brackets would make a definition -- at the start of a
--- line, a list item or a quote, with a `:` after it -- is left as
--- written.
local function test_a_span_that_would_become_a_definition_is_left_alone()
  local source = lines(
    "`Known.thing`: the thing.",
    "- `Known.thing`: the thing.",
    "1. `Known.thing`: the thing.",
    "> `Known.thing`: the thing.",
    "Not here `Known.thing`: the thing.")
  same({ (rewritten(linking_world(), "/p/a.md", "markdown", source)) }, { lines(
    "`Known.thing`: the thing.",
    "- `Known.thing`: the thing.",
    "1. `Known.thing`: the thing.",
    "> `Known.thing`: the thing.",
    "Not here [`Known.thing`]: the thing.",
    "",
    "[`Known.thing`]: known.tl") })
end

--- A span a definition of its block already names is left as written:
--- the link would be that definition's, not the span's.
local function test_a_span_a_definition_names_is_left_alone()
  local source = lines("-- `Known.thing` is [the thing][`Known.thing`].", "--", "-- [`Known.thing`]: known.tl",
    "return 1")
  same({ (rewritten(linking_world(), "/p/a.tl", "teal", source)) }, { source })
end

--- A Markdown file gets a definition for each label its links use, at
--- its end, sorted and once each, naming the file that declares a
--- symbol or the file itself, from the file's own directory.
local function test_markdown_gets_a_definition_for_each_label()
  local source = lines(
    "# Guide `Known.thing`",
    "",
    "Use `Known.thing`, then `Known.thing` again, and `build/x.tl`; see [the guide](guide.md),",
    "not `Loose.name`, declared outside the tree, nor `Two.names`.",
    "",
    "[human]: https://example.com")
  local got, linked = rewritten(linking_world(), "/p/doc/a.md", "markdown", source)
  local want = lines(
    "# Guide `Known.thing`",
    "",
    "Use [`Known.thing`], then [`Known.thing`] again, and [`build/x.tl`]; see [the guide](guide.md),",
    "not `Loose.name`, declared outside the tree, nor `Two.names`.",
    "",
    "[human]: https://example.com",
    "",
    "[`build/x.tl`]: ../build/x.tl",
    "[`Known.thing`]: ../known.tl")
  same({ got }, { want })
  assert(#linked == 3, table.concat(linked, "\n"))
  same(checked(linking_world(), "/p/doc/a.md", "markdown", got), {})
  same({ (rewritten(linking_world(), "/p/doc/a.md", "markdown", got)) }, { got })
end

--- The block of definitions follows the links: one whose symbol moved
--- is set right, and one no link uses goes, the block with it when
--- none is left. `fix --check` finds the stale one first.
local function test_markdown_definitions_follow_their_links()
  local moved = world({ ["/p/moved.tl"] = "", ["/p/known.tl"] = "" },
    { ["Known.thing"] = { "known.Known.thing@moved.tl" } })
  local source = lines("See [`Known.thing`].", "", "[`Known.thing`]: known.tl", "[`Gone.name`]: known.tl")
  same(checked(moved, "/p/a.md", "markdown", source), {
    "/p/a.md:3: link: the definition of Known.thing names known.tl, but Known.thing is declared in moved.tl",
  })
  same({ (rewritten(moved, "/p/a.md", "markdown", source)) },
    { lines("See [`Known.thing`].", "", "[`Known.thing`]: moved.tl") })
  local unused = lines("Nothing links here.", "", "[`Known.thing`]: moved.tl")
  same({ (rewritten(moved, "/p/a.md", "markdown", unused)) }, { lines("Nothing links here.") })
end

--- A shortcut's brackets show as the code span alone, and a code-span
--- label's definition not at all; any other link shows as written.
local function test_a_reader_is_shown_a_link_as_its_code_span()
  same({ link_text.unlinked(lines(
    "See [`Fs.read`], [`x`](a.md), [`y`][z] and `` [`w`] ``.",
    "",
    "[z]: b.md",
    "[`Fs.read`]: cosmic/fs.tl")) }, { lines(
    "See `Fs.read`, [`x`](a.md), [`y`][z] and `` [`w`] ``.",
    "",
    "[z]: b.md"):sub(1, -2) })
end

--- A name alone links only to its own file's declaration, however
--- few symbols elsewhere spell it: another module's is written in full.
--- A parameter of a signature -- a record's function field, a `.d.tl`
--- declaration -- is the file's too, and blocks the name. A file's name
--- that spells a module (`vendor.tl`) is left as written.
local function test_a_name_alone_links_only_to_its_own_file()
  local context = world({ ["/p/vendor.tl"] = "" }, {
    Other_name = { "other.Other_name" },
    ["vendor.tl"] = { "vendor.tl" },
    ["Other.name"] = { "other.Other.name" },
  })
  local source = lines(
    "local record Box",
    "  grow: function(self: Box, step_size: integer): boolean",
    "end",
    "",
    "local function step_size(): integer return 1 end",
    "",
    "-- `Other_name` is elsewhere, `Other.name` in full; `step_size` is a",
    "-- parameter too; `vendor.tl` is a module's name as well as a file's.",
    "return { Box = Box, step_size = step_size }")
  same({ (rewritten(context, "/p/a.tl", "teal", source)) },
    { (source:gsub("`Other%.name` in full", "[`Other.name`] in full")) })
  local markdown = "Not `Other_name`, but `Other.name`.\n"
  same({ (rewritten(world({ ["/p/other.tl"] = "" }, { ["Other.name"] = { "other.Other.name@other.tl" },
    Other_name = { "other.Other_name@other.tl" } }), "/p/a.md", "markdown", markdown)) },
    { "Not `Other_name`, but [`Other.name`].\n\n[`Other.name`]: other.tl\n" })
end

--- A C header's `---` and `--` lines are a Teal declaration, whose names
--- are not the header's: their spans stay as written.
local function test_a_c_headers_teal_lines_are_left_alone()
  local context = world({}, { ["Known.thing"] = { "known.Known.thing" } })
  local c = lines(
    "/* `Known.thing` in C.",
    " * --- `Known.thing` in Teal.",
    " */")
  same({ (rewritten(context, "/p/a.h", "c", c)) }, { (c:gsub("/%* `Known.thing`", "/* [`Known.thing`]")) })
end

--- A file's name alone is left as written, even with no symbol of the
--- name: it may mean the module the file holds, or another file of the
--- name. A path with a `/` links, and a link written by hand to the
--- name alone still resolves.
local function test_a_files_name_alone_is_left_as_written()
  local context = world({ ["/p/build/thing.tl"] = "", ["/p/build/a.tl"] = "" })
  local source = lines("-- `thing.tl` is here, as is `build/thing.tl`.", "return 1")
  same({ (rewritten(context, "/p/build/a.tl", "teal", source)) },
    { (source:gsub("`build/thing.tl`", "[`build/thing.tl`]")) })
  same(checked(context, "/p/build/a.tl", "teal", lines("-- [`thing.tl`]", "return 1")), {})
end

--- A plain lowercase word links to its own file's top-level function
--- only when it is written as a call; any other name stays as written.
local function test_a_lowercase_name_written_as_a_call_links()
  local source = lines(
    "local function render(): string",
    "  local function inner() end",
    "  inner()",
    "  return \"\"",
    "end",
    "",
    "-- `render()` links; `render`, `render(x)`, `inner()` and `other()` do not.",
    "return { render = render }")
  local got, linked = rewritten(linking_world(), "/p/a.tl", "teal", source)
  same({ got }, { (source:gsub("`render%(%)` links", "[`render()`] links")) })
  same(linked, { "/p/a.tl:7: link: `render()` would link to render" })
  same(checked(linking_world(), "/p/a.tl", "teal", got), {})
end
