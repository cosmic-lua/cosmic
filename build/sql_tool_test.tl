--- `cosmic sql --from` run as this program: real standard input and the
--- files of the working directory, the rows alone on stdout, and
--- what `cosmic help` says of it. These start this program, so they need
--- `tool`; the verb's own cases are in `sql_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}, input?: string): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ns = Clock.seconds(30),
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
  assert(#lines == 3, ran.out)
  assert(ran.err:find("^sql: 2 rows from owners.json, standard input, %d+ ms\n$"), ran.err)
end

--- A refused line and a bad file are complained about, and get no
--- summary: stdout stays empty for both.
local function test_a_refused_line_and_a_bad_file_say_why_on_stderr(tmp: string)
  local unknown = cosmic(tmp, { "sql", "--from", "data.xml", "SELECT 1" })
  assert(unknown.code == 2 and unknown.out == "", unknown.out)
  assert(unknown.err:find("^cosmic: sql: ") and not unknown.err:find("\nsql: "), unknown.err)
  local invalid = cosmic(tmp, { "sql", "--from", "-", "--as", "json", "SELECT 1" }, "{")
  assert(invalid.code == 1 and invalid.out == "", invalid.out)
  assert(invalid.err:find("^cosmic: sql: ") and not invalid.err:find("\nsql: "), invalid.err)
  assert(invalid.err:find("standard input: json: invalid JSON", 1, true), invalid.err)
end

--- Help reads the store's docs, which a test not declaring `store` is not
--- given, so it is here, with the tests that start the program.
local function test_help_points_between_sql_and_json(tmp: string)
  local sql = cosmic(tmp, { "help", "sql" })
  assert(sql.code == 0, sql.err)
  assert(sql.out:find("--from", 1, true) and sql.out:find("cosmic json", 1, true), sql.out)
  local json = cosmic(tmp, { "help", "json" })
  assert(json.out:find("cosmic sql --from", 1, true), json.out)
end

local function test_a_csv_from_a_file_and_standard_input_through_the_binary(tmp: string)
  assert(Fs.write(tmp .. "/sales.csv", "region,amount\nn,\"1,5\"\ns,2\ns,3\n"))
  local ran = cosmic(tmp, { "sql", "--from", "sales.csv", "--raw", "--from", "t=-", "--as", "tsv",
    "SELECT region, typeof(amount), b FROM sales JOIN t ON t.a = region ORDER BY amount" }, "a\tb\nn\tone\n")
  assert(ran.code == 0, ran.err)
  assert(ran.out == "region\ttypeof(amount)\tb\nn\ttext\tone\n", ran.out)
  assert(ran.err:find("^sql: 1 row from sales.csv, standard input, "), ran.err)
end

--- `--to` in a pipe through the binary: stdout holds the data alone, the
--- summary is on stderr, and an NDJSON row whose keys are in byte
--- order comes back as it went in, as `_json` holds it.
local function test_to_writes_data_alone_on_stdout_through_the_binary(tmp: string)
  local row = '{"a":3,"b":"y\\"\\\\n","c":{"d":[1,2]}}'
  local ran = cosmic(tmp, { "sql", "--from", "-", "--as", "ndjson", "--to", "ndjson",
    "SELECT _json FROM stdin WHERE a > 1" }, '{"a":1}\n' .. row .. "\n")
  assert(ran.code == 0, ran.err)
  assert(ran.out == row .. "\n", ran.out)
  assert(ran.err:find("^sql: 1 row from standard input, ") ~= nil, ran.err)
  ran = cosmic(tmp, { "sql", "--from", "-", "--as", "ndjson", "--to", "csv", "SELECT a, b FROM stdin" },
    '{"a":1,"b":"x, y"}\n')
  assert(ran.code == 0 and ran.out == 'a,b\n1,"x, y"\n', ran.out .. ran.err)
end

--- With `--to` on the line, a command line that will not parse is
--- complained about on stderr: stdout stays empty.
local function test_to_keeps_stdout_empty_for_a_usage_error(tmp: string)
  for _, words in ipairs({ { "sql", "--to", "csv", "--bogus", "SELECT 1" }, { "sql", "SELECT 1", "--to" },
      { "sql", "--to", "csv", "--to", "ndjson", "SELECT 1" } }) do
    local ran = cosmic(tmp, words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.out)
    assert(ran.err:find("^cosmic: sql: ") ~= nil, ran.err)
  end
end
