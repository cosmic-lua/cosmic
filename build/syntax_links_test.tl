--- Tests of [`build.syntax_links`] and [`build.syntax_link_text`]: the links of a Teal source, read off the new tree, are
--- what [`build.links`] finds and rewrites in it.
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local LinkText = require("build.link_text")
local Node = require("build.syntax_node")
local SyntaxLinkText = require("build.syntax_link_text")
local SyntaxLinks = require("build.syntax_links")
local Test = require("cosmic.test")
local link_resolve = require("build.link_resolve")

--- The element of `list` at `index`, which the case knows is there.
local function nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

Test.policy{ grants = { { path = "core", letters = "r" } } }

local function lines(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- A world for the checks: the files at their absolute paths under `/p`, and the symbols a query names (spelled
--- `module.symbol@file`).
local function world(files: {string: string}, symbols?: {string: {string}}, members?: {string: {string}}):
    link_resolve.Context
  local dirs: mut {string: boolean} = { ["/p"] = true }
  for path in pairs(files) do
    local dir = Fs.dirname(path)
    while dir ~= "/" and dir ~= "" do
      dirs[dir] = true
      dir = Fs.dirname(dir)
    end
  end
  local function symbols_of(spelled: {string}): {link_resolve.Symbol}
    local out: mut {link_resolve.Symbol} = {}
    for _, written in ipairs(spelled) do
      local name, file = written:match("^(.-)@(.+)$")
      name = name or written
      local module, symbol = name:match("^([^.]+)%.(.+)$")
      out[#out + 1] = { module = module or name, symbol = symbol or "", file = file }
    end
    return out
  end
  return {
    root = "/p",
    kind = function(path: string): string?
      if files[path] ~= nil then return "file" end
      if dirs[path] == true then return "dir" end
      return nil
    end,
    read = function(path: string): string? return files[path] end,
    real = function(path: string): string? return path end,
    unbuilt = function(): string? return nil end,
    symbols = function(query: string): {link_resolve.Symbol}?, string
      return symbols_of((symbols or {})[query] or {}), ""
    end,
    member = function(module: string, member: string): {link_resolve.Symbol}?, string
      return symbols_of((members or {})[module .. "." .. member] or {}), ""
    end,
  }
end

local function linking_world(): link_resolve.Context
  return world({ ["/p/known.tl"] = "", ["/p/build/x.tl"] = "", ["/p/doc/guide.md"] = "" }, {
    ["Known.thing"] = { "known.Known.thing@known.tl" },
    ["Two.names"] = { "a.Two.names", "b.Two.names" },
  }, { ["cosmic.fs.read"] = { "cosmic.fs.read@cosmic/fs.tl" } })
end

--- Teal sources with links in their comments, to be checked and rewritten.
local SOURCES: {string} = {
  lines(
    "local record Box",
    "  width: integer",
    "end",
    "",
    "--- Grows [`Box.width`]; see [`helper`] and [`Box.grow`], and [`Box.nope`].",
    "function Box.grow(step: integer)",
    "  -- By [`step`].",
    "end",
    "",
    "local function helper()",
    "end",
    "",
    "return Box"),
  lines(
    "local Fs = require(\"cosmic.fs\")",
    "-- [`Fs.read`] reads, [`Fs.nope`] does not.",
    "local function a()",
    "  local Fs = require(\"cosmic.json\")",
    "  -- [`Fs.read`] is Json's here.",
    "  return Fs.encode",
    "end",
    "return Fs.read"),
  lines(
    "local record Box",
    "  width: integer",
    "end",
    "",
    "local a_local = 1",
    "",
    "--- Links `Box`, `Box.width`, `top_level`, `Known.thing` and `build/x.tl`;",
    "--- not `a_local`, `a_param`, `each_item`, `width`, `Two.names`, `nowhere.tl`, `path` or [`Known.thing`] again.",
    "local function top_level(a_param: integer): integer",
    "  for each_item = 1, a_param do a_local = a_local + each_item end",
    "  return a_local",
    "end",
    "",
    "-- The same in a plain comment: `Known.thing`.",
    "return { Box = Box, top_level = top_level }"),
  lines(
    "local function a()",
    "  local Fs = require(\"cosmic.fs\")",
    "  -- `Fs.read` reads.",
    "  return Fs.read",
    "end",
    "",
    "-- `Fs.read` reads.",
    "return a"),
  lines(
    "local record Queue<T>",
    "  --- Sends.",
    "  send: function(self: Queue<T>, item: T): boolean",
    "end",
    "-- [`Queue.send`] and [`Queue.nowhere`]",
    "return Queue"),
}

local function test_the_links_of_a_source_are_checked_and_rewritten()
  local checked = 0
  local linked = 0
  for index, source in ipairs(SOURCES) do
    local path = "/p/a" .. tostring(index) .. ".tl"
    local new = SyntaxLinks.check(link_resolve.resolver(linking_world()), path, path, "teal", source)
    checked = checked + #new
    local now = SyntaxLinks.rewrite(link_resolve.resolver(linking_world()), path, path, "teal", source)
    linked = linked + #now.linked
  end
  -- Something was found to be wrong and something was linked.
  assert(checked >= 3, tostring(checked))
  assert(linked >= 5, tostring(linked))
end

local function test_a_source_that_does_not_parse_is_left_as_it_is_and_its_comments_are_still_checked()
  local source = lines("-- [`gone.md`] and [gone](gone.md)", "local x = = 1", "-- `Known.thing`")
  local resolver = link_resolve.resolver(linking_world())
  local checks = SyntaxLinks.check(resolver, "/p/a.tl", "/p/a.tl", "teal", source)
  assert(#checks == 2 and checks[2]:find("gone.md does not resolve", 1, true) ~= nil, table.concat(checks, "\n"))
  local out = SyntaxLinks.rewrite(resolver, "/p/a.tl", "/p/a.tl", "teal", source)
  assert(out.source == source and #out.linked == 0)
end

local function test_a_facts_value_read_once_answers_check_and_rewrite()
  local source = nth(SOURCES, 1)
  local chunk = assert(Node.parse(source, "/p/a.tl"))
  local facts = SyntaxLinks.facts(chunk, Node.scope(chunk, "/p/a.tl"), source)
  local resolver = link_resolve.resolver(linking_world())
  assert(table.concat(SyntaxLinks.check(resolver, "/p/a.tl", "/p/a.tl", "teal", source, facts), "\n") ==
      table.concat(SyntaxLinks.check(resolver, "/p/a.tl", "/p/a.tl", "teal", source), "\n"))
  assert(facts.known.module_level["helper"] == true and facts.known.module_level["Box"] == true)
end

--- Only the lines of comment blocks have a scope settled; a line outside every block is a fault in the caller and is
--- refused, not answered as if nothing were declared there.
local function test_a_line_outside_every_comment_block_is_refused()
  local source = lines("local record Box", "  n: integer", "end", "--- Holds [`Box`].", "local function f() end")
  local chunk = assert(Node.parse(source, "/p/a.tl"))
  local facts = SyntaxLinks.facts(chunk, Node.scope(chunk, "/p/a.tl"), source)
  assert(#facts.blocks == 1 and assert(facts.blocks[1]).line == 4)
  assert(facts.known.at(4).names["Box"] == true)
  local block = assert(facts.blocks[1])
  local _, breaks = block.text:gsub("\n", "")
  assert(facts.known.at(block.line + breaks).names["Box"] == true)
  Test.raises(function() facts.known.at(5) end, "line 5 is outside every comment block")
  local before, _ = pcall(facts.known.at, 1)
  assert(not before)
end

--- The comments of a source are read from the tokens, where each starts in the file.
local function test_the_comments_of_a_source_say_where_their_text_starts()
  local source = lines("local x = 1 -- trail", "--- [`x`] doc", "return x")
  local comments = SyntaxLinkText.comments_of(Lexer.lex(source, "a.tl").tokens)
  assert(#comments == 2)
  assert(comments[1].line == 1 and comments[1].column == 15 and not comments[1].doc and comments[1].lines[1] == " trail")
  assert(comments[2].line == 2 and comments[2].column == 4 and comments[2].doc)
  local starts = comments[2].starts or {}
  assert(source:sub(nth(starts, 1), nth(starts, 1) + 3) == " [`x")
  assert(LinkText.line_starts(source)[3] == #"local x = 1 -- trail\n--- [`x`] doc\n" + 1)
end

--- The members of a generic type are declared as those of any other type are, at the top and nested.
local function test_the_members_of_a_generic_type_are_declared_as_those_of_any_type_are()
  local source = lines(
    "local record Queue<T>",
    "  send: function(self: Queue<T>, item: T): boolean",
    "end",
    "local record Plain",
    "  send: function(self: Plain): boolean",
    "  record Inner<T>",
    "    drop: function(self: Inner<T>)",
    "  end",
    "  record Flat",
    "    keep: function(self: Flat)",
    "  end",
    "end",
    "-- comment",
    "return Queue")
  local chunk = assert(Node.parse(source, "a.tl"))
  local declared = SyntaxLinkText.declarations(chunk, Node.scope(chunk, "a.tl"))
  local here = declared.at(14)
  assert(here.names["Plain.send"] == true and here.names["Queue.send"] == true)
  assert(here.names["Plain.Flat.keep"] == true and here.names["Plain.Inner.drop"] == true)
end
