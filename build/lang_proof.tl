--- The proof that the seed can build the new checker from its translated source (doc/plans/strict-teal.md, "the
--- switch"): `lang/` is translated into the new grammar ([`lang.translate`]), the steps the switch change makes by
--- hand are applied to the translation, it is compiled with `cosmic compile --grammar new` ([`build/compile.tl`]),
--- and the tests of `lang/` are run against the Lua that comes out, each test module in a process of its own.
---
---     bin/cosmic build/lang_proof_main.tl prove /tmp/proof [stem...]
---
--- writes the translation to `<dir>/src/lang`, the Lua to `<dir>/lua` and the complaints of the compile to
--- `<dir>/compile.log`, and prints one line for each test module; the exit is 0 where all of them pass. With
--- stems (`lexer`, `check_test`) only those files and the modules they require are built, and only the stems that
--- name test modules are run. A run of all of `lang/` is 65 files and takes about a minute.
---
--- The steps the switch makes by hand, applied here mechanically so that the proof can be repeated until it does:
---
--- - `where` clauses in lang/ast.tl and lang/types.tl, which the new grammar has no spelling of, are blanked
---   ([`LangProof.blank_where`]). The tags of the plan's tagged unions replace them.
--- - a test `x is Ast.Local` of a record those clauses told apart is written, by the code generator, as a test
---   that `x` is a table, since it reads one file and the clause is gone. [`LangProof.rewrite`] writes each as the
---   tag test the clause was (`(x.kind == "Local")`). `cosmic compile --grammar new` refuses such a test that it
---   is given, so a source that still has one fails loudly.
---
--- The declaration files of the standard library are not given: the Lua the seed writes does not depend on them.
---
--- With `--seed <cosmic>` (the pinned release, [`bin/cosmic-bootstrap`]) the same translation is compiled by that release
--- too, into `<dir>/seed`, and the Lua of each file is compared with what the tree's compile wrote: the files that
--- differ are the ones the emitter has moved ahead of the pin, and `lang/SEED_DIFFERS` lists them, one bare name a line
--- (`codegen.lua`), as checker/SEED_DIFFERS lists the files of the fork's checker the seed writes otherwise
--- (core/bridge.lua). The proof fails for a file that differs and is not listed, for a listed file that does not
--- differ, for a name that is no file of lang/, and for an empty list that is there; the pin move that takes a release
--- carrying the change empties the list. Until the switch (doc/plans/strict-teal.md, "the switch") the bridge, `build.zig`'s
--- `seedCompiler` and checker/SEED_DIFFERS are the fork's: this is the rehearsal of the seed the switch adds.

local Ast = require("lang.ast")
local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Translate = require("lang.translate")
local compile = require("build.compile")
local this_program = require("build.this_program")
local type Child = require("cosmic.child")

local record LangProof
  --- One tag test a `where` clause was: `x.<field> == "<value>"`, or `x.atom == true` for the clause of an atom.
  record Tag
    field: string
    value: string
  end

  --- What the clauses of a module tell apart: the tag tests of each record, and of each union of records, by name.
  type Tags = {string: {Tag}}

  --- The clauses of `ast` and `types`, the texts of lang/ast.tl and lang/types.tl, by module (`ast`, `types`).
  tags: function(ast: string, types: string): {string: Tags}

  --- A text and how many edits made it.
  record Edited
    text: string
    count: integer
  end

  --- `text` less its `where` clauses, each line left empty.
  blank_where: function(text: string): Edited

  --- `text`, the translation of the file `name` of lang/, with each test of a record `tags` tells apart written as
  --- its tag test, and how many it wrote. Another module's name is told by the local that requires it, and by
  --- `local type` aliases of it.
  rewrite: function(text: string, name: string, tags: {string: Tags}): Edited

  --- What `prepare` wrote.
  record Prepared
    --- The modules written, by stem.
    files: {string}
    --- How many tests of records were rewritten.
    rewritten: integer
  end

  --- Writes the translation of lang/ below `root` (the tree) to `out`/src/lang, all of it or the files `only` names
  --- with what they require.
  prepare: function(root: string, out: string, only: {string}): Prepared

  --- What `build` did.
  record Built
    --- The exit code of the compile.
    code: integer
    --- Its complaints, one per line.
    complaints: string
  end

  --- Compiles what `prepare` wrote.
  build: function(out: string, files: {string}): Built

  --- The names of the files of `files` (stems of lang/) whose Lua, `<stem>.lua`, differs between the directories `a` and
  --- `b`, as bare names in the order of `files`; a file one directory lacks differs.
  differing: function(files: {string}, a: string, b: string): {string}

  --- The names a text of lang/SEED_DIFFERS lists, one bare file name a line, blanks around it taken off.
  listed: function(text: string): {string}

  --- What is wrong with `declared` (the names of lang/SEED_DIFFERS) against `differ` (the files the seed writes otherwise),
  --- one line each: a file that differs and is not listed, a listed file that does not differ, a name that is none of `written`
  --- (the files compiled), and a file `present` that lists nothing. None where the two agree.
  judged: function(differ: {string}, declared: {string}, written: {string}, present: boolean): {string}

  --- The command line of [`build/lang_proof_main.tl`]: `prove <dir> [--seed <cosmic>] [stem...]` or `run <dir> <stem>`.
  main: function(argv: {string}): integer
end

local function lines_of(text: string): {string}
  local out: {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

function LangProof.blank_where(text: string): LangProof.Edited
  local out, count = text:gsub("\n[ \t]*where [^\n]*", "\n")
  return { text = out, count = count }
end

--- The union `name` of the members the words of `body` name, if every one is a record with a clause.
local function union_of(held: LangProof.Tags, name: string, body: string)
  local tests: {LangProof.Tag} = {}
  local whole = true
  for member in body:gmatch("[A-Za-z]+") do
    local sub = held[member]
    if sub == nil then
      whole = false
    else
      for _, t in ipairs(sub) do
        tests[#tests + 1] = t
      end
    end
  end
  if whole and held[name] == nil then
    held[name] = tests
  end
end

--- The tests of the records of one module's source, then its unions of them.
local function tags_of(text: string): LangProof.Tags
  local held: LangProof.Tags = {}
  local lines = lines_of(text)
  for index, line in ipairs(lines) do
    local name = line:match("^  record ([A-Za-z]+) is Base")
    local clause = lines[index + 1]
    if name ~= nil and clause ~= nil then
      local field, value = clause:match("^    where self%.(%a+) == \"([%w_]+)\"")
      if field ~= nil and value ~= nil then
        held[name] = { { field = field, value = value } }
      elseif clause:match("^    where self%.atom") ~= nil then
        held[name] = { { field = "atom", value = "" } }
      end
    end
  end
  -- A union may go on over lines that end in `|`.
  local pending: string | nil = nil
  local body = ""
  for _, line in ipairs(lines) do
    local name, rest = line:match("^  type ([A-Za-z]+) = (.*)$")
    if pending ~= nil then
      body = body .. " " .. (line:match("^%s*(.*)$") or "")
      if body:sub(-1) ~= "|" then
        union_of(held, pending, body)
        pending = nil
      end
    elseif name ~= nil and rest ~= nil then
      if rest:sub(-1) == "|" then
        pending = name
        body = rest
      else
        union_of(held, name, rest)
      end
    end
  end
  return held
end

function LangProof.tags(ast: string, types: string): {string: LangProof.Tags}
  return { ast = tags_of(ast), types = tags_of(types) }
end

--- The text a test of `operand` for `tests` is written as.
local function tag_test(operand: string, simple: boolean, tests: {LangProof.Tag}): string
  local subject = "v"
  if simple then
    subject = operand
  end
  local parts: {string} = {}
  for _, t in ipairs(tests) do
    if t.field == "atom" then
      parts[#parts + 1] = subject .. ".atom == true"
    else
      parts[#parts + 1] = subject .. "." .. t.field .. " == \"" .. t.value .. "\""
    end
  end
  local body = table.concat(parts, " or ")
  if simple then
    return "(" .. body .. ")"
  end
  return "(function(v: any): boolean return " .. body .. " end)(" .. operand .. ")"
end

--- One test written another way: the bytes `first` to `last`, now `text`.
local record Edit
  first: integer
  last: integer
  text: string
end

--- A type name of lang/ told by its module.
local record Member
  --- The module, "" where `own` and the locals that require a module or alias a type of one do not say.
  module: string
  name: string
end

--- The module and the name the type name `path` stands for.
local function member_of(path: {string}, own: string, qualifier: {string: string}, alias: {string: {string}}): Member
  local head = path[1]
  if head == nil then
    return { module = "", name = "" }
  end
  local second = path[2]
  if #path == 2 and second ~= nil then
    return { module = qualifier[head] or "", name = second }
  end
  local named = alias[head]
  if named ~= nil then
    local owner, what = named[1], named[2]
    if owner ~= nil and what ~= nil then
      return { module = qualifier[owner] or "", name = what }
    end
  end
  return { module = own, name = head }
end

--- The edit that writes the test `node` of a record `tags` tells apart as its tag test, or nil.
local function test_edit(text: string, chunk: Ast.Chunk, node: Ast.IsTest, tags: {string: LangProof.Tags},
                         own: string, qualifier: {string: string}, alias: {string: {string}}): Edit | nil
  local tested = node.type
  if not (tested is Ast.TypeName) then
    return nil
  end
  local member = member_of(tested.path, own, qualifier, alias)
  local tests: {LangProof.Tag} | nil = nil
  local table_of = tags[member.module]
  if table_of ~= nil then
    tests = table_of[member.name]
  end
  local tokens = chunk.tokens
  local first, last, whole_first, whole_last = node.value.first, node.value.last, node.first, node.last
  local count = Lexer.count(tokens)
  if tests == nil or first < 1 or last > count or whole_first < 1 or whole_last > count then
    return nil
  end
  local operand = text:sub(Lexer.offset(tokens, first), Lexer.stop(tokens, last) - 1)
  return {
    first = Lexer.offset(tokens, whole_first), last = Lexer.stop(tokens, whole_last) - 1,
    text = tag_test(operand, operand:match("^[%w_%.]+$") ~= nil, tests),
  }
end

function LangProof.rewrite(text: string, name: string, tags: {string: LangProof.Tags}): LangProof.Edited
  local parsed = Parser.parse(Lexer.lex(text, name), name, "tl")
  local chunk = parsed.chunk
  local qualifier: {string: string} = {}
  local alias: {string: {string}} = {}
  for q, m in text:gmatch("local ([A-Za-z_]+) = require%(\"lang%.(%a+)\"%)") do
    if m ~= nil then
      qualifier[q] = m
    end
  end
  for n, q, m in text:gmatch("local type ([A-Za-z_]+) = ([A-Za-z_]+)%.([A-Za-z_]+)") do
    if q ~= nil and m ~= nil then
      alias[n] = { q, m }
    end
  end
  local own = ""
  if name == "ast.tl" then
    own = "ast"
    qualifier["Ast"] = "ast"
  elseif name == "types.tl" then
    own = "types"
    qualifier["Types"] = "types"
  end
  local edits: {Edit} = {}
  -- Every node, the walk's own list growing as it goes.
  local nodes: {Ast.Node} = { chunk.body }
  for _, node in ipairs(nodes) do
    if node is Ast.IsTest then
      local edit = test_edit(text, chunk, node, tags, own, qualifier, alias)
      if edit ~= nil then
        edits[#edits + 1] = edit
      end
    end
    Ast.children(node, function(child: Ast.Node)
      nodes[#nodes + 1] = child
    end)
  end
  -- From the end, so that an edit moves none before it; a test inside another is in the text of the outer one.
  table.sort(edits, function(a: Edit, b: Edit): boolean
    return a.first > b.first
  end)
  local out = text
  local count = 0
  local limit = #text + 1
  for _, edit in ipairs(edits) do
    if edit.last < limit then
      out = out:sub(1, edit.first - 1) .. edit.text .. out:sub(edit.last + 1)
      limit = edit.first
      count = count + 1
    end
  end
  return { text = out, count = count }
end

--- The names `text` requires of lang/.
local function lang_requires(text: string): {string}
  local out: {string} = {}
  for name in text:gmatch("require%(\"lang%.([%w_]+)\"%)") do
    out[#out + 1] = name
  end
  return out
end

--- `text`, a translated test module, with a final `return` of its tests by name.
local function exporting(text: string): string
  local names: {string} = {}
  for _, line in ipairs(lines_of(text)) do
    local test = line:match("^local function (test_[%w_]*)%(")
    if test ~= nil then
      names[#names + 1] = test .. " = " .. test
    end
  end
  local end_of_line = text:sub(-1) == "\n" and "" or "\n"
  return text .. end_of_line .. "return { " .. table.concat(names, ", ") .. " }\n"
end

function LangProof.prepare(root: string, out: string, only: {string}): LangProof.Prepared
  local names: {string} = {}
  for _, name in ipairs((assert(Fs.list(root .. "/lang")))) do
    local stem = name:match("^(.*)%.tl$")
    if stem ~= nil then
      names[#names + 1] = stem
    end
  end
  table.sort(names, function(a: string, b: string): boolean
    return a < b
  end)
  local wanted: {string: boolean} = {}
  -- The stems asked for, then what each requires, the list growing as it is read.
  local reach: {string} = {}
  for _, stem in ipairs(only) do
    reach[#reach + 1] = stem
  end
  if #only == 0 then
    for _, stem in ipairs(names) do
      wanted[stem] = true
    end
  end
  for _, stem in ipairs(reach) do
    if wanted[stem] ~= true then
      wanted[stem] = true
      local text = (assert(Fs.read(root .. "/lang/" .. stem .. ".tl")))
      for _, dependency in ipairs(lang_requires(text)) do
        reach[#reach + 1] = dependency
      end
    end
  end
  local tags = LangProof.tags((assert(Fs.read(root .. "/lang/ast.tl"))), (assert(Fs.read(root .. "/lang/types.tl"))))
  assert(Fs.mkdirs(out .. "/src/lang"))
  local written: {string} = {}
  local rewritten = 0
  for _, stem in ipairs(names) do
    if wanted[stem] == true then
      local source = (assert(Fs.read(root .. "/lang/" .. stem .. ".tl")))
      local translated = Translate.translate(source, "lang/" .. stem .. ".tl")
      local text = translated.text
      if #translated.errors > 0 then
        text = LangProof.blank_where(text).text
      end
      local edited = LangProof.rewrite(text, stem .. ".tl", tags)
      rewritten = rewritten + edited.count
      local changed = edited.text
      if stem:match("_test$") ~= nil then
        changed = exporting(changed)
      end
      assert(Fs.write(out .. "/src/lang/" .. stem .. ".tl", changed))
      written[#written + 1] = stem
    end
  end
  return { files = written, rewritten = rewritten }
end

function LangProof.build(out: string, files: {string}): LangProof.Built
  assert(Fs.mkdirs(out .. "/lua"))
  local argv: {string} = {
    "compile", "--grammar", "new", "--errors", "--root", out .. "/src", "-o", out .. "/lua",
  }
  for index, stem in ipairs(files) do
    argv[8 + index] = out .. "/src/lang/" .. stem .. ".tl"
  end
  local complaints: {string} = {}
  local code = compile.run(argv, {
    out = function(_text: string): boolean, string return true, "" end,
    err = function(line: string) complaints[#complaints + 1] = line end,
  })
  return { code = code, complaints = table.concat(complaints, "\n") }
end

function LangProof.differing(files: {string}, a: string, b: string): {string}
  local out: {string} = {}
  for _, stem in ipairs(files) do
    local one, _ = Fs.read(a .. "/" .. stem .. ".lua")
    local other, _ = Fs.read(b .. "/" .. stem .. ".lua")
    if one == nil or other == nil or one ~= other then
      out[#out + 1] = stem .. ".lua"
    end
  end
  return out
end

function LangProof.listed(text: string): {string}
  local out: {string} = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^%s*(.-)%s*$") or ""
    if name ~= "" then
      out[#out + 1] = name
    end
  end
  return out
end

function LangProof.judged(differ: {string}, declared: {string}, written: {string}, present: boolean): {string}
  local out: {string} = {}
  local differs: {string: boolean} = {}
  for _, name in ipairs(differ) do
    differs[name] = true
  end
  local listed: {string: boolean} = {}
  for _, name in ipairs(declared) do
    listed[name] = true
  end
  local known: {string: boolean} = {}
  for _, stem in ipairs(written) do
    known[stem .. ".lua"] = true
  end
  for _, name in ipairs(declared) do
    if known[name] ~= true then
      out[#out + 1] = "lang/SEED_DIFFERS: " .. name .. " names no file lang/ compiles to: list bare output names, e.g. codegen.lua"
    end
  end
  for _, name in ipairs(differ) do
    if listed[name] ~= true then
      out[#out + 1] = "the seed writes " .. name .. " otherwise than the tree's compile of the same translation, and lang/SEED_DIFFERS " ..
        "does not list it: a seed that miscompiles, or a change to what the generator writes, which the file declares " ..
        "(one file name a line) until ci/cosmic-driver.pin names a release that carries it"
    end
  end
  for _, name in ipairs(declared) do
    if known[name] == true and differs[name] ~= true then
      out[#out + 1] = "lang/SEED_DIFFERS lists " .. name .. ", which the seed writes as the tree's compile does: remove it " ..
        "from the file, and the file once it lists nothing"
    end
  end
  if present and #declared == 0 then
    out[#out + 1] = "lang/SEED_DIFFERS lists no file: remove it"
  end
  return out
end

--- Compiles what `prepare` wrote with the release `seed` (`<seed> compile --grammar new`), into `<out>/seed`.
local function seeded(out: string, files: {string}, seed: string): LangProof.Built
  assert(Fs.mkdirs(out .. "/seed"))
  local argv: {string} = { seed, "compile", "--grammar", "new", "--errors", "--root", out .. "/src", "-o", out .. "/seed" }
  for _, stem in ipairs(files) do
    argv[#argv + 1] = out .. "/src/lang/" .. stem .. ".tl"
  end
  local result, trouble = Child.run(argv, { cwd = out, stdout = "capture", stderr = "capture" })
  if result == nil then
    return { code = 1, complaints = tostring(trouble) }
  end
  return { code = result.code or 1, complaints = (result.stderr or "") .. (result.stdout or "") }
end

--- What `run` found.
local record Ran
  passed: integer
  failures: {string}
end

--- The test modules the proof does not run, each with why: they load a module that reads a record through
--- `Shape.record_of("Name")`, which the build resolves in the source it compiles ([`build.syntax_shape_specs`]) and
--- `cosmic compile` does not, so its Lua raises when it is loaded.
--
-- TODO: run these once the proof resolves [`Shape.record_of`] in the translation it compiles ([`build.tree_program`]'s
-- `splice`), or once `cosmic compile` does: the seed step of the switch compiles lang/ with `compile` and would write a
-- lang/check_verdicts.lua that raises when it is loaded.
local UNRESOLVED <const>: {string: string} = {
  check_verdicts_test = "lang/check_verdicts.tl reads its records through Shape.record_of, which `cosmic compile` leaves unresolved",
}

--- Runs the tests of the compiled module `stem` (a `_test` module of lang/), in this process, which must run
--- no other module's tests: a module may declare its policy once.
local function run(out: string, stem: string): Ran
  local lua_dir = out .. "/lua/"
  for _, file in ipairs((assert(Fs.list(lua_dir)))) do
    local module = file:match("^(.*)%.lua$")
    if module ~= nil then
      package.preload["lang." .. module] = function(...: any): any
        local text = (assert(Fs.read(lua_dir .. file)))
        local chunk, why = load(text, "=" .. file, "t")
        if chunk == nil then
          error("load " .. file .. ": " .. tostring(why))
        end
        return chunk(...)
      end
    end
  end
  local request: function(string): any = require
  local loaded = request("lang." .. stem)
  assert(loaded is {string: function(string)}, stem .. " exports no tests")
  local names: {string} = {}
  for name in pairs(loaded) do
    names[#names + 1] = name
  end
  table.sort(names, function(a: string, b: string): boolean
    return a < b
  end)
  local passed = 0
  local failures: {string} = {}
  for _, name in ipairs(names) do
    local tmp = out .. "/tmp/" .. stem .. "-" .. name
    assert(Fs.mkdirs(tmp))
    local test = loaded[name]
    if test ~= nil then
      local ok = xpcall(test, function(why: any): any
        failures[#failures + 1] = name .. ": " .. tostring(why)
        return why
      end, tmp)
      if ok then
        passed = passed + 1
      end
    end
  end
  return { passed = passed, failures = failures }
end

--- Runs the tests of `stem` in a process of its own, and answers its last line and whether it passed.
local function run_in_process(out: string, stem: string): string, boolean
  local started = this_program.program({ "build/lang_proof_main.tl", "run", out, stem }, {
    stdout = "capture", stderr = "capture",
  })
  local result = assert(Child.run(started.argv, started.options))
  local text = (result.stdout or "") .. (result.stderr or "")
  local last = ""
  for _, line in ipairs(lines_of(text)) do
    if line ~= "" then last = line end
  end
  return last, result.code == 0
end

--- Compiles `files` with the release `seed`, and holds the files that differ from the tree's compile to lang/SEED_DIFFERS.
--- The number of problems it printed. With `whole` (all of lang/ was built) the list is held both ways; a part only says
--- which of its files differ.
local function compare_with_seed(out: string, files: {string}, seed: string, whole: boolean): integer
  local built = seeded(out, files, seed)
  assert(Fs.write(out .. "/seed.log", built.complaints .. "\n"))
  print(seed .. " compile --grammar new: exit " .. tostring(built.code) .. " (" .. out .. "/seed.log)")
  if built.code ~= 0 then
    print("the seed cannot build the translation of lang/; the switch waits on a pin that can")
    return 1
  end
  local differ = LangProof.differing(files, out .. "/lua", out .. "/seed")
  print("the seed writes " .. String.counted(#differ, "file") .. " of " .. tostring(#files) ..
      " otherwise than the tree's compile: " .. table.concat(differ, ", "))
  if not whole then
    return 0
  end
  local text, _ = Fs.read("lang/SEED_DIFFERS")
  local problems = LangProof.judged(differ, LangProof.listed(text or ""), files, text ~= nil)
  for _, problem in ipairs(problems) do
    print(problem)
  end
  return #problems
end

function LangProof.main(argv: {string}): integer
  local command, out = argv[1], argv[2]
  if out == nil then
    print("usage: bin/cosmic build/lang_proof_main.tl prove <dir> [--seed <cosmic>] [stem...] | run <dir> <stem>")
    return 2
  end
  if command == "run" then
    local stem = argv[3]
    if stem == nil then
      print("run needs the stem of a test module")
      return 2
    end
    local ran = run(out, stem)
    for _, failure in ipairs(ran.failures) do
      print("FAIL " .. failure)
    end
    print(stem .. ": " .. tostring(ran.passed) .. " passed, " .. tostring(#ran.failures) .. " failed")
    return #ran.failures == 0 and 0 or 1
  end
  local only: {string} = {}
  local seed: string | nil = nil
  local index = 3
  while argv[index] ~= nil do
    if argv[index] == "--seed" then
      seed = argv[index + 1]
      if seed == nil then
        print("--seed needs the cosmic to compile with")
        return 2
      end
      index = index + 2
    else
      only[#only + 1] = assert(argv[index])
      index = index + 1
    end
  end
  local prepared = LangProof.prepare(".", out, only)
  local files = prepared.files
  print("translated " .. String.counted(#files, "file") .. ", rewrote " .. String.counted(prepared.rewritten, "test") ..
      " of records")
  local built = LangProof.build(out, files)
  assert(Fs.write(out .. "/compile.log", built.complaints .. "\n"))
  print("cosmic compile --grammar new: exit " .. tostring(built.code) .. " (" .. out .. "/compile.log)")
  if built.code ~= 0 then
    return 1
  end
  local named: {string: boolean} = {}
  for _, stem in ipairs(only) do
    named[stem] = true
  end
  local failed = 0
  for _, stem in ipairs(files) do
    if stem:match("_test$") ~= nil and (#only == 0 or named[stem] == true) then
      local unresolved = UNRESOLVED[stem]
      if unresolved ~= nil then
        print(stem .. ": not run: " .. unresolved)
      else
        local line, ok = run_in_process(out, stem)
        print(line)
        if not ok then failed = failed + 1 end
      end
    end
  end
  if seed ~= nil then
    failed = failed + compare_with_seed(out, files, seed, #only == 0)
  end
  return failed == 0 and 0 or 1
end

return LangProof
