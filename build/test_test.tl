--- `cosmic test`'s own pieces, held directly: how a selector chooses a
--- test, how a failing one is named to be run again, and what the
--- harness's digest holds.

local Clock = require("cosmic.clock")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local test = require("build.test")
local worker = require("build.test_worker")

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
  local ids: {string} = {}
  for module = 1, 5 do
    for name = 1, module * 3 do
      ids[#ids + 1] = string.format("m%d test_%02d", module, name)
    end
  end
  local reversed: {string} = {}
  for i = #ids, 1, -1 do reversed[#reversed + 1] = ids[i] end
  for count = 1, 4 do
    local held: {string:integer} = {}
    local sizes: {integer} = {}
    for index = 1, count do
      local dealt = test.dealt(ids, { index = index, count = count })
      local again = test.dealt(reversed, { index = index, count = count })
      local size = 0
      local modules: {string:boolean} = {}
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
  local word = test.harness_word("8-072f7458", Clock.seconds(30))
  assert(word == "e8-072f7458-t" .. Clock.seconds(30), word)
  assert(word:match("^%S+$") and not word:find("[,;]"), word)
  assert(test.harness_word("8-3f9c2a1b", Clock.seconds(30)) ~= word, "two bumps from one count")
  assert(test.harness_word("8-072f7458", Clock.seconds(60)) ~= word, "another timeout")
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
  local many: {string} = {}
  for i = 1, 12 do many[i] = string.format("test_%02d", i) end
  near = test.nearest("test_12x", many)
  assert(#near == 10 and near[1] == "test_12" and near[2] == "test_10", near[2])
end

--- The harness's digest, which build/harness_epoch.tl acknowledges, is
--- what a worker runs and the code that makes and reads a key, each by
--- its source and bytecode; a closure store's address is salted by what
--- writes it and what that requires, by source and bytecode. So an edit
--- to the runner, to how a key is computed or to how a verdict is looked
--- up under one moves the digest, a comment's too, and fails
--- build/harness_epoch_test.tl until it is acknowledged or the epoch
--- bumped; so does one to the worker, to the plan of its sandbox or to
--- cosmic's main, and one to the store's writer, its schema or a module
--- they require moves the address. One to a module of none of them
--- moves neither: not one to cosmic.removed, which a test is keyed by
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
  local key_code = { "build.test", "build.declared_key", "build.shared_verdicts",
    "build.artifact", "build.bind", "build.harness_epoch", "build.host_requires",
    "build.host_names" }
  local imports: {{string}} = {
    { "build.declared_key", "build.artifact" }, { "build.declared_key", "cosmic.fs" },
    { "build.shared_verdicts", "build.bind" }, { "build.test", "build.importer" },
    { "build.test", "build.harness_epoch" }, { "build.test", "build.test_report" },
    { "build.shared_verdicts", "build.harness_epoch" },
    { "build.closure_store", "build.schema" }, { "build.closure_store", "cosmic.sqlite" },
    { "build.shared_verdicts", "cosmic.sqlite" }, { "cosmic.sqlite", "cosmic.sys" },
    { "build.host_requires", "build.host_names" },
  }
  for _, row in ipairs(imports) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES (?, ?)", { { text = row[1] }, { text = row[2] } }))
  end
  local others = { "build.test_sandbox", "build.test_policy", "build.closure_artifact",
    "build.caches", "build.zig_caches",
    "cosmic.child", "cosmic.sandbox",
    "build.closure_store", "build.writer",
    "build.test_report", "build.schema", "build.importer", "build.analyzer", "cosmic.removed",
    "cosmic.sqlite", "cosmic.sys" }
  -- Each module's bytecode names what it requires, as a require by
  -- value leaves the name among its constants ([`test.value_imports`]).
  local named_in: {string:string} = {}
  for _, row in ipairs(imports) do
    named_in[row[1]] = (named_in[row[1]] or "") .. " " .. row[2]
  end
  local function set(name: string, source: string, bytecode: string)
    assert(Sqlite.run(db, "DELETE FROM modules WHERE path = ?", { { text = name } }))
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?, ?, ?, ?)", { { text = name },
      { text = name == "cmd.cosmic.main" and "main" or "module" },
      { blob = Hash.hex_sha256(source) }, { blob = bytecode .. (named_in[name] or "") } }))
  end
  for _, list in ipairs({ worker.loads, key_code, others }) do
    for _, name in ipairs(list) do set(name, "return 'a key'\n", "bytecode") end
  end
  -- A digest to each module the harness holds, and none else.
  local function each_named(modules: {string:string}, names: {string})
    local named: {string:boolean} = {}
    for _, name in ipairs(names) do
      named[name] = true
      assert(modules[name] ~= nil, name .. " has no digest of its own")
    end
    for name in pairs(modules) do assert(named[name], name .. " is none of `names`") end
  end
  local before = assert(test.harness(db))
  each_named(before.modules, before.names)
  local function moves(name: string, source: string, bytecode: string): string
    set(name, source, bytecode)
    local edited = assert(test.harness(db))
    set(name, "return 'a key'\n", "bytecode")
    each_named(edited.modules, edited.names)
    local moved = false
    for other, digest in pairs(before.modules) do
      if edited.modules[other] ~= digest then
        assert(other == name, "an edit to " .. name .. " moved " .. other .. "'s digest")
        moved = true
      end
    end
    return (moved and "harness" or "") ..
      (edited.store_salt ~= before.store_salt and "store" or "")
  end
  local commented = "-- a comment, and a blank line after it\n\nreturn 'a key'\n"
  local function edited(name: string): string return moves(name, commented, "bytecode") end
  for _, name in ipairs({ "build.test", "build.declared_key", "build.shared_verdicts",
      "build.artifact", "build.test_worker", "build.test_sandbox", "build.test_policy",
      "cmd.cosmic.main", "build.confine",
      "build.test_inputs", "cosmic.test", "build.host_requires", "build.host_names",
      "build.caches", "build.zig_caches" }) do
    assert(edited(name) == "harness", name .. " moved " .. edited(name))
  end
  for _, name in ipairs({ "build.importer", "build.analyzer", "build.writer",
      "build.harness_epoch", "build.test_report", "cosmic.removed" }) do
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
  recompiled = moves("build.test", "return 'a key'\n", "other bytecode")
  assert(recompiled == "harness", "a recompile moved " .. recompiled)
  assert(moves("build.writer", "return 'a key'\n", "other bytecode") == "")
  assert(moves("build.test_report", "return 'a key'\n", "other bytecode") == "")
  -- The harness's modules are named, and those it runs apart.
  local named: {string:boolean} = {}
  for _, name in ipairs(before.names) do named[name] = true end
  assert(named["build.caches"] and named["build.zig_caches"] and named["build.test"] and
      not named["build.harness_epoch"] and not named["build.test_report"])
  local runs: {string:boolean} = {}
  for _, name in ipairs(before.runs) do runs[name] = true end
  assert(runs["build.test_sandbox"] and runs["build.test_policy"] and runs["build.test_worker"] and
      not runs["build.test"])
  -- A module that makes a key and that the binary does not carry fails
  -- the harness, naming it.
  assert(db:exec("DELETE FROM modules WHERE path = 'build.artifact'"))
  local none, why = test.harness(db)
  assert(none == nil and why:find("build.artifact", 1, true), why)
  set("build.artifact", "return 'a key'\n", "bytecode")
  -- So does one the store's writer requires.
  assert(db:exec("DELETE FROM modules WHERE path = 'cosmic.sqlite'"))
  none, why = test.harness(db)
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
      { text = name == "cmd.cosmic.main" and "main" or "module" },
      { blob = Hash.hex_sha256(source) },
      { blob = string.dump(assert(load(source)), true) } }))
  end
  for _, name in ipairs(worker.loads) do add(name) end
  for _, name in ipairs({ "build.test", "build.declared_key", "build.shared_verdicts",
      "build.host_requires", "build.artifact", "build.test_sandbox", "build.test_policy",
      "build.closure_artifact",
      "build.caches", "build.zig_caches", "build.closure_store", "build.schema",
      "cosmic.child", "cosmic.sandbox", "cosmic.time", "cosmic.sqlite", "cosmic.stream" }) do
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
  local found = assert(test.harness(db))
  db:close()
  local named: {string:boolean} = {}
  for _, name in ipairs(found.names) do named[name] = true end
  assert(named["build.artifact"] and named["cosmic.sqlite"] and named["cosmic.child"])
  assert(not named["cosmic.stream"] and not named["cosmic.time"])
end
