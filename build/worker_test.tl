--- A build with a pool of processes ([`build.workers`]) against the same
--- build without one: the rows it writes are the same ones, byte for
--- byte, whichever process parsed or compiled what, and whatever it is
--- left to do itself when a worker is lost or a module is refused.
--- Each case starts this program as the workers, past its launcher, and
--- so declares the profile that lets it.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local cache_formats = require("build.cache_formats")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local this_program = require("build.this_program")
local work = require("build.work")
local workers = require("build.workers")

Test.policy{ profiles = { "cosmic", "proc" } }

local built = assert(teal.load())

--- A library, six modules that each use a record of it, and a test of
--- each: the tests do not import one another, so that sharing them
--- among processes pays ([`build.shards`]). The library quotes a line
--- led by the word `global` and declares none, as the checker's own
--- sources do: the pool takes the build all the same.
local function project(): {string:string}
  local files: {string:string} = {
    ["lib.tl"] = [[
--[=[
global G: integer = 1
]=]
local record lib
  record Box
    value: integer
  end
end

function lib.new(value: integer): lib.Box
  return { value = value }
end

return lib
]],
  }
  for at = 1, 6 do
    local name = "user" .. at
    files[name .. ".tl"] = 'local lib = require("lib")\n' ..
      "local function " .. name .. "(): integer\n" ..
      "  local box = lib.new(" .. at .. ")\n" ..
      "  return box.value + " .. at .. "\n" ..
      "end\n" ..
      "return " .. name .. "\n"
    files[name .. "_test.tl"] = 'local ' .. name .. ' = require("' .. name .. '")\n\n' ..
      "local function test_" .. name .. "_adds_its_number()\n" ..
      "  assert(" .. name .. "() == " .. 2 * at .. ")\n" ..
      "end\n"
  end
  return files
end

local function fixture(case: string, files: {string:string}): string
  local root = assert(Fs.mkdtemp("cosmic-worker-test-" .. case .. "-"))
  for filename, source in pairs(files) do
    local parent = filename:match("^(.+)/[^/]+$")
    if parent ~= nil then assert(Fs.mkdirs(root .. "/" .. parent)) end
    assert(Fs.write(root .. "/" .. filename, source))
  end
  return root
end

--- Every row of every table a parse or a compile writes, in the order the
--- table holds them (its key's, or the order they were written in where it
--- has none), one string per table, so that two builds that differ name
--- the table.
local function written(db: Sqlite.Handle): {string:string}
  local statements: {string:string} = {
    compiled = "SELECT key, tool, lua, bytecode, seen FROM compiled",
    typed_refs = "SELECT key, ordinal, module, member, line FROM typed_refs",
    plan = "SELECT path, key, ordinal FROM plan",
    parsed = "SELECT * FROM parsed",
    requires = "SELECT * FROM requires",
    tests = "SELECT * FROM tests",
    catalog = "SELECT * FROM catalog",
    docs = "SELECT * FROM docs",
    refs = "SELECT * FROM refs",
    bound = "SELECT * FROM bound",
    examples = "SELECT * FROM examples",
    test_inputs = "SELECT * FROM test_inputs",
    links = "SELECT * FROM links",
  }
  local out: {string:string} = {}
  for table_name, statement in pairs(statements) do
    local rows = assert(Sqlite.rows(db, statement))
    local lines: {string} = {}
    for _, row in ipairs(rows) do
      local cells: {string} = {}
      for index = 1, row:count() do
        local kind = row:kind(index)
        local value = ""
        if kind == "text" or kind == "blob" then
          value = row:bytes(index)
        elseif kind == "integer" then
          value = tostring(row:integer(index))
        end
        cells[#cells + 1] = kind .. ":" .. value
      end
      lines[#lines + 1] = table.concat(cells, "\t")
    end
    out[table_name] = Hash.hex_sha256(table.concat(lines, "\n")) .. " " .. #lines
  end
  return out
end

local record Built
  rows: {string:string}
  result: importer.Result | nil
  trouble: string
end

--- Stages `files` as cosmic's own tree when `own`, and compiles them with
--- `pool`, or alone for nil, keeping what the contracts refuse when
--- `unjudged`.
local function build_with(case: string, files: {string:string}, pool?: importer.Workers,
                          own?: boolean, unjudged?: boolean, shared?: importer.Shared): Built
  local root = fixture(case, files)
  local handle = assert(work.open(root))
  assert(work.stage(handle, own or false))
  local result, trouble = importer.compile(handle, built, "worker-test", unjudged or false,
    shared, pool)
  local rows = written(handle.db)
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
  return { rows = rows, result = result, trouble = trouble }
end

--- A pool of two workers that any amount of source is worth, started as
--- a tool starts them, or running `chunk` where one is given.
local function pool_of(chunk?: string, quiet_ns?: integer): importer.Workers
  local spec = workers.tool_spec()
  spec.open_bytes, spec.phase_bytes, spec.startup_ns = 0, 0, quiet_ns or 0
  if chunk ~= nil then spec.argv[#spec.argv] = chunk end
  return workers.pool(spec, 2)
end

local function same_rows(one: Built, other: Built)
  for table_name, digest in pairs(one.rows) do
    assert(other.rows[table_name] == digest,
      table_name .. ": " .. digest .. " against " .. tostring(other.rows[table_name]))
  end
end

local function test_a_pool_writes_the_rows_a_build_alone_writes()
  local alone = build_with("alone", project())
  local pooled = build_with("pooled", project(), pool_of())
  assert(alone.result ~= nil and pooled.result ~= nil, pooled.trouble)
  same_rows(alone, pooled)
  -- A pool that did nothing would pass the comparison.
  local result = pooled.result as importer.Result
  assert(result.parses.worked > 0 and result.parses.worked == result.parses.parsed,
    "workers parsed " .. result.parses.worked .. " of " .. result.parses.parsed)
  assert(result.worked > 0 and result.worked == result.compiled,
    "workers compiled " .. result.worked .. " of " .. result.compiled)
  assert((alone.result as importer.Result).worked == 0)
end

local function test_a_build_that_parses_while_the_workers_load_writes_the_same_rows()
  -- An hour of startup leaves every source to this process, as a short
  -- one leaves some: the rows come out in the same order.
  local alone = build_with("alone-early", project())
  local here = build_with("parsed-here", project(), pool_of(nil, 3600 * 1000000000))
  assert(here.result ~= nil, here.trouble)
  same_rows(alone, here)
  assert((here.result as importer.Result).parses.worked == 0)
end

local function test_a_module_the_compiler_refuses_is_refused_as_a_build_alone_refuses_it()
  local files = project()
  files["user3.tl"] = 'local lib = require("lib")\n' ..
    'local function user3(): integer\n  return lib.new(3).value .. "x"\nend\nreturn user3\n'
  local alone = build_with("refused-alone", files)
  local pooled = build_with("refused-pooled", files, pool_of())
  assert(alone.result == nil and pooled.result == nil, "a refused module compiled")
  assert(alone.trouble ~= "" and alone.trouble:find("user3.tl", 1, true), alone.trouble)
  assert(pooled.trouble == alone.trouble, pooled.trouble .. "\nagainst\n" .. alone.trouble)
end

local function test_a_build_whose_workers_will_not_start_goes_on_alone()
  local spec = workers.tool_spec()
  spec.open_bytes, spec.phase_bytes = 0, 0
  spec.argv = { "/nonexistent/cosmic-worker" }
  local alone = build_with("unstarted-alone", project())
  local lost = build_with("unstarted", project(), workers.pool(spec, 2))
  assert(lost.result ~= nil, lost.trouble)
  same_rows(alone, lost)
  assert((lost.result as importer.Result).worked == 0)
end

local function test_a_build_whose_workers_end_goes_on_alone()
  local alone = build_with("ended-alone", project())
  local ended = build_with("ended", project(), pool_of('require("cosmic.proc").exit(3)'))
  assert(ended.result ~= nil, ended.trouble)
  same_rows(alone, ended)
  local result = ended.result as importer.Result
  assert(result.worked == 0 and result.parses.worked == 0)
end

local function test_a_pool_is_ready_only_for_source_worth_its_workers()
  local spec = workers.tool_spec()
  spec.open_bytes, spec.phase_bytes = 1000, 10
  spec.argv = { "/nonexistent/cosmic-worker" }
  local pool = workers.pool(spec, 3)
  assert(not pool.ready(999), "ready for too little")
  -- Enough to start them, which cannot be done: the pool says so and
  -- is no more use.
  assert(not pool.ready(1000))
  assert(not pool.ready(1000000))
  pool.close()
  assert(not workers.pool(spec, 1).ready(1000000), "one worker is none")
end

--- A chunk for a worker that writes its process number to a file of
--- `dir` as it starts, then serves.
local function recording_worker(dir: string): string
  return 'local Proc = require("cosmic.proc") ' ..
    string.format('require("cosmic.fs").write(%q .. "/" .. Proc.pid(), "") ', dir) ..
    'Proc.exit(require("build.worker").serve())'
end

--- A chunk for a worker that writes its process number to a file of `dir`
--- as it starts, then sleeps a minute without reading its input.
local function sleeping_worker(dir: string): string
  return 'local Proc = require("cosmic.proc") ' ..
    string.format('require("cosmic.fs").write(%q .. "/" .. Proc.pid(), "") ', dir) ..
    'local Clock = require("cosmic.clock") Clock.sleep_ns(Clock.seconds(60))'
end

--- A chunk for a process that starts a pool of workers running `worker`
--- as a tool does, and then does `ending`.
local function starting_pool(dir: string, ending: string, worker?: string): string
  return 'local workers = require("build.workers") ' ..
    "local spec = workers.tool_spec() " ..
    "spec.open_bytes = 0 " ..
    string.format("spec.argv[#spec.argv] = %q ", worker or recording_worker(dir)) ..
    "local pool = workers.pool(spec) " ..
    'print(pool.ready(1)) ' .. ending
end

--- A chunk's statement that waits, at most a few seconds, until
--- `expected` workers have written their files to `dir`, and a moment
--- more for any that should not have.
local function waiting_for(dir: string, expected: integer): string
  if expected == 0 then return "" end
  return 'local Clock = require("cosmic.clock") local Fs = require("cosmic.fs") ' ..
    "local until_ns = Clock.monotonic_ns() + Clock.seconds(8) " ..
    string.format("while #Fs.list(%q) < %d and ", dir, expected) ..
    "Clock.monotonic_ns() < until_ns do Clock.sleep_ns(Clock.ms(20)) end " ..
    "Clock.sleep_ns(Clock.ms(500))"
end

--- Runs `chunk` in a process of this program, with `value` as
--- COSMIC_BUILD_JOBS (none for nil): what it printed and wrote to stderr.
local function run_chunk(chunk: string, value?: string, tmpdir?: string): string, string
  local env = this_program.environment()
  env.COSMIC_BUILD_JOBS = value
  if tmpdir ~= nil then env.TMPDIR = tmpdir end
  local started = this_program.program({ "-e", chunk }, {
    env = env, stdout = "capture", stderr = "capture",
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, result.stderr)
  return (result.stdout or ""):gsub("%s+$", ""), result.stderr or ""
end

local function names_in(dir: string): {string}
  local names = (assert(Fs.list(dir)))
  table.sort(names)
  return names
end

--- Waits until `holds` is true, at most ten seconds.
local function eventually(what: string, holds: function(): boolean)
  local deadline = Clock.monotonic_ns() + Clock.seconds(10)
  while not holds() do
    assert(Clock.monotonic_ns() < deadline, "no " .. what)
    Clock.sleep_ns(Clock.ms(20))
  end
end

--- The scratch directories a pool of this user left in the test's
--- temporary directory.
local function scratch_left(): {string}
  local parent = (this_program.environment().TMPDIR or "/tmp") .. "/cosmic-workers-" .. sys.getuid()
  local found: {string} = {}
  if Fs.exists(parent) then
    for _, name in ipairs(names_in(parent)) do
      if name:match("^%.scratch%.") then found[#found + 1] = name end
    end
  end
  return found
end

--- How many workers a pool of a process that has `value` as
--- COSMIC_BUILD_JOBS starts, and what that process said.
local function workers_started(expected: integer, value?: string): integer, string
  local dir = assert(Fs.mkdtemp("cosmic-pids-"))
  local _, said = run_chunk(starting_pool(dir, waiting_for(dir, expected) .. " pool.close()"), value)
  local count = #names_in(dir)
  -- A pool that was closed leaves no scratch directory.
  assert(#scratch_left() == 0, "a closed pool left its scratch directory")
  assert(Fs.remove_tree(dir))
  return count, said
end

local function test_the_variable_sets_how_many_workers_a_build_runs()
  local fewer = math.max(Proc.cpu_count() - 1, 1)
  local expected = fewer >= 2 and fewer or 0
  local three, three_said = workers_started(3, "3")
  assert(three == 3 and three_said == "", three .. " " .. three_said)
  assert(workers_started(0, "1") == 0)
  assert(workers_started(expected) == expected)
  for _, wrong in ipairs({ "0", "-2", "many", "2.5" }) do
    local count, said = workers_started(expected, wrong)
    assert(count == expected, wrong .. ": " .. count)
    assert(said:find("COSMIC_BUILD_JOBS=" .. wrong, 1, true), wrong .. ": " .. said)
  end
end

--- Whether the process `pid` is running, a zombie being none.
local function running(pid: string): boolean
  local stat = Fs.read("/proc/" .. pid .. "/stat")
  if stat == nil then return false end
  return stat:match("%) (%a)") ~= "Z"
end

local function test_a_pool_its_build_never_closed_leaves_no_worker_and_is_swept()
  local dir = assert(Fs.mkdtemp("cosmic-abandoned-"))
  local parent = (this_program.environment().TMPDIR or "/tmp") .. "/cosmic-workers-" .. sys.getuid()
  -- The build ends as a killed one does: with its pool open.
  local printed = run_chunk(starting_pool(dir, waiting_for(dir, 2) ..
      ' require("cosmic.proc").exit(0)'), "2")
  assert(printed == "true", printed)
  assert(#names_in(dir) == 2, "workers started: " .. #names_in(dir))
  for _, pid in ipairs(names_in(dir)) do
    eventually("worker " .. pid .. " ended", function(): boolean return not running(pid) end)
  end
  local left = names_in(parent)
  local abandoned: {string} = {}
  for _, name in ipairs(left) do
    if name:match("^%.scratch%.") then abandoned[#abandoned + 1] = name end
  end
  assert(#abandoned == 1, "scratch directories left: " .. #abandoned)
  -- The next build's pool sweeps what a dead one left.
  assert(run_chunk(starting_pool(dir, "pool.close()"), "2") == "true")
  for _, name in ipairs(names_in(parent)) do
    assert(name ~= abandoned[1], abandoned[1] .. " was not swept")
  end
  assert(Fs.remove_tree(dir))
end

local function test_a_second_parse_on_one_pool_is_served_by_workers_too()
  local root = fixture("twice", project())
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local pool = pool_of()
  local first = assert(importer.derive(handle, false, built, nil, pool))
  assert(first.parsed > 0 and first.worked == first.parsed, "first: " .. first.worked)
  assert(Fs.write(root .. "/extra1.tl", "local function one(): integer\n  return 1\nend\nreturn one\n"))
  assert(Fs.write(root .. "/extra2.tl", "local function two(): integer\n  return 2\nend\nreturn two\n"))
  assert(work.stage(handle, false))
  local second = assert(importer.derive(handle, false, built, nil, pool))
  assert(second.parsed == 2 and second.worked == 2,
    "second: parsed " .. second.parsed .. ", by workers " .. second.worked)
  pool.close()
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

--- A tree of cosmic's own, as [`build.importer`]'s tests make one: four
--- modules that are as they should be and one whose cast the contracts
--- refuse, none importing another.
local function own_tree(): {string:string}
  local files: {string:string} = {
    ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
    ["core/syscalls.h"] = table.concat({
      "/**",
      " * --- Reads bytes.",
      " * ---@param fd integer descriptor",
      " * ---@return string|nil data bytes",
      " * ---@return string error failure",
      " * ---@return integer errno number",
      " */",
      "COSMIC_SYSCALL(read, 1);",
    }, "\n") .. "\n",
    ["cosmic/casting.tl"] = table.concat({
      "local record Casting end",
      "function Casting.value(v: any): integer",
      "  return v as integer",
      "end",
      "return Casting",
    }, "\n") .. "\n",
  }
  for _, name in ipairs({ "first", "second", "third", "fourth" }) do
    files["cosmic/" .. name .. ".tl"] = "local record " .. name .. " end\n" ..
      "function " .. name .. ".value(): integer\n  return 1\nend\nreturn " .. name .. "\n"
  end
  return files
end

local function test_what_the_contracts_refuse_is_refused_as_a_build_alone_refuses_it()
  local alone = build_with("contract-alone", own_tree(), nil, true)
  local pooled = build_with("contract-pooled", own_tree(), pool_of(), true)
  assert(alone.result == nil and pooled.result == nil, "a refused cast compiled")
  assert(alone.trouble:find("cosmic/casting.tl:3: Casting.value: a cast", 1, true), alone.trouble)
  assert(pooled.trouble == alone.trouble, pooled.trouble .. "\nagainst\n" .. alone.trouble)
end

local function test_a_compile_an_unjudged_build_keeps_is_kept_by_the_workers_too()
  -- The workers judge as the build does: told not to, they hand back the
  -- refused module like any other, marked refused in `compiled`.
  local alone = build_with("kept-alone", own_tree(), nil, true, true)
  local pooled = build_with("kept-pooled", own_tree(), pool_of(), true, true)
  assert(alone.result ~= nil and pooled.result ~= nil, pooled.trouble)
  same_rows(alone, pooled)
  local result = pooled.result as importer.Result
  assert(result.worked == result.compiled and result.worked > 0,
    "workers compiled " .. result.worked .. " of " .. result.compiled)
end

--- What the compiles of a database hold of each planned module: its Lua,
--- its bytecode and the record-field uses it found.
local function compiled_outputs(db: Sqlite.Handle): string
  local rows = assert(Sqlite.rows(db,
    "SELECT p.path, c.lua, c.bytecode, coalesce((SELECT group_concat(module || member || line, ',') " ..
      "FROM (SELECT * FROM typed_refs r WHERE r.key = p.key ORDER BY ordinal)), '') FROM plan p JOIN compiled c ON c.key = p.key " ..
      "ORDER BY p.path"))
  local out = ""
  for _, row in ipairs(rows) do
    out = out .. row:bytes(1) .. "\n" .. row:bytes(2) .. "\n" .. Hash.hex_sha256(row:bytes(3)) ..
      "\n" .. row:bytes(4) .. "\n\0\n"
  end
  return out
end

--- A tree of cosmic's own whose modules a pool compiles the first time, and
--- which the second time an edit of a module that only moves the lines of
--- its stub leaves to one compile in this process: what stands in for each
--- of the others is what the pool made, byte for byte as a fresh build
--- would make it, and a type that changes is compiled by the pool again.
local function test_a_pooled_rebuild_after_an_edit_that_only_moves_lines_compiles_the_one()
  --- The tree with `first` as cosmic/first.tl, which seven modules require.
  local function tree(case: string, first: string): string
    local root = fixture(case, own_tree())
    assert(Fs.remove(root .. "/cosmic/casting.tl"))
    assert(Fs.write(root .. "/cosmic/first.tl", first))
    for at = 1, 7 do
      local name = "user" .. tostring(at)
      assert(Fs.write(root .. "/cosmic/" .. name .. ".tl", 'local first = require("cosmic.first")\n' ..
          "local record " .. name .. " end\nfunction " .. name .. ".value(): number\n" ..
          "  return first.value() + " .. tostring(at) .. "\nend\nreturn " .. name .. "\n"))
    end
    return root
  end
  local plain = "local record first end\nfunction first.value(): integer\n  return 1\nend\nreturn first\n"
  local shifted = "-- noted\n\n" .. plain
  local changed = "-- noted\n\nlocal record first end\nfunction first.value(): number\n  return 1.5\nend\nreturn first\n"
  local root = tree("moved", plain)
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local pool = pool_of()
  local one = assert(importer.compile(handle, built, "worker-test", false, nil, pool))
  assert(one.worked > 0, "the pool compiled nothing the first time")
  for step, source in ipairs({ shifted, changed }) do
    assert(Fs.write(root .. "/cosmic/first.tl", source))
    assert(work.stage(handle, true))
    local again, trouble = importer.compile(handle, built, "worker-test", false, nil, pool)
    local fresh_root = tree("moved-fresh", source)
    local fresh_handle = assert(work.open(fresh_root))
    assert(work.stage(fresh_handle, true))
    assert(importer.compile(fresh_handle, built, "worker-test", false, nil, nil))
    if step == 1 then
      assert(again ~= nil, trouble)
      assert(again.compiled == 1, "a move of lines compiled " .. tostring(again.compiled) .. " modules, not the one")
      assert(again.worked == 0, "the pool compiled " .. tostring(again.worked) .. " modules ahead where a compile stood in for the rest")
    end
    assert(again ~= nil, trouble)
    if step == 2 then
      assert(again.compiled > 1, "a type that changed compiled " .. tostring(again.compiled) .. " modules")
    end
    assert(compiled_outputs(handle.db) == compiled_outputs(fresh_handle.db),
      "step " .. tostring(step) .. ": a compile that stands in for another is not a fresh one")
    assert(work.close(fresh_handle))
    assert(Fs.remove_tree(fresh_root))
  end
  pool.close()
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

--- The compiles and parses every checkout shares, in the file `path`,
--- as a build is given them.
local function shared_at(path: string): importer.Shared
  return assert(shared_compiles.for_build({ COSMIC_BUILD_CACHE = path }))
end

--- What a shared cache file holds: each compile and parse by key, with
--- its digest, and how many were used after `since`.
local function cache_of(path: string, since: integer): {string}, integer
  local db = (assert(Sqlite.open(path)))
  local lines: {string} = {}
  local used = 0
  for _, kind in ipairs({ cache_formats.compiled, cache_formats.parsed }) do
    local held = (assert(Sqlite.rows(db, "SELECT * FROM " .. kind)))
    for _, row in ipairs(held) do
      local cells: {string} = {}
      for index = 1, row:count() do
        local cell_kind = row:kind(index)
        cells[#cells + 1] = cell_kind == "text" and row:text(index) or
          cell_kind == "integer" and tostring(row:integer(index)) or ""
      end
      lines[#lines + 1] = kind .. " " .. cells[1] .. " " .. cells[#cells - 2]
    end
    local touched = (assert(Sqlite.rows(db, "SELECT 1 FROM " .. kind .. " WHERE used_ns > ?1",
      { { integer = since } })))
    used = used + #touched
  end
  assert(db:close())
  table.sort(lines)
  return lines, used
end

local function test_a_pool_beside_the_shared_compiles_counts_and_marks_as_a_build_alone_does()
  local seed = assert(Fs.mkdtemp("cosmic-shared-")) .. "/seed.db"
  assert(build_with("seeded", project(), nil, nil, nil, shared_at(seed)).result)
  local seeded = assert(Fs.read(seed))
  local since = 0
  do
    local db = assert(Sqlite.open(seed))
    for _, kind in ipairs({ cache_formats.compiled, cache_formats.parsed }) do
      local row = (assert(Sqlite.rows(db, "SELECT max(used_ns) FROM " .. kind)))
      since = math.max(since, row[1]:kind(1) == "integer" and row[1]:integer(1) or 0)
    end
    assert(db:close())
  end
  -- The same project with two more modules, which only a compile can have.
  local files = project()
  for _, name in ipairs({ "extra1", "extra2" }) do
    files[name .. ".tl"] = 'local lib = require("lib")\nlocal function ' .. name ..
      '(): integer\n  return lib.new(1).value\nend\nreturn ' .. name .. "\n"
    files[name .. "_test.tl"] = 'local ' .. name .. ' = require("' .. name .. '")\n\n' ..
      "local function test_" .. name .. "()\n  assert(" .. name .. "() == 1)\nend\n"
  end
  local dir = assert(Fs.mkdtemp("cosmic-shared-copies-"))
  assert(Fs.write(dir .. "/alone.db", seeded))
  assert(Fs.write(dir .. "/pooled.db", seeded))
  local alone = build_with("shared-alone", files, nil, nil, nil, shared_at(dir .. "/alone.db"))
  local pooled = build_with("shared-pooled", files, pool_of(), nil, nil,
    shared_at(dir .. "/pooled.db"))
  assert(alone.result ~= nil and pooled.result ~= nil, pooled.trouble)
  same_rows(alone, pooled)
  local one, other = alone.result as importer.Result, pooled.result as importer.Result
  assert(one.shared > 0 and one.compiled == 4, "alone: " .. one.shared .. ", " .. one.compiled)
  assert(other.shared == one.shared and other.cached == one.cached and
      other.compiled == one.compiled and other.parses.shared == one.parses.shared,
    "pooled: shared " .. other.shared .. ", cached " .. other.cached .. ", compiled " ..
      other.compiled)
  assert(other.worked > 0, "workers compiled nothing")
  local alone_rows, alone_used = cache_of(dir .. "/alone.db", since)
  local pooled_rows, pooled_used = cache_of(dir .. "/pooled.db", since)
  assert(table.concat(alone_rows, "\n") == table.concat(pooled_rows, "\n"), "caches differ")
  assert(alone_used == pooled_used, "used " .. alone_used .. " against " .. pooled_used)
  assert(Fs.remove_tree(dir))
end

local function test_a_pool_refuses_a_scratch_parent_another_user_could_write()
  local tmp = this_program.environment().TMPDIR or "/tmp"
  local parent = tmp .. "/cosmic-workers-" .. sys.getuid()
  assert(Fs.mkdirs(parent))
  assert(Fs.chmod(parent, 0x1ff))
  local dir = assert(Fs.mkdtemp("cosmic-refused-"))
  local printed, said = run_chunk(starting_pool(dir, ""), "2")
  assert(printed == "false", "a pool started in a directory anyone can write: " .. printed)
  assert(said:find(parent .. ": writable by its group or others", 1, true), said)
  assert(said:find("building in this process", 1, true), said)
  assert(#names_in(dir) == 0 and #names_in(parent) == 0, "something was put there")
  assert(Fs.remove_tree(dir))
end

local function test_a_signal_to_the_builds_group_ends_its_workers()
  local dir = assert(Fs.mkdtemp("cosmic-group-"))
  local env = this_program.environment()
  env.COSMIC_BUILD_JOBS = "2"
  -- Workers that never read their input, as one busy with a job does,
  -- end only by the signal.
  local started = this_program.program({ "-e", starting_pool(dir, waiting_for(dir, 2) ..
      ' Clock.sleep_ns(Clock.seconds(60))', sleeping_worker(dir)) }, {
        env = env, stdout = "capture", stderr = "capture",
      })
  local build = assert(Child.start(started.argv, started.options))
  eventually("workers started", function(): boolean return #names_in(dir) == 2 end)
  assert(build:stop())
  assert(build:wait())
  for _, pid in ipairs(names_in(dir)) do
    eventually("worker " .. pid .. " ended", function(): boolean return not running(pid) end)
  end
  assert(Fs.remove_tree(dir))
end

--- `pool` as a build is given it, and how many times it handed back
--- compiled modules for the build to take. `before` is run on the working
--- database just before each ask.
local function counted(pool: importer.Workers, before?: function(Sqlite.Handle)): importer.Workers, {integer}
  local taken = { 0 }
  return {
    ready = pool.ready,
    parse = pool.parse,
    compile = function(db: Sqlite.Handle, root: string, order: {importer.Module},
                       wanted: {string:boolean}, own: boolean,
                       judged: boolean): importer.Ahead | nil, string
      if before ~= nil then before(db) end
      local ahead, trouble = pool.compile(db, root, order, wanted, own, judged)
      if ahead ~= nil then taken[1] = taken[1] + 1 end
      return ahead, trouble
    end,
    close = pool.close,
  }, taken
end

local function test_a_build_that_declares_a_global_compiles_alone_as_it_would_have()
  -- A global stays in the checker's environment for the modules checked
  -- after it in a process, so shards of modules would answer otherwise:
  -- the second declaration, unlike the first, is refused alone.
  local clash = project()
  clash["ga.tl"] = 'global G: string = "x"\nreturn {}\n'
  clash["gb.tl"] = "global G: integer = 1\nreturn {}\n"
  -- And a module that names a global without requiring its declarer is
  -- accepted alone, for whatever came before it.
  local named = project()
  named["ga.tl"] = "global G: integer = 1\nreturn {}\n"
  named["zc.tl"] = "local x: integer = G\nreturn x\n"
  for case, files in pairs({ clash = clash, named = named }) do
    local alone = build_with("global-alone-" .. case, files)
    local pool, taken = counted(pool_of())
    local pooled = build_with("global-pooled-" .. case, files, pool)
    assert((alone.result == nil) == (pooled.result == nil),
      case .. ": alone " .. alone.trouble .. " against pooled " .. pooled.trouble)
    assert(pooled.trouble == alone.trouble, case .. ": " .. pooled.trouble)
    if alone.result ~= nil then same_rows(alone, pooled) end
    assert(taken[1] == 0, case .. ": the pool compiled a build that declares a global")
  end
  assert(build_with("global-clash", clash).result == nil, "a clashing global compiled")
end

local function test_a_pool_leaves_a_build_whose_parse_found_a_global_to_one_process()
  -- importer.compile refuses a declared global before it asks a pool, so
  -- the pool's own answer is held here: given the parse's row of one, it
  -- takes no part, and without one it does.
  local clean, taken_clean = counted(pool_of())
  build_with("no-global-row", project(), clean)
  assert(taken_clean[1] == 1, "the pool took no part in a build with no global")
  local recorded, taken_recorded = counted(pool_of(), function(db: Sqlite.Handle)
    assert(Sqlite.run(db, "INSERT INTO globals (source_hash, ordinal, line, column) " ..
        "SELECT source_hash, 1, 1, 1 FROM inputs WHERE kind <> 'vendor' LIMIT 1", {}))
  end)
  build_with("global-row", project(), recorded)
  assert(taken_recorded[1] == 0, "the pool compiled a build the parse found a global in")
end

local function test_a_pool_refuses_a_scratch_parent_that_is_a_link()
  local tmp = this_program.environment().TMPDIR or "/tmp"
  local elsewhere = assert(Fs.mkdtemp("cosmic-elsewhere-"))
  assert(Fs.symlink(elsewhere, tmp .. "/cosmic-workers-" .. sys.getuid()))
  local dir = assert(Fs.mkdtemp("cosmic-linked-"))
  local printed, said = run_chunk(starting_pool(dir, ""), "2")
  assert(printed == "false", "a pool started through a link: " .. printed)
  assert(said:find(": is a link", 1, true), said)
  assert(#names_in(elsewhere) == 0, "something was put through the link")
  assert(Fs.remove_tree(dir))
end

local function test_a_pool_takes_an_empty_temporary_directory_for_none()
  local dir = assert(Fs.mkdtemp("cosmic-empty-"))
  local printed = run_chunk(starting_pool(dir, waiting_for(dir, 2) .. " pool.close()"), "2", "")
  assert(printed == "true", printed)
  assert(#names_in(dir) == 2, "workers started: " .. #names_in(dir))
  assert(not Fs.exists("/cosmic-workers-" .. sys.getuid()), "a scratch parent at the root")
  assert(Fs.remove_tree(dir))
end
