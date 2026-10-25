--- `cosmic test`'s own pieces, held directly: how a selector chooses a
--- test, how a failing one is named to be run again, and what the
--- harness's digest holds.

local Clock = require("cosmic.clock")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local test = require("build.test")
local test_key = require("build.test_key")
local work = require("build.work")
local worker = require("build.test_worker")

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
--- row, the run's hits hold their union, and a table taken before is
--- not folded or spelled again.
local function test_a_modules_load_and_test_hits_are_two_lines_of_its_row()
  local hits: {string:{integer:boolean}} = {}
  local folded: {{integer:boolean}:boolean} = {}
  local spelled: {{integer:boolean}:string} = {}
  local loaded: {integer:boolean} = { [3] = true, [1] = true }
  local row = test.take_hits(hits, { ["core"] = {} }, folded, spelled,
    { ["build.a"] = loaded, ["core"] = { [9] = true } }, { ["build.a"] = { [7] = true } })
  assert(row == "build.a\t1,3\nbuild.a\t7\n", row)
  assert(hits["build.a"][1] and hits["build.a"][3] and hits["build.a"][7])
  assert(hits["core"] == nil)
  hits["build.a"][1] = nil
  row = test.take_hits(hits, {}, folded, spelled, { ["build.a"] = loaded }, {})
  assert(row == "build.a\t1,3\n" and hits["build.a"][1] == nil, "a taken table is folded once")
  local again = test.take_hits({}, {}, {}, {}, { ["build.a"] = loaded }, {})
  assert(again == row)
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
    assert(refused == nil and why:find("--shard must be I/N", 1, true), text)
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
  for i = #ids, 1, -1 do reversed[#reversed + 1] = ids[i] end
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
        modules[id:match("^(%S+)")] = true
      end
      for id in pairs(again) do assert(dealt[id], id) end
      sizes[#sizes + 1] = size
      -- m5's fifteen tests reach every share.
      assert(modules.m5, "share " .. index .. " of " .. count .. " holds none of m5")
    end
    for _, id in ipairs(ids) do
      assert(held[id] == 1, id .. " is in " .. tostring(held[id]) .. " of " .. count .. " shares")
    end
    table.sort(sizes)
    assert(sizes[#sizes] - sizes[1] <= 1, "shares of " .. count .. " differ by more than one")
  end
end

--- The census says a key's harness parts as one word, which a report
--- compares whole (ci/cosmic_ci/report.tl) and reads as the rest of a
--- part, up to a space: two bumps of the epoch from one count say
--- a moved harness, as another timeout does.
local function test_the_census_says_each_bump_of_the_epoch_apart()
  local word = test_key.harness_word("8-072f7458", Clock.seconds(30))
  assert(word == "e8-072f7458-t" .. Clock.seconds(30), word)
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

--- The harness's digest, which build/harness_epoch.tl acknowledges, is
--- what a worker runs and the code that makes and reads a key, each by
--- its source and bytecode; a closure store's address is salted by what
--- writes it and what that requires, by source and bytecode. So an edit
--- to how a key is computed, to how a verdict is looked up under one or
--- kept (build.test_key) moves the digest, a comment's too, and fails
--- build/harness_epoch_test.tl until it is acknowledged or the epoch
--- bumped; so does one to the worker, to the plan of its sandbox or to
--- cosmic's main, and one to the store's writer, its schema or a module
--- they require moves the address. One to a module of none of them
--- moves neither: not one to the runner (build.test) or the types it
--- shares with the key's code (build.test_state), nor one to
--- cosmic.removed, which a test is keyed by
--- only where its closure holds it, nor one to
--- build.dispatch, or to what only it requires, since cosmic's main
--- starts a worker ahead of it (cmd/cosmic/main.tl), nor one to the
--- projection's writer, whose edits reach a store only through the rows
--- and orderings its address digests (build/closure_store_test.tl holds
--- that), nor build.harness_epoch, which records the digest.
local function test_the_harness_holds_what_a_worker_runs_and_what_keys_it()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE modules (path TEXT, kind TEXT, source_hash BLOB, " ..
      "bytecode BLOB); CREATE TABLE imports (path TEXT, requires TEXT)"))
  local key_code = { "build.test_key", "build.declared_key", "build.shared_verdicts",
    "build.artifact", "build.bind", "build.harness_epoch", "build.host_requires",
    "build.host_names" }
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
    named_in[row[1]] = (named_in[row[1]] or "") .. " " .. row[2]
  end
  local function set(name: string, source: string, bytecode: string)
    assert(Sqlite.run(db, "DELETE FROM modules WHERE path = ?", { { text = name } }))
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?, ?, ?, ?)", { { text = name },
      { text = if name == "cmd.cosmic.main" then "main" else "module" end },
      { blob = Hash.hex_sha256(source) }, { blob = bytecode .. (named_in[name] or "") } }))
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
  for _, name in ipairs({ "build.test_key", "build.declared_key", "build.shared_verdicts",
      "build.artifact", "build.test_worker", "build.test_sandbox", "build.test_policy",
      "cmd.cosmic.main", "build.confine",
      "build.test_inputs", "cosmic.test", "build.host_requires", "build.host_names",
      "build.caches", "build.zig_caches" }) do
    assert(edited(name) == "harness", name .. " moved " .. edited(name))
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
    assert(edited(name) == "harnessstore", name .. " moved " .. edited(name))
  end
  -- build.bind reads the shared verdicts' rows; a closure store's writer
  -- binds its own.
  assert(edited("build.bind") == "harness", "build.bind moved " .. edited("build.bind"))
  -- What the compiler made of the same source moves each that holds it:
  -- a compiler whose codegen moved can change what a worker runs.
  local recompiled = moves("cosmic.sqlite", "return 'a key'\n", "other bytecode")
  assert(recompiled == "harnessstore", "a recompile moved " .. recompiled)
  recompiled = moves("build.test_key", "return 'a key'\n", "other bytecode")
  assert(recompiled == "harness", "a recompile moved " .. recompiled)
  assert(moves("build.test", "return 'a key'\n", "other bytecode") == "")
  assert(moves("build.writer", "return 'a key'\n", "other bytecode") == "")
  assert(moves("build.test_report", "return 'a key'\n", "other bytecode") == "")
  -- The harness's modules are named, and those it runs apart.
  local named: mut {string:boolean} = {}
  for _, name in ipairs(before.names) do named[name] = true end
  assert(named["build.caches"] and named["build.zig_caches"] and named["build.test_key"] and
      named["build.test"] == nil and named["build.test_state"] == nil and
      not named["build.harness_epoch"] and not named["build.test_report"])
  local runs: mut {string:boolean} = {}
  for _, name in ipairs(before.runs) do runs[name] = true end
  assert(runs["build.test_sandbox"] and runs["build.test_policy"] and runs["build.test_worker"] and
      not runs["build.test_key"])
  -- A module that makes a key and that the binary does not carry fails
  -- the harness, naming it.
  assert(db:exec("DELETE FROM modules WHERE path = 'build.artifact'"))
  local none, why = test_key.harness(db)
  assert(none == nil and why:find("build.artifact", 1, true), why)
  set("build.artifact", "return 'a key'\n", "bytecode")
  -- So does one the store's writer requires.
  assert(db:exec("DELETE FROM modules WHERE path = 'cosmic.sqlite'"))
  none, why = test_key.harness(db)
  assert(none == nil and why:find("cosmic.sqlite", 1, true), why)
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
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?, ?, ?, ?)", { { text = name },
      { text = if name == "cmd.cosmic.main" then "main" else "module" end },
      { blob = Hash.hex_sha256(source) },
      { blob = string.dump(assert(load(source)), true) } }))
  end
  for _, name in ipairs(worker.loads) do add(name) end
  for _, name in ipairs({ "build.test_key", "build.declared_key", "build.shared_verdicts",
      "build.host_requires", "build.artifact", "build.test_sandbox", "build.test_policy",
      "build.caches", "build.zig_caches", "build.closure_store", "build.schema",
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
  assert(named["build.artifact"] and named["cosmic.sqlite"] and named["cosmic.child"])
  assert(not named["cosmic.stream"] and not named["cosmic.time"])
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
