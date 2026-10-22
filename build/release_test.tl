--- `cosmic release` in process, over [`cosmic.http`]'s scripted
--- transport ([`build.release.Io.script`]: a canned reply per request, in
--- order, so no test reaches the network; [`build.release.Io.api`] points
--- it at http, since a canned reply cannot answer TLS). A run asks the
--- API for the `next-` tags, main's history and the release of each
--- tagged commit in it until enough are found -- or, for a `--commit`
--- prefix, the tags it starts and each one's release -- then SHA256SUMS,
--- source.json and, when it keeps or pins it, the binary.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local release = require("build.release")

--- `store`: a root the binary carries is read through
--- [`Store.databases()`].
Test.policy{ loopback = { "127.0.0.1" }, grants = { { path = "o/cosmic.db", letters = "r" } } }

local record Ran
  code: integer
  out: string
  err: string
  --- Each API request's URL, in order.
  asked: {string}
end

--- What `--json` prints of one release.
local record Printed
  tag: string
  commit: string
  sha256: string | nil
end
local PRINTED <const> = Shape.record({ tag = Shape.string, commit = Shape.string,
  sha256 = Shape.optional(Shape.string) })

local binary <const> = "the cosmic binary's bytes"
local digest <const> = Hash.hex_sha256(binary)
local newest <const> = string.rep("a", 40)
local older <const> = "ab" .. string.rep("c", 38)
local oldest <const> = "ab" .. string.rep("d", 38)
local all_assets <const> = '[{"name":"cosmic"},{"name":"SHA256SUMS"},{"name":"source.json"}]'

local function reply(status: string, body: string): string
  return "HTTP/1.1 " .. status .. "\r\nContent-Length: " .. tostring(#body) ..
    "\r\nConnection: close\r\n\r\n" .. body
end

local function ok(body: string): string return reply("200 OK", body) end

--- One release as the API lists it.
local function entry(commit: string, published: string, draft?: boolean, assets?: string): string
  return string.format('{"tag_name":"next-%s","draft":%s,"prerelease":true,"published_at":"%s","assets":%s}',
    commit, tostring(draft == true), published, assets or all_assets)
end

--- What git matching-refs answers for tags of these commits.
local function refs(...: string): string
  local items: {string} = {}
  for i, commit in ipairs({ ... }) do items[i] = '{"ref":"refs/tags/next-' .. commit .. '"}' end
  return ok("[" .. table.concat(items, ",") .. "]")
end

--- A page of main's history: these commits, newest first.
local function history(...: string): string
  local items: {string} = {}
  for i, commit in ipairs({ ... }) do items[i] = '{"sha":"' .. commit .. '"}' end
  return ok("[" .. table.concat(items, ",") .. "]")
end

--- The replies that find the newest of the three, then `rest`.
local function newest_then(...: string): {string}
  local script: {string} = {
    refs(newest, older, oldest),
    history(newest, older, oldest),
    ok(entry(newest, "2026-10-18T10:00:00Z")),
  }
  for _, one in ipairs({ ... }) do script[#script + 1] = one end
  return script
end

local function sums(): string return ok(digest .. "  cosmic\n") end

local function source(commit: string, d?: string): string
  return ok(string.format('{"commit":"%s","digest":"%s","run_url":"%s"}', commit, d or digest,
    "https://github.com/cosmic-lua/cosmic/actions/runs/1"))
end

local function run(words: {string}, script: {string}, env?: {string:string}, api?: string): Ran
  local argv: {integer:string} = { [1] = "release" }
  for i, word in ipairs(words) do argv[i + 1] = word end
  local scripts: {{string}} = {}
  for i, one in ipairs(script) do scripts[i] = { one } end
  local out: {string} = {}
  local err: {string} = {}
  local asked: {string} = {}
  local code = release.run(argv, {
    requested = function(url: string) asked[#asked + 1] = url end,
    script = scripts,
    api = api or "http://cosmic.test/repo",
    downloads = "http://cosmic.test/download/",
    env = env or {},
    out = function(text: string): boolean, string
      out[#out + 1] = text
      return true, ""
    end,
    err = function(line: string) err[#err + 1] = line .. "\n" end,
  })
  return { code = code, out = table.concat(out), err = table.concat(err), asked = asked }
end

--- Asserts `ran` failed with exit 1 saying `says`, and printed nothing.
local function failed(ran: Ran, says: string)
  assert(ran.code == 1, tostring(ran.code) .. " " .. ran.err)
  assert(ran.err:find(says, 1, true) ~= nil, ran.err)
  assert(ran.out == "", ran.out)
end

local function test_the_newest_published_release_prints_as_a_pin()
  local ran = run({}, newest_then(sums(), source(newest)))
  assert(ran.code == 0, ran.err)
  assert(ran.out == newest .. "\nhttps://github.com/cosmic-lua/cosmic/releases/download/next-" ..
      newest .. "/cosmic\n" .. digest .. "\n", ran.out)
  assert(ran.out == release.pin_text(newest, digest), ran.out)
end

--- A prefix is looked up by its tags, not the pages: the script holds
--- no page, so reading one would fail the run.
local function test_a_commit_prefix_picks_its_release_by_its_tags()
  local ran = run({ "--commit", "ABCCCCC" },
    { refs(older), ok(entry(older, "2026-10-17T10:00:00Z")), sums(), source(older) })
  assert(ran.code == 0, ran.err)
  assert(ran.out:sub(1, 41) == older .. "\n", ran.out)
end

--- A tag with no release (404) or only a draft's is passed over, and
--- the rest are sorted newest first.
local function test_a_prefix_passes_over_tags_without_a_release()
  local bare_tag = "abcdef0" .. string.rep("1", 33)
  local draft = "abcdef0" .. string.rep("4", 33)
  local earlier = "abcdef0" .. string.rep("2", 33)
  local later = "abcdef0" .. string.rep("3", 33)
  local ran = run({ "--list", "--commit", "abcdef0" }, {
    refs(bare_tag, draft, earlier, later),
    reply("404 Not Found", "{}"),
    ok(entry(draft, "2026-10-19T10:00:00Z", true)),
    ok(entry(earlier, "2026-10-17T10:00:00Z")),
    ok(entry(later, "2026-10-18T10:00:00Z")),
  })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "2026-10-18T10:00:00Z  " .. later .. "\n2026-10-17T10:00:00Z  " .. earlier .. "\n", ran.out)
  failed(run({ "--commit", "abcdef0" }, { refs() }), "no release matches, among the tags next-abcdef0 starts")
  failed(run({ "--commit", "abcdef0", "--until", "2026-01-01" }, { refs(earlier), ok(entry(earlier, "2026-10-17T10:00:00Z")) }),
    "published by --until 2026-01-01")
  failed(run({ "--commit", "abcdef0" }, { reply("404 Not Found", "{}") }), "matching-refs/tags/next-abcdef0: HTTP 404")
end

local function test_a_prefix_two_releases_share_is_refused_naming_both()
  local first = "1234567" .. string.rep("0", 33)
  local second = "1234567" .. string.rep("1", 33)
  local ran = run({ "--commit", "1234567" },
    { refs(first, second), ok(entry(first, "2026-10-18T10:00:00Z")), ok(entry(second, "2026-10-17T10:00:00Z")) })
  failed(ran, first)
  assert(ran.err:find(second, 1, true) ~= nil, ran.err)
end

local function test_a_prefix_naming_too_many_tags_is_refused()
  local many: {string} = {}
  for i = 1, 11 do many[i] = string.format("1234567%033x", i) end
  failed(run({ "--commit", "1234567" }, { refs(table.unpack(many)) }), "11 tags start with next-1234567")
  -- Ten are each asked for, none with a release.
  local ten: {string} = { refs(table.unpack(many, 1, 10)) }
  for i = 2, 11 do ten[i] = reply("404 Not Found", "{}") end
  failed(run({ "--commit", "1234567" }, ten), "no release matches, among the tags")
end

--- The history is main's, asked for cut at `--until`; a commit made by
--- then whose release was published after is passed over, a time
--- includes itself, and a date runs to the second before the next
--- midnight.
local function test_until_takes_the_latest_published_at_or_before()
  local late = "ab" .. string.rep("e", 38)
  local at = run({ "--until", "2026-10-17T10:00:00Z" }, {
    refs(late, older, oldest), history(late, older, oldest),
    ok(entry(late, "2026-10-17T10:30:00Z")), ok(entry(older, "2026-10-17T10:00:00Z")),
    sums(), source(older) })
  assert(at.code == 0, at.err)
  assert(at.out:sub(1, 41) == older .. "\n", "a time includes itself: " .. at.out)
  assert(at.asked[2] == "http://cosmic.test/repo/commits?sha=main&per_page=100&until=2026-10-17T10:00:00Z&page=1",
    tostring(at.asked[2]))
  local day = run({ "--until", "2026-10-17" }, {
    refs(late, older), history(late, older),
    ok(entry(late, "2026-10-18T00:00:00Z")), ok(entry(older, "2026-10-17T23:59:59Z")),
    sums(), source(older) })
  assert(day.code == 0, day.err)
  assert(day.out:sub(1, 41) == older .. "\n", "a date ends before the next one's midnight: " .. day.out)
  assert(tostring(day.asked[2]):find("&until=2026-10-17T23:59:59Z&", 1, true) ~= nil, tostring(day.asked[2]))
  failed(run({ "--until", "2026-01-01" }, { refs(newest), history() }), "no release matches, published by --until")
end

--- An untagged commit is not asked for, and a tagged one whose release
--- is gone (404), a draft, or unlike a published prerelease is passed
--- over.
local function test_history_passes_over_commits_without_a_usable_release()
  local untagged = string.rep("9", 40)
  local gone = "ab" .. string.rep("e", 38)
  local draft = "ab" .. string.rep("f", 38)
  local ran = run({}, {
    refs(newest, gone, draft, oldest, older),
    history(untagged, newest, gone, draft, oldest, older),
    ok(string.format('{"tag_name":"next-%s","draft":false,"prerelease":false,"published_at":"%s","assets":%s}',
      newest, "2026-10-18T10:00:00Z", all_assets)),
    reply("404 Not Found", "{}"),
    ok(entry(draft, "2026-10-18T09:30:00Z", true)),
    ok(entry(oldest, "2026-10-18T09:00:00Z", false,
      '[{"name":"cosmic"},{"name":"SHA256SUMS"},{"name":"source.json"},{"name":"extra"}]')),
    ok(entry(older, "2026-10-17T10:00:00Z")),
    sums(), source(older),
  })
  assert(ran.code == 0, ran.err)
  assert(ran.out:sub(1, 41) == older .. "\n", ran.out)
end

--- A full page of history leads to the next, even one with no tagged
--- commit; a commit the next repeats (history that grew between the two
--- requests) is asked for once.
local function test_history_is_read_past_a_page_without_a_tag()
  local untagged: {string} = {}
  for i = 1, 99 do untagged[i] = string.format("%040x", i) end
  untagged[100] = older
  local blank: {string} = {}
  for i = 1, 100 do blank[i] = string.format("%040x", 1000 + i) end
  local ran = run({ "--list" }, {
    refs(newest, older, oldest),
    history(table.unpack(blank)),
    history(table.unpack(untagged)),
    ok(entry(older, "2026-10-17T10:00:00Z")),
    history(older, oldest),
    ok(entry(oldest, "2026-10-16T10:00:00Z")),
  })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "2026-10-17T10:00:00Z  " .. older .. "\n2026-10-16T10:00:00Z  " .. oldest .. "\n", ran.out)
  assert(#ran.asked == 6, "older is asked for once: " .. table.concat(ran.asked, " "))
end

--- The read ends once every tagged commit has been passed, mid-page:
--- the script holds no next page. With no tags it reads no history.
local function test_history_ends_once_every_tag_is_passed()
  local page: {string} = { older }
  for i = 2, 100 do page[i] = string.format("%040x", i) end
  local ran = run({ "--list" }, { refs(older), history(table.unpack(page)), ok(entry(older, "2026-10-17T10:00:00Z")) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "2026-10-17T10:00:00Z  " .. older .. "\n", ran.out)
  local none = run({}, { refs() })
  failed(none, "no release matches")
  assert(#none.asked == 1, table.concat(none.asked, " "))
end

--- Past 100 full pages with a tag not yet passed, it fails rather than
--- answer in part.
local function test_history_past_100_pages_fails()
  local blank: {string} = {}
  for i = 1, 100 do blank[i] = string.format("%040x", i) end
  local script: {string} = { refs(newest) }
  for i = 2, 101 do script[i] = history(table.unpack(blank)) end
  failed(run({}, script), "main's history runs past 100 pages")
end

local function test_a_full_commit_is_asked_for_by_its_tag()
  local ran = run({ "--commit", oldest }, { ok(entry(oldest, "2026-10-16T10:00:00Z")), sums(), source(oldest) })
  assert(ran.code == 0, ran.err)
  assert(ran.out:sub(1, 41) == oldest .. "\n", ran.out)
  failed(run({ "--commit", oldest }, { reply("404 Not Found", "{}") }), "no release matches, by its tag")
end

local function test_a_release_that_disagrees_with_itself_fails()
  failed(run({}, newest_then(sums(), source(older))), "source.json names commit " .. older)
  local other = string.rep("0", 64)
  failed(run({}, newest_then(sums(), source(newest, other))), "source.json names digest " .. other)
  failed(run({}, newest_then(ok(""))), "no digest for cosmic")
  failed(run({}, newest_then(ok(string.rep("x", 65537)))), "more than 65536 bytes")
end

local function test_o_writes_the_verified_binary_executable(tmp: string)
  local path = tmp .. "/cosmic"
  local ran = run({ "-o", path }, newest_then(sums(), source(newest), ok(binary)))
  assert(ran.code == 0, ran.err)
  assert(ran.out == "", ran.out)
  assert(Fs.read(path) == binary)
  local st = assert(Fs.stat(path))
  assert(st.mode & 0x1ff == 0x1ed, string.format("%o", st.mode))
end

local function test_a_binary_that_is_not_the_digest_leaves_nothing(tmp: string)
  local path = tmp .. "/cosmic"
  failed(run({ "-o", path }, newest_then(sums(), source(newest), ok("other bytes"))), "sha256 mismatch")
  assert(Fs.exists(path) == false)
  assert(#assert(Fs.list(tmp)) == 0, "a temporary file was left")
  local pin = tmp .. "/pin"
  failed(run({ "--pin", pin }, newest_then(sums(), source(newest), ok("other bytes"))), "sha256 mismatch")
  assert(Fs.exists(pin) == false)
end

local function test_cache_fills_bootstraps_cache_once(tmp: string)
  local env = { XDG_CACHE_HOME = tmp .. "/cache" }
  local want = tmp .. "/cache/cosmic/bootstrap/cosmic-" .. digest
  local ran = run({ "--cache" }, newest_then(sums(), source(newest), ok(binary)), env)
  assert(ran.code == 0, ran.err)
  assert(ran.out == want .. "\n", ran.out)
  assert(Fs.read(want) == binary)
  -- No reply for the binary: a second download would fail the run. A
  -- run cut off before its chmod leaves the file unexecutable.
  assert(Fs.chmod(want, 0x1a4))
  local again = run({ "--cache" }, newest_then(sums(), source(newest)), env)
  assert(again.code == 0, again.err)
  assert(again.out == want .. "\n", again.out)
  assert(assert(Fs.stat(want)).mode & 0x1ff == 0x1ed, "a cached binary is made executable again")
end

local function test_pin_writes_the_pin_once_the_bytes_check(tmp: string)
  local pin = tmp .. "/cosmic-driver.pin"
  local ran = run({ "--pin", pin }, newest_then(sums(), source(newest), ok(binary)))
  assert(ran.code == 0, ran.err)
  assert(ran.out == "", ran.out)
  assert(Fs.read(pin) == release.pin_text(newest, digest))
  assert(#assert(Fs.list(tmp)) == 1, "only the pin is kept")
  local path = tmp .. "/bin"
  local both = run({ "--pin", pin, "-o", path }, newest_then(sums(), source(newest), ok(binary)))
  assert(both.code == 0, both.err)
  assert(Fs.read(path) == binary)
end

local function test_list_prints_the_matches_newest_first()
  local ran = run({ "--list" }, {
    refs(newest, older, oldest), history(newest, older, oldest),
    ok(entry(newest, "2026-10-18T10:00:00Z")), ok(entry(older, "2026-10-17T10:00:00Z")),
    ok(entry(oldest, "2026-10-16T10:00:00Z")),
  })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "2026-10-18T10:00:00Z  " .. newest .. "\n" ..
      "2026-10-17T10:00:00Z  " .. older .. "\n" ..
      "2026-10-16T10:00:00Z  " .. oldest .. "\n", ran.out)
  local none = run({ "--list", "--commit", "abcdeff" }, { refs() })
  assert(none.code == 0, none.err)
  assert(none.out == "", none.out)
  local empty = run({ "--list", "--json", "--commit", "abcdeff" }, { refs() })
  assert(empty.code == 0, empty.err)
  assert(empty.out == "[]\n", empty.out)
  local json = run({ "--list", "--json", "-n", "1" }, newest_then())
  assert(json.code == 0, json.err)
  local decoded, why: {Printed} | nil, string = Shape.decode_into(json.out, Shape.list(PRINTED))
  assert(decoded ~= nil, why)
  assert(#decoded == 1, json.out)
  local first = assert(decoded[1])
  assert(first.commit == newest and first.tag == "next-" .. newest, json.out)
end

local function test_json_prints_the_verified_release()
  local ran = run({ "--json" }, newest_then(sums(), source(newest)))
  assert(ran.code == 0, ran.err)
  local decoded, why: Printed | nil, string = Shape.decode_into(ran.out, PRINTED)
  assert(decoded ~= nil, why)
  assert(decoded.sha256 == digest and decoded.commit == newest, ran.out)
end

local function test_a_rate_limit_says_to_set_a_token()
  failed(run({}, { reply("403 Forbidden", "{}") }), "set GH_TOKEN")
  local held = run({}, { reply("403 Forbidden", "{}") }, { GH_TOKEN = "x" })
  failed(held, "rate limit")
  assert(held.err:find("GH_TOKEN", 1, true) == nil, held.err)
end

local function test_a_command_line_it_cannot_use_is_refused()
  for _, words in ipairs({
      { "--commit", "abc" },
      { "--commit", "xyzxyzx" },
      { "--until", "yesterday" },
      { "-o", "a", "--cache" },
      { "--list", "-o", "a" },
      { "--list", "--pin", "a" },
      { "-n", "3" },
      { "--list", "-n", "0" },
      { "--json", "--cache" },
      { "-o", "" },
      { "word" },
  }) do
    local ran = run(words, {})
    assert(ran.code == 2, table.concat(words, " ") .. ": " .. tostring(ran.code) .. " " .. ran.err)
    assert(ran.err:find("cosmic release", 1, true) ~= nil, ran.err)
  end
end

local function test_sums_digest_reads_the_cosmic_line()
  assert(release.sums_digest(string.rep("A", 64) .. " *cosmic\n") == string.rep("a", 64))
  assert(release.sums_digest(string.rep("a", 64) .. "  other\n") == nil)
  assert(release.sums_digest(string.rep("a", 63) .. "  cosmic\n") == nil)
  local twice = string.rep("a", 64) .. "  cosmic\n"
  assert(release.sums_digest(twice .. twice) == nil)
end

--- A TLS 1.2 server's first flight presenting the root the binary
--- carries under `label`: as far as a script can take a handshake, and
--- far enough to see the root trusted or not (cosmic/http_store_test.tl
--- has the same).
local function presenting(label: string): string
  local databases = Store.databases()
  local own = assert(databases[#databases])
  local rows = assert(Sqlite.text_rows(own,
    "SELECT hex(der) FROM ca_roots WHERE label = ?1", { { text = label } }))
  local der = assert(Codec.unhex(assert(rows[1]):text(1)))
  local function message(kind: integer, body: string): string
    return string.char(kind) .. string.pack(">I3", #body) .. body
  end
  local hello = message(2, "\3\3" .. string.rep("B", 32) .. "\0" .. "\192\47" .. "\0")
  local certificate = message(11, string.pack(">I3", #der + 3) .. string.pack(">I3", #der) .. der)
  local records = hello .. certificate
  return "\22\3\3" .. string.pack(">I2", #records) .. records
end

--- The API's answer names the digests downloads are checked against, so
--- its server is trusted by the minimal roots, not every carried one: one presenting a
--- root outside them is refused for this request's choice of roots, and
--- one inside them only for the name it stands for.
local function test_the_api_is_trusted_by_the_minimal_roots_alone()
  local api = "https://cosmic.test/repo"
  local outside = run({}, { presenting("Telia RSA TLS Root CA v3") }, {}, api)
  failed(outside, "opts.roots")
  local inside = run({}, { presenting("ISRG Root X1") }, {}, api)
  failed(inside, "Common Name")
end
