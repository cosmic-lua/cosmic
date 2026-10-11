--- A build with a pool of processes ([`build.workers`]) against the same
--- build without one: the rows it writes are the same ones, byte for
--- byte, whichever process parsed or compiled what, and whatever it is
--- left to do itself when a worker is lost or a module is refused.
--- Each case starts this program as the workers, past its launcher, and
--- so declares the profile that lets it.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local importer = require("build.importer")
local teal = require("build.teal")
local this_program = require("build.this_program")
local work = require("build.work")
local workers = require("build.workers")

Test.policy{ profiles = { "cosmic" } }

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- A library, six modules that each use a record of it, and a test of
--- each: the tests do not import one another, so that sharing them
--- among processes pays ([`build.shards`]).
local function project(): {string:string}
  local files: {string:string} = {
    ["lib.tl"] = [[
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
      for _, cell in ipairs(row) do
        cells[#cells + 1] = cell.kind .. ":" .. tostring(cell.text or cell.blob or cell.integer or "")
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
                          own?: boolean, unjudged?: boolean): Built
  local root = fixture(case, files)
  local handle = assert(work.open(root))
  assert(work.stage(handle, own or false))
  local result, trouble = importer.compile(handle, built, "worker-test", unjudged or false,
    nil, pool)
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

--- How many workers a pool takes in a process of this program that has
--- `value` as COSMIC_BUILD_JOBS, or has none for nil, and what it said.
local function jobs_with(value: string | nil): string, string
  local env = this_program.environment()
  env.COSMIC_BUILD_JOBS = value
  local chunk = 'local workers = require("build.workers") ' ..
    "print(workers.pool(workers.tool_spec()).size())"
  local started = this_program.program({ "-e", chunk }, {
    env = env, stdout = "capture", stderr = "capture",
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.ok, result.stderr)
  return (result.stdout or ""):gsub("%s+$", ""), result.stderr or ""
end

local function test_the_variable_sets_how_many_workers_a_build_runs()
  local fewer = math.max(Proc.cpu_count() - 1, 1)
  local three, three_said = jobs_with("3")
  assert(three == "3" and three_said == "", three .. " " .. three_said)
  assert(jobs_with("1") == "1")
  assert(jobs_with(nil) == tostring(fewer))
  for _, wrong in ipairs({ "0", "-2", "many", "2.5" }) do
    local answer, said = jobs_with(wrong)
    assert(answer == tostring(fewer), wrong .. ": " .. answer)
    assert(said:find("COSMIC_BUILD_JOBS=" .. wrong, 1, true), wrong .. ": " .. said)
  end
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
