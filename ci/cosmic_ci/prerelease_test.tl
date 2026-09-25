local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Prerelease = require("cosmic_ci.prerelease")
local Proc = require("cosmic.proc")

local commit <const> = string.rep("c", 40)
local repository <const> = "owner/repo"
local run_prefix <const> = "https://github.com/owner/repo/actions/runs/"
local tag <const> = "next-" .. commit

local function read(path: string): string return (assert(Fs.read(path))) end
local function write(path: string, data: string) assert(Fs.write(path, data)) end
local function exists(path: string): boolean
  local there, why = Fs.exists(path)
  assert(there ~= nil, why)
  return there
end
local function output(value: string | nil): string return value or "" end

--- Raises unless `action` raises a message holding `expected`.
local function refused(expected: string, action: function())
  local ok, why: boolean, any = pcall(action)
  assert(not ok, "accepted; expected a refusal naming " .. expected)
  assert(tostring(why):find(expected, 1, true), "refused otherwise: " .. tostring(why))
end

local function test_manifest_digest()
  local digest = string.rep("0123456789abcdef", 4)
  assert(Prerelease.manifest_digest(digest .. "  cosmic\n") == digest)
  assert(Prerelease.manifest_digest(digest .. "  cosmic") == digest)
  assert(Prerelease.manifest_digest(digest .. "  cosmic\n\n") == digest)
  for _, bad in ipairs({ digest:upper() .. "  cosmic\n", digest .. " cosmic\n",
      digest:sub(2) .. "  cosmic\n", digest .. "0  cosmic\n", digest .. "  cosmic \n",
      digest .. "  cosmic\r\n", digest .. "  cosmic\nmore\n", " " .. digest .. "  cosmic\n", "" }) do
    assert(Prerelease.manifest_digest(bad) == nil, bad)
  end
end

local function test_expects_four()
  assert(Prerelease.expects_four("4\n") and Prerelease.expects_four("4")
    and Prerelease.expects_four("4\n\n"))
  for _, bad in ipairs({ "3\n", " 4\n", "4 \n", "04\n", "", "\n4\n" }) do
    assert(not Prerelease.expects_four(bad), bad)
  end
end

--- The bytes the shell script wrote, `jq -n` for source.json and a
--- here-document for the notes, for the same inputs.
local function test_release_text_is_the_shell_scripts()
  local digest = string.rep("ab", 32)
  local run_url = run_prefix .. "123"
  assert(Prerelease.sums(digest) == digest .. "  cosmic\n")
  assert(Prerelease.source_json(commit, digest, run_url) ==
    '{\n  "commit": "' .. commit .. '",\n  "digest": "' .. digest ..
    '",\n  "run_url": "' .. run_url .. '"\n}\n')
  assert(Prerelease.notes(commit, digest, run_url) ==
    "Prerelease of commit `" .. commit .. "` from [CI run](" .. run_url .. ").\n\n" ..
    "The identical Cosmic bytes (SHA-256 `" .. digest .. "`) were tested by all four native " ..
    "workers: Linux x86_64, Linux aarch64, macOS aarch64, and Alpine x86_64. Each worker " ..
    "uploaded its executed-byte attestation, and the provenance join verified all four " ..
    "hashes before publication.\n")
end

local function test_source_valid()
  local digest = string.rep("ab", 32)
  local function valid(text: string): boolean
    return (Prerelease.source_valid(text, commit, digest, run_prefix))
  end
  assert(valid(Prerelease.source_json(commit, digest, run_prefix .. "123")))
  assert(valid('{"run_url":"' .. run_prefix .. '9","digest":"' .. digest ..
    '","commit":"' .. commit .. '","extra":1}'))
  for _, bad in ipairs({
      Prerelease.source_json(string.rep("d", 40), digest, run_prefix .. "1"),
      Prerelease.source_json(commit, string.rep("cd", 32), run_prefix .. "1"),
      Prerelease.source_json(commit, digest, run_prefix),
      Prerelease.source_json(commit, digest, run_prefix .. "12a"),
      Prerelease.source_json(commit, digest, run_prefix .. "12\n"),
      Prerelease.source_json(commit, digest, run_prefix .. "-1"),
      Prerelease.source_json(commit, digest, "https://github.com/other/repo/actions/runs/1"),
      Prerelease.source_json(commit, digest, "x" .. run_prefix .. "1"),
      '{"commit":"' .. commit .. '","digest":"' .. digest .. '","run_url":1}',
      '{"commit":"' .. commit .. '","digest":"' .. digest .. '"}',
      '["' .. commit .. '"]', "", "not json" }) do
    assert(not valid(bad), bad)
  end
end

local function test_http_status()
  assert(Prerelease.http_status("HTTP/2.0 404 Not Found\nX: y\n\n{}") == "404")
  assert(Prerelease.http_status("HTTP/1.1 302 Found\n\nHTTP/2.0 500 Error\n\n{}") == "500")
  assert(Prerelease.http_status("HTTP/2.0 404\n\n") == "404")
  assert(Prerelease.http_status("") == nil)
  assert(Prerelease.http_status("error connecting to api.github.com\n") == nil)
  assert(Prerelease.http_status(" HTTP/2.0 404 Not Found\n") == nil)
  assert(Prerelease.http_status("HTTP/2.0 Not Found\n") == nil)
end

local function test_asset_set()
  assert(Prerelease.complete_assets({ "SHA256SUMS", "cosmic", "source.json" }))
  assert(Prerelease.complete_assets({ "source.json", "cosmic", "SHA256SUMS" }))
  for _, bad in ipairs({ {}, { "cosmic", "SHA256SUMS" },
      { "cosmic", "SHA256SUMS", "source.json", "notes.md" },
      { "cosmic", "cosmic", "source.json" }, { "cosmic", "SHA256SUMS", "notes.md" } }) do
    assert(not Prerelease.complete_assets(bad), table.concat(bad, ","))
  end
  assert(Prerelease.known_asset("cosmic") and Prerelease.known_asset("SHA256SUMS")
    and Prerelease.known_asset("source.json"))
  assert(not Prerelease.known_asset("notes.md") and not Prerelease.known_asset("cosmic.exe"))
end

local function test_release_ids_gathers_every_page()
  local text = '[[{"id":1,"tag_name":"next-a"}],[{"id":2,"tag_name":"' .. tag ..
    '"},{"id":3,"tag_name":"next-b"}],[],[{"id":4,"tag_name":"' .. tag .. '"}]]'
  local ids = Prerelease.release_ids(text, tag)
  assert(#ids == 2 and ids[1] == 2 and ids[2] == 4)
  assert(#Prerelease.release_ids("[[]]", tag) == 0)
  refused("no JSON array", function() Prerelease.release_ids('{"id":1}', tag) end)
  refused("no array", function() Prerelease.release_ids('[{"id":1}]', tag) end)
  refused("has no id", function() Prerelease.release_ids('[[{"tag_name":"' .. tag .. '"}]]', tag) end)
end

--- Four lanes' products under `products`, each holding `bytes`.
local function products(dir: string, bytes: string): string
  for _, lane in ipairs(Prerelease.lanes) do
    local product = dir .. "/portable-product-" .. lane
    assert(Fs.mkdirs(product))
    write(product .. "/cosmic", bytes)
    write(product .. "/executed-cosmic.sha256", Hash.hex_sha256(bytes) .. "  cosmic\n")
    write(product .. "/expected-platforms", "4\n")
  end
  return dir
end

local function stage_context(tmp: string): Prerelease.Stage
  return { products = products(tmp .. "/products", "product bytes"),
    release = tmp .. "/release", commit = commit, run_url = run_prefix .. "7" }
end

local function test_stage_writes_the_release(tmp: string)
  local s = stage_context(tmp)
  Prerelease.stage(s)
  local digest = Hash.hex_sha256("product bytes")
  assert(read(s.release .. "/cosmic") == "product bytes")
  assert(read(s.release .. "/SHA256SUMS") == digest .. "  cosmic\n")
  assert(read(s.release .. "/source.json") == Prerelease.source_json(commit, digest, s.run_url))
  assert(read(s.release .. "/notes.md") == Prerelease.notes(commit, digest, s.run_url))
  assert(#assert(Fs.list(s.release)) == 4)
end

local function test_stage_refuses_what_the_lanes_disagree_on(tmp: string)
  local cases: {string: function(string)} = {
    ["found 3"] = function(p: string) assert(Fs.remove_tree(p .. "/portable-product-macos-aarch64")) end,
    ["found 5"] = function(p: string) assert(Fs.mkdirs(p .. "/portable-product-windows-x86_64")) end,
    ["expected portable-product-linux-x86_64"] = function(p: string)
      assert(Fs.rename(p .. "/portable-product-linux-x86_64", p .. "/elsewhere"))
      assert(Fs.symlink(p .. "/elsewhere", p .. "/portable-product-linux-x86_64"))
      assert(Fs.mkdirs(p .. "/portable-product-other"))
    end,
    ["no file expected-platforms"] = function(p: string)
      assert(Fs.remove(p .. "/portable-product-alpine-x86_64/expected-platforms"))
    end,
    ["no file executed-cosmic.sha256"] = function(p: string)
      local manifest = p .. "/portable-product-linux-aarch64/executed-cosmic.sha256"
      assert(Fs.remove(manifest) and Fs.mkdirs(manifest))
    end,
    ["expected-platforms is not 4"] = function(p: string)
      write(p .. "/portable-product-macos-aarch64/expected-platforms", "3\n")
    end,
    ["not `<sha256>  cosmic`"] = function(p: string)
      local manifest = p .. "/portable-product-alpine-x86_64/executed-cosmic.sha256"
      write(manifest, read(manifest):upper())
    end,
    ["not the bytes it executed"] = function(p: string)
      write(p .. "/portable-product-macos-aarch64/cosmic", "other bytes")
    end,
    ["differs from linux-x86_64's"] = function(p: string)
      local product = p .. "/portable-product-linux-aarch64"
      write(product .. "/cosmic", "other bytes")
      write(product .. "/executed-cosmic.sha256", Hash.hex_sha256("other bytes") .. "  cosmic\n")
    end,
  }
  local n = 0
  for expected, spoil in pairs(cases) do
    n = n + 1
    local dir = tmp .. "/case-" .. n
    local s = stage_context(dir)
    spoil(s.products)
    refused(expected, function() Prerelease.stage(s) end)
    assert(not exists(s.release), expected .. ": staged anyway")
  end
end

--- A repository standing in for GitHub's, behind a fake `gh` on PATH,
--- and a release staged for it.
local record Repo
  state: string
  env: {string:string}
  release: string
  temp: string
end

local function gh_script(): string
  local here = assert(Fs.absolute("."))
  return here .. "/testdata/prerelease/gh.tl"
end

local function repo(tmp: string, bytes?: string): Repo
  local state, bin = tmp .. "/state", tmp .. "/bin"
  assert(Fs.mkdirs(state) and Fs.mkdirs(bin))
  write(state .. "/repo", repository)
  write(bin .. "/gh", "#!/bin/sh\nexec '" .. assert(Proc.executable()) ..
    "' --standalone '" .. gh_script() .. "' \"$@\"\n")
  assert(Fs.chmod(bin .. "/gh", 0x1ed))
  local s = stage_context(tmp)
  s.products = products(tmp .. "/staged-products", bytes or "product bytes")
  Prerelease.stage(s)
  local env = Env.all()
  env.PATH = bin .. ":/usr/bin:/bin"
  env.GH_TOKEN = "fake-token"
  env.FAKE_GH_STATE = state
  env.REPOSITORY = repository
  env.RELEASE = s.release
  env.SOURCE_COMMIT = commit
  env.SOURCE_RUN_PREFIX = run_prefix
  env.RUNNER_TEMP = tmp .. "/runner"
  assert(Fs.mkdirs(env.RUNNER_TEMP))
  return { state = state, env = env, release = s.release, temp = env.RUNNER_TEMP }
end

local function publish(r: Repo): string
  return Prerelease.publish(Prerelease.publish_context(r.env))
end

--- A release of the tag in the fake repository, with these assets.
local function seed(r: Repo, id: string, draft: boolean, assets: {string:string})
  assert(Fs.mkdirs(r.state .. "/tags"))
  write(r.state .. "/tags/" .. tag, commit)
  local dir = r.state .. "/releases/" .. id
  assert(Fs.mkdirs(dir .. "/assets"))
  write(dir .. "/tag", tag)
  write(dir .. "/draft", tostring(draft))
  write(dir .. "/prerelease", "true")
  for name, data in pairs(assets) do write(dir .. "/assets/" .. name, data) end
end

local function staged(r: Repo): {string:string}
  local assets: {string:string} = {}
  for _, name in ipairs(Prerelease.assets) do assets[name] = read(r.release .. "/" .. name) end
  return assets
end

local function calls(r: Repo): string
  return exists(r.state .. "/calls") and read(r.state .. "/calls") or ""
end

local function count(text: string, pattern: string): integer
  local n = 0
  for _ in text:gmatch(pattern) do n = n + 1 end
  return n
end

--- The one release the fake repository holds is published and holds
--- exactly the staged assets.
local function published(r: Repo, id: string)
  local dir = r.state .. "/releases/" .. id
  assert(#assert(Fs.list(r.state .. "/releases")) == 1)
  assert(read(dir .. "/draft") == "false" and read(dir .. "/prerelease") == "true")
  local names = assert(Fs.list(dir .. "/assets"))
  assert(#names == 3)
  for name, data in pairs(staged(r)) do assert(read(dir .. "/assets/" .. name) == data, name) end
end

local function test_publish_creates_tag_and_release(tmp: string)
  local r = repo(tmp)
  assert(publish(r) == "prerelease published and verified: " .. tag)
  assert(read(r.state .. "/tags/" .. tag) == commit)
  published(r, "1")
  assert(read(r.state .. "/releases/1/notes") == read(r.release .. "/notes.md"))
  assert(read(r.state .. "/releases/1/title") == tag)
  local log = calls(r)
  assert(count(log, "release create ") == 1 and count(log, "release upload ") == 3)
  assert(count(log, "api %-%-method POST repos/owner/repo/git/refs ") == 1)
end

local function test_publish_resumes_a_draft_uploading_only_what_is_missing(tmp: string)
  local r = repo(tmp)
  local digest = Hash.hex_sha256("product bytes")
  -- The draft's source.json names the earlier run that uploaded it.
  seed(r, "5", true, { cosmic = "product bytes",
    ["source.json"] = Prerelease.source_json(commit, digest, run_prefix .. "3") })
  assert(publish(r) == "prerelease published and verified: " .. tag)
  local log = calls(r)
  assert(count(log, "release upload ") == 1, log)
  assert(log:find("release upload " .. tag .. " " .. r.release .. "/SHA256SUMS", 1, true))
  assert(count(log, "release create ") == 0 and count(log, "POST") == 0)
  local dir = r.state .. "/releases/5"
  assert(read(dir .. "/draft") == "false")
  assert(read(dir .. "/assets/source.json") ==
    Prerelease.source_json(commit, digest, run_prefix .. "3"))
  assert(read(dir .. "/assets/cosmic") == "product bytes")
  assert(read(dir .. "/assets/SHA256SUMS") == read(r.release .. "/SHA256SUMS"))
end

local function test_publish_refuses_a_draft_holding_other_bytes(tmp: string)
  local r = repo(tmp)
  seed(r, "1", true, { cosmic = "other bytes" })
  refused("differs from", function() publish(r) end)
  local log = calls(r)
  assert(count(log, "release upload ") == 0 and count(log, "release edit ") == 0, log)
  assert(read(r.state .. "/releases/1/draft") == "true")
end

local function test_publish_refuses_a_draft_holding_an_unknown_asset(tmp: string)
  local r = repo(tmp)
  seed(r, "1", true, { cosmic = "product bytes", ["notes.md"] = "notes" })
  refused("unexpected asset: notes.md", function() publish(r) end)
  assert(count(calls(r), "release upload ") == 0)
end

local function test_publish_verifies_an_identical_published_release(tmp: string)
  local r = repo(tmp)
  seed(r, "1", false, staged(r))
  assert(publish(r) == "prerelease already published and verified: " .. tag)
  local log = calls(r)
  assert(count(log, "release create ") == 0 and count(log, "release upload ") == 0
    and count(log, "release edit ") == 0 and count(log, "POST") == 0, log)
  assert(count(log, "release download ") == 1)
end

local function test_publish_refuses_a_published_release_that_differs(tmp: string)
  local r = repo(tmp)
  local assets = staged(r)
  assets.SHA256SUMS = string.rep("0", 64) .. "  cosmic\n"
  seed(r, "1", false, assets)
  refused("differs from", function() publish(r) end)
  local r2 = repo(tmp .. "/second")
  local short = staged(r2)
  short["source.json"] = nil
  seed(r2, "1", false, short)
  refused("holds 2 assets", function() publish(r2) end)
end

local function test_publish_refuses_a_tag_naming_another_commit(tmp: string)
  local r = repo(tmp)
  seed(r, "1", false, staged(r))
  write(r.state .. "/tags/" .. tag, string.rep("d", 40))
  refused("names another commit", function() publish(r) end)
end

local function test_publish_refuses_api_failures_other_than_404(tmp: string)
  -- ref-transport fails only the tag probe, and with no status line at
  -- all: the listing before it succeeds, so the probe itself refuses.
  local expected: {string:string} = { ref = "HTTP status 500",
    ["ref-transport"] = "HTTP status nil", transport = "failed" }
  for _, failure in ipairs({ "ref", "ref-transport", "transport" }) do
    local r = repo(tmp .. "/" .. failure)
    assert(Fs.mkdirs(r.state .. "/fail"))
    write(r.state .. "/fail/" .. failure, "")
    refused(expected[failure], function() publish(r) end)
    assert(not exists(r.state .. "/tags") and not exists(r.state .. "/releases"), failure)
    local log = calls(r)
    assert(count(log, "POST") == 0 and count(log, "release create") == 0, log)
  end
end

local function test_publish_refuses_a_release_that_is_no_prerelease(tmp: string)
  local r = repo(tmp)
  seed(r, "1", false, staged(r))
  write(r.state .. "/releases/1/prerelease", "false")
  refused("is no prerelease", function() publish(r) end)
  assert(count(calls(r), "release download ") == 0)
end

local function test_publish_refuses_a_draft_whose_source_names_another_digest(tmp: string)
  local r = repo(tmp)
  seed(r, "1", true, { ["source.json"] =
    Prerelease.source_json(commit, string.rep("cd", 32), run_prefix .. "3") })
  refused("source.json names another digest", function() publish(r) end)
  local log = calls(r)
  assert(count(log, "release upload ") == 0 and count(log, "release edit ") == 0, log)
end

local function test_publish_refuses_a_release_still_a_draft_after_edit(tmp: string)
  local r = repo(tmp)
  assert(Fs.mkdirs(r.state .. "/fail"))
  write(r.state .. "/fail/edit-draft", "")
  refused("is still a draft", function() publish(r) end)
  assert(count(calls(r), "release edit ") == 1)
end

--- A branch named for the tag is no tag: a draft whose tag is missing is
--- refused before publishing it would make the tag at its own target.
local function test_publish_refuses_a_branch_named_for_the_tag(tmp: string)
  local r = repo(tmp)
  seed(r, "1", true, staged(r))
  assert(Fs.remove(r.state .. "/tags/" .. tag))
  assert(Fs.mkdirs(r.state .. "/branches"))
  write(r.state .. "/branches/" .. tag, commit)
  write(r.state .. "/releases/1/target", commit)
  refused("gh api repos/owner/repo/git/ref/tags/" .. tag .. " failed", function() publish(r) end)
  assert(count(calls(r), "release edit ") == 0)
  assert(not exists(r.state .. "/tags/" .. tag))
  assert(read(r.state .. "/releases/1/draft") == "true")
end

--- An annotated tag is peeled to the commit it tags.
local function test_publish_peels_an_annotated_tag(tmp: string)
  local r = repo(tmp)
  seed(r, "1", false, staged(r))
  local object = string.rep("e", 40)
  assert(Fs.mkdirs(r.state .. "/annotated") and Fs.mkdirs(r.state .. "/tag-objects"))
  write(r.state .. "/annotated/" .. tag, object)
  write(r.state .. "/tag-objects/" .. object, commit)
  assert(publish(r) == "prerelease already published and verified: " .. tag)
  assert(count(calls(r), "api repos/owner/repo/git/tags/" .. object) == 1)
  write(r.state .. "/tag-objects/" .. object, string.rep("d", 40))
  refused("names another commit", function() publish(r) end)
end

local function test_publish_refuses_two_releases_for_the_tag(tmp: string)
  local r = repo(tmp)
  seed(r, "1", false, staged(r))
  seed(r, "2", true, {})
  refused("2 releases are tagged " .. tag, function() publish(r) end)
  local log = calls(r)
  assert(count(log, "\n") == 1, log)
end

local function test_publish_needs_gh_and_its_token(tmp: string)
  local r = repo(tmp)
  r.env.GH_TOKEN = nil
  refused("GH_TOKEN", function() publish(r) end)
  r.env.GH_TOKEN = "fake-token"
  r.env.PATH = tmp .. "/nowhere"
  refused("gh: ", function() publish(r) end)
  assert(calls(r) == "")
end

--- The two commands as prerelease.yml runs them, through driver.tl, from
--- a copy of the namespace in a project of its own (see
--- orchestration_test.tl): stage, publish, then publish again.
local function test_driver_stages_and_publishes(tmp: string)
  local r = repo(tmp)
  local project = tmp .. "/driver-project"
  assert(Fs.mkdirs(project))
  assert(assert(Child.run({ "/bin/cp", "-R", assert(Fs.absolute("cosmic_ci")), project })).ok)
  local host = assert(Proc.executable())
  local env = r.env
  env.PRODUCTS = tmp .. "/staged-products"
  env.RELEASE = tmp .. "/driver-release"
  env.SOURCE_RUN_URL = run_prefix .. "7"
  local function driver(command: string): Child.Result
    return (assert(Child.run({ host, "cosmic_ci/driver.tl", command }, { cwd = project,
      env = env, stdout = "capture", stderr = "capture" })))
  end
  local staged_run = driver("prerelease-stage")
  assert(staged_run.ok, staged_run.stderr)
  assert(read(env.RELEASE .. "/source.json") == read(r.release .. "/source.json"))
  local first = driver("prerelease-publish")
  assert(first.ok, first.stderr)
  assert(output(first.stdout):find("prerelease published and verified: " .. tag, 1, true), first.stdout)
  published(r, "1")
  env.RUNNER_TEMP = tmp .. "/second-runner"
  assert(Fs.mkdirs(env.RUNNER_TEMP))
  local again = driver("prerelease-publish")
  assert(again.ok, again.stderr)
  assert(output(again.stdout):find("prerelease already published and verified", 1, true), again.stdout)
  write(env.RELEASE .. "/cosmic", "other bytes")
  env.RUNNER_TEMP = tmp .. "/third-runner"
  assert(Fs.mkdirs(env.RUNNER_TEMP))
  local refusal = driver("prerelease-publish")
  assert(not refusal.ok and refusal.code == 1, refusal.stdout)
  assert(output(refusal.stderr):find("prerelease-publish: ", 1, true), refusal.stderr)
  local extra = driver("prerelease-stage")
  assert(extra.ok, extra.stderr)
  local usage = assert(Child.run({ host, "cosmic_ci/driver.tl", "prerelease-stage", "word" },
    { cwd = project, env = env, stdout = "capture", stderr = "capture" }))
  assert(usage.code == 1 and output(usage.stderr):find("usage: driver.tl prerelease-stage", 1, true),
    usage.stderr)
end
