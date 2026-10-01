--- `cosmic refresh`: a program `cosmic build` wrote, refreshed from
--- files on disk -- the vendored bundle, a tzdata sdist made here from
--- the vendored zones -- and read back: its rows, the release its bill
--- of materials records, and that it still runs; and the docs that find
--- the verb. These need `store`: building that program copies every
--- `cosmic.*` module's rows from this program's own database
--- ([`embed.database`] reads [`Store.databases()`]), and `docs` searches
--- them. Refreshing this program itself is in build/refresh_tool_test.tl,
--- and what needs neither in build/refresh_test.tl.

local Child = require("cosmic.child")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local embed = require("build.embed")
local invoke = require("build.invoke")
local refresh = require("build.refresh")
local Time = require("cosmic.time")

--- The vendored bundle and zones a refresh replaces, and this program,
--- whose core a program it builds runs on.
--- `store`: [`embed.database`] reads every `cosmic.*` module's rows, and
--- `docs` searches them.
Test.needs{ reads = { "vendor/cacert/", "vendor/tzdata/" }, tool = true, store = true }

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

--- A program `cosmic build` wrote under `tmp`, which prints "ok": a
--- portable one, or with `host` one of this host's alone
--- (`cosmic build --host`), which a test runs with nothing of the
--- system's.
local function program(tmp: string, host?: boolean): string
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/cmd/ok"))
  assert(Fs.write(tree .. "/cmd/ok/main.tl", 'return function(): integer print("ok") return 0 end\n'))
  assert(embed.tree(tree, host))
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
  local path = program(tmp, true)
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

  local ran = assert(Child.run({ out }, { stdout = "capture",
    stderr = "capture", timeout_ns = Time.seconds(30) }))
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

--- What someone whose data went stale would ask `cosmic docs` finds
--- the verb.
local function test_docs_finds_refresh_by_what_it_is_for(tmp: string)
  for _, words in ipairs({ "update certificates", "time zone database out of date" }) do
    local result = invoke.run({ "docs", words }, { cwd = tmp })
    assert(result.stdout:find("Cli.refresh", 1, true), words .. ":\n" .. result.stdout)
  end
end
