--- The memory of what a run keeps of each Teal file for its links ([`build.syntax_links`]' `facts`): the file's text, the
--- comments' blocks and what each line sees declared, and not the file's tokens and syntax tree, which are most of what its
--- parse holds. `cosmic fix` keeps the facts of every file of the tree from its parse to the end of its run.
local Ast = require("lang.ast")
local Links = require("build.links")
local Node = require("build.syntax_node")
local Scopes = require("lang.scopes")
local SyntaxLinkText = require("build.syntax_link_text")
local SyntaxLinks = require("build.syntax_links")
local Test = require("cosmic.test")

Test.policy{}

--- The files a case parses one after another, and the functions in each. A file of this size holds some seven thousand
--- tokens, whose tree and tokens are some megabytes.
local FILES <const> = 6
local FUNCTIONS <const> = 120

--- The most a file's facts may hold on to over the file's own text, in kilobytes. The blocks of its comments and the bindings
--- of its scopes are some hundred; its tree and tokens are some megabytes.
local BUDGET <const> = 400

--- What a case keeps of a file, and of the files before it.
local record Held
  facts?: Links.Facts
  chunk?: Ast.Chunk
  scoped?: Scopes.Scoped
  older?: Held
end

--- The text of file `i`: a record and functions, each with a doc comment that names a declaration of the file.
local function text_of(i: integer): string
  local text = ("local record Box%d\n  n: integer\nend\n"):format(i)
  for f = 1, FUNCTIONS do
    text = text .. ("--- Adds %d to `a` as [`Box%d`] does, and answers `b` of `f%d`.\n"):format(f, i, f) ..
      ("local function f%d(a: integer): integer\n  local b: integer = a + %d\n  return b * 2\nend\n"):format(f, f)
  end
  return text .. ("return Box%d\n"):format(i)
end

--- What `keep` holds on to per file, in kilobytes over the file's text, after `FILES` files are each parsed and `keep` is
--- given the tree, its scopes and the text. It is counted after a full collection, so it is what `keep` returned and not the
--- garbage of the parse.
local function held_per_file(keep: function(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string, older: Held?): Held): number
  collectgarbage("collect")
  collectgarbage("collect")
  local base = collectgarbage("count")
  local held: Held? = nil
  local text = 0
  for i = 1, FILES do
    local source = text_of(i)
    local name = ("f%d.tl"):format(i)
    text = text + #source
    local chunk, trouble = Node.parse(source, name)
    assert(chunk ~= nil, tostring(trouble))
    held = keep(chunk, Node.scope(chunk, name), source, held)
  end
  collectgarbage("collect")
  collectgarbage("collect")
  local used = collectgarbage("count") - base
  assert(held ~= nil)
  return (used - text / 1024) / FILES
end

local function test_the_facts_of_a_file_hold_its_comments_and_not_its_syntax()
  local held = held_per_file(function(chunk: Ast.Chunk, scoped: Scopes.Scoped, source: string, older: Held?): Held
    return { facts = SyntaxLinks.facts(chunk, scoped, source), older = older }
  end)
  assert(held < BUDGET, ("the facts of a file held %.0f KB over its text, over the budget of %d KB"):format(held, BUDGET))
end

local function test_a_tree_kept_with_its_scopes_is_over_the_budget()
  -- The budget is a bound with something on the other side of it: the tree and its scopes, kept for the first comment to
  -- ask, are far over it.
  local held = held_per_file(function(chunk: Ast.Chunk, scoped: Scopes.Scoped, _source: string, older: Held?): Held
    return { chunk = chunk, scoped = scoped, older = older }
  end)
  assert(held > 2 * BUDGET, ("a tree kept held only %.0f KB, which the budget of %d KB cannot tell from none"):
      format(held, BUDGET))
end

local function test_the_facts_of_a_file_answer_what_a_comment_sees()
  local source = text_of(1)
  local chunk = assert(Node.parse(source, "f1.tl"))
  local facts = SyntaxLinks.facts(chunk, Node.scope(chunk, "f1.tl"), source)
  assert(facts.known.parsed and #facts.blocks == FUNCTIONS)
  -- The lazy answer and the settled one agree on every line of every block.
  local lazy = SyntaxLinkText.declarations(chunk, Node.scope(chunk, "f1.tl"))
  for _, block in ipairs(facts.blocks) do
    local settled, waiting = facts.known.at(block.line), lazy.at(block.line)
    for _, name in ipairs({ "Box1", "f1", "f2", "f120", "a", "b", "missing" }) do
      assert(settled.names[name] == waiting.names[name], ("line %d, %s"):format(block.line, name))
    end
    for _, name in ipairs({ "Box1", "f1", "a" }) do
      assert(settled.aliases[name] == waiting.aliases[name], ("line %d, alias %s"):format(block.line, name))
    end
  end
  assert(assert(facts.blocks[1]).line == 4 and facts.known.at(4).names["Box1"] == true)
  assert(facts.known.at(4).names["missing"] ~= true)
end
