--- `cosmic sql --from` run as this program: real standard input and the
--- files of the working directory, the verdict line last on stdout, and
--- what `cosmic help` says of it. These start this program, so they need
--- `tool`; the verb's own cases are in `sql_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.needs{ tool = true }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}, input?: string): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ms = 30000,
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

local function test_a_pipe_is_a_table_and_a_file_beside_it_joins(tmp: string)
  assert(Fs.write(tmp .. "/owners.json", '[{"id": 1, "who": "ann"}, {"id": 2, "who": "bob"}]'))
  local ran = cosmic(tmp, { "sql", "--from", "owners.json", "--from", "bal=-", "--as", "ndjson",
    "SELECT who, sum(balance) FROM owners JOIN bal USING (id) GROUP BY who ORDER BY who" },
    '{"id": 1, "balance": 5}\n{"id": 1, "balance": 7}\n{"id": 2, "balance": 1}\n')
  assert(ran.code == 0, ran.err)
  local lines: {string} = {}
  for line in ran.out:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(lines[1] == "who\tsum(balance)" and lines[2] == "ann\t12" and lines[3] == "bob\t1", ran.out)
  assert(lines[4]:find("^sql: PASS %(2 rows from owners.json, standard input, "), ran.out)
  assert(#lines == 4 and ran.err == "", ran.out .. ran.err)
end

local function test_a_refused_line_and_a_bad_file_keep_the_verdict_last(tmp: string)
  local unknown = cosmic(tmp, { "sql", "--from", "data.csv", "SELECT 1" })
  assert(unknown.code == 2, unknown.err)
  assert(unknown.out:find("^sql: FAIL %(usage"), unknown.out)
  local invalid = cosmic(tmp, { "sql", "--from", "-", "--as", "json", "SELECT 1" }, "{")
  assert(invalid.code == 1 and invalid.out:find("^sql: FAIL %(standard input"), invalid.out)
  assert(invalid.err:find("standard input: invalid JSON", 1, true), invalid.err)
end

--- Help reads the store's docs, which a test not declaring `store` is held
--- from, so it is here, with the tests that start the program.
local function test_help_points_between_sql_and_json(tmp: string)
  local sql = cosmic(tmp, { "help", "sql" })
  assert(sql.code == 0, sql.err)
  assert(sql.out:find("--from", 1, true) and sql.out:find("cosmic json", 1, true), sql.out)
  local json = cosmic(tmp, { "help", "json" })
  assert(json.out:find("cosmic sql --from", 1, true), json.out)
  local all = cosmic(tmp, { "help" })
  assert(all.out:find("cosmic sql --from", 1, true), all.out)
end
