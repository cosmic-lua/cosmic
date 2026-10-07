--- The harness's digests ([`build.test`]'s `harness`: what every worker
--- loads, the sandbox's maker and the code that makes and reads a key,
--- a digest per module by its source and bytecode) are the ones
--- build/harness_epoch.tl acknowledges, one to a line. No key holds
--- the harness's code, only its epoch, so an edit to it runs no test
--- again by itself: this fails until someone says, in
--- build/harness_epoch.tl, whether the edit can alter a pass or a
--- fail. And the digests hold all the harness runs: every module of
--- the tree the modules it runs require.

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Rand = require("cosmic.rand")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local harness_epoch = require("build.harness_epoch")
local test = require("build.test")

--- The harness is read from the projection, o/cosmic.db: its modules
--- are the tree's, most of them outside this module's closure, and so
--- is the `imports` table `key_code`'s closure is walked by. Declared
--- `store`, the key holds the projection by its contents, so every
--- edit to the tree runs this again, an edit to the harness among
--- them, and so does a compiler that makes other bytecode of it; it
--- is this module alone that pays that.
Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }

--- The line of build/harness_epoch.tl's `acknowledged` that holds
--- `name` at `digest`, as the file lays it out: each such line between
--- blank ones, so git merges changes to two modules that sort next to
--- each other as it does any other two.
local function entry(name: string, digest: string): string
  return string.format("  [%q] = %q,", name, digest)
end

--- The count and token of `epoch` (build/harness_epoch.tl) when it
--- has the form the file keeps, a count, a dash and 8 lower-case hex
--- digits ("N-xxxxxxxx"), or nil where it has another.
local function epoch_parts(epoch: string): integer | nil, string | nil
  local count, token = epoch:match("^(%d+)%-(%x%x%x%x%x%x%x%x)$")
  if count == nil or token:find("%u") then return nil, nil end
  return math.tointeger(tonumber(count)), token
end

local function holds(list: {string}, wanted: string): boolean
  for _, value in ipairs(list) do
    if value == wanted then return true end
  end
  return false
end

--- The two edits of a bump from `epoch` and `retired`: the line to set
--- `epoch`'s to, with a token drawn from the system's entropy, and the
--- line to append to `retired`, nil where there is none to retire -- a
--- bare count, set on a conflict, whose token the merge retired
--- already. The count is one past `retired`, as it will be after the
--- append, so two bumps from one value -- on two branches -- append
--- the same line, which merges, and set their `epoch` lines apart,
--- which conflict.
local function bump(epoch: string, retired: {string}): string, string | nil
  local _, token = epoch_parts(epoch)
  local retire: string | nil = nil
  if token ~= nil and not holds(retired, token) then retire = token end
  local count = #retired + (retire ~= nil and 1 or 0) + 1
  local line = string.format("harness_epoch.epoch = %q",
    string.format("%d-%s", count, Codec.hex((assert(Rand.entropy(4))))))
  return line, retire ~= nil and string.format("  %q,", retire) or nil
end

--- The words that tell how to bump `epoch`, with the two edits to paste.
local function how_to_bump(epoch: string, retired: {string}): string
  local line, append = bump(epoch, retired)
  return "To bump it, set the `epoch` line to\n" .. line .. "\nkeeping its comment" ..
    (append ~= nil and ", and append this line to `retired`:\n" .. append or
      "; append nothing to `retired`: `epoch` has no token of its own to retire") ..
    "\nThe token is drawn fresh here: never copy one from another branch."
end

--- Nil where `epoch` and `retired` are as build/harness_epoch.tl keeps
--- them, or what is wrong: `epoch` is a count and a token, the token is
--- not retired, and the count is one past how many are; `retired`
--- holds no token twice. So a bump that moves the count alone fails,
--- whether or not it retires the token it keeps.
---
--- TODO: hold a conflict's resolution to a fresh token, which nothing
--- here can: a merge that keeps one side's `epoch` line, with the token
--- both sides retired, passes, and the merged tree stands on the
--- verdicts that side earned without the other's change. Enforcing it
--- needs what a tree alone does not say -- the tokens other branches
--- hold: have CI's merge queue (ci/cosmic_ci/orchestration.tl, beside
--- its `harness_moved`) refuse a change whose `epoch` token its base
--- did not hold but another open pull request's head does, once the
--- queue's driver reads open pull requests.
local function epoch_trouble(epoch: string, retired: {string}): string | nil
  local seen: {string:boolean} = {}
  for _, token in ipairs(retired) do
    if seen[token] then return string.format("`retired` holds %q twice", token) end
    seen[token] = true
  end
  local count, token = epoch_parts(epoch)
  if count == nil then
    return string.format("`epoch` is %q, not a count, a dash and 8 lower-case hex digits",
      epoch)
  end
  if seen[token] then
    return string.format("`epoch`'s token %s is retired: a bump draws a new one", token)
  end
  if count ~= #retired + 1 then
    return string.format("`epoch`'s count is %d, not %d, one past the %d tokens `retired` " ..
        "holds: a bump appends the old token there and draws a new one", count,
      #retired + 1, #retired)
  end
  return nil
end

--- What differs between the harness's modules as `found` has them (a
--- digest per module, [`build.test`]'s `harness`) and `acknowledged`:
--- nil where they agree, or a message naming each module that moved,
--- that has no entry, and each entry that names no module of the
--- harness, with the lines that acknowledge the first two.
local function unacknowledged(found: {string:string}, acknowledged: {string:string},
                              epoch: string, retired: {string}): string | nil
  local moved: {string} = {}
  local stale: {string} = {}
  for name, digest in pairs(found) do
    if acknowledged[name] ~= digest then moved[#moved + 1] = name end
  end
  for name in pairs(acknowledged) do
    if found[name] == nil then stale[#stale + 1] = name end
  end
  if #moved == 0 and #stale == 0 then return nil end
  table.sort(moved)
  table.sort(stale)
  local out: {string} = {
    "the test harness moved (build/harness_epoch.tl): what every worker loads, " ..
      "the sandbox's maker or the code that makes and reads a key. Bump `epoch` if " ..
      "the change can alter a pass or a fail -- what a worker is given, how it is " ..
      "judged, how a key is computed; a sandbox's hold or bind tightened, too, which " ..
      "moves no other part of a key, so a pass earned through the hole does not " ..
      "stand -- which runs every test again; otherwise keep it. " .. how_to_bump(epoch, retired) ..
      "\nEither way, in `acknowledged`:",
  }
  for _, name in ipairs(moved) do
    out[#out + 1] = acknowledged[name] == nil and
      "no entry for " .. name .. "; add this line, in its place by name, between blank lines" or
      "moved: " .. name .. "; set its line to"
    out[#out + 1] = entry(name, found[name])
  end
  for _, name in ipairs(stale) do
    out[#out + 1] = "stale entry: " .. name .. " is no module of the harness; delete its line"
  end
  return table.concat(out, "\n")
end

local function test_the_harness_is_acknowledged()
  local db = assert(Sqlite.open("o/cosmic.db"))
  local found, trouble = test.harness(db)
  db:close()
  assert(found ~= nil, trouble)
  local complaint = unacknowledged(found.modules, harness_epoch.acknowledged,
    harness_epoch.epoch, harness_epoch.retired)
  assert(complaint == nil, complaint)
end

--- Presentation edits need no acknowledgment; the runner's judgment remains
--- held whole, even though its reporting dependency is not followed.
local function test_the_runner_is_acknowledged_without_its_reporter()
  local db = assert(Sqlite.open("o/cosmic.db"))
  local found, trouble = test.harness(db)
  db:close()
  assert(found ~= nil, trouble)
  assert(found.modules["build.test"] ~= nil)
  assert(found.modules["build.test_report"] == nil)
end

--- A `retired` of the bare counts "1" to `n`, as build/harness_epoch.tl's
--- begins with the counts of the epochs that had no token.
local function counted(n: integer): {string}
  local retired: {string} = {}
  for i = 1, n do retired[i] = tostring(i) end
  return retired
end

--- A module that moved is named alone, with the one line to set; one
--- the harness gained has a line to add; an entry for a module the
--- harness does not hold is stale.
local function test_unacknowledged_names_each_module()
  local acknowledged = { ["build.a"] = "1", ["build.b"] = "2" }
  local epoch, retired = "8-072f7458", counted(7)
  assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "2" }, acknowledged, epoch,
    retired) == nil)
  local moved = assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "3" }, acknowledged,
    epoch, retired))
  assert(moved:find("moved: build.b; set its line to\n" .. entry("build.b", "3"), 1, true), moved)
  assert(not moved:find("build.a", 1, true), moved)
  assert(moved:find("Bump `epoch`", 1, true), moved)
  -- Both edits of a bump, to paste.
  assert(moved:find('\nharness_epoch.epoch = "9%-%x%x%x%x%x%x%x%x"\n'), moved)
  assert(moved:find('append this line to `retired`:\n  "072f7458",\n', 1, true), moved)
  local added = assert(unacknowledged({ ["build.a"] = "1", ["build.b"] = "2", ["build.c"] = "4" },
    acknowledged, epoch, retired))
  assert(added:find("no entry for build.c; add this line, in its place by name, between " ..
      "blank lines\n" .. entry("build.c", "4"), 1, true), added)
  local gone = assert(unacknowledged({ ["build.a"] = "1" }, acknowledged, epoch, retired))
  assert(gone:find("stale entry: build.b", 1, true), gone)
  assert(not gone:find("build.a", 1, true), gone)
end

--- `epoch` and `retired` are as build/harness_epoch.tl says: a count and
--- a token no bump before used, the count one past the tokens retired.
--- A bare count -- as a conflict's resolution sets it -- fails here,
--- printing a fresh value.
local function test_the_epoch_is_a_count_and_an_unused_token()
  local trouble = epoch_trouble(harness_epoch.epoch, harness_epoch.retired)
  assert(trouble == nil, "build/harness_epoch.tl: " .. tostring(trouble) .. ". " ..
      how_to_bump(harness_epoch.epoch, harness_epoch.retired))
end

--- What a bump's two edits, as `bump` prints them, leave `epoch` and
--- `retired` as.
local function applied(line: string, append: string | nil, retired: {string}): string, {string}
  local after: {string} = {}
  for i, token in ipairs(retired) do after[i] = token end
  if append ~= nil then after[#after + 1] = assert(append:match('^  "(%x+)",$'), append) end
  return assert(line:match('^harness_epoch%.epoch = "(.*)"$'), line), after
end

--- The form is held exactly; the count is held to `retired`, so a bump
--- of the count alone fails whether or not it retires the token it
--- keeps; and a bump as the guard prints it passes, and two drawn from
--- one value append the same line but set `epoch` apart.
local function test_the_guard_holds_the_epoch_to_its_retired_tokens()
  local retired = counted(7)
  assert(epoch_trouble("8-072f7458", retired) == nil)
  for _, malformed in ipairs({ "8", "", "8-", "-072f7458", "8-072f745", "8-072f74581",
      "8-072F7458", "8-072g7458", "x-072f7458", "8_072f7458", " 8-072f7458" }) do
    local trouble = epoch_trouble(malformed, retired)
    assert(trouble ~= nil and trouble:find("not a count, a dash", 1, true),
      string.format("%q was taken as an epoch: %s", malformed, tostring(trouble)))
  end
  local skipped = assert(epoch_trouble("9-072f7458", retired))
  assert(skipped:find("count is 9, not 8", 1, true), skipped)
  local more = counted(7)
  more[8] = "072f7458"
  local kept = assert(epoch_trouble("9-072f7458", more))
  assert(kept:find("072f7458 is retired", 1, true), kept)
  local twice = counted(7)
  twice[8] = "7"
  local doubled = assert(epoch_trouble("9-aaaaaaaa", twice))
  assert(doubled:find('holds "7" twice', 1, true), doubled)
  -- Two branches bump from one value.
  local one, one_append = bump("8-072f7458", retired)
  local two, two_append = bump("8-072f7458", retired)
  assert(one_append == '  "072f7458",' and two_append == one_append, tostring(one_append))
  assert(one ~= two, "two bumps from one value drew one token: " .. one)
  local epoch, after = applied(one, one_append, retired)
  assert(epoch:match("^9%-"), epoch)
  assert(epoch_trouble(epoch, after) == nil, tostring(epoch_trouble(epoch, after)))
  -- Their conflict resolved as the epoch line's comment says: the bare
  -- count, with the token the merge retired; the guard fails and
  -- prints a bump that retires nothing more.
  local bare = assert(epoch_trouble("9", after))
  assert(bare:find("not a count, a dash", 1, true), bare)
  local line, append = bump("9", after)
  assert(append == nil, tostring(append))
  assert(how_to_bump("9", after):find("append nothing to `retired`", 1, true))
  local resolved, still = applied(line, append, after)
  assert(resolved:match("^9%-") and resolved ~= epoch, resolved)
  assert(epoch_trouble(resolved, still) == nil, tostring(epoch_trouble(resolved, still)))
end

--- The lines the guard prints are the lines build/harness_epoch.tl
--- holds, sorted by name and each between blank lines, so pasting one
--- is the whole edit and git merges two changes to different modules,
--- even two that sort next to each other.
local function test_the_file_holds_its_entries_as_the_guard_prints_them()
  local db = assert(Sqlite.open("o/cosmic.db"))
  local rows = assert(Sqlite.rows(db, "SELECT source FROM modules WHERE path = ?1",
    { { text = "build.harness_epoch" } }))
  db:close()
  local text = assert(Compress.inflate("raw", rows[1][1].blob))
  local names: {string} = {}
  for name in pairs(harness_epoch.acknowledged) do names[#names + 1] = name end
  assert(#names > 0)
  table.sort(names)
  local last = 0
  for _, name in ipairs(names) do
    local at = text:find("\n\n" .. entry(name, harness_epoch.acknowledged[name]) .. "\n\n", 1,
      true)
    assert(at ~= nil, name .. "'s entry is not one line as the guard prints it, between " ..
        "blank lines")
    assert(at > last, name .. "'s entry is out of order: keep them sorted by name")
    last = at
  end
end

--- A require the harness never follows: cosmic's main hands the
--- command line to build.dispatch, which a worker never reaches, since
--- main starts a worker ahead of it (cmd/cosmic/main.tl).
local unfollowed: {string:{string:boolean}} = {
  ["cmd.cosmic.main"] = { ["build.dispatch"] = true },
}

--- Every module of the tree a module the harness runs requires by value
--- (what every worker loads, and the sandbox's maker, `harness_own`) is
--- in the harness's digest. Otherwise an edit to it moves neither a key
--- nor the digest. build/zig.tl, which build.caches requires, is such a
--- module: it decides where a declared cache is bound from.
local function test_the_harness_holds_what_it_runs_requires()
  local db = assert(Sqlite.open("o/cosmic.db"))
  local found, trouble = test.harness(db)
  assert(found ~= nil, trouble)
  local named: {string:boolean} = {}
  for _, name in ipairs(found.names) do named[name] = true end
  named["build.harness_epoch"] = true
  local by_value = assert(test.value_imports(db))
  local tree: {string:boolean} = {}
  for _, row in ipairs((assert(Sqlite.text_rows(db, "SELECT path FROM modules")))) do
    tree[row[1]] = true
  end
  local missing: {string} = {}
  for _, name in ipairs(found.runs) do
    assert(tree[name], name .. " is no module of the tree")
    for _, wanted in ipairs(by_value[name] or {}) do
      if tree[wanted] and not named[wanted] and not (unfollowed[name] or {})[wanted] then
        missing[#missing + 1] = name .. " requires " .. wanted
      end
    end
  end
  db:close()
  assert(#missing == 0, "the harness runs what its digest does not hold -- name each " ..
      "in build/test.tl's `harness_own`, or build/test_worker.tl's `worker.loads` where " ..
      "a worker loads it: " .. table.concat(missing, ", "))
end

--- A standard-library module of the harness held alone, whose requires are
--- not walked, holds what is split off it too: a module it requires by
--- value named after it (cosmic.sandbox_policy, which cosmic.sandbox's
--- `merge` is, deciding a policy worker's grants) is in the harness.
--- Otherwise an edit to the part split off would move no digest.
local function test_what_is_split_off_a_module_of_the_harness_is_held()
  local db = assert(Sqlite.open("o/cosmic.db"))
  local found, trouble = test.harness(db)
  assert(found ~= nil, trouble)
  local by_value = assert(test.value_imports(db))
  db:close()
  local named: {string:boolean} = {}
  for _, name in ipairs(found.names) do named[name] = true end
  assert(named["cosmic.sandbox_policy"], "cosmic.sandbox_policy is not held")
  local unheld: {string} = {}
  for _, name in ipairs(found.names) do
    if name:match("^cosmic%.") then
      for _, wanted in ipairs(by_value[name] or {}) do
        if wanted:sub(1, #name + 1) == name .. "_" and not named[wanted] then
          unheld[#unheld + 1] = name .. " requires " .. wanted
        end
      end
    end
  end
  table.sort(unheld)
  assert(#unheld == 0, "the harness holds a module and not what is split off it -- name " ..
      "each in build/test.tl's `harness_alone`: " .. table.concat(unheld, ", "))
end

--- The harness's `cosmic.*` modules are exactly those
--- build/harness_epoch.tl's `library` names, each with its reason: a
--- module of the harness that comes to require another -- cosmic.time
--- for a clock the raw binding gives -- fails here with the rule,
--- rather than passing once its digest is acknowledged.
local function test_the_harness_names_its_library()
  local db = assert(Sqlite.open("o/cosmic.db"))
  local found, trouble = test.harness(db)
  db:close()
  assert(found ~= nil, trouble)
  local held: {string:boolean} = {}
  local unnamed: {string} = {}
  for _, name in ipairs(found.names) do
    if name:match("^cosmic%.") then
      held[name] = true
      if harness_epoch.library[name] == nil then unnamed[#unnamed + 1] = name end
    end
  end
  local unheld: {string} = {}
  for name, reason in pairs(harness_epoch.library) do
    assert(reason ~= "", name .. " is in `library` with no reason")
    if not held[name] then unheld[#unheld + 1] = name end
  end
  table.sort(unnamed)
  table.sort(unheld)
  assert(#unnamed == 0, "the harness reaches " .. table.concat(unnamed, ", ") ..
      ", which build/harness_epoch.tl's `library` does not name: a module of the harness " ..
      "reaches the host through raw bindings and the library `library` names, each " ..
      "with its reason; take what it needs from a raw binding, or name the module there " ..
      "with why the harness must reach it")
  assert(#unheld == 0, "build/harness_epoch.tl's `library` names " ..
      table.concat(unheld, ", ") .. ", which no module of the harness reaches: " ..
      "delete its entry")
end

--- An edge of `imports` is followed unless the importer's bytecode
--- lacks the name it requires: a require spelt `require"x"`, or split
--- across lines, keeps the name there and is followed; a `local type`
--- one, which Teal erases, leaves none and is not.
local function test_value_imports_follows_every_spelling_of_a_require()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE modules (path TEXT, kind TEXT, bytecode BLOB); " ..
      "CREATE TABLE imports (path TEXT, requires TEXT)"))
  local compiled = string.dump(assert(load(table.concat({
    'local a = require"cosmic.fs"',
    'local b = require(',
    '  "cosmic.env")',
    'return a, b',
  }, "\n"))), true)
  assert(Sqlite.run(db, "INSERT INTO modules VALUES ('build.x', 'module', ?1)",
    { { blob = compiled } }))
  for _, wanted in ipairs({ "cosmic.fs", "cosmic.env", "cosmic.child" }) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES ('build.x', ?1)", { { text = wanted } }))
  end
  -- An importer the table holds no bytecode of is followed as it is.
  assert(Sqlite.run(db, "INSERT INTO imports VALUES ('build.y', 'cosmic.time')"))
  local by_value = assert(test.value_imports(db))
  db:close()
  local kept: {string:boolean} = {}
  for _, name in ipairs(by_value["build.x"] or {}) do kept[name] = true end
  assert(kept["cosmic.fs"] and kept["cosmic.env"], "a require's spelling dropped its edge")
  assert(not kept["cosmic.child"], "an edge the bytecode does not name was followed")
  assert((by_value["build.y"] or {})[1] == "cosmic.time")
end

--- The edges `type_only_imports` names are the ones `value_imports`
--- leaves out, of the importers whose bytecode the table holds.
local function test_type_only_imports_is_what_value_imports_drops()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE modules (path TEXT, kind TEXT, bytecode BLOB); " ..
      "CREATE TABLE imports (path TEXT, requires TEXT)"))
  local compiled = string.dump(assert(load('local a = require"cosmic.fs" return a')), true)
  assert(Sqlite.run(db, "INSERT INTO modules VALUES ('build.x', 'module', ?1)",
    { { blob = compiled } }))
  assert(Sqlite.run(db, "INSERT INTO modules VALUES ('build.t_test', 'test', ?1)",
    { { blob = compiled } }))
  for _, row in ipairs({ { "build.x", "cosmic.fs" }, { "build.x", "cosmic.child" },
      { "build.y", "cosmic.time" }, { "build.t_test", "cosmic.child" } }) do
    assert(Sqlite.run(db, "INSERT INTO imports VALUES (?1, ?2)",
      { { text = row[1] }, { text = row[2] } }))
  end
  local erased = assert(test.type_only_imports(db))
  db:close()
  assert(erased["build.x"] ~= nil and erased["build.x"]["cosmic.child"], "a type-only edge was kept")
  assert(not erased["build.x"]["cosmic.fs"], "a value edge was dropped")
  assert(erased["build.y"] == nil, "an importer with no bytecode lost an edge")
  assert(erased["build.t_test"] == nil, "a test's own edge was dropped")
end
