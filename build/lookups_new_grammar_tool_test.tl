--- `cosmic docs`, `uses`, `db` and `sql` in a project written in the new grammar, as the tool runs them with the new checker
--- (`COSMIC_GRAMMAR=new`): a lookup builds the project as it stands before it answers ([`build.rebuild`]), and that build reads the
--- sources with the new checker's syntax tree, so a symbol declared with `mut` or `name?: T` is found, and so is a call through
--- a method. The fork does not read the grammar, which the same project's lookups in the default mode show. A project written
--- in Teal both checkers read is answered the same in either mode. The project is the fixture of [`build.new_grammar_project`].
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local NewGrammarProject = require("build.new_grammar_project")
local this_program = require("build.this_program")

--- The program itself, which this test starts, and the project of testdata/rehearsal it reads.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" }, { path = "testdata/rehearsal", letters = "r" } } }

--- A module of the fixture's project that declares what only the new grammar spells: `mut width` and `label?: string`, and a
--- method, `grow`, that a value of the nested record `Shapes.Box` is called through (a call through a value is found by its
--- type, which a record the module is does not need: [`build.syntax_receivers`]).
local SHAPES <const> = [==[
--- Boxes that grow.
local record Shapes
  --- A box with a width.
  record Box
    --- How wide it is, changed by `grow`.
    mut width: integer
    --- A label, absent until one is set.
    label?: string
    --- Widens the box by `by`.
    grow: function(self: Box, by: integer)
  end

  --- A box `width` wide, with no label.
  new: function(width: integer): Box
end

local function grow(self: Shapes.Box, by: integer)
  self.width = self.width + by
end

--- Makes a box.
function Shapes.new(width: integer): Shapes.Box
  return { width = width, grow = grow }
end

return Shapes
]==]

local SHAPES_TEST <const> = [==[
local Shapes = require("shapes")

local function test_a_box_grows()
  local box = Shapes.new(2)
  box:grow(3)
  assert(box.width == 5)
  assert(box.label == nil)
end
]==]

--- A module of the fixture's project with two classes of a method named alike, neither of them the record the module returns.
local VESSELS <const> = [==[
--- Holds liquid.
local class Tank
  mut level: integer

  --- Pours `by` in.
  function fill(self, by: integer): integer
    self.level = self.level + by
    return self.level
  end

  --- Pours one in, through `self`.
  function top_up(self): integer
    return self:fill(1)
  end
end

--- Holds jam.
local class Jar
  function fill(self, by: integer): integer
    return by
  end
end

local record Garden
  tank: Tank
end

--- Something with an area.
local interface Shape
  area: function(self: Shape): integer
end

--- A square, which defines the area itself.
local class Sq is Shape
  side: integer

  function area(self): integer
    return self.side * self.side
  end
end

local function square_area(sq: Sq): integer
  return sq:area()
end

local function shape_area(shape: Shape): integer
  return shape:area()
end

local function through_the_class(tank: Tank): integer
  local Alias = Tank
  local first = Tank.fill(tank, 3)
  return first + Alias.fill(tank, 4)
end

local function drain(tank: Tank): integer
  return tank:fill(-1)
end

local record Vessels
  tank: function(): Tank
  jar: function(): Jar
  garden: function(): Garden
  drain: function(tank: Tank): integer
  filled: function(): integer
  square_area: function(sq: Sq): integer
  shape_area: function(shape: Shape): integer
  through_the_class: function(tank: Tank): integer
end

local function tank(): Tank
  local made: Tank = { level = 0 }
  return made
end

local function garden(): Garden
  return { tank = tank() }
end

local function filled(): integer
  local planted = garden()
  return planted.tank:fill(2)
end

local vessels: Vessels = { tank = tank, jar = function(): Jar return {} end, garden = garden, drain = drain, filled = filled,
  square_area = square_area, shape_area = shape_area, through_the_class = through_the_class }
return vessels
]==]

local VESSELS_TEST <const> = [==[
local Vessels = require("vessels")

local function test_a_tank_fills()
  local tank = Vessels.tank()
  assert(tank:fill(2) == 2 and tank:top_up() == 3)
  local jar = Vessels.jar()
  assert(jar:fill(3) == 3)
end
]==]

--- `cosmic <args>` in `root` with `grammar` as COSMIC_GRAMMAR, unsandboxed (a sandbox nested in this test's own may be refused
--- where the host nests only two deep): what it exited with, and what it said on standard output and on standard error.
local function ran(root: string, tmp: string, grammar: string, args: {string}): Child.Result, string, string
  local stamp = tostring(Clock.monotonic_ns())
  local out_path, err_path = tmp .. "/out." .. stamp, tmp .. "/err." .. stamp
  local out_fd, err_fd = assert(Fs.open_write(out_path)), assert(Fs.open_write(err_path))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_BUILD_CACHE"] = "0"
  env["COSMIC_GRAMMAR"] = grammar
  env["TMPDIR"] = tmp
  local started = this_program.program(args, {
    cwd = root, env = env, stdout = out_fd, stderr = err_fd, process_group = true, timeout_ns = Clock.seconds(120),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(out_fd))
  assert(Fs.close(err_fd))
  return assert(result, trouble), (assert(Fs.read(out_path))), (assert(Fs.read(err_path)))
end

--- The fixture's project under `tmp`, built by `cosmic test` with the new checker, which is what starts the build a lookup
--- then keeps up to date, and the module `shapes` added after, so that only a lookup has seen it.
local function started(tmp: string, name: string): string
  local root = tmp .. "/" .. name
  assert(NewGrammarProject.write(root))
  local result, out, err = ran(root, tmp, "new", { "test" })
  assert(result.ok, out .. err)
  assert(Fs.write(root .. "/shapes.tl", SHAPES))
  assert(Fs.write(root .. "/shapes_test.tl", SHAPES_TEST))
  return root
end

--- `cosmic <args>` in `root` with the new checker, which must exit 0: what it said on standard output, and on standard error.
local function looked_up(root: string, tmp: string, args: {string}): string, string
  local result, out, err = ran(root, tmp, "new", args)
  assert(result.ok, table.concat(args, " ") .. ": " .. out .. err)
  return out, err
end

--- That `text` holds `word`, saying `text` when it does not.
local function holds(text: string, word: string)
  assert(text:find(word, 1, true) ~= nil, word .. " is not in: " .. text)
end

local function test_docs_finds_a_symbol_declared_with_what_only_the_new_grammar_spells(tmp: string)
  local root = started(tmp, "docs")
  -- `shapes` was added after the build: the lookup builds the project as it stands, with the new checker
  local box, box_err = looked_up(root, tmp, { "docs", "Box" })
  holds(box, "shapes Shapes.Box (shapes.tl:4)")
  holds(box, "mut width: integer -- How wide it is, changed by `grow`.")
  holds(box, "label?: string -- A label, absent until one is set.")
  holds(box, "grow: function(self: Box, by: integer) -- Widens the box by `by`.")
  assert(box_err:find("not rebuilt", 1, true) == nil and box_err:find("syntax error", 1, true) == nil, box_err)
  -- the fixture's own, which the build before it had already read: `mut`, a `T?` result and a class
  local queue = looked_up(root, tmp, { "docs", "Queue" })
  holds(queue, "items: mut {string} -- The words waiting, first in line first.")
  holds(queue, "pop: function(self: Queue): string? -- Takes the word at the front, nil when none waits.")
  -- a class and its method, which `uses` is not asked of here ([`test_a_call_through_a_class_value_is_a_use_of_the_method_it_calls`])
  holds((looked_up(root, tmp, { "docs", "Counter.add" })), "counter Counter:add (counter.tl:11)")
  -- the example a lookup shows is the one the new checker read
  holds(queue, "example order (queue_example.tl:7):")
end

local function test_uses_finds_a_call_through_a_method_and_a_call_of_a_module_function(tmp: string)
  local root = started(tmp, "uses")
  -- `box:grow(3)` is a use of `Box.grow` by the type of `box`, found by the last name alone as in the default mode
  assert((looked_up(root, tmp, { "uses", "Box.grow" })) == "shapes_test.tl:5: shapes Box.grow\n")
  assert((looked_up(root, tmp, { "uses", "grow" })) == "shapes_test.tl:5: shapes Box.grow\n")
  -- a call of a function of the module, by the name the module requires
  assert((looked_up(root, tmp, { "uses", "Queue.new" })) ==
      "cmd/tally/main.tl:6: queue new\nqueue_example.tl:8: queue new\nqueue_test.tl:4: queue new\n")
  -- every use the build recorded of the new module, in one question: a read of `.width` and of `.label` are uses of those fields
  local rows = looked_up(root, tmp, { "sql", "SELECT symbol, from_file, line FROM uses WHERE module = 'shapes' ORDER BY symbol, line" })
  assert(rows == "symbol\tfrom_file\tline\nBox.grow\tshapes_test.tl\t5\nBox.label\tshapes_test.tl\t7\n" ..
      "Box.width\tshapes_test.tl\t6\nBox.width\tshapes.tl\t18\nnew\tshapes_test.tl\t4\n", rows)
end

--- A call through a value of a class (`counter:add(word)`, `Counter` a class declared at the top of its module's file) is a use
--- of the method it calls, by the type of the value: the project's `Counter`, and a module of its own whose `Tank` is called
--- through a local, a parameter, a field, `self` and a value its constructor made, beside a `Jar` that has a method of the
--- same name, which is no use of `Tank.fill`.
local function test_a_call_through_a_class_value_is_a_use_of_the_method_it_calls(tmp: string)
  local root = started(tmp, "class")
  assert(Fs.write(root .. "/vessels.tl", VESSELS))
  assert(Fs.write(root .. "/vessels_test.tl", VESSELS_TEST))
  for _, symbol in ipairs({ "Counter.add", "add" }) do
    local out = looked_up(root, tmp, { "uses", symbol })
    assert(out == "cmd/tally/main.tl:16: counter Counter.add\ncounter_test.tl:7: counter Counter.add\n", symbol .. ": " .. out)
  end
  local line = looked_up(root, tmp, { "uses", "Counter.line" })
  assert(line == "cmd/tally/main.tl:18: counter Counter.line\ncounter_test.tl:8: counter Counter.line\n", line)
  -- `self:fill(1)`, `tank:fill(-1)` through a parameter and `planted.tank:fill(2)` through a field, `Tank.fill(tank, 3)` and
  -- the same through an alias of the class; the constructor's value and the jar, which is another class. `sq:area()` is a use of
  -- the `area` the class `Sq` defines, `shape:area()` of the one the interface `Shape` declares.
  local square = looked_up(root, tmp, { "uses", "Sq.area" })
  assert(square == "vessels.tl:43: vessels Sq.area\n", square)
  local rows = looked_up(root, tmp, { "sql", "SELECT symbol, from_file, line FROM uses WHERE module = 'vessels' AND symbol LIKE '%.%' " ..
      "ORDER BY symbol, from_file, line" })
  assert(rows == "symbol\tfrom_file\tline\nJar.fill\tvessels_test.tl\t7\nShape.area\tvessels.tl\t47\nSq.area\tvessels.tl\t43\n" ..
      "Tank.fill\tvessels.tl\t13\nTank.fill\tvessels.tl\t52\nTank.fill\tvessels.tl\t53\nTank.fill\tvessels.tl\t57\n" ..
      "Tank.fill\tvessels.tl\t82\nTank.fill\tvessels_test.tl\t5\nTank.top_up\tvessels_test.tl\t5\n", rows)
end

--- A mistyped COSMIC_GRAMMAR is refused by the lookups, as it is by every command that reads it, saying the allowed values.
local function test_a_lookup_refuses_a_grammar_that_is_none(tmp: string)
  for _, args in ipairs({ { "docs", "Fs.read" }, { "uses", "Fs.read" } }) do
    local result, out, err = ran(tmp, tmp, "bogus", args)
    assert(result.code == 1 and out == "", out .. err)
    holds(err, "COSMIC_GRAMMAR=bogus: the grammars are `teal` (the default) and `new`")
  end
end

local function test_db_and_sql_read_the_rows_the_new_checkers_syntax_tree_made(tmp: string)
  local root = started(tmp, "rows")
  -- the lookup makes the rows; `sql` stages nothing, and reads them
  holds((looked_up(root, tmp, { "docs", "Box" })), "shapes Shapes.Box")
  local symbols = looked_up(root, tmp, { "sql", "SELECT symbol, line FROM docs WHERE module = 'shapes' ORDER BY line, symbol" })
  holds(symbols, "Box\t4\n")
  holds(symbols, "Box.width\t6\n")
  holds(symbols, "Box.label\t8\n")
  holds(symbols, "Box.grow\t10\n")
  local uses = looked_up(root, tmp, { "sql", "SELECT symbol, from_file, line FROM uses WHERE module = 'shapes' ORDER BY symbol, line" })
  holds(uses, "Box.grow\tshapes_test.tl\t5\n")
  -- the working database holds the source the lookup parsed, one that only the lookup has seen
  local parsed = looked_up(root, tmp, { "sql", "--build",
    "SELECT count(*) FROM inputs i JOIN parsed p ON p.source_hash = i.source_hash WHERE i.file = 'shapes.tl'" })
  holds(parsed, "\n1\n")
  -- `db` reads the same database and finds it whole
  local databases, databases_err = looked_up(root, tmp, { "db" })
  holds(databases_err, "db: ")
  assert(databases:find("syntax error", 1, true) == nil, databases)
end

local function test_the_fork_reads_none_of_the_grammar_so_a_lookup_in_the_default_mode_finds_nothing_of_it(tmp: string)
  local root = started(tmp, "forked")
  local result, out, err = ran(root, tmp, "teal", { "docs", "Box" })
  -- it answers, from the binary's own databases and the last build, and says why the build did not happen
  assert(result.ok == false or out:find("Shapes.Box", 1, true) == nil, out)
  holds(err, "not rebuilt, answering from the last build")
  holds(err, "syntax error")
  assert(out:find("shapes Shapes.Box", 1, true) == nil, out)
end

local function test_a_lookup_answers_from_the_last_build_when_the_new_checker_refuses_a_module(tmp: string)
  local root = started(tmp, "refused")
  holds((looked_up(root, tmp, { "docs", "Box" })), "shapes Shapes.Box")
  local text = assert(Fs.read(root .. "/shapes.tl"))
  assert(Fs.write(root .. "/shapes.tl", (text:gsub("function Shapes.new%(width: integer%): Shapes.Box\n",
    "function Shapes.new(width: integer): Shapes.Box\n  local unused = 1\n"))))
  -- the refusal is said with the new checker's fix, and the answer is the last build's, as a build the fork stops leaves it
  local last, last_err = looked_up(root, tmp, { "docs", "Box" })
  holds(last_err, "docs: not rebuilt, answering from the last build: shapes.tl: the compiler refused it")
  holds(last_err, "shapes.tl:23:9: unused variable unused (unused_variable): name it `_` or `_unused`")
  holds(last, "shapes Shapes.Box")
  -- mended, it builds again and says nothing
  assert(Fs.write(root .. "/shapes.tl", text))
  local mended, mended_err = looked_up(root, tmp, { "docs", "Box.grow" })
  holds(mended, "Widens the box by `by`.")
  assert(mended_err:find("not rebuilt", 1, true) == nil, mended_err)
end

--- `text` with the words the translation of a Teal source to the new grammar changes set to the source's: a signature the new
--- checker reads is the translation's (`T | nil` is `T?`, a field the program changes is `mut`), as it is in every row of the
--- analysis ([`build.syntax_compared_analysis`] compares them by the words they hold).
local function spelled(text: string): string
  return (text:gsub("mut ", ""):gsub("(%S+) | nil", "%1?"))
end

--- A copy of the project of testdata/rehearsal, Teal both checkers read, under `tmp`, for a run in `grammar`.
local function teal_project(tmp: string, grammar: string): string
  local root = tmp .. "/teal-" .. grammar
  assert(Fs.copy_tree("testdata/rehearsal/project", root))
  local result, out, err = ran(root, tmp, grammar, { "test" })
  assert(result.ok, out .. err)
  return root
end

--- That `forked` and `new`, each built by its own checker, answer `question` the same, by the words of the source, with
--- something to compare: the output of the fork is not empty. The row count of what was compared.
local function same_answer(forked: string, new: string, tmp: string, question: {string}): integer
  local said = table.concat(question, " ")
  local fork_result, fork_out = ran(forked, tmp, "teal", question)
  local new_result, new_out = ran(new, tmp, "new", question)
  assert(fork_result.ok and new_result.ok, said)
  assert(fork_out ~= "", said .. " found nothing")
  assert(spelled(new_out) == spelled(fork_out), said .. "\nthe fork:\n" .. fork_out .. "\nthe new checker:\n" .. new_out)
  local _, rows = fork_out:gsub("\n", "")
  return rows
end

--- The same Teal is answered the same by either checker: every row the build recorded of the project of testdata/rehearsal,
--- the symbols documented and the uses, in one question each mode. The rows carry their file and line, in order.
local function test_the_rows_of_a_project_both_checkers_read_are_the_same_in_either_mode(tmp: string)
  local forked, new = teal_project(tmp, "teal"), teal_project(tmp, "new")
  local rows = same_answer(forked, new, tmp, { "sql",
    "SELECT 'docs', module, symbol, file, line FROM docs UNION ALL SELECT 'uses', module, symbol, from_file, line FROM uses " ..
      "WHERE from_module IN ('queue', 'queue_test', 'report', 'report_test') ORDER BY 1, 2, 3, 4, 5" })
  -- the project holds more rows than its few uses alone: a dimension that compared nothing fails
  assert(rows > 20, tostring(rows))
end

--- The same Teal is answered the same by either checker: what `docs` and `uses` say of the project of testdata/rehearsal in
--- each mode, over the questions below, every one of which finds something.
local function test_the_lookups_of_a_project_both_checkers_read_say_the_same_in_either_mode(tmp: string)
  local forked, new = teal_project(tmp, "teal"), teal_project(tmp, "new")
  local questions: {{string}} = { { "docs", "Report.of" }, { "uses", "Queue.new" } }
  local rows = 0
  for _, question in ipairs(questions) do
    rows = rows + same_answer(forked, new, tmp, question)
  end
  assert(rows >= #questions * 2, tostring(rows))
end
