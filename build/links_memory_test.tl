--- The memory of what a run keeps of each Teal file for its links ([`links.facts`]): the file's text and the comments'
--- blocks, and not the file's tokens and syntax tree, which are most of what its parse holds. `cosmic fix` keeps the facts
--- of every file of the tree from its parse to the end of its run.
local Test = require("cosmic.test")
local ast = require("build.ast")
local link_text = require("build.link_text")
local links = require("build.links")
local teal = require("build.teal")

Test.policy{ grants = { { path = "core", letters = "r" } } }

local built = assert(teal.load())

--- The files a case parses one after another, and the functions in each. A file of this size holds some seven thousand
--- tokens, whose tree and tokens are some megabytes.
local FILES <const> = 6
local FUNCTIONS <const> = 120

--- The most a file's facts may hold on to over the file's own text, in kilobytes. The blocks of its comments and the bindings
--- of its scopes are some hundred; its tree and tokens are some megabytes.
local BUDGET <const> = 300

--- What a case keeps of a file: one of the two, and what it kept of the files before.
local record Held
  facts?: links.Facts
  declarations?: link_text.Declarations
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

--- What `keep` holds on to per file, in kilobytes over the file's text, after `FILES` files are each parsed and `keep`
--- is given the parse and the text. It is counted after a full collection, so it is what `keep` returned and not the
--- garbage of the parse.
local function held_per_file(keep: function(parsed: ast.Parsed, source: string, older: Held | nil): Held): number
  collectgarbage("collect")
  collectgarbage("collect")
  local base = collectgarbage("count")
  local held: Held | nil = nil
  local text = 0
  for i = 1, FILES do
    local source = text_of(i)
    text = text + #source
    local parsed, trouble = ast.parse(built, source, ("f%d.tl"):format(i))
    assert(parsed ~= nil, tostring(trouble))
    held = keep(parsed, source, held)
  end
  collectgarbage("collect")
  collectgarbage("collect")
  local used = collectgarbage("count") - base
  assert(held ~= nil)
  return (used - text / 1024) / FILES
end

local function test_the_facts_of_a_file_hold_its_comments_and_not_its_syntax()
  local held = held_per_file(function(parsed: ast.Parsed, source: string, older: Held | nil): Held
    return { facts = links.facts(parsed, source), older = older }
  end)
  assert(held < BUDGET, ("the facts of a file held %.0f KB over its text, over the budget of %d KB"):format(held, BUDGET))
end

local function test_declarations_that_have_not_walked_the_scopes_are_over_the_budget()
  -- The budget is a bound with something on the other side of it: declarations that wait for the first comment to ask
  -- keep the tree to walk then, and are far over it.
  local held = held_per_file(function(parsed: ast.Parsed, _source: string, older: Held | nil): Held
    return { declarations = link_text.declarations(parsed), older = older }
  end)
  assert(held > 2 * BUDGET, ("declarations that keep the tree held only %.0f KB, which the budget of %d KB cannot tell from none"):
      format(held, BUDGET))
end

local function test_the_facts_of_a_file_answer_what_a_comment_sees()
  -- Holding less of the file must not change what a comment sees declared at its line.
  local source = text_of(1)
  local parsed = assert(ast.parse(built, source, "f1.tl"))
  local facts = links.facts(parsed, source)
  local lazy = link_text.declarations(parsed)
  for line = 1, 40 do
    local settled, waiting = facts.known.at(line), lazy.at(line)
    for _, name in ipairs({ "Box1", "f1", "f2", "a", "b", "missing" }) do
      assert(settled.names[name] == waiting.names[name], ("line %d, %s"):format(line, name))
    end
    for _, name in ipairs({ "Box1", "f1", "a" }) do
      assert(settled.aliases[name] == waiting.aliases[name], ("line %d, alias %s"):format(line, name))
    end
  end
  assert(facts.known.at(2).names["Box1"] == true)
  assert(facts.known.at(2).names["missing"] ~= true)
end
