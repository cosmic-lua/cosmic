--- `cosmic test`'s own pieces, held directly: how a selector chooses a
--- test, how a failing one is named to be run again, and what the
--- harness's digest holds.

local Clock = require("cosmic.clock")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local type PolicyRules = require("build.policy_rules")
local type plans = require("build.plans")
local test = require("build.test")
local type test_state = require("build.test_state")
local lua_tail = require("build.lua_tail")
local test_key = require("build.test_key")
local test_report = require("build.test_report")
local work = require("build.work")
local worker = require("build.test_worker")
local support = require("build.test_support_fixture")

local function test_a_run_that_names_tests_is_failed_by_the_refusals_of_the_files_it_names_alone()
  local lines = {
    "cosmic/removed_example.tl:279:3: `function Friendly:greet` is not in the grammar (method_in_record): declare it",
    "build/one.tl: the compiler refused it\nbuild/one.tl:1:1: wrong (code): fix",
    "build/one_test.tl: not compiled: it requires build.one, which the new checker refused",
  }
  assert(#test.refusals_of(lines, {}) == 3, "a run that names nothing is failed by every refusal")
  assert(#test.refusals_of(lines, { "build/other_test.tl" }) == 0)
  assert(#test.refusals_of(lines, { "build/one_test.tl" }) == 1)
  assert(#test.refusals_of(lines, { "build" }) == 2)
  assert(test.refusals_of(lines, { "cosmic" })[1] == lines[1])
  assert(#test.refusals_of(lines, { "build/one_test.tl:test_it" }) == 1, "a selector that names a test is its module's")
end

local function test_a_named_file_that_did_not_compile_is_shown_the_refusals_it_rests_on_first()
  local lines = {
    "build/one_test.tl: not compiled: it requires build.one, which the new checker refused",
    "build/one.tl: the compiler refused it\nbuild/one.tl:1:1: wrong (code): fix",
    "build/two.tl: the compiler refused it\nbuild/two.tl:1:1: also wrong (code): fix",
    "build/mid.tl: not compiled: it requires build.one, which the new checker refused",
  }
  local roots = { ["build/one_test.tl"] = { 2 }, ["build/one.tl"] = { 2 }, ["build/two.tl"] = { 3 },
    ["build/mid.tl"] = { 2, 3 } }
  local explained = test.explained(lines, roots, { "build/one_test.tl" })
  local shown = explained.lines
  assert(#shown == 2 and shown[1] == lines[2] and shown[2] == lines[1], table.concat(shown, "|"))
  assert(explained.matched["build/one_test.tl"] == true)
  -- A directory choosing the root and its dependents shows each line once, roots ahead of dependents.
  local whole = test.explained(lines, roots, { "build" }).lines
  assert(#whole == 4 and whole[1] == lines[2] and whole[2] == lines[3], table.concat(whole, "|"))
  local mid = test.explained(lines, roots, { "build/mid.tl" }).lines
  assert(#mid == 3 and mid[1] == lines[2] and mid[2] == lines[3] and mid[3] == lines[4], table.concat(mid, "|"))
  local none = test.explained(lines, roots, { "build/absent_test.tl" })
  assert(#none.lines == 0 and none.matched["build/absent_test.tl"] == nil)
end

--- A run shows the refusals it fails for with the roots apart from the files that only require one: all of them for a
--- run that names nothing, and for one that names files, theirs and the roots they rest on.
local function test_a_run_shows_the_refusals_it_fails_for_roots_apart_from_dependents()
  local lines = {
    "build/one_test.tl: not compiled: it requires build.one, which the new checker refused",
    "build/one.tl: the compiler refused it\nbuild/one.tl:1:1: wrong (code): fix",
    "build/two.tl: the compiler refused it\nbuild/two.tl:1:1: also wrong (code): fix",
    "build/mid.tl: not compiled: it requires build.one, which the new checker refused",
  }
  local roots = { ["build/one_test.tl"] = { 2 }, ["build/one.tl"] = { 2 }, ["build/two.tl"] = { 3 },
    ["build/mid.tl"] = { 2, 3 } }
  local whole = test.cascade(lines, roots, {})
  assert(#whole.roots == 2 and whole.roots[1] == lines[2], table.concat(whole.roots, "|"))
  assert(table.concat(whole.dependents, " ") == "build/one_test.tl build/mid.tl")
  local named = test.cascade(lines, roots, { "build/one_test.tl" })
  assert(#named.roots == 1 and named.roots[1] == lines[2] and table.concat(named.dependents) == "build/one_test.tl")
end

local function test_selection_is_exact_or_at_a_directory_boundary()
  assert(test.matches("build.test_test", "build.test_test", "build/test_test.tl"))
  assert(test.matches("build/test_test.tl", "build.test_test", "build/test_test.tl"))
  assert(test.matches("./build", "build.test_test", "build/test_test.tl"))
  assert(test.matches("./build/", "build.test_test", "build/test_test.tl"))
  assert(test.matches(".", "build.test_test", "build/test_test.tl"))
  assert(test.matches("./", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("/", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("test_test", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("build/test", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("build", "builder.other_test", "builder/other_test.tl"))
end

--- A worker's load hits and test hits of one module are two lines of its
--- row, each naming the module's text, the run's hits hold their union, and
--- a table taken before is not folded or spelled again.
local function test_a_modules_load_and_test_hits_are_two_lines_of_its_row()
  local hits: mut {string:mut {integer:boolean}} = {}
  local folded: {{integer:boolean}:boolean} = {} -- declared: key_type
  local spelled: {{integer:boolean}:string} = {} -- declared: key_type
  local loaded: {integer:boolean} = { [3] = true, [1] = true }
  local texts = { ["build.a"] = "0123abcd" }
  local row = test.take_hits(hits, { ["core"] = {} }, folded, spelled,
    { ["build.a"] = loaded, ["core"] = { [9] = true } }, { ["build.a"] = { [7] = true } }, texts)
  assert(row == "build.a 0123abcd\t1,3\nbuild.a 0123abcd\t7\n", row)
  local taken = assert(hits["build.a"], "build.a is taken")
  assert(taken[1] == true and taken[3] == true and taken[7] == true)
  assert(hits["core"] == nil)
  taken[1] = nil
  row = test.take_hits(hits, {}, folded, spelled, { ["build.a"] = loaded }, {}, texts)
  local retaken = hits["build.a"]
  assert(row == "build.a 0123abcd\t1,3\n" and retaken ~= nil and retaken[1] == nil, "a taken table is folded once")
  local again = test.take_hits({}, {}, {}, {}, { ["build.a"] = loaded }, {}, texts)
  assert(again == row)
  -- A path that is no module of the run (the core's C) names no text: the key holds it.
  assert(test.take_hits({}, {}, {}, {}, { ["core/a.c"] = { [2] = true } }, {}, texts) == "core/a.c -\t2\n")
end

--- A worker given a pure store reports the lines of an imported module's numbered chunk as instruction ordinals
--- ([`lua_tail.numbered`]), placed at the source lines this run's text gives each instruction; a module's own lines
--- and those of a module with no ordinal are left as they are, the same table for the same table, and an ordinal
--- that cannot be placed is dropped and named, never put on another line.
local function test_a_pure_stores_instruction_ordinals_are_placed_at_this_runs_lines()
  local base = lua_tail.ordinal_base
  local lines: {string:{integer}} = { ["build.lib"] = { 4, 4, 9 } }
  local asked = 0
  local function lines_of(path: string): {integer}?, string
    asked = asked + 1
    local known = lines[path]
    if known == nil then return nil, "no module of the projection" end
    return known, ""
  end
  local modules = { ["build.lib"] = "0123abcd", ["build.lib_test"] = "4567cdef", ["build.gone"] = "89abcdef" }
  local placed: mut {string:mut {test_state.Placed}} = {}
  local unplaced: mut {string:string} = {}
  local plain: {string:{integer:boolean}} = { ["build.lib_test"] = { [2] = true } }
  local same = test.place_hits(plain, modules, lines_of, placed, unplaced)
  assert(same.hits == plain and same.whole, "hits with no ordinal were made again")
  local loaded: {integer:boolean} = { [base + 1] = true, [base + 3] = true }
  local hits: {string:{integer:boolean}} = { ["build.lib"] = loaded, ["build.lib_test"] = { [2] = true } }
  local placing = test.place_hits(hits, modules, lines_of, placed, unplaced)
  local out = placing.hits
  assert(placing.whole, "hits every one of which was placed are said not to be")
  local lib = assert(out["build.lib"], "the library's hits are dropped")
  assert(lib[4] == true and lib[9] == true and lib[base + 1] == nil and lib[1] == nil, "an ordinal is not placed at its line")
  assert(out["build.lib_test"] == hits["build.lib_test"], "the test's own lines were made again")
  local again = test.place_hits({ ["build.lib"] = loaded }, modules, lines_of, placed, unplaced).hits
  assert(again["build.lib"] == lib and asked == 1, "the same table of hits was placed twice")
  assert(next(unplaced) == nil)
  local past_hits: {integer:boolean} = { [base + 4] = true, [5] = true }
  local past = test.place_hits({ ["build.lib"] = past_hits }, modules, lines_of, placed, unplaced)
  local kept = assert(past.hits["build.lib"])
  assert(not past.whole, "hits some of which were dropped are said to be whole")
  -- The same table again, remembered placed, is still said not to be whole: its test keeps no verdict either.
  assert(not test.place_hits({ ["build.lib"] = past_hits }, modules, lines_of, placed, unplaced).whole, "a remembered table some of whose hits were dropped is said to be whole")
  assert(kept[5] == true and kept[4] == nil and kept[9] == nil, "an ordinal past the instructions was put on a line")
  assert(unplaced["build.lib"] ~= nil, "an ordinal past the instructions was dropped unsaid")
  local gone = test.place_hits({ ["build.gone"] = { [base + 1] = true } }, modules, lines_of, placed, unplaced)
  assert(next(assert(gone.hits["build.gone"])) == nil and unplaced["build.gone"] == "no module of the projection")
  assert(not gone.whole)
  -- The run says so, a line each, with why, and that no verdict of a test that reached them is kept.
  local said = test.unplaced_errors(unplaced)
  assert(#said == 2 and said[1] == "coverage: the hits of build.gone are not placed at its lines: no module of " ..
      "the projection; no verdict of a test that reached them is kept", table.concat(said, "\n"))
  assert(said[2]:find("^coverage: the hits of build%.lib are not placed at its lines: line %d+ is past " ..
      "the module's 3 instructions") ~= nil, table.concat(said, "\n"))
  assert(#test.unplaced_errors({}) == 0)
  -- A chunk the test numbers itself is no module of the run, and its lines are kept as no module's are.
  local own: {string:{integer:boolean}} = { ["m"] = { [base + 1] = true } }
  local own_out = test.place_hits(own, modules, lines_of, placed, unplaced)
  assert(own_out.hits == own and own_out.whole and unplaced["m"] == nil)
end

--- A traceback's frame of a function of a pure store's import names it by the instruction before its first, which
--- is shown at the module's file and the line this run's text defines the function on; a frame of another chunk, one
--- no function starts at, and a message's position (which a numbered chunk writes as -1) are left as they are.
local function test_a_frame_of_a_numbered_chunk_is_shown_at_the_line_its_function_is_defined_on()
  local base = lua_tail.ordinal_base
  -- The function whose first instruction is the second is defined on line 8.
  local function defined_of(path: string): {integer:integer}?, string
    if path == "build.lib" then return { [1] = 8 }, "" end
    return nil, "no module of the projection"
  end
  local files = { ["build.lib"] = "build/lib.tl", ["build.gone"] = "build/gone.tl" }
  local said = "build.lib:-1: attempt to index a nil value\n" ..
    "  build.lib_test:7: in function <build.lib_test:5>\n" ..
    "  build.gone: in function <build.gone:" .. tostring(base + 1) .. ">\n" ..
    "  build.lib: in function <build.lib:" .. tostring(base + 1) .. ">\n" ..
    "  build.lib: in function <build.lib:" .. tostring(base + 2) .. ">"
  local shown = test.placed_positions(said, files, defined_of)
  assert(shown == "build.lib:-1: attempt to index a nil value\n" ..
      "  build.lib_test:7: in function <build.lib_test:5>\n" ..
      "  build.gone: in function <build.gone:" .. tostring(base + 1) .. ">\n" ..
      "  build.lib: in function <build/lib.tl:8>\n" ..
      "  build.lib: in function <build.lib:" .. tostring(base + 2) .. ">",
    shown)
end

--- A standing row's lines are credited only for the modules whose text it
--- names is still this run's. A comment that moves a harness module's lines
--- moves no key, so a row written before it numbers lines the text no longer
--- has there: those are dropped and the module named stale, as is every
--- module of a row too old to name its text. The core's C is credited as it
--- stands, its text held by the key.
local function test_standing_hits_of_a_module_whose_text_moved_are_dropped_and_counted()
  local function module(path: string, hash: string): plans.Module
    return { path = path, file = path, kind = "lib", source = "", source_hash = hash, requires = {}, tests = {}, inputs = nil }
  end
  local texts = test.identities({ module("build.moved", string.rep("b", 64)),
    module("build.same", string.rep("c", 64)) })
  assert(texts["build.same"] == string.rep("c", 16), texts["build.same"])
  local row = "build.moved " .. string.rep("a", 16) .. "\t4,5\n" ..
    "build.same " .. string.rep("c", 16) .. "\t1,2\n" ..
    "core/a.c -\t9\n" .. "core/b.c\t8\n" ..
    "build.old\t3\n"
  local hits: mut {string:mut {integer:boolean}} = {}
  local stale: mut {string:string} = {}
  local kept = test.decode_hits(row, hits, texts, stale)
  assert(hits["build.moved"] == nil, "a module numbered in another text is credited no line")
  local same = assert(hits["build.same"], "a module of the same text is credited")
  assert(same[1] == true and same[2] == true)
  assert(assert(hits["core/a.c"])[9] == true and assert(hits["core/b.c"])[8] == true,
    "the core's C is credited as it stands")
  assert(stale["build.moved"] == test_report.other_text and stale["build.same"] == nil, "the moved module is stale")
  assert(hits["build.old"] ~= nil and stale["build.old"] == nil,
    "a path that is no module of this run is no figure's, and folded as it stands")
  -- A row from before rows named their text names a module of this run: stale.
  local before: mut {string:string} = {}
  local _ = test.decode_hits("build.same\t1,2\n", {}, texts, before)
  assert(before["build.same"] == test_report.other_text, "a row naming no text credits no module")
  -- A path may hold a space: only a last word of 16 hex digits (or "-") is a text.
  local spaced = test.identities({ module("suite.he lper", string.rep("d", 64)) })
  local old_spaced: mut {string:string} = {}
  local old_hits: mut {string:mut {integer:boolean}} = {}
  local _ = test.decode_hits("suite.he lper\t3\n", old_hits, spaced, old_spaced)
  assert(old_spaced["suite.he lper"] == test_report.other_text and old_hits["suite.he lper"] == nil and old_hits["suite.he"] == nil,
    "an old row of a path with a space was read as naming a text")
  local new_hits: mut {string:mut {integer:boolean}} = {}
  local _ = test.decode_hits("suite.he lper " .. string.rep("d", 16) .. "\t3\n", new_hits, spaced, {})
  assert(assert(new_hits["suite.he lper"])[3] == true, "a row of a path with a space naming its text is credited")
  assert(kept == row, "the row is kept as written, so a run standing on it drops the same lines: " .. kept)
  -- A share keeps no line of the core's C another project owns.
  local unowned_kept = test.decode_hits(row, {}, texts, {}, { ["core/a.c"] = {}, ["core/b.c"] = {} })
  assert(unowned_kept:find("core/", 1, true) == nil and unowned_kept:find("build.moved", 1, true) ~= nil, unowned_kept)
end

--- A pure store's import is reported by instruction, and its row keeps the
--- ordinals, named by the module's stripped bytecode, not the lines this run
--- placed them at: a comment above them later moves the lines and not the
--- key, and a run standing on the row places each ordinal at the line its own
--- text has it on, so the module is credited and not stale. The row names no
--- text, so a decoder that reads a row's numbers as lines (an older tool's,
--- or the line path here, given no bytecode) drops it as of another text and
--- never credits an ordinal as a line. An ordinal the run cannot place is
--- dropped, and the module named stale with why.
local function test_a_standing_rows_ordinals_are_placed_at_the_lines_of_this_runs_text()
  local base = lua_tail.ordinal_base
  local text, code = string.rep("d", 16), string.rep("c", 16)
  local reported: {integer:boolean} = { [base + 1] = true, [base + 3] = true }
  local placed: {integer:boolean} = { [4] = true, [9] = true }
  local hits: mut {string:mut {integer:boolean}} = {}
  local codes = { ["build.lib"] = code }
  local row = test.take_hits(hits, {}, {}, {}, { ["build.lib"] = reported, ["build.lib_test"] = { [2] = true } }, {},
    { ["build.lib"] = text, ["build.lib_test"] = text }, { ["build.lib"] = placed }, {}, codes)
  assert(row == "build.lib " .. code .. "\t" .. tostring(base + 1) .. "," .. tostring(base + 3) .. "\n" ..
      "build.lib_test " .. text .. "\t2\n", row)
  local folded = assert(hits["build.lib"], "the placed lines are not folded")
  assert(folded[4] == true and folded[9] == true and folded[base + 1] == nil, "the run's figure holds an ordinal")
  -- With no bytecode to name, the row keeps the lines placed, under the module's text.
  local plain = test.take_hits({}, {}, {}, {}, { ["build.lib"] = reported }, {}, { ["build.lib"] = text },
    { ["build.lib"] = placed }, {})
  assert(plain == "build.lib " .. text .. "\t4,9\n", plain)
  -- Later, a comment above the module's code: its text is another, its instructions one line lower.
  local now = { ["build.lib"] = string.rep("e", 16) }
  local function lines_of(path: string): {integer}?, string
    if path == "build.lib" then return { 5, 5, 10 }, "" end
    return nil, "no module of the projection"
  end
  local credited: mut {string:mut {integer:boolean}} = {}
  local stale: mut {string:string} = {}
  local kept = test.decode_hits(row, credited, now, stale, nil, lines_of, codes)
  local lib = assert(credited["build.lib"], "a standing row's ordinals are credited no line")
  assert(lib[5] == true and lib[10] == true and lib[4] == nil and lib[9] == nil, "an ordinal is not placed at this run's line")
  assert(stale["build.lib"] == nil, "a module whose ordinals were all placed is stale")
  assert(kept == row, kept)
  -- The line path, which an older tool's decoder is: the row names another text than the module's, even where
  -- the text is unchanged, so it is dropped as such and no ordinal is credited as a line.
  local lined: mut {string:mut {integer:boolean}} = {}
  local lined_stale: mut {string:string} = {}
  local _ = test.decode_hits(row, lined, { ["build.lib"] = text }, lined_stale, nil, lines_of)
  assert(lined["build.lib"] == nil and lined_stale["build.lib"] == test_report.other_text,
    "a row of ordinals was read as lines")
  -- One past the instructions, or with nothing to place it by, is dropped, never put on a line, and why is said.
  local past: mut {string:mut {integer:boolean}} = {}
  local past_stale: mut {string:string} = {}
  local _ = test.decode_hits("build.lib " .. code .. "\t" .. tostring(base + 1) .. "," .. tostring(base + 4) .. "\n",
    past, now, past_stale, nil, lines_of, codes)
  local some = assert(past["build.lib"])
  local count = 0
  for _ in pairs(some) do count = count + 1 end
  assert(some[5] == true and count == 1, "an ordinal past the instructions was credited")
  assert(past_stale["build.lib"] == "were not placed at its lines: line " .. tostring(base + 4) ..
      " is past the module's 3 instructions", past_stale["build.lib"])
  local gone: mut {string:mut {integer:boolean}} = {}
  local gone_stale: mut {string:string} = {}
  local _ = test.decode_hits(row, gone, now, gone_stale, nil, function(_: string): {integer}?, string
    return nil, "no module of the projection"
  end, codes)
  assert(gone["build.lib"] == nil and gone_stale["build.lib"] == "were not placed at its lines: no module of the " ..
      "projection", gone_stale["build.lib"])
end

--- The first progress line of a run that names the longest-running tests
--- points at where every test's time is; the later ones do not.
local function test_the_first_longest_running_line_says_where_every_tests_time_is()
  local first = test.longest_detail("a 31 s", false)
  assert(first:find("^longest running: a 31 s; every test's time: cosmic sql %-%-build \"select ") ~= nil, first)
  assert(first:find("from runs order by elapsed_ns desc", 1, true), first)
  assert(test.longest_detail("a 61 s", true) == "longest running: a 61 s")
end

--- `--shard I/N` names one of N shares, from 1; nothing else does.
local function test_a_shard_is_one_of_n_shares_from_one()
  local shard = assert(test.shard("2/3"))
  assert(shard.index == 2 and shard.count == 3)
  shard = assert(test.shard("1/1"))
  assert(shard.index == 1 and shard.count == 1)
  for _, text in ipairs({ "0/2", "3/2", "1/0", "2", "/2", "1/", "-1/2", "1.5/2",
      "1/2/3", " 1/2", "99999999999999999999/99999999999999999999" }) do
    local refused, why = test.shard(text)
    assert(refused == nil and why:find("--shard must be I/N", 1, true) ~= nil, text)
  end
end

--- The N shares of one run's tests hold each test once, whatever order
--- they come in, spread every module's tests across them, and differ
--- in size by one at most.
local function test_the_shares_deal_each_test_once()
  local ids: mut {string} = {}
  for module = 1, 5 do
    for name = 1, module * 3 do
      ids[#ids + 1] = string.format("m%d test_%02d", module, name)
    end
  end
  local reversed: mut {string} = {}
  for i = #ids, 1, -1 do reversed[#reversed + 1] = support.nth(ids, i) end
  for count = 1, 4 do
    local held: mut {string:integer} = {}
    local sizes: mut {integer} = {}
    for index = 1, count do
      local dealt = test.dealt(ids, { index = index, count = count })
      local again = test.dealt(reversed, { index = index, count = count })
      local size = 0
      local modules: mut {string:boolean} = {}
      for id in pairs(dealt) do
        assert(again[id], id .. " is dealt by the order the ids came in")
        held[id] = (held[id] or 0) + 1
        size = size + 1
        modules[assert(id:match("^(%S+)"), id .. " names a module")] = true
      end
      for id in pairs(again) do assert(dealt[id], id) end
      sizes[#sizes + 1] = size
      -- m5's fifteen tests reach every share.
      assert(modules.m5, "share " .. tostring(index) .. " of " .. tostring(count) .. " holds none of m5") -- checked: map_field
    end
    for _, id in ipairs(ids) do
      assert(held[id] == 1, id .. " is in " .. tostring(held[id]) .. " of " .. tostring(count) .. " shares")
    end
    table.sort(sizes)
    assert(support.nth(sizes, #sizes) - support.nth(sizes, 1) <= 1, "shares of " .. tostring(count) .. " differ by more than one")
  end
end

--- The census says a key's harness parts as one word, which a report
--- compares whole (ci/cosmic_ci/report.tl) and reads as the rest of a
--- part, up to a space: two bumps of the epoch from one count say
--- a moved harness, as another timeout does.
local function test_the_census_says_each_bump_of_the_epoch_apart()
  local word = test_key.harness_word("8-072f7458", Clock.seconds(30))
  assert(word == "e8-072f7458-t" .. tostring(Clock.seconds(30)), word)
  assert(word:match("^%S+$") and not word:find("[,;]"), word)
  assert(test_key.harness_word("8-3f9c2a1b", Clock.seconds(30)) ~= word, "two bumps from one count")
  assert(test_key.harness_word("8-072f7458", Clock.seconds(60)) ~= word, "another timeout")
end

local function test_a_selector_can_name_one_test_of_one_module()
  local path, file = "build.test_test", "build/test_test.tl"
  assert(test.selects("build/test_test.tl:test_a", path, file, "test_a"))
  assert(test.selects("./build/test_test.tl:test_a", path, file, "test_a"))
  assert(test.selects("build.test_test:test_a", path, file, "test_a"))
  assert(not test.selects("build/test_test.tl:test_a", path, file, "test_b"))
  assert(not test.selects("build/test_test.tl:test_a", path, file, "test_ab"))
  assert(test.selects("build/test_test.tl", path, file, "test_b"))
  -- A named test is looked for in one module, never under a directory.
  assert(not test.matches("build:test_a", path, file))
  assert(not test.matches(".:test_a", path, file))
  assert(test.matches("build/test_test.tl:test_a", path, file))
  assert(test.selects("cosmic/hash_example.tl:hex_sha256", "cosmic.hash_example",
    "cosmic/hash_example.tl", "hex_sha256"))
  assert(test.selects("cosmic/hash_example.tl:Example.hex_sha256", "cosmic.hash_example",
    "cosmic/hash_example.tl", "hex_sha256"))
  assert(not test.selects("cosmic/hash_example.tl:Example.hex_sha256",
    "cosmic.hash_example", "cosmic/hash_example.tl", "digest"))
end

local function test_only_a_name_after_the_last_colon_names_a_test()
  assert(test.selects("a:b/c_test.tl:test_a", "a:b.c_test", "a:b/c_test.tl", "test_a"))
  assert(not test.selects("a:b/c_test.tl:test_a", "a:b.c_test", "a:b/c_test.tl", "test_b"))
  -- Anything else after the last `:` leaves the selector a path whole:
  -- each one selects the module it spells, and not another's.
  for _, whole in ipairs({ "C:\\dir\\x_test.tl", "a:b/c_test.tl", ":test_a",
      "x_test.tl:", "x_test.tl:Other.a", "x_test.tl:1a" }) do
    assert(test.selects(whole, "x_test", whole, "test_a"), whole)
    assert(not test.matches(whole, "x_test", "x_test.tl"), whole)
  end
end

local function test_a_refused_name_is_shown_the_nearest_names_first()
  local near = test.nearest("test_rows", { "test_b", "test_rows_escaped", "test_a",
    "test_row" })
  assert(table.concat(near, " ") == "test_rows_escaped test_row test_a test_b",
    table.concat(near, " "))
  local many: mut {string} = {}
  for i = 1, 12 do many[i] = string.format("test_%02d", i) end
  near = test.nearest("test_12x", many)
  assert(#near == 10 and near[1] == "test_12" and near[2] == "test_10", near[2])
end

--- `string.dump` of the Lua `source`, as a module's bytecode is stored.
local function dumped(source: string, strip: boolean): string
  return string.dump(assert(load(source)), strip) -- checked: not_assignable
end

--- The harness's digest, which every key holds, is what a worker runs and
--- the code that makes and reads a key, each by its bytecode stripped of
--- debug information; a closure store's address is salted by what writes
--- it and what that requires, by source and bytecode. So an edit to how a
--- key is computed, to how a verdict is looked up under one or kept
--- (build.test_key) moves the digest when it changes the bytecode, and a
--- comment's does not; so does one to the worker, to the plan of its
--- sandbox or to cosmic's main, and one to the store's writer, its schema
--- or a module they require moves the address. One to a module of none of
--- them moves neither: not one to the runner (build.test) or the types it
--- shares with the key's code (build.test_state), nor one to
--- cosmic.removed, which a test is keyed by
--- only where its closure holds it, nor one to
--- build.dispatch, or to what only it requires, since cosmic's main
--- starts a worker ahead of it (cmd/cosmic/main.tl), nor one to the
--- projection's writer, whose edits reach a store only through the rows
--- and orderings its address digests (build/closure_store_test.tl holds
--- that), nor build.harness_epoch, which every key holds beside the digest.
local function test_the_harness_holds_what_a_worker_runs_and_what_keys_it()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE modules (path TEXT, kind TEXT, source_hash BLOB, " ..
      "bytecode BLOB); CREATE TABLE imports (path TEXT, requires TEXT)"))
  local key_code = { "build.test_key", "build.declared_key", "build.shared_verdicts",
    "build.artifact", "build.bind", "build.harness_epoch", "build.host_requires",
    "build.host_names", "build.lua_tail" }
  local imports: {{string}} = {
    { "build.declared_key", "build.artifact" }, { "build.declared_key", "cosmic.fs" },
    { "build.shared_verdicts", "build.bind" }, { "build.test_key", "build.importer" },
    { "build.test_key", "build.harness_epoch" }, { "build.test_key", "build.test_report" },
    { "build.test", "build.test_key" },
    { "build.shared_verdicts", "build.harness_epoch" },
    { "build.closure_store", "build.schema" }, { "build.closure_store", "cosmic.sqlite" },
    { "build.shared_verdicts", "cosmic.sqlite" }, { "cosmic.sqlite", "cosmic.sys" },
    { "build.host_requires", "build.host_names" },
  }
  for _, row in ipairs(imports) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES (?, ?)", { { text = row[1] }, { text = row[2] } }))
  end
  local others = { "build.test_sandbox", "build.test_policy",
    "build.caches", "build.zig_caches",
    "cosmic.child", "cosmic.sandbox", "cosmic.sandbox.policy",
    "build.closure_store", "build.writer",
    "build.test_report", "build.schema", "build.importer", "build.syntax_analyzer", "cosmic.removed",
    "cosmic.sqlite", "cosmic.sys", "build.test", "build.test_state" }
  -- Each module's bytecode names what it requires, as a require by
  -- value leaves the name among its constants ([`test_key.value_imports`]).
  local named_in: mut {string:string} = {}
  for _, row in ipairs(imports) do
    named_in[support.nth(row, 1)] = (named_in[support.nth(row, 1)] or "") .. " " .. support.nth(row, 2)
  end
  local function set(name: string, source: string, bytecode: string)
    assert(Sqlite.run(db, "DELETE FROM modules WHERE path = ?", { { text = name } }))
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?, ?, ?, deflate(?))", { { text = name },
      { text = if name == "cmd.cosmic.main" then "main" else "module" end },
      { blob = Hash.hex_sha256(source) },
      { blob = dumped("return " .. string.format("%q", bytecode .. (named_in[name] or "")), false) } }))
  end
  for _, list in ipairs({ worker.loads, key_code, others }) do
    for _, name in ipairs(list) do set(name, "return 'a key'\n", "bytecode") end
  end
  -- A digest to each module the harness holds, and none else.
  local function each_named(modules: {string:string}, names: {string})
    local named: mut {string:boolean} = {}
    for _, name in ipairs(names) do
      named[name] = true
      assert(modules[name] ~= nil, name .. " has no digest of its own")
    end
    for name in pairs(modules) do assert(named[name], name .. " is none of `names`") end
  end
  local before = assert(test_key.harness(db))
  each_named(before.modules, before.names)
  local function moves(name: string, source: string, bytecode: string): string
    set(name, source, bytecode)
    local edited = assert(test_key.harness(db))
    set(name, "return 'a key'\n", "bytecode")
    each_named(edited.modules, edited.names)
    local moved = false
    for other, digest in pairs(before.modules) do
      if edited.modules[other] ~= digest then
        assert(other == name, "an edit to " .. name .. " moved " .. other .. "'s digest")
        moved = true
      end
    end
    return (if moved then "harness" else "" end) ..
      (if edited.store_salt ~= before.store_salt then "store" else "" end)
  end
  local commented = "-- a comment, and a blank line after it\n\nreturn 'a key'\n"
  local function edited(name: string): string return moves(name, commented, "bytecode") end
  -- What the compiler made differently of a module's source.
  local function recompiled(name: string): string
    return moves(name, "return 'a key'\n", "other bytecode")
  end
  -- A comment moves no digest of the harness, whose bytecode is the same; another bytecode does.
  for _, name in ipairs({ "build.test_key", "build.declared_key", "build.shared_verdicts",
      "build.artifact", "build.test_worker", "build.test_sandbox", "build.test_policy",
      "cmd.cosmic.main", "build.confine", "build.lua_tail",
      "build.test_inputs", "cosmic.test", "build.host_requires", "build.host_names",
      "build.caches", "build.zig_caches" }) do
    assert(edited(name) == "", name .. " moved " .. edited(name))
    assert(recompiled(name) == "harness", name .. " recompiled moved " .. recompiled(name))
  end
  -- The runner is none of it: build.test requires the key's code and the types
  -- they share, and an edit to it moves no digest.
  for _, name in ipairs({ "build.importer", "build.syntax_analyzer", "build.writer",
      "build.harness_epoch", "build.test_report", "cosmic.removed", "build.test",
      "build.test_state" }) do
    assert(edited(name) == "", name .. " moved " .. edited(name))
  end
  for _, name in ipairs({ "build.dispatch", "build.clock", "build.exit_status", "cosmic.cli",
      "cosmic.flags" }) do
    assert(edited(name) == "", name .. " moved " .. edited(name))
  end
  -- The writer's closure, what cosmic.sqlite requires among it: an
  -- edit to how it binds a blob can change a store's bytes while every
  -- row's digest stays. The key's code requires cosmic.sqlite too
  -- (build.shared_verdicts), and with it what it requires.
  for _, name in ipairs({ "build.closure_store", "build.schema" }) do
    assert(edited(name) == "store", name .. " moved " .. edited(name))
  end
  for _, name in ipairs({ "cosmic.sqlite", "cosmic.sys" }) do
    assert(edited(name) == "store", name .. " moved " .. edited(name))
    assert(recompiled(name) == "harnessstore", name .. " recompiled moved " .. recompiled(name))
  end
  -- build.bind reads the shared verdicts' rows; a closure store's writer
  -- binds its own.
  assert(edited("build.bind") == "" and recompiled("build.bind") == "harness",
    "build.bind moved " .. edited("build.bind"))
  -- What the compiler made of the same source moves each that holds it:
  -- a compiler whose codegen moved can change what a worker runs.
  local again = moves("cosmic.sqlite", "return 'a key'\n", "other bytecode")
  assert(again == "harnessstore", "a recompile moved " .. again)
  again = moves("build.test_key", "return 'a key'\n", "other bytecode")
  assert(again == "harness", "a recompile moved " .. again)
  assert(moves("build.test", "return 'a key'\n", "other bytecode") == "")
  assert(moves("build.writer", "return 'a key'\n", "other bytecode") == "")
  assert(moves("build.test_report", "return 'a key'\n", "other bytecode") == "")
  -- The harness's modules are named, and those it runs apart.
  local named: mut {string:boolean} = {}
  for _, name in ipairs(before.names) do named[name] = true end
  assert(named["build.caches"] == true and named["build.zig_caches"] == true and named["build.test_key"] == true and
      named["build.test"] == nil and named["build.test_state"] == nil and
      named["build.harness_epoch"] ~= true and named["build.test_report"] ~= true)
  local runs: mut {string:boolean} = {}
  for _, name in ipairs(before.runs) do runs[name] = true end
  assert(runs["build.test_sandbox"] == true and runs["build.test_policy"] == true and runs["build.test_worker"] == true and
      runs["build.test_key"] ~= true)
  -- A module that makes a key and that the binary does not carry fails
  -- the harness, naming it.
  assert(db:exec("DELETE FROM modules WHERE path = 'build.artifact'"))
  local none, why = test_key.harness(db)
  assert(none == nil and why:find("build.artifact", 1, true) ~= nil, why)
  set("build.artifact", "return 'a key'\n", "bytecode")
  -- So does one the store's writer requires.
  assert(db:exec("DELETE FROM modules WHERE path = 'cosmic.sqlite'"))
  none, why = test_key.harness(db)
  assert(none == nil and why:find("cosmic.sqlite", 1, true) ~= nil, why)
  db:close()
end

--- The key's code is walked over the requires each module makes by
--- value, as its bytecode names them: a `local type` require, which
--- Teal erases, leaves what it names out of the harness, and a require
--- inside a function keeps it in. cosmic.child and cosmic.sandbox are held
--- alone, their own requires not walked.
local function test_the_harness_walks_the_key_code_by_value()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE modules (path TEXT, kind TEXT, source_hash BLOB, " ..
      "bytecode BLOB); CREATE TABLE imports (path TEXT, requires TEXT)"))
  local sources: {string:string} = {
    ["build.declared_key"] = 'local function later() return require("build.artifact") end\n' ..
      'return later\n',
    ["build.shared_verdicts"] = 'return require("cosmic.sqlite")\n',
    ["cosmic.child"] = 'return require("cosmic.time")\n',
  }
  local function add(name: string)
    local source = sources[name] or "return 1\n"
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?, ?, ?, deflate(?))", { { text = name },
      { text = if name == "cmd.cosmic.main" then "main" else "module" end },
      { blob = Hash.hex_sha256(source) },
      { blob = dumped(source, true) } }))
  end
  for _, name in ipairs(worker.loads) do add(name) end
  for _, name in ipairs({ "build.test_key", "build.declared_key", "build.shared_verdicts",
      "build.host_requires", "build.artifact", "build.test_sandbox", "build.test_policy",
      "build.caches", "build.zig_caches", "build.closure_store", "build.schema", "build.lua_tail",
      "cosmic.child", "cosmic.sandbox", "cosmic.sandbox.policy", "cosmic.time", "cosmic.sqlite", "cosmic.stream" }) do
    add(name)
  end
  -- build.declared_key's edge to cosmic.stream is a `local type` one.
  for _, row in ipairs({ { "build.declared_key", "cosmic.stream" },
      { "build.declared_key", "build.artifact" },
      { "build.shared_verdicts", "cosmic.sqlite" },
      { "cosmic.child", "cosmic.time" } }) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES (?, ?)",
      { { text = row[1] }, { text = row[2] } }))
  end
  local found = assert(test_key.harness(db))
  db:close()
  local named: mut {string:boolean} = {}
  for _, name in ipairs(found.names) do named[name] = true end
  assert(named["build.artifact"] == true and named["cosmic.sqlite"] == true and named["cosmic.child"] == true)
  assert(named["cosmic.stream"] ~= true and named["cosmic.time"] ~= true)
end

--- A run keeps the coverage of the newest ten runs and drops that of the
--- rest, with the `test_runs` row nothing refers to any more.
local function test_coverage_is_kept_for_the_newest_ten_runs_only()
  local db = assert(Sqlite.open(":memory:", { writable = true }))
  for _, statement in ipairs(work.schema) do assert(db:exec(statement)) end
  for run = 1, 13 do
    assert(db:exec("INSERT INTO test_runs (ran_at_ns) VALUES (" .. tostring(run) .. ")"))
    assert(db:exec("INSERT INTO coverage (ran_at_ns, path, line, hit) VALUES (" .. tostring(run) ..
        ", 'a', 1, 1), (" .. tostring(run) .. ", 'a', 2, 0)"))
  end
  assert(test.prune_history(db, 100))
  local kept = assert(assert(Sqlite.text_rows(db,
    "SELECT min(ran_at_ns), max(ran_at_ns), count(DISTINCT ran_at_ns), count(*) FROM coverage"))[1]):texts()
  assert(kept[1] == "4" and kept[2] == "13" and kept[3] == "10" and kept[4] == "20",
    "coverage kept: " .. table.concat(kept, " "))
  local runs = assert(assert(Sqlite.text_rows(db, "SELECT count(*), min(ran_at_ns) FROM test_runs"))[1]):texts()
  assert(runs[1] == "10" and runs[2] == "4", "test_runs kept: " .. table.concat(runs, " "))
  assert(db:close())
end

--- A module that declares loopback addresses requires `loopback` without
--- writing it, once where it writes it too; one that declares none, or
--- no policy at all, requires only what it writes.
local function test_declared_loopback_addresses_require_loopback()
  local function requirements(network: {string}, requires: {string}, declares: boolean): string
    local declared: PolicyRules.Declared = { line = 1, reads = {}, host = {}, env = {},
      network = network, tool = false, lua = false, nests = false, noexec = false,
      store = false, system = false, caches = {}, requires = requires }
    local m: plans.Module = { path = "net_test", file = "net_test.tl", kind = "test", source = "",
      source_hash = "", requires = {}, tests = { "test_listens" },
      inputs = if declares then declared else nil end }
    return table.concat(test_key.requirements(m), ",")
  end
  assert(requirements({ "127.0.0.1" }, {}, true) == "loopback")
  assert(requirements({ "127.0.0.1" }, { "loopback" }, true) == "loopback")
  assert(requirements({ "127.0.0.1" }, { "root" }, true) == "loopback,root")
  assert(requirements({}, { "root" }, true) == "root")
  assert(requirements({ "127.0.0.1" }, {}, false) == "")
end
