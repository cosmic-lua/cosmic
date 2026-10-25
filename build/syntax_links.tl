--- The link checks of `cosmic fix` on the new syntax tree: [`build.links`]' `check` and `rewrite` of a file, with its
--- comments and what it declares read from the tree [`lang.parser`] builds ([`build.syntax_link_text`]) in place of the
--- fork's. The checks themselves are [`build.links`]', which takes the way a file is read as a [`Links.Reader`]; this is
--- the other reader and the entries that use it. A file of another kind (Markdown, C, Zig) is read as it always is
--- ([`build.link_files`]).
---
--- A Teal file that does not parse is left as it is, as the fork's: it declares nothing, and a rewrite changes none of
--- it. Its comments are still checked, since they are lexed whatever the file holds.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local LinkText = require("build.link_text")
local Links = require("build.links")
local Node = require("build.syntax_node")
local Scopes = require("lang.scopes")
local SyntaxLinkText = require("build.syntax_link_text")
local link_files = require("build.link_files")
local link_resolve = require("build.link_resolve")

local record SyntaxLinks
  --- The facts of the Teal source `chunk` is the tree of, whose names `scoped` resolved ([`Node.scope`]), for `check`
  --- and `rewrite`.
  facts: function(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string): Links.Facts

  --- What is wrong with the links of `source`: [`Links.check`], reading Teal off the new tree.
  check: function(resolver: link_resolve.Resolver, file: string, absolute: string, kind: string, source: string,
                  facts?: Links.Facts): {string}

  --- `source` with its plain code spans linked: [`Links.rewrite`], reading Teal off the new tree.
  rewrite: function(resolver: link_resolve.Resolver, file: string, absolute: string, kind: string, source: string,
                    facts?: Links.Facts): Links.Rewritten
end

--- What a Teal source that does not parse declares: nothing.
local nothing: LinkText.Declared = { names = {}, aliases = {} }

local reader: Links.Reader = {
  blocks = function(kind: string, source: string, name: string): {LinkText.Block}
    if kind == "teal" then
      return LinkText.blocks_of(SyntaxLinkText.comments_of(Lexer.lex(source, name).tokens))
    end
    return link_files.blocks(kind, source)
  end,
  declarations = function(kind: string, source: string, name: string): Links.Known
    if kind == "teal" then
      local chunk, _ = Node.parse(source, name)
      if chunk == nil then
        return { at = function(_: integer): LinkText.Declared return nothing end, module_level = {}, parsed = false }
      end
      local found = SyntaxLinkText.declarations(chunk, Node.scope(chunk, name))
      return { at = found.at, module_level = found.module_level, parsed = true }
    end
    local found = link_files.declarations(kind, source)
    return { at = found.at, module_level = found.module_level, parsed = true }
  end,
}

function SyntaxLinks.facts(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string): Links.Facts
  local found = SyntaxLinkText.declarations(chunk, scoped)
  local blocks = LinkText.blocks_of(SyntaxLinkText.comments_of(chunk.tokens))
  -- What each line of a comment sees is settled now, for every line a link or a code span of a block can stand on. `found.at`
  -- would keep the tree and its scopes until the first comment asked, and `cosmic fix` keeps the facts of every file of
  -- the tree: build/links_memory_test.tl holds a file's facts to a budget the tree is far over.
  local settled: mut {integer: LinkText.Declared} = {}
  for _, block in ipairs(blocks) do
    local _, breaks = block.text:gsub("\n", "")
    for line = block.line, block.line + breaks do
      if settled[line] == nil then
        settled[line] = found.at(line)
      end
    end
  end
  return {
    source = source,
    blocks = blocks,
    known = {
      at = function(line: integer): LinkText.Declared
        local seen = settled[line]
        if seen == nil then
          error("line " .. tostring(line) .. " is outside every comment block, whose lines alone have their scope settled " ..
            "(build/links.tl asks only for a line a link or a code span stands on)")
        end
        return seen
      end,
      module_level = found.module_level,
      parsed = true,
    },
  }
end

function SyntaxLinks.check(resolver: link_resolve.Resolver, file: string, absolute: string, kind: string,
                           source: string, facts?: Links.Facts): {string}
  return Links.check(reader, resolver, file, absolute, kind, source, facts)
end

function SyntaxLinks.rewrite(resolver: link_resolve.Resolver, file: string, absolute: string, kind: string,
                             source: string, facts?: Links.Facts): Links.Rewritten
  return Links.rewrite(reader, resolver, file, absolute, kind, source, facts)
end

return SyntaxLinks
