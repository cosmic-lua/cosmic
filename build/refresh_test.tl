--- `cosmic refresh`: a program `cosmic build` wrote, refreshed from
--- files on disk -- the vendored bundle, a tzdata sdist made here from
--- the vendored zones -- and read back: its rows, the release its bill
--- of materials records, and that it still runs.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Test = require("cosmic.test")
local Vendor = require("build.vendor")
local artifact = require("build.artifact")
local embed = require("build.embed")
local invoke = require("build.invoke")
local observations = require("build.filesystem_observations")
local refresh = require("build.refresh")

--- The vendored bundle and zones a refresh replaces, and the tool it
--- refreshes.
Test.needs{ reads = { "vendor/cacert/", "vendor/tzdata/" }, tool = true }

-- What these tests start is a program built from this very one.
observations.confine({ reads = observations.itself() })

local bundle <const> = "vendor/cacert/cacert.pem"
local zones <const> = "vendor/tzdata/zoneinfo"

--- The version `vendor/<name>/PIN` names: what a binary built from the
--- tree records.
local function pinned(name: string): string
  local text = assert(Fs.read("vendor/" .. name .. "/PIN"))
  return (assert(("\n" .. text):match("\nversion (%S+)")))
end

local datasets: {string:refresh.Dataset} = {}
for _, dataset in ipairs(refresh.datasets) do
  datasets[dataset.name] = dataset
end

--- A program `cosmic build` wrote under `tmp`, which prints "ok".
local function program(tmp: string): string
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/cmd/ok"))
  assert(Fs.write(tree .. "/cmd/ok/main.tl", 'return function(): integer print("ok") return 0 end\n'))
  assert(embed.tree(tree))
  return tree .. "/o/bin/ok"
end

--- The database the artifact at `path` carries, opened from a copy.
local function carried(path: string): Sqlite.Handle
  local parts = assert(artifact.split((assert(Fs.read(path)))))
  assert(Fs.write(path .. ".db", parts.database))
  return (assert(Sqlite.open(path .. ".db")))
end

local function rows(db: Sqlite.Handle, sql: string): {{string}}
  return (assert(Sqlite.text_rows(db, sql)))
end

--- A tzdata sdist as PyPI publishes one, `version`'s, holding `files`
--- under its `src/tzdata/`, as a gzipped tar at `path`.
local function sdist(path: string, version: string, files: {string:string})
  local out = Stream.collect()
  local w = Tar.writer(out, { deterministic = true })
  local names: {string} = {}
  for name in pairs(files) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    assert(w:add_file(("tzdata-%s/src/tzdata/%s"):format(version, name), files[name]))
  end
  assert(w:close())
  assert(Fs.write(path, (assert(Compress.deflate("gzip", out:result())))))
end

--- Every vendored zone, by its path under the sdist's `src/tzdata/`.
local function vendored_zones(): {string:string}
  local files: {string:string} = {}
  for _, name in ipairs((assert(Fs.walk_following(zones)))) do
    files["zoneinfo/" .. name] = assert(Fs.read(zones .. "/" .. name))
  end
  return files
end

--- The very bundle the binary was built from, refreshed in, makes the
--- binary it was: the same parse, the same rows in the same order,
--- the same release recorded, the same vacuumed bytes.
local function test_the_carried_bundle_makes_the_same_binary(tmp: string)
  local path = program(tmp)
  local out = tmp .. "/refreshed"
  local lines = assert(refresh.binary(path, out, { datasets.cacert }, { cacert = bundle }))
  assert(lines[1]:find("(as it was)", 1, true), lines[1])
  assert(Fs.read(out) == Fs.read(path), "a refresh to the carried release changed the binary")
end

--- A different bundle replaces the roots, records the release it came
--- from, and leaves a program that still runs.
local function test_a_new_bundle_replaces_the_roots(tmp: string)
  local path = program(tmp)
  local pem = assert(Fs.read(bundle))
  -- The bundle less its last certificate.
  local last = pem:match(".*()\n[^\n]+\n=+\n%-%-%-%-%-BEGIN CERTIFICATE")
  local smaller = pem:sub(1, last)
  local file = tmp .. "/smaller.pem"
  assert(Fs.write(file, smaller))
  local before = carried(path)
  local count = math.tointeger(tonumber(rows(before, "SELECT count(*) FROM ca_roots")[1][1]))
  assert(before:close())

  local out = tmp .. "/refreshed"
  assert(refresh.binary(path, out, { datasets.cacert }, { cacert = file }))
  local after = carried(out)
  assert(rows(after, "SELECT count(*) FROM ca_roots")[1][1] == tostring(count - 1))
  local component = rows(after, "SELECT version, url, sha256 FROM components WHERE name = 'cacert'")[1]
  assert(component[1] == pinned("cacert"), component[1])
  assert(component[2] == "file:smaller.pem", component[2])
  assert(component[3] == Hash.hex_sha256(smaller), component[3])
  assert(after:close())

  local ran = assert(Child.run({ out }, { env = observations.environment(), stdout = "capture",
    stderr = "capture", timeout_ms = 30000 }))
  assert(ran.ok and ran.stdout == "ok\n", tostring(ran.stderr))
end

--- An sdist of the vendored zones makes the table a boot made of them,
--- row for row, and records the sdist's version; what the PIN drops
--- stays out.
local function test_a_tzdata_sdist_replaces_the_zones(tmp: string)
  local path = program(tmp)
  local files = vendored_zones()
  files["zoneinfo/__init__.py"] = ""
  files["zoneinfo/tzdata.zi"] = "# version 2099a\n"
  files["zoneinfo/zone1970.tab"] = "# tab\n"
  files["__init__.py"] = ""
  local archive = tmp .. "/tzdata-2099.1.tar.gz"
  sdist(archive, "2099.1", files)

  local out = tmp .. "/refreshed"
  local lines = assert(refresh.binary(path, out, { datasets.tzdata }, { tzdata = archive }))
  assert(lines[1]:find("-> 2099.1", 1, true), lines[1])
  local before = carried(path)
  local after = carried(out)
  local query = "SELECT rowid, name, hex(sha256(data)) FROM zoneinfo ORDER BY rowid"
  local was, now = rows(before, query), rows(after, query)
  assert(#now == #was, #now .. " zones, not " .. #was)
  for i, row in ipairs(was) do
    assert(now[i][1] == row[1] and now[i][2] == row[2] and now[i][3] == row[3], row[2])
  end
  local component = rows(after, "SELECT version, sha256 FROM components WHERE name = 'tzdata'")[1]
  assert(component[1] == "2099.1", component[1])
  assert(component[2] == Hash.hex_sha256((assert(Fs.read(archive)))), component[2])
  assert(before:close())
  assert(after:close())
end

--- A release with one row that does not check out writes nothing.
local function test_a_bad_release_writes_nothing(tmp: string)
  local path = program(tmp)
  local archive = tmp .. "/tzdata.tar.gz"
  sdist(archive, "2099.1", { ["zoneinfo/Bad/Zone"] = "TZif not really" })
  local out = tmp .. "/refreshed"
  local lines, trouble = refresh.binary(path, out, { datasets.tzdata }, { tzdata = archive })
  assert(lines == nil and trouble:find("zone Bad/Zone", 1, true), trouble)

  -- A DER sequence, `30 03 'abc'`, that is no certificate: a binary
  -- carrying only it would trust nothing.
  local pem = tmp .. "/bad.pem"
  assert(Fs.write(pem, "Bad\n===\n-----BEGIN CERTIFICATE-----\nMANhYmM=\n-----END CERTIFICATE-----\n"))
  lines, trouble = refresh.binary(path, out, { datasets.cacert }, { cacert = pem })
  assert(lines == nil and trouble:find("certificate 1 (Bad)", 1, true), trouble)
  assert(not Fs.exists(out))

  -- Among roots it can read, it is left out, as the binary would drop
  -- it, and named.
  local mixed = tmp .. "/mixed.pem"
  assert(Fs.write(mixed, (assert(Fs.read(pem))) .. (assert(Fs.read(bundle)))))
  lines, trouble = refresh.binary(path, out, { datasets.cacert }, { cacert = mixed })
  assert(lines ~= nil, trouble)
  assert(lines[1]:find("left out certificate 1 (Bad)", 1, true), lines[1])
  local after = carried(out)
  local want = carried(path)
  local query = "SELECT hex(sha256), label FROM ca_roots ORDER BY rowid"
  local now, was = rows(after, query), rows(want, query)
  assert(#now == #was, #now .. " roots, not " .. #was)
  assert(after:close())
  assert(want:close())
  assert(Fs.remove(out))
  assert(not Fs.exists(out))
end

--- A verdict of a test that read a zone does not stand on a refreshed
--- binary, whose runtime identity is the one it was: its tables are
--- not, and the test, run again, fails for the zone it lacks.
local function test_a_refreshed_binary_runs_again_a_test_that_read_a_zone(tmp: string)
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/suite"))
  assert(Fs.write(tree .. "/suite/zone_test.tl", [[
local Time = require("cosmic.time")

local function test_reads_a_zone()
  assert(Time.zone("Europe/Paris"))
end
]]))
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  local function run(binary: string, name: string): boolean, string
    local output = tmp .. "/" .. name .. ".out"
    local fd = assert(Fs.open_write(output))
    local result, trouble = Child.run({ binary, "test" }, {
      cwd = tree, env = env, stdout = fd, stderr = fd,
      process_group = true, timeout_ms = 60000,
    })
    assert(Fs.close(fd))
    local text = assert(Fs.read(output))
    assert(result ~= nil, tostring(trouble) .. text)
    return result.ok, text
  end
  local itself = assert(Proc.executable())
  local ok, text = run(itself, "first")
  assert(ok and text:find("1 ran, 0 stood", 1, true), text)
  ok, text = run(itself, "again")
  assert(ok and text:find("0 ran, 1 stood", 1, true), text)

  -- A release of one zone, Paris not among them.
  local archive = tmp .. "/tzdata-2099.1.tar.gz"
  sdist(archive, "2099.1", {
    ["zoneinfo/Etc/GMT"] = assert(Fs.read(zones .. "/Etc/GMT")),
  })
  local refreshed = tmp .. "/refreshed"
  assert(refresh.binary(itself, refreshed, { datasets.tzdata }, { tzdata = archive }))
  ok, text = run(refreshed, "refreshed")
  assert(not ok and text:find("1 of 1 failed", 1, true) and text:find("Europe/Paris", 1, true), text)
end

--- What is not an artifact is refused by name, before anything is read
--- into it.
local function test_a_file_that_is_no_artifact_is_refused(tmp: string)
  local path = tmp .. "/plain"
  assert(Fs.write(path, "#!/bin/sh\n" .. ("# a script, not an artifact\n"):rep(4), 0x1ed))
  local lines, trouble = refresh.binary(path, tmp .. "/out", { datasets.cacert }, { cacert = bundle })
  assert(lines == nil and trouble:find("no artifact trailer", 1, true), trouble)
end

--- The command line: -o is required, and a dataset it does not know is
--- refused; -o naming the binary itself writes nothing.
local function test_the_command_line_is_refused_by_name(tmp: string)
  local path = program(tmp)
  local pem = assert(Fs.absolute(bundle))
  local cases: {{string}} = {
    { "refresh", "--binary", path, "--cacert", pem },
    { "refresh", "-o", tmp .. "/out", "--binary", path, "nosuch" },
  }
  for _, words in ipairs(cases) do
    local result = invoke.run(words, { cwd = tmp })
    assert(result.code == 2, table.concat(words, " ") .. ": exit " .. result.code)
  end
  -- Not a usage error, but never done: the binary it reads is not written.
  local itself = invoke.run({ "refresh", "-o", path, "--binary", path, "--cacert", pem }, { cwd = tmp })
  assert(itself.code == 1 and itself.stderr:find("never written", 1, true), itself.stderr)
  local result = invoke.run({ "refresh", "-o", tmp .. "/out", "--binary", path, "--cacert", pem },
    { cwd = tmp })
  assert(result.code == 0, result.stderr)
  assert(Fs.read(tmp .. "/out") == Fs.read(path))
end

--- The rules a refresh keeps an sdist's files by are the PIN's own.
local function test_the_tzdata_rules_are_the_pins()
  local text = assert(Fs.read("vendor/tzdata/PIN"))
  local pin = Vendor.read_pin(text)
  local version = assert(("\n" .. text):match("\nversion (%S+)"))
  local rules = refresh.tzdata_rules
  assert(pin.strip == rules.strip:format(version), pin.strip)
  assert(table.concat(pin.keep, " ") == table.concat(rules.keep, " "))
  assert(table.concat(pin.drop, " ") == table.concat(rules.drop, " "))
end

--- Every dataset is an option naming a file to read it from.
local function test_every_dataset_is_an_option()
  for _, dataset in ipairs(refresh.datasets) do
    assert(Cli.options.refresh["--" .. dataset.name] ~= nil, dataset.name)
  end
end

local function test_a_bundle_is_named_by_its_mozilla_date()
  assert(refresh.cacert_date((assert(Fs.read(bundle)))) == pinned("cacert"))
  assert(refresh.cacert_date("##\n## Certificate data from Mozilla as of: Tue Sep  1 00:00:00 2026 GMT\n")
    == "2026-09-01")
  assert(refresh.cacert_date("no date here") == nil)
  -- A day no month has, or one too long for an integer, is no date.
  for _, day in ipairs({ "00", "32", "99999999999999999999" }) do
    assert(refresh.cacert_date("\n## Certificate data from Mozilla as of: Thu Aug " .. day ..
      " 03:12:01 2026 GMT\n") == nil, day)
  end
  assert(refresh.cacert_date("\n## Certificate data from Mozilla as of: Tue Foo  1 00:00:00 2026 GMT\n") == nil)
end

local function test_the_newest_sdist_is_read_from_pypi()
  local source = assert(refresh.tzdata_release([[{
    "info": {"version": "2099.1"},
    "urls": [
      {"packagetype": "bdist_wheel", "url": "https://example.com/w.whl",
       "digests": {"sha256": "]] .. ("a"):rep(64) .. [["}},
      {"packagetype": "sdist", "url": "https://example.com/tzdata-2099.1.tar.gz",
       "digests": {"sha256": "]] .. ("B"):rep(64) .. [["}}
    ]}]]))
  assert(source.version == "2099.1")
  assert(source.url == "https://example.com/tzdata-2099.1.tar.gz")
  assert(source.sha256 == ("b"):rep(64))
  local none, trouble = refresh.tzdata_release([[{"info": {"version": "1"}, "urls": []}]])
  assert(none == nil and trouble:find("names no sdist", 1, true), trouble)
  none, trouble = refresh.tzdata_release("[]")
  assert(none == nil, trouble)
end

--- What someone whose data went stale would ask `cosmic docs` finds
--- the verb.
local function test_docs_finds_refresh_by_what_it_is_for(tmp: string)
  for _, words in ipairs({ "update certificates", "time zone database out of date" }) do
    local result = invoke.run({ "docs", words }, { cwd = tmp })
    assert(result.stdout:find("Cli.refresh", 1, true), words .. ":\n" .. result.stdout)
  end
end
