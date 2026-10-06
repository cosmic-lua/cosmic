local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Prerelease = require("cosmic_ci.prerelease")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

-- These tests start this program (the pinned driver's own cosmic, or a copy of it
-- as the bootstrap), which a worker on a sealed database does not have whole;
-- that is a script /bin/sh runs, hence "system", and the driver is copied
-- from cosmic_ci.
Test.policy{ profiles = { "cosmic", "system" }, grants = { { path = "o/bin", letters = "rx" },
  { path = "cosmic_ci", letters = "r" } } }

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
  assert(Prerelease.expects_four("4\n") and Prerelease.expects_four("4") and
      Prerelease.expects_four("4\n\n"))
  for _, bad in ipairs({ "3\n", " 4\n", "4 \n", "04\n", "", "\n4\n" }) do
    assert(not Prerelease.expects_four(bad), bad)
  end
end

--- The release text is byte for byte what `jq -n` (source.json) and a
--- here-document (the notes) make of the same inputs.
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
  -- A source.json of another shape is refused naming its first wrong
  -- value, where a missing or mistyped field was once reported as
  -- another commit, or as a run_url that is no string.
  local function unshaped(text: string, at: string, expected: string)
    local accepted, trouble = Prerelease.source_valid(text, commit, digest, run_prefix)
    assert(not accepted, text)
    assert(trouble:find("source.json is no source record: ", 1, true) and
        trouble:find('pointer "' .. at .. '": expected ' .. expected, 1, true), trouble)
  end
  unshaped('{"commit":"' .. commit .. '","digest":"' .. digest .. '","run_url":1}',
    "/run_url", "string, got integer")
  unshaped('{"commit":"' .. commit .. '"}', "/digest", "string, got nothing")
  unshaped('["' .. commit .. '"]', "", "record, got array")
end

local function test_asset_set()
  assert(Prerelease.complete_assets({ "SHA256SUMS", "cosmic", "source.json" }))
  assert(Prerelease.complete_assets({ "source.json", "cosmic", "SHA256SUMS" }))
  for _, bad in ipairs({ {}, { "cosmic", "SHA256SUMS" },
      { "cosmic", "SHA256SUMS", "source.json", "notes.md" },
      { "cosmic", "cosmic", "source.json" }, { "cosmic", "SHA256SUMS", "notes.md" } }) do
    assert(not Prerelease.complete_assets(bad), table.concat(bad, ","))
  end
  assert(Prerelease.known_asset("cosmic") and Prerelease.known_asset("SHA256SUMS") and
      Prerelease.known_asset("source.json"))
  assert(not Prerelease.known_asset("notes.md") and not Prerelease.known_asset("cosmic.exe"))
end

local function release(id: integer, name: string): {string:any}
  return { id = id, tag_name = name }
end

local function test_release_ids_gathers_every_page()
  local pages: {any} = { Json.array({ release(1, "next-a") }),
    Json.array({ release(2, tag), release(3, "next-b") }), Json.array(),
    Json.array({ release(4, tag) }) }
  local ids = Prerelease.release_ids(pages, tag)
  assert(#ids == 2 and ids[1] == 2 and ids[2] == 4)
  assert(#Prerelease.release_ids({ Json.array() }, tag) == 0)
  refused("no array", function() Prerelease.release_ids({ { id = 1 } }, tag) end)
  refused("is no object", function() Prerelease.release_ids({ Json.array({ 7 }) }, tag) end)
  refused("has no id", function()
    Prerelease.release_ids({ Json.array({ { tag_name = tag } }) }, tag)
  end)
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
    ["found 3"] = function(p: string)
      assert(Fs.remove_tree(p .. "/portable-product-macos-aarch64"))
    end,
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

--- A release of the fake repository.
local record Asset
  name: string
  id: integer
  data: string
end
local record Release
  id: integer
  tag: string
  draft: boolean
  prerelease: boolean
  assets: {Asset}
  title: string
  notes: string
  --- The commit publishing the release makes its tag at, where the tag
  --- is missing.
  target: string | nil
end

--- A repository standing in for GitHub's, answering a client's `send`
--- and `fetch` from tables, and a release staged for it. `fail` holds
--- the faults to inject: ref (the tag probe answers 500), ref-transport
--- (it gets no answer), transport (nothing is answered), create-ref (the
--- POST of a tag is refused 403 with this message, or GitHub's to a
--- GITHUB_TOKEN when empty) and edit-draft (the PATCH leaves the draft
--- flag).
local record Repo
  client: GithubApi.Client
  release: string
  temp: string
  tags: {string:string}
  annotated: {string:string}
  tag_objects: {string:string}
  branches: {string:string}
  releases: {Release}
  assets: integer
  compare: {string}
  fail: {string:string}
  --- Each request as "METHOD path" ("UPLOAD name" for an upload).
  log: {string}
  --- The content type each uploaded asset came with.
  uploaded: {string:string}
end

local api <const> = "https://api.test/"
local uploads <const> = "https://uploads.test/"
local blob <const> = "https://blob.test/"

local function reply(status: integer, value: any, headers?: {string:string}): GithubApi.Reply
  local body = value is string and value or assert(Json.encode(value))
  return { status = status, headers = headers or {}, body = body }
end

local function not_found(): GithubApi.Reply
  return reply(404, { message = "Not Found" })
end

local function release_json(rel: Release): {string:any}
  local assets: {any} = {}
  for _, asset in ipairs(rel.assets) do
    assets[#assets + 1] = { name = asset.name, id = asset.id, size = #asset.data,
      state = "uploaded" }
  end
  return { id = rel.id, tag_name = rel.tag, draft = rel.draft, prerelease = rel.prerelease,
    assets = Json.array(assets),
    upload_url = uploads .. "repos/" .. repository .. "/releases/" .. rel.id ..
      "/assets{?name,label}" }
end

local function release_by(r: Repo, id: string): Release | nil
  for _, rel in ipairs(r.releases) do
    if tostring(rel.id) == id then return rel end
  end
  return nil
end

local function asset_by(r: Repo, id: string): Asset | nil
  for _, rel in ipairs(r.releases) do
    for _, asset in ipairs(rel.assets) do
      if tostring(asset.id) == id then return asset end
    end
  end
  return nil
end

local function serve_upload(r: Repo, request: GithubApi.Request): GithubApi.Reply
  assert(request.method == "POST" and request.upload == true, "an upload is not flagged")
  local id, name = request.url:match("^" .. uploads:gsub("%p", "%%%0") ..
      "repos/owner/repo/releases/(%d+)/assets%?name=([^&]+)$")
  local rel = id and release_by(r, id)
  if rel == nil or name == nil then return not_found() end
  r.log[#r.log + 1] = "UPLOAD " .. name
  for _, asset in ipairs(rel.assets) do
    if asset.name == name then
      return reply(422, { message = "Validation Failed",
        errors = { { code = "already_exists", field = "name" } } })
    end
  end
  r.assets = r.assets + 1
  local expected: {string:string} = { ["source.json"] = "application/json",
    SHA256SUMS = "text/plain", cosmic = "application/octet-stream" }
  assert(request.headers["Content-Type"] == expected[name],
    name .. " is uploaded as " .. tostring(request.headers["Content-Type"]))
  r.uploaded[name] = request.headers["Content-Type"]
  rel.assets[#rel.assets + 1] = { name = name, id = r.assets, data = assert(request.body) }
  return reply(201, { id = r.assets, name = name, state = "uploaded" })
end

local function serve_page(r: Repo, rest: string): GithubApi.Reply
  -- One release to a page, so a caller must gather every page.
  local page = math.tointeger(tonumber(rest:match("&page=(%d+)$") or "1")) as integer
  local rel = r.releases[page]
  local list: {any} = {}
  if rel then list[1] = { id = rel.id, tag_name = rel.tag } end
  local headers: {string:string} = {}
  if r.releases[page + 1] then
    headers.link = '<' .. api .. "repos/" .. repository .. "/releases?per_page=100&page=" ..
      (page + 1) .. '>; rel="next"'
  end
  return reply(200, Json.array(list), headers)
end

local function serve(r: Repo, request: GithubApi.Request): GithubApi.Reply | nil, string
  if r.fail.transport then return nil, "connection refused" end
  assert(request.headers.Authorization == nil, "the fake adds the token itself")
  if request.url:sub(1, #uploads) == uploads then return serve_upload(r, request) end
  assert(request.url:sub(1, #api) == api, "a request to " .. request.url)
  local path = request.url:sub(#api + 1)
  local method = request.method
  r.log[#r.log + 1] = method .. " " .. path
  local body: {string:any} = {}
  if request.body then
    assert(request.headers["Content-Type"] == "application/json", "a JSON body is not typed")
    body = assert(Json.decode_object(request.body))
  end
  if path == "repos/" .. repository then
    return reply(200, { full_name = repository, default_branch = "main" })
  end
  local prefix = "repos/" .. repository .. "/"
  assert(path:sub(1, #prefix) == prefix, "an unexpected path " .. path)
  local rest = path:sub(#prefix + 1)
  if rest:match("^releases%?per_page=100") and method == "GET" then return serve_page(r, rest) end
  local probed = rest:match("^git/ref/tags/(.+)$")
  if probed and method == "GET" then
    if r.fail["ref-transport"] then return nil, "connection reset" end
    if r.fail.ref then return reply(500, { message = "Server Error" }) end
    local sha = r.tags[probed]
    if sha == nil then return not_found() end
    local object = { sha = sha, type = "commit" }
    if r.annotated[probed] then object = { sha = r.annotated[probed], type = "tag" } end
    return reply(200, { ref = "refs/tags/" .. probed, object = object })
  end
  local tag_object = rest:match("^git/tags/(.+)$")
  if tag_object and method == "GET" then
    local tagged = r.tag_objects[tag_object]
    if tagged == nil then return not_found() end
    return reply(200, { sha = tag_object, object = { sha = tagged, type = "commit" } })
  end
  if rest:match("^compare/%x+%.%.%.main$") and method == "GET" then
    local files: {any} = {}
    for _, name in ipairs(r.compare) do files[#files + 1] = { filename = name } end
    return reply(200, { status = "ahead", files = Json.array(files) })
  end
  if rest == "git/refs" and method == "POST" then
    local ref, sha = body.ref, body.sha
    assert(ref is string and sha is string, "no ref or sha")
    local made = assert(ref:match("^refs/tags/(.+)$"))
    local message = r.fail["create-ref"]
    if message then
      return reply(403, { message = message ~= "" and message or
          "Resource not accessible by integration" })
    end
    if r.tags[made] then return reply(422, { message = "Reference already exists" }) end
    r.tags[made] = sha
    return reply(201, { ref = ref, object = { sha = sha } })
  end
  if rest == "releases" and method == "POST" then
    local name = body.tag_name
    assert(name is string and body.name == name, "a release is named for its tag")
    assert(body.draft == true and body.prerelease == true, "a release is a draft prerelease")
    -- A tag the draft names is made already, as the flow verifies it.
    if r.tags[name] == nil then return reply(422, { message = "Validation Failed" }) end
    local rel: Release = { id = #r.releases + 1, tag = name, draft = true, prerelease = true,
      assets = {}, title = name, notes = tostring(body.body) }
    r.releases[#r.releases + 1] = rel
    return reply(201, release_json(rel))
  end
  local id = rest:match("^releases/(%d+)$")
  local rel = id and release_by(r, id)
  if id and method == "GET" then
    if rel == nil then return not_found() end
    return reply(200, release_json(rel))
  end
  if id and method == "PATCH" then
    if rel == nil then return not_found() end
    local keys = 0
    for _ in pairs(body) do keys = keys + 1 end
    assert(keys == 2 and body.draft == false and body.prerelease == true,
      "the edit is not exactly draft=false, prerelease=true")
    if not r.fail["edit-draft"] then
      rel.draft = false
      -- Publishing a draft whose tag is missing makes the tag, at the
      -- draft's target.
      if r.tags[rel.tag] == nil and rel.target then r.tags[rel.tag] = rel.target end
    end
    rel.prerelease = true
    return reply(200, release_json(rel))
  end
  local asset_id = rest:match("^releases/assets/(%d+)$")
  if asset_id and method == "GET" then
    assert(request.headers.Accept == "application/octet-stream", "an asset is asked for as bytes")
    if asset_by(r, asset_id) == nil then return not_found() end
    return reply(302, "", { location = blob .. asset_id })
  end
  error("an unexpected request " .. method .. " " .. path)
end

--- A staged release and a fake repository for it. The client is the live
--- one with its transport replaced, so its upload origin is the real
--- derivation's.
local function repo(tmp: string, bytes?: string): Repo
  local s = stage_context(tmp)
  s.products = products(tmp .. "/staged-products", bytes or "product bytes")
  Prerelease.stage(s)
  local client = assert(GithubApi.live({ GH_TOKEN = "fake-token", GITHUB_API_URL = "https://api.test" }))
  local r: Repo = { client = client, release = s.release, temp = tmp .. "/runner",
    tags = {}, annotated = {}, tag_objects = {}, branches = {}, releases = {}, assets = 100,
    compare = {}, fail = {}, log = {}, uploaded = {} }
  client.send = function(request: GithubApi.Request): GithubApi.Reply | nil, string
    return serve(r, request)
  end
  client.fetch = function(url: string, to: string): boolean, string
    assert(url:sub(1, #blob) == blob, "a download from " .. url)
    local asset = asset_by(r, url:sub(#blob + 1))
    if asset == nil then return false, "HTTP 404" end
    return Fs.write(to, asset.data)
  end
  assert(Fs.mkdirs(r.temp))
  return r
end

local function publisher(r: Repo): Prerelease.Publish
  return { client = r.client, repository = repository, release = r.release, commit = commit,
    run_prefix = run_prefix, temp = r.temp }
end

local function publish(r: Repo): string
  return Prerelease.publish(publisher(r))
end

--- A release of the tag in the fake repository, with these assets.
local function seed(r: Repo, draft: boolean, assets: {string:string}): Release
  r.tags[tag] = commit
  local rel: Release = { id = #r.releases + 1, tag = tag, draft = draft, prerelease = true,
    assets = {}, title = tag, notes = "" }
  for _, name in ipairs(Prerelease.assets) do
    if assets[name] then
      r.assets = r.assets + 1
      rel.assets[#rel.assets + 1] = { name = name, id = r.assets, data = assets[name] }
    end
  end
  for name, data in pairs(assets) do
    if not Prerelease.known_asset(name) then
      r.assets = r.assets + 1
      rel.assets[#rel.assets + 1] = { name = name, id = r.assets, data = data }
    end
  end
  r.releases[#r.releases + 1] = rel
  return rel
end

local function staged(r: Repo): {string:string}
  local assets: {string:string} = {}
  for _, name in ipairs(Prerelease.assets) do assets[name] = read(r.release .. "/" .. name) end
  return assets
end

--- How many requests of the log begin with `prefix`.
local function count(r: Repo, prefix: string): integer
  local n = 0
  for _, line in ipairs(r.log) do
    if line:sub(1, #prefix) == prefix then n = n + 1 end
  end
  return n
end

local function logged(r: Repo): string return table.concat(r.log, "\n") end

local function test_publish_creates_tag_and_release(tmp: string)
  local r = repo(tmp)
  -- Other commits' releases, so the list takes two pages.
  for id, letter in ipairs({ "a", "b" }) do
    r.releases[id] = { id = id, tag = "next-" .. string.rep(letter, 40), draft = false,
      prerelease = true, assets = {}, title = "", notes = "" }
  end
  assert(publish(r) == "prerelease published and verified: " .. tag)
  assert(r.tags[tag] == commit)
  assert(#r.releases == 3)
  local rel = r.releases[3]
  assert(not rel.draft and rel.prerelease and #rel.assets == 3)
  local data = staged(r)
  for _, asset in ipairs(rel.assets) do assert(asset.data == data[asset.name], asset.name) end
  assert(rel.notes == read(r.release .. "/notes.md"))
  assert(rel.title == tag)
  local log = logged(r)
  assert(count(r, "POST repos/owner/repo/releases") == 1 and count(r, "UPLOAD ") == 3, log)
  assert(count(r, "POST repos/owner/repo/git/refs") == 1, log)
  assert(r.uploaded["source.json"] == "application/json" and
      r.uploaded.SHA256SUMS == "text/plain" and
      r.uploaded.cosmic == "application/octet-stream")
  assert(count(r, "GET repos/owner/repo/releases?per_page=100&page=2") == 1, log)
end

local function test_publish_resumes_a_draft_uploading_only_what_is_missing(tmp: string)
  local r = repo(tmp)
  local digest = Hash.hex_sha256("product bytes")
  -- The draft's source.json names the earlier run that uploaded it.
  local earlier = Prerelease.source_json(commit, digest, run_prefix .. "3")
  local rel = seed(r, true, { cosmic = "product bytes", ["source.json"] = earlier })
  assert(publish(r) == "prerelease published and verified: " .. tag)
  assert(count(r, "UPLOAD ") == 1, logged(r))
  assert(logged(r):find("UPLOAD SHA256SUMS", 1, true))
  assert(count(r, "POST") == 0)
  assert(not rel.draft)
  local data: {string:string} = {}
  for _, asset in ipairs(rel.assets) do data[asset.name] = asset.data end
  assert(data["source.json"] == earlier)
  assert(data.cosmic == "product bytes")
  assert(data.SHA256SUMS == read(r.release .. "/SHA256SUMS"))
end

local function test_publish_refuses_a_draft_holding_other_bytes(tmp: string)
  local r = repo(tmp)
  local rel = seed(r, true, { cosmic = "other bytes" })
  refused("differs from", function() publish(r) end)
  assert(count(r, "UPLOAD ") == 0 and count(r, "PATCH ") == 0, logged(r))
  assert(rel.draft)
end

local function test_publish_refuses_a_draft_holding_an_unknown_asset(tmp: string)
  local r = repo(tmp)
  seed(r, true, { cosmic = "product bytes", ["notes.md"] = "notes" })
  refused("unexpected asset: notes.md", function() publish(r) end)
  assert(count(r, "UPLOAD ") == 0)
end

local function test_publish_verifies_an_identical_published_release(tmp: string)
  local r = repo(tmp)
  seed(r, false, staged(r))
  assert(publish(r) == "prerelease already published and verified: " .. tag)
  assert(count(r, "POST") == 0 and count(r, "UPLOAD ") == 0 and count(r, "PATCH ") == 0, logged(r))
  assert(count(r, "GET repos/owner/repo/releases/assets/") == 3, logged(r))
end

local function test_publish_refuses_a_published_release_that_differs(tmp: string)
  local r = repo(tmp)
  local assets = staged(r)
  assets.SHA256SUMS = string.rep("0", 64) .. "  cosmic\n"
  seed(r, false, assets)
  refused("differs from", function() publish(r) end)
  local r2 = repo(tmp .. "/second")
  local short = staged(r2)
  short["source.json"] = nil
  seed(r2, false, short)
  refused("holds 2 assets", function() publish(r2) end)
end

local function test_publish_refuses_a_tag_naming_another_commit(tmp: string)
  local r = repo(tmp)
  seed(r, false, staged(r))
  r.tags[tag] = string.rep("d", 40)
  refused("names another commit", function() publish(r) end)
end

local function test_publish_refuses_api_failures_other_than_404(tmp: string)
  -- ref-transport fails only the tag probe, with no answer at all: the
  -- listing before it succeeds, so the probe itself refuses.
  local expected: {string:string} = { ref = "HTTP status 500",
    ["ref-transport"] = "connection reset", transport = "connection refused" }
  for _, failure in ipairs({ "ref", "ref-transport", "transport" }) do
    local r = repo(tmp .. "/" .. failure)
    r.fail[failure] = ""
    refused(expected[failure], function() publish(r) end)
    assert(next(r.tags) == nil and #r.releases == 0, failure)
    assert(count(r, "POST") == 0, logged(r))
  end
end

--- Where GitHub refuses a GITHUB_TOKEN the tag because the default
--- branch's workflows have moved past the commit, the publish skips with
--- a warning, making nothing, rather than failing main's run.
local function test_publish_skips_a_commit_the_default_branchs_workflows_moved_past(tmp: string)
  local r = repo(tmp)
  r.fail["create-ref"] = ""
  r.compare = { "build/x.tl", ".github/workflows/ci.yml" }
  local line = publish(r)
  assert(line == "::warning::prerelease skipped: " .. tag .. ": GitHub refused the tag, " ..
      "the default branch's workflows having moved past it", line)
  assert(next(r.tags) == nil and #r.releases == 0)
  assert(count(r, "GET repos/owner/repo/compare/" .. commit .. "...main") == 1, logged(r))
  assert(count(r, "POST repos/owner/repo/releases") == 0, logged(r))
end

--- A refusal the default branch's workflows do not explain -- the
--- token's permissions, a ruleset -- still fails the publish.
local function test_publish_refuses_a_forbidden_tag_the_workflows_do_not_explain(tmp: string)
  local r = repo(tmp)
  r.fail["create-ref"] = ""
  r.compare = { "build/x.tl", ".github/scripts/y.sh" }
  refused("POST repos/owner/repo/git/refs ref=refs/tags/" .. tag .. " failed (HTTP status 403)",
    function() publish(r) end)
  assert(#r.releases == 0)
end

--- A 403 of another kind -- a secondary rate limit -- fails the publish
--- whatever the workflows, without asking the compare.
local function test_publish_refuses_another_forbidden_answer(tmp: string)
  local r = repo(tmp)
  r.fail["create-ref"] = "You have exceeded a secondary rate limit"
  r.compare = { ".github/workflows/ci.yml" }
  refused("failed (HTTP status 403)", function() publish(r) end)
  assert(count(r, "GET repos/owner/repo/compare/") == 0, logged(r))
end

local function test_publish_refuses_a_release_that_is_no_prerelease(tmp: string)
  local r = repo(tmp)
  seed(r, false, staged(r)).prerelease = false
  refused("is no prerelease", function() publish(r) end)
  assert(count(r, "GET repos/owner/repo/releases/assets/") == 0)
end

local function test_publish_refuses_a_draft_whose_source_names_another_digest(tmp: string)
  local r = repo(tmp)
  seed(r, true, { ["source.json"] =
      Prerelease.source_json(commit, string.rep("cd", 32), run_prefix .. "3") })
  refused("source.json names another digest", function() publish(r) end)
  assert(count(r, "UPLOAD ") == 0 and count(r, "PATCH ") == 0, logged(r))
end

local function test_publish_refuses_a_release_still_a_draft_after_edit(tmp: string)
  local r = repo(tmp)
  r.fail["edit-draft"] = ""
  refused("is still a draft", function() publish(r) end)
  assert(count(r, "PATCH ") == 1)
end

--- A branch named for the tag is no tag: a draft whose tag is missing is
--- refused before publishing it would make the tag at its own target.
local function test_publish_refuses_a_branch_named_for_the_tag(tmp: string)
  local r = repo(tmp)
  local rel = seed(r, true, staged(r))
  r.tags[tag] = nil
  r.branches[tag] = commit
  rel.target = commit
  refused("git/ref/tags/" .. tag .. ": HTTP 404", function() publish(r) end)
  assert(count(r, "PATCH ") == 0)
  assert(r.tags[tag] == nil)
  assert(rel.draft)
end

--- An annotated tag is peeled to the commit it tags.
local function test_publish_peels_an_annotated_tag(tmp: string)
  local r = repo(tmp)
  seed(r, false, staged(r))
  local object = string.rep("e", 40)
  r.annotated[tag] = object
  r.tag_objects[object] = commit
  assert(publish(r) == "prerelease already published and verified: " .. tag)
  assert(count(r, "GET repos/owner/repo/git/tags/" .. object) == 1)
  r.tag_objects[object] = string.rep("d", 40)
  refused("names another commit", function() publish(r) end)
end

local function test_publish_refuses_two_releases_for_the_tag(tmp: string)
  local r = repo(tmp)
  seed(r, false, staged(r))
  seed(r, true, {})
  refused("2 releases are tagged " .. tag, function() publish(r) end)
  -- Both pages of the list were read, and nothing else was asked.
  assert(#r.log == 2, logged(r))
end

--- A name the draft holds already is no upload: GitHub's 422 fails the
--- publish, naming it.
local function test_publish_fails_an_upload_the_release_refuses(tmp: string)
  local r = repo(tmp)
  local rel = seed(r, true, {})
  local send = r.client.send
  r.client.send = function(request: GithubApi.Request): GithubApi.Reply | nil, string
    -- Another run uploads SHA256SUMS just before this one does.
    if request.upload and request.url:find("name=SHA256SUMS", 1, true) and
        #rel.assets == 1 then
      rel.assets[#rel.assets + 1] = { name = "SHA256SUMS", id = 999, data = "x" }
    end
    return send(request)
  end
  refused("HTTP 422: Validation Failed (the release holds an asset of that name)", function()
    publish(r)
  end)
  assert(rel.draft)
end

--- The command prerelease.yml runs exits 0 on a publish and again on
--- the verification of it, and a third run says the release is already
--- published.
local function test_the_publish_command_succeeds_through_a_fake_api(tmp: string)
  local r = repo(tmp)
  -- Each run has a temporary directory of its own, as a job does.
  local function run(n: integer, argv: {string}): integer
    local p = publisher(r)
    p.temp = tmp .. "/run-" .. n
    assert(Fs.mkdirs(p.temp))
    return Prerelease.publish_command(argv, p)
  end
  assert(run(1, {}) == 0)
  assert(#r.releases == 1 and not r.releases[1].draft)
  assert(run(2, {}) == 0)
  assert(count(r, "POST repos/owner/repo/releases") == 1 and count(r, "UPLOAD ") == 3, logged(r))
  r.temp = tmp .. "/run-3"
  assert(publish(r) == "prerelease already published and verified: " .. tag)
  assert(run(4, { "word" }) == 1)
end

local function test_publish_needs_a_token(tmp: string)
  local env: {string:string} = { REPOSITORY = repository, RELEASE = tmp, SOURCE_COMMIT = commit,
    SOURCE_RUN_PREFIX = run_prefix, RUNNER_TEMP = tmp }
  refused("GH_TOKEN", function() Prerelease.publish_context(env) end)
  env.GITHUB_TOKEN = "fake-token"
  local p = Prerelease.publish_context(env)
  assert(p.repository == repository and p.commit == commit and p.temp == tmp)
  assert(p.client.base == "https://api.github.com")
  env.REPOSITORY = nil
  refused("REPOSITORY", function() Prerelease.publish_context(env) end)
end

--- The two commands as prerelease.yml runs them, through driver.tl, from
--- a copy of the namespace in a project of its own (see
--- orchestration_test.tl): stage, then publish, which fails without a
--- token before it asks the API anything.
local function test_driver_stages_and_refuses_to_publish_without_a_token(tmp: string)
  local r = repo(tmp)
  local project = tmp .. "/driver-project"
  assert(Fs.mkdirs(project))
  assert(Fs.copy_tree(assert(Fs.absolute("cosmic_ci")), project .. "/cosmic_ci"))
  local host = assert(Proc.executable())
  local env = Env.all()
  env.GH_TOKEN = nil
  env.GITHUB_TOKEN = nil
  env.PRODUCTS = tmp .. "/staged-products"
  env.RELEASE = tmp .. "/driver-release"
  env.SOURCE_COMMIT = commit
  env.SOURCE_RUN_URL = run_prefix .. "7"
  env.SOURCE_RUN_PREFIX = run_prefix
  env.REPOSITORY = repository
  env.RUNNER_TEMP = tmp .. "/driver-runner"
  local function driver(command: string): Child.Result
    return (assert(Child.run({ host, "cosmic_ci/driver.tl", command }, { cwd = project,
      env = env, stdout = "capture", stderr = "capture" })))
  end
  local staged_run = driver("prerelease-stage")
  assert(staged_run.ok, staged_run.stderr)
  assert(read(env.RELEASE .. "/source.json") == read(r.release .. "/source.json"))
  local refusal = driver("prerelease-publish")
  assert(not refusal.ok and refusal.code == 1, refusal.stdout)
  assert(output(refusal.stderr):find("prerelease-publish: ", 1, true) and
      output(refusal.stderr):find("GH_TOKEN", 1, true), refusal.stderr)
  assert(not exists(env.RUNNER_TEMP .. "/prerelease"))
  local usage = assert(Child.run({ host, "cosmic_ci/driver.tl", "prerelease-stage", "word" },
    { cwd = project, env = env, stdout = "capture", stderr = "capture" }))
  assert(usage.code == 1 and output(usage.stderr):find("usage: driver.tl prerelease-stage", 1, true),
    usage.stderr)
end
