--- A project written in the new grammar (`mut`, a class, function fields called as `queue:push(word)`, `T?`) with a template,
--- an example and a program, as the tests that build it with the new checker (`COSMIC_GRAMMAR=new`) write it into a directory
--- of their own: [`build.project_new_grammar_tool_test`] tests it and counts its coverage, plants errors in it and sees them
--- refused with the new checker's fixes; [`build.embed_tool_test`] builds its program with `cosmic build`.
---
--- It is text here and no `.tl` file of the tree because the default `cosmic fix` reads every `.tl` file of a tree with the
--- fork's parser, which does not read the grammar, and so does `cosmic lsp`. `COSMIC_GRAMMAR=new cosmic fix` reads such a
--- file with the new parser and does not lay it out; [`build.project_new_grammar_tool_test`] checks the project that way.
--
-- TODO: make this project real files, testdata/rehearsal/new_grammar, run by CI's `rehearsal-project` phase beside the other two
-- (ci/cosmic_ci/rehearsal.tl), and delete this module, once the switch makes the default `cosmic fix` read a new-grammar file
-- as `COSMIC_GRAMMAR=new` does and `cosmic lsp` skip it gracefully instead of parsing every `.tl` of a tree with the fork's
-- parser (doc/plans/strict-teal.md, "the switch").
local Fs = require("cosmic.fs")

local record NewGrammarProject
  --- Writes the files of the project under `root`, made if it is not there. true, or nil and why not.
  write: function(root: string): boolean?, string
end

local FILES <const>: {string: string} = {
  ["cmd/tally/main.tl"] = [==[
local Fs = require("cosmic.fs")
local Counter = require("counter")
local Queue = require("queue")

return function(argv: {string}): integer
  local queue = Queue.new()
  for _, word in ipairs(argv) do
    queue:push(word)
  end
  local counter = Counter.new("words")
  while true do
    local word = queue:pop()
    if word == nil then
      break
    end
    counter:add(word)
  end
  local _, _ = Fs.put(Fs.stdout, counter:line() .. "\n")
  return counter.count
end
]==],
  ["counter.tl"] = [==[
--- A count of the words seen, as a class.
local class Counter
  --- What the words are counted for.
  label: string
  --- How many have been counted.
  mut count: integer
  --- The words, in the order they came.
  seen: mut {string}

  --- Counts `word` and answers how many have been counted.
  function add(self, word: string): integer
    self.count = self.count + 1
    table.insert(self.seen, word)
    return self.count
  end

  --- The words counted, joined by commas.
  function line(self): string
    return table.concat(self.seen, ",")
  end
end

local record Counters
  new: function(label: string): Counter
end

local function new(label: string): Counter
  return { label = label, count = 0, seen = {} }
end

local counters: Counters = { new = new }
return counters
]==],
  ["counter_test.tl"] = [==[
local Counter = require("counter")
local Html = require("cosmic.html")
local report = require("report")

local function test_a_counter_counts_the_words_it_is_given()
  local counter = Counter.new("words")
  assert(counter:add("a") == 1 and counter:add("b") == 2)
  assert(counter:line() == "a,b")
end

local function test_a_template_of_the_project_renders_escaped()
  local out = Html.raw(report.render({ title = "a<b", words = { "x" }, note = nil }))
  assert(out:find("<h1>a&lt;b</h1>", 1, true) ~= nil, out)
  assert(out:find("<li>x</li>", 1, true) ~= nil, out)
end
]==],
  ["queue.tl"] = [==[
--- A queue of words, in the new grammar.
local record Queue
  --- The words waiting, first in line first. The queue changes them in place.
  items: mut {string}
  --- How many wait, which changes with every push and pop.
  mut length: integer
  --- Puts `word` at the end of the line.
  push: function(self: Queue, word: string)
  --- Takes the word at the front, nil when none waits.
  pop: function(self: Queue): string?
end

local function push(self: Queue, word: string)
  table.insert(self.items, word)
  self.length = self.length + 1
end

local function pop(self: Queue): string?
  if self.length == 0 then
    return nil
  end
  self.length = self.length - 1
  return table.remove(self.items, 1)
end

--- A queue with nothing in it. Each function is a field of the queue, so that `queue:push(word)` finds it in the value
--- (a record's value has no metatable).
function Queue.new(): Queue
  return { items = {}, length = 0, push = push, pop = pop }
end

return Queue
]==],
  ["queue_example.tl"] = [==[
--- Worked examples for the queue, shown by `cosmic docs` and run by `cosmic test`.
local Queue = require("queue")

local record Example end

--- Words come out in the order they went in, and `pop` answers nil once none waits.
function Example.order()
  local queue = Queue.new()
  queue:push("first")
  queue:push("second")
  assert(queue:pop() == "first")
  assert(queue:pop() == "second")
  assert(queue:pop() == nil)
end

return Example
]==],
  ["queue_test.tl"] = [==[
local Queue = require("queue")

local function test_a_queue_gives_its_words_back_in_the_order_they_came()
  local queue = Queue.new()
  queue:push("b")
  queue:push("a")
  assert(queue:pop() == "b" and queue:pop() == "a" and queue:pop() == nil)
  assert(queue.length == 0)
end
]==],
  ["report.tmpl"] = [==[
{{type Report from report_data}}
<h1>{{.title}}</h1>
{{range .words}}<li>{{.}}</li>{{end}}
{{with .note}}<p>{{.}}</p>{{end}}
]==],
  ["report_data.tl"] = [==[
local record data
  record Report
    title: string
    words: {string}
    note: string?
  end
end
return data
]==],
}

function NewGrammarProject.write(root: string): boolean?, string
  local rooted, rooted_why = Fs.mkdirs(root)
  if not rooted then return nil, rooted_why end
  for name, text in pairs(FILES) do
    local dir = name:match("^(.*)/[^/]*$")
    if dir ~= nil then
      local made, made_why = Fs.mkdirs(root .. "/" .. dir)
      if not made then return nil, made_why end
    end
    local written, why = Fs.write(root .. "/" .. name, text)
    if not written then return nil, why end
  end
  return true, ""
end

return NewGrammarProject
