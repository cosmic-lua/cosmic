--- What `cosmic fix` reads off a Teal file it parses, so nothing after it parses the file again: what its links read, the
--- functions the notes compare, and, where the tree checks run, what the file requires and the plurals they look for.
--- A memo keeps a read by the file's path and text ([`build.fix.read_memo`]), salted by the code of this module, so this
--- module loads only what a read runs.
local type Links = require("build.links")
local PluralSites = require("build.plural_sites")
local ReadMemo = require("build.fix.read_memo")
local String = require("cosmic.string")
local SyntaxAnalyzer = require("build.syntax_analyzer")
local SyntaxLinks = require("build.syntax_links")
local SyntaxNode = require("build.syntax_node")
local known = require("build.tree_checks.known")
local type Ast = require("lang.ast")
local type near = require("build.fix.near")

local record FixRead
  --- Whether `file` is one whose functions `near` compares: not a test, an example or a declaration file, which offer
  --- nothing to compare.
  compared: function(file: string): boolean

  --- What `near` compares of a file: each exported function or method with a doc comment, read off `chunk`
  --- ([`SyntaxAnalyzer.docs`]), the tree of `text`.
  candidates_from: function(chunk: Ast.Chunk, text: string): {near.Candidate}

  --- [`candidates_from`] `source`, as written; nil where it does not parse.
  written_candidates_of: function(source: string, file: string): {near.Candidate}?

  --- What a run keeps of `file`'s parse: what its links read (`facts`), what the notes compare (`ready`), and, where the
  --- tree checks will run, the plurals they look for (`plurals`, by the file's path from the root). `chunk` is the new
  --- checker's tree of `source`, as written.
  off: function(file: string, chunk: Ast.Chunk, source: string, facts: mut {string: Links.Facts},
    ready: mut {string: {near.Candidate}}, plurals: mut {string: PluralSites.Plurals}?): ReadMemo.Read

  --- Takes what was read off `file`, whose text is `source` ([`off`], or a memo of it), into the tables a run keeps of
  --- every file.
  take: function(file: string, source: string, read: ReadMemo.Read, facts: mut {string: Links.Facts},
    ready: mut {string: {near.Candidate}}, plurals: mut {string: PluralSites.Plurals}?)
end

function FixRead.compared(file: string): boolean
  return not String.ends_with(file, "_test.tl") and
    not String.ends_with(file, "_example.tl") and not String.ends_with(file, ".d.tl")
end

--- The candidate `near` compares for a doc entry, nil for one it passes over: an exported function or method with a
--- doc comment. `signature` tells a method written as a function with a `self` first.
local function candidate_of(exported: boolean, kind: string, text: string, signature: string, source_symbol: string,
                            line: integer): near.Candidate?
  if exported and (kind == "function" or kind == "method") and text ~= "" then
    return { source_symbol = source_symbol, text = text, line = line,
      method = kind == "method" or signature:find("^[^(]*%(%s*self%s*:") ~= nil }
  end
  return nil
end

function FixRead.candidates_from(chunk: Ast.Chunk, text: string): {near.Candidate}
  local candidates: mut {near.Candidate} = {}
  for _, entry in ipairs(SyntaxAnalyzer.docs(chunk, text)) do
    local found = candidate_of(entry.exported, entry.kind, entry.text, entry.signature, entry.source_symbol, entry.line)
    if found ~= nil then candidates[#candidates + 1] = found end
  end
  return candidates
end

function FixRead.written_candidates_of(source: string, file: string): {near.Candidate}?
  local chunk, _ = SyntaxNode.parse(source, file)
  if chunk == nil then return nil end
  return FixRead.candidates_from(chunk, source)
end

--- `file` as a path from the root.
local function from_root(file: string): string
  while file:sub(1, 2) == "./" do file = file:sub(3) end
  return file
end

function FixRead.off(file: string, chunk: Ast.Chunk, source: string, facts: mut {string: Links.Facts},
                     ready: mut {string: {near.Candidate}}, plurals: mut {string: PluralSites.Plurals}?): ReadMemo.Read
  local read: ReadMemo.Read = {
    settled = SyntaxLinks.settled(chunk, SyntaxNode.scope(chunk, file)),
    candidates = if FixRead.compared(file) then FixRead.candidates_from(chunk, source) else nil end,
    plurals = nil,
  }
  if plurals ~= nil then
    -- What the tree checks keep of the parse goes into the memo too.
    known.parse(source, file, chunk)
    read.plurals = PluralSites.found_in(from_root(file), source, chunk)
    local kept = known.of(source, file)
    if kept ~= nil then read.requires, read.returns = kept.requires, kept.returns end
  end
  FixRead.take(file, source, read, facts, ready, plurals)
  return read
end

function FixRead.take(file: string, source: string, read: ReadMemo.Read, facts: mut {string: Links.Facts},
                      ready: mut {string: {near.Candidate}}, plurals: mut {string: PluralSites.Plurals}?)
  facts[file] = SyntaxLinks.facts_of(read.settled, source)
  local candidates = read.candidates
  if candidates ~= nil then ready[file] = candidates end
  local requires = read.requires
  if plurals ~= nil and requires ~= nil then
    known.keep(source, file, { requires = requires, returns = read.returns })
  end
  local found = read.plurals
  if plurals ~= nil and found ~= nil then
    plurals[from_root(file)] = found
  end
end

return FixRead
