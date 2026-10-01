--- `cosmic refresh` of this program itself, run as a host program of
--- its core: a verdict of a test that read a zone does not stand on the
--- binary it refreshes. It needs `tool`, since it runs this program.
--- The refreshes of a program `cosmic build` wrote are in
--- build/refresh_store_test.tl, and what needs neither in
--- build/refresh_test.tl.

local Child = require("cosmic.child")
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local this_program = require("build.this_program")
local refresh = require("build.refresh")
local Time = require("cosmic.time")

--- The zone a release is made of, and the tool it refreshes, run as a
--- host program of this program's core: the kernel runs it, with no
--- launcher of the system's `sh` to run.
Test.needs{ reads = { "vendor/tzdata/zoneinfo/Etc/GMT" }, tool = true }

local zones <const> = "vendor/tzdata/zoneinfo"

local datasets: {string:refresh.Dataset} = {}
for _, dataset in ipairs(refresh.datasets) do
  datasets[dataset.name] = dataset
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
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = tmp .. "/cache/verdicts.db"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- Unsandboxed: the tables are keyed in the runtime of a run sandboxed
  -- or not, and a sandbox nested in this test's own is one a host may
  -- refuse (root nests one only two deep, where its runner cannot run
  -- its workers as a user of their own), so the runs mean the same
  -- everywhere.
  env.COSMIC_TEST_SANDBOX = "0"
  local function run(binary: string, name: string): boolean, string
    local output = tmp .. "/" .. name .. ".out"
    local fd = assert(Fs.open_write(output))
    local result, trouble = Child.run({ binary, "test" }, {
      cwd = tree, env = env, stdout = fd, stderr = fd,
      process_group = true, timeout_ns = Time.seconds(60),
    })
    assert(Fs.close(fd))
    local text = assert(Fs.read(output))
    assert(result ~= nil, tostring(trouble) .. text)
    return result.ok, text
  end
  -- This program, as a host program of its own core, which the kernel
  -- runs past any launcher.
  local parts = assert(artifact.split((assert(Fs.read((assert(Proc.executable())))))))
  local itself = tmp .. "/cosmic"
  assert(Fs.write(itself, assert(artifact.host_program(assert(artifact.trusted_core()),
    parts.database)), 0x1ed))
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
