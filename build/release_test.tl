--- `cosmic release` in process, over [`cosmic.http`]'s scripted
--- transport ([`build.release.Io.script`]: a canned reply per request, in
--- order, so no test reaches the network; [`build.release.Io.api`] points
--- it at http, since a canned reply cannot answer TLS). A run asks the
--- API for a page, then SHA256SUMS, source.json and, when it keeps or
--- pins it, the binary.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Shape = require("cosmic.shape")
local Test = require("cosmic.test")
local release = require("build.release")

Test.policy{ loopback = { "127.0.0.1" } }

local record Ran
  code: integer
  out: string
  err: string
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
  return string.format('{"tag_name":"next-%s","draft":%s,"published_at":"%s","assets":%s}',
    commit, tostring(draft == true), published, assets or all_assets)
end

--- A page of the API's: a draft newest of all, a release missing its
--- assets, then three usable ones, newest first.
local function page(): string
  return "[" .. table.concat({
    entry(string.rep("f", 40), "2026-10-18T12:00:00Z", true),
    entry(string.rep("e", 40), "2026-10-18T11:00:00Z", false, '[{"name":"cosmic"}]'),
    entry(newest, "2026-10-18T10:00:00Z"),
    entry(older, "2026-10-17T10:00:00Z"),
    entry(oldest, "2026-10-16T10:00:00Z"),
  }, ",") .. "]"
end

local function sums(): string return ok(digest .. "  cosmic\n") end

local function source(commit: string, d?: string): string
  return ok(string.format('{"commit":"%s","digest":"%s","run_url":"%s"}', commit, d or digest,
    "https://github.com/cosmic-lua/cosmic/actions/runs/1"))
end

local function run(words: {string}, script: {string}, env?: {string:string}): Ran
  local argv: {integer:string} = { [1] = "release" }
  for i, word in ipairs(words) do argv[i + 1] = word end
  local scripts: {{string}} = {}
  for i, one in ipairs(script) do scripts[i] = { one } end
  local out: {string} = {}
  local err: {string} = {}
  local code = release.run(argv, {
    script = scripts,
    api = "http://cosmic.test/releases",
    downloads = "http://cosmic.test/download/",
    env = env or {},
    out = function(text: string): boolean, string
      out[#out + 1] = text
      return true, ""
    end,
    err = function(line: string) err[#err + 1] = line .. "\n" end,
  })
  return { code = code, out = table.concat(out), err = table.concat(err) }
end

--- Asserts `ran` failed with exit 1 saying `says`, and printed nothing.
local function failed(ran: Ran, says: string)
  assert(ran.code == 1, tostring(ran.code) .. " " .. ran.err)
  assert(ran.err:find(says, 1, true) ~= nil, ran.err)
  assert(ran.out == "", ran.out)
end

local function test_the_newest_published_release_prints_as_a_pin()
  local ran = run({}, { ok(page()), sums(), source(newest) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == newest .. "\nhttps://github.com/cosmic-lua/cosmic/releases/download/next-" ..
      newest .. "/cosmic\n" .. digest .. "\n", ran.out)
  assert(ran.out == release.pin_text(newest, digest), ran.out)
end

local function test_a_commit_prefix_picks_its_release()
  local ran = run({ "--commit", "ABCCCCC" }, { ok(page()), sums(), source(older) })
  assert(ran.code == 0, ran.err)
  assert(ran.out:sub(1, 41) == older .. "\n", ran.out)
end

local function test_a_prefix_two_releases_share_is_refused_naming_both()
  local first = "1234567" .. string.rep("0", 33)
  local second = "1234567" .. string.rep("1", 33)
  local text = "[" .. entry(first, "2026-10-18T10:00:00Z") .. "," .. entry(second, "2026-10-17T10:00:00Z") .. "]"
  local ran = run({ "--commit", "1234567" }, { ok(text) })
  failed(ran, first)
  assert(ran.err:find(second, 1, true) ~= nil, ran.err)
end

local function test_before_takes_the_newest_published_earlier()
  local ran = run({ "--before", "2026-10-18" }, { ok(page()), sums(), source(older) })
  assert(ran.code == 0, ran.err)
  assert(ran.out:sub(1, 41) == older .. "\n", ran.out)
  local timed = run({ "--before", "2026-10-17T10:00:00Z" }, { ok(page()), sums(), source(oldest) })
  assert(timed.code == 0, timed.err)
  assert(timed.out:sub(1, 41) == oldest .. "\n", timed.out)
  failed(run({ "--before", "2026-01-01" }, { ok(page()) }), "no release matches")
end

local function test_a_full_commit_is_asked_for_by_its_tag()
  local ran = run({ "--commit", oldest }, { ok(entry(oldest, "2026-10-16T10:00:00Z")), sums(), source(oldest) })
  assert(ran.code == 0, ran.err)
  assert(ran.out:sub(1, 41) == oldest .. "\n", ran.out)
  failed(run({ "--commit", oldest }, { reply("404 Not Found", "{}") }), "no release matches, by its tag")
end

local function test_a_release_that_disagrees_with_itself_fails()
  failed(run({}, { ok(page()), sums(), source(older) }), "source.json names commit " .. older)
  local other = string.rep("0", 64)
  failed(run({}, { ok(page()), sums(), source(newest, other) }), "source.json names digest " .. other)
  failed(run({}, { ok(page()), ok("") }), "no digest for cosmic")
end

local function test_o_writes_the_verified_binary_executable(tmp: string)
  local path = tmp .. "/cosmic"
  local ran = run({ "-o", path }, { ok(page()), sums(), source(newest), ok(binary) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "", ran.out)
  assert(Fs.read(path) == binary)
  local st = assert(Fs.stat(path))
  assert(st.mode & 0x1ff == 0x1ed, string.format("%o", st.mode))
end

local function test_a_binary_that_is_not_the_digest_leaves_nothing(tmp: string)
  local path = tmp .. "/cosmic"
  failed(run({ "-o", path }, { ok(page()), sums(), source(newest), ok("other bytes") }), "sha256 mismatch")
  assert(Fs.exists(path) == false)
  assert(#assert(Fs.list(tmp)) == 0, "a temporary file was left")
  local pin = tmp .. "/pin"
  failed(run({ "--pin", pin }, { ok(page()), sums(), source(newest), ok("other bytes") }), "sha256 mismatch")
  assert(Fs.exists(pin) == false)
end

local function test_cache_fills_bootstraps_cache_once(tmp: string)
  local env = { XDG_CACHE_HOME = tmp .. "/cache" }
  local want = tmp .. "/cache/cosmic/bootstrap/cosmic-" .. digest
  local ran = run({ "--cache" }, { ok(page()), sums(), source(newest), ok(binary) }, env)
  assert(ran.code == 0, ran.err)
  assert(ran.out == want .. "\n", ran.out)
  assert(Fs.read(want) == binary)
  -- No reply for the binary: a second download would fail the run.
  local again = run({ "--cache" }, { ok(page()), sums(), source(newest) }, env)
  assert(again.code == 0, again.err)
  assert(again.out == want .. "\n", again.out)
end

local function test_pin_writes_the_pin_once_the_bytes_check(tmp: string)
  local pin = tmp .. "/cosmic-driver.pin"
  local ran = run({ "--pin", pin }, { ok(page()), sums(), source(newest), ok(binary) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "", ran.out)
  assert(Fs.read(pin) == release.pin_text(newest, digest))
  assert(#assert(Fs.list(tmp)) == 1, "only the pin is kept")
  local path = tmp .. "/bin"
  local both = run({ "--pin", pin, "-o", path }, { ok(page()), sums(), source(newest), ok(binary) })
  assert(both.code == 0, both.err)
  assert(Fs.read(path) == binary)
end

local function test_list_prints_the_matches_newest_first()
  local ran = run({ "--list" }, { ok(page()) })
  assert(ran.code == 0, ran.err)
  assert(ran.out == "2026-10-18T10:00:00Z  " .. newest .. "\n" ..
      "2026-10-17T10:00:00Z  " .. older .. "\n" ..
      "2026-10-16T10:00:00Z  " .. oldest .. "\n", ran.out)
  local none = run({ "--list", "--commit", "abcdeff" }, { ok(page()) })
  assert(none.code == 0, none.err)
  assert(none.out == "", none.out)
  local empty = run({ "--list", "--json", "--commit", "abcdeff" }, { ok(page()) })
  assert(empty.code == 0, empty.err)
  assert(empty.out == "[]\n", empty.out)
  local json = run({ "--list", "--json", "-n", "1" }, { ok(page()) })
  assert(json.code == 0, json.err)
  local decoded, why: {Printed} | nil, string = Shape.decode_into(json.out, Shape.list(PRINTED))
  assert(decoded ~= nil, why)
  assert(#decoded == 1, json.out)
  local first = assert(decoded[1])
  assert(first.commit == newest and first.tag == "next-" .. newest, json.out)
end

local function test_json_prints_the_verified_release()
  local ran = run({ "--json" }, { ok(page()), sums(), source(newest) })
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
      { "--before", "yesterday" },
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
