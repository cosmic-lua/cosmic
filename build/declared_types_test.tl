--- The declarations of the tool's own modules tell the truth about nil: a
--- function declared to answer a value answers nil only where its type
--- says so, and a parameter a caller may leave out is optional. Each test drives the
--- paths where a value may be nil and asks a checked run
--- (`cosmic test --check-types`) whether a value crossed a typed boundary
--- under build/ as a kind its type does not admit; in any other run the
--- tests skip. The C rules, the importer and the spawn stand-in are in
--- build/c/declared_types_test.tl, build/importer_declared_types_test.tl
--- and build/confine_declared_types_test.tl, which declare what they read.
--- Until a compile writes the boundary checks (build/type_watch.tl), they skip in a checked run too.

local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local Fuzz = require("build.fuzz")
local alias_members = require("build.alias_members")
local Analyzer = require("build.syntax_analyzer")
local fetch = require("build.fetch")
local flow = require("build.flow")
local formats = require("build.cache_formats")
local invoke = require("build.invoke")
local maintenance = require("build.cache_maintenance")
local test = require("build.test")
local todo_scan = require("build.todo_scan")
local TypeWatch = require("build.type_watch")

Test.policy{ loopback = { "127.0.0.1" } }

--- Fails, listing what `during` met under build/, unless it met nothing.
local function honest(what: string, fn: function())
  local found = TypeWatch.during(fn, "build/")
  assert(#found == 0, what .. ": " .. #found .. " violations:\n" .. table.concat(found, "\n"))
end

--- A line that is no comment, a comment that carries on, and one that does
--- not answer a comment at all: the TODO scan reads each.
local function test_the_todo_scan_answers_a_comment_or_none()
  honest("todo_scan", function()
    local found = todo_scan.scan(table.concat({
      "local x = 1",
      "-- TODO: first,",
      "-- carried on.",
      "# not a marker we know",
      "-- TODO: second",
      "",
      "y = 2 -- TODO: after code is not found",
    }, "\n"))
    assert(#found == 2)
  end)
end

--- A selector that names no one test has no test name to answer.
local function test_a_selector_naming_no_test_is_as_declared()
  honest("test selectors", function()
    assert(test.matches("build/x_test.tl", "build/x_test.tl", "build/x_test.tl"))
    assert(not test.selects("build/x_test.tl", "build/y_test.tl", "build/y_test.tl", "test_a"))
    assert(test.selects("build/x_test.tl:test_a", "build.x_test", "build/x_test.tl", "test_a"))
  end)
end

--- A run of the binary's verb in this process: its descriptors are held
--- and put back.
local function test_a_run_in_process_holds_what_it_opens(tmp: string)
  honest("build.invoke", function()
    local result = invoke.run({ "-e", "print('out') return 3" }, { cwd = tmp })
    assert(result.code == 3 and result.stdout == "out\n")
  end)
end

--- A database that holds a table of a family the tool has no shape for.
local function test_a_cache_with_a_table_of_no_known_shape_is_as_declared(tmp: string)
  local path = tmp .. "/cache.db"
  honest("build.cache_maintenance", function()
    local db = assert(Sqlite.open(path, { writable = true }))
    for _, sql in ipairs(formats.compiles) do assert(db:exec(sql)) end
    assert(db:exec("CREATE TABLE compiled_v99 (key TEXT PRIMARY KEY, lua BLOB)"))
    assert(db:close())
    local result = maintenance.run({ family = "compiles", paths = { path }, since_ns = Clock.seconds(1), whole = false })
    assert(result.complete and #result.report.files[1].unknown_tables == 1)
  end)
end

--- A property with no directory keeps no input and names no case.
local function test_a_fuzz_property_with_no_directory_is_as_declared()
  honest("build.fuzz", function()
    local ran = Fuzz.run({
      name = "holds",
      iters = 3,
      gen = function(src: Fuzz.Source): string return Fuzz.bytes(src, 8) end,
      check = function(_input: string): boolean, string return true, "" end,
    })
    assert(ran == 3)
  end)
end

--- A fragment that reads as a checksum with no `=` in it, and one that
--- checks.
local function test_a_fetch_checksum_fragment_is_as_declared()
  honest("build.fetch", function()
    local url = "http://cosmic.test/data"
    local hex = string.rep("0", 64)
    local function run(words: {string}, script: {string}): integer
      local argv: mut {string} = { "fetch" }
      for _, word in ipairs(words) do argv[#argv + 1] = word end
      return fetch.run(argv, {
        script = script,
        out = function(_text: string): boolean, string return true, "" end,
        err = function(_line: string) end,
      })
    end
    assert(run({ url .. "#sha256" }, {}) == 2)
    assert(run({ url .. "#sha256=" .. hex }, {}) ~= 0)
  end)
end

--- `local a, b = require("cosmic.test")` binds the second name to nothing.
local function test_a_policy_read_from_a_source_with_fewer_values_is_as_declared()
  honest("build.syntax_analyzer", function()
    local found = Analyzer.analyze(table.concat({
      'local Test, other = require("cosmic.test")',
      "local function test_a() end",
    }, "\n"), "fixture.tl")
    assert(found ~= nil)
  end)
end

--- A reference that names none of the types a source holds, whether the
--- source says why or says nothing.
local function test_a_reference_naming_no_type_is_as_declared()
  honest("build.alias_members", function()
    local source: alias_members.Source<alias_members.Declared> = {
      declared = function(_module: string, _name: string): alias_members.Declared?, string
        return nil
      end,
      exported = function(_module: string, _name: string): alias_members.Declared?, string
        return nil
      end,
      bound = function(_module: string, _name: string): string?, string
        return nil
      end,
      under = function(_target: alias_members.Declared): {alias_members.Declared}?, string
        return {}
      end,
      as_member = function(_owner: alias_members.Declared, member: alias_members.Declared,
                           _name: string): alias_members.Declared
        return member
      end,
    }
    local alias: alias_members.Declared = { module = "m", symbol = "A", source_symbol = "A",
      kind = "alias", signature = "type A = Mod.Thing" }
    assert(alias_members.resolved(source, alias, "Mod.Thing") == nil)
  end)
end

--- Flow text with a comment after a token and one that stands alone.
local function test_flow_comments_are_as_declared()
  honest("build.flow", function()
    local text = table.concat({
      "{",
      "  # alone",
      "  name: \"ci\", # after",
      "  list: [1, 2], # after the list",
      "  last: true,",
      "}",
      "",
    }, "\n")
    assert(flow.format(text) ~= nil)
  end)
end
