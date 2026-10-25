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
Test.policy{
  grants = {
    { path = "vendor/cacert/", letters = "r" },
    { path = "vendor/tzdata/PIN", letters = "r" },
  },
}

local bundle <const> = "vendor/cacert/certdata.txt"

--- The version `vendor/<name>/PIN` names: what a binary built from the
--- tree records.
local function pinned(name: string): string
  local text = assert(Fs.read("vendor/" .. name .. "/PIN"))
  return (assert(("\n" .. text):match("\nversion (%S+)")))
end

local datasets: mut {string:refresh.Dataset} = {}
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
    assert(assert(Cli.verbs.refresh.spec)["--" .. dataset.name] ~= nil, dataset.name)
  end
end

--- A PEM bundle `--cacert` names (curl's cacert.pem) is named by the
--- date of the Mozilla data it holds.
local function test_a_bundle_is_named_by_its_mozilla_date()
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

--- The newest NSS release is the greatest version among the tags,
--- compared by number, a patch release past its minor's; a tag that is
--- no release is none.
local function test_the_newest_nss_release_is_read_from_its_tags()
  local function refs(...: string): string
    local items: mut {string} = {}
    for i, tag in ipairs({ ... }) do
      items[i] = '{"ref": "refs/tags/' .. tag .. '", "object": {}}'
    end
    return "[" .. table.concat(items, ",") .. "]"
  end
  assert(refresh.newest_nss(refs("NSS_3_99_RTM", "NSS_3_131_RTM", "NSS_3_131_1_RTM", "NSS_3_132_BETA1")) ==
      "NSS_3_131_1_RTM")
  assert(refresh.newest_nss(refs("NSS_3_131_1_RTM", "NSS_3_132_RTM", "NSS_3_9_RTM")) == "NSS_3_132_RTM")
  assert(refresh.newest_nss(refs("NSS_4_1_RTM", "NSS_3_200_RTM")) == "NSS_4_1_RTM")
  assert(refresh.newest_nss(refs("NSS_3_132_BETA1", "nss-3.132")) == nil)
  assert(refresh.newest_nss("[]") == nil)
  -- The tree's own pin names one.
  assert(refresh.newest_nss(refs(pinned("cacert"))) == pinned("cacert"))
end

--- The next page of a listing is the `Link` header's `rel="next"`, and
--- the last page has none.
local function test_the_next_page_is_read_from_the_link_header()
  local api = "https://api.github.com/repositories/1/git/matching-refs/tags/NSS_?per_page=100"
  assert(refresh.next_page('<' .. api .. '&page=2>; rel="next", <' .. api .. '&page=4>; rel="last"') ==
      api .. "&page=2")
  assert(refresh.next_page('<' .. api .. '&page=1>; rel="prev", <' .. api .. '&page=1>; rel="first"') == nil)
  assert(refresh.next_page(nil) == nil)
  assert(refresh.next_page("") == nil)
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

--- A refresh fetches what a binary trusts next, checked by nothing but
--- the connection it came over, so it trusts the minimal roots, not
--- every root the running binary carries.
local function test_a_refresh_trusts_the_minimal_roots_alone()
  local roots = refresh.fetching().roots
  assert(roots == "minimal", tostring(roots))
end
