--- `cosmic refresh`'s parts that need no program to refresh: what it
--- refuses before reading one, and how it reads a bundle, a PIN and
--- PyPI's answer. The refreshes of a program `cosmic build` wrote, and
--- the searches of this program's docs, are in `refresh_tool_test.tl`.

local Cli = require("cosmic.cli")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Vendor = require("build.vendor")
local refresh = require("build.refresh")

--- The vendored bundle, and the tzdata PIN whose rules a refresh keeps.
Test.needs{ reads = { "vendor/cacert/", "vendor/tzdata/PIN" } }

local bundle <const> = "vendor/cacert/cacert.pem"

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

--- What is not an artifact is refused by name, before anything is read
--- into it.
local function test_a_file_that_is_no_artifact_is_refused(tmp: string)
  local path = tmp .. "/plain"
  assert(Fs.write(path, "#!/bin/sh\n" .. ("# a script, not an artifact\n"):rep(4), 0x1ed))
  local lines, trouble = refresh.binary(path, tmp .. "/out", { datasets.cacert }, { cacert = bundle })
  assert(lines == nil and trouble:find("no artifact trailer", 1, true), trouble)
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
    assert(Cli.verbs.refresh.spec["--" .. dataset.name] ~= nil, dataset.name)
  end
end

local function test_a_bundle_is_named_by_its_mozilla_date()
  assert(refresh.cacert_date((assert(Fs.read(bundle)))) == pinned("cacert"))
  assert(refresh.cacert_date("##\n## Certificate data from Mozilla as of: Tue Sep  1 00:00:00 2026 GMT\n") ==
      "2026-09-01")
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
