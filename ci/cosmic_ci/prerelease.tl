-- The prerelease gate, for prerelease.yml's publish job: `stage` checks
-- the products every platform leg uploaded name the same bytes, which
-- each leg executed, and stages the release from them; `publish` makes
-- that release the immutable next-<commit> prerelease, or verifies the
-- one already there. Neither executes a byte it reads: the candidate
-- product is data here. `publish` drives the GitHub API through
-- [`GithubApi`], whose token comes from GH_TOKEN or GITHUB_TOKEN.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")
local Plural = require("cosmic_ci.plural")
local String = require("cosmic.string")

local record Prerelease
  --- The platform legs, in the byte order of their products'
  --- directories' names, the order `stage` expects them in.
  lanes: {string}
  --- The assets a published prerelease holds, and the order a resumed
  --- draft uploads the missing ones in.
  assets: {string}
  --- What `stage` reads from its environment: PRODUCTS, RELEASE,
  --- SOURCE_COMMIT and SOURCE_RUN_URL.
  record Stage
    products: string
    release: string
    commit: string
    run_url: string
  end
  --- What `publish` reads from its environment: REPOSITORY, RELEASE,
  --- SOURCE_COMMIT, SOURCE_RUN_PREFIX and RUNNER_TEMP, with the client
  --- its GH_TOKEN (else GITHUB_TOKEN) and GITHUB_API_URL make.
  record Publish
    client: GithubApi.Client
    repository: string
    release: string
    commit: string
    run_prefix: string
    temp: string
  end
end

--- The source.json a release holds: the commit and bytes it was made
--- from, and the run that made it.
local record Source
  commit: string
  digest: string
  run_url: string
end
local SOURCE <const> = Shape.record_of("Source")

Prerelease.lanes = { "alpine-x86_64", "linux-aarch64", "linux-x86_64", "macos-aarch64" }
--- The lane whose bytes every other lane's must equal.
local baseline_lane <const> = "linux-x86_64"
Prerelease.assets = { "cosmic", "SHA256SUMS", "source.json" }

local function read(path: string): string return (assert(Fs.read(path))) end

local function is_file(path: string): boolean
  local st = Fs.stat(path)
  return st ~= nil and st.kind == "file"
end

--- `text` as a shell's `$(cat file)` gives it: without its trailing
--- newlines.
local function substituted(text: string): string
  return (text:gsub("\n+$", ""))
end

--- Whether an expected-platforms file says 4: its text, trailing newlines
--- aside, is exactly "4", as `test "$(cat f)" = 4` would test it.
function Prerelease.expects_four(text: string): boolean
  return substituted(text) == "4"
end

--- The digest an executed-cosmic.sha256 manifest names: its text,
--- trailing newlines aside, is exactly `<64 lowercase hex>  cosmic`.
--- nil and why otherwise.
function Prerelease.manifest_digest(text: string): string | nil, string
  local line = substituted(text)
  local digest = line:match("^([0-9a-f]+)  cosmic$")
  if digest == nil or #digest ~= 64 then
    return nil, "not `<sha256>  cosmic`"
  end
  return digest, ""
end

--- SHA256SUMS for the staged release.
function Prerelease.sums(digest: string): string
  return digest .. "  cosmic\n"
end

--- source.json for the staged release: the object laid out as `jq -n`
--- lays it out, keys in byte order.
function Prerelease.source_json(commit: string, digest: string, run_url: string): string
  local text = assert(Json.encode({ commit = commit, digest = digest, run_url = run_url },
    { pretty = true }))
  return text .. "\n"
end

function Prerelease.notes(commit: string, digest: string, run_url: string): string
  return "Prerelease of commit `" .. commit .. "` from [CI run](" .. run_url .. ").\n" ..
    "\n" ..
    "The identical Cosmic bytes (SHA-256 `" .. digest .. "`) were tested by all four " ..
    "native workers: Linux x86_64, Linux aarch64, macOS aarch64, and Alpine x86_64. " ..
    "Each worker uploaded its executed-byte attestation, and the provenance join " ..
    "verified all four hashes before publication.\n"
end

--- Whether a release's source.json names `commit` and `digest`, and a
--- run_url that is `run_prefix` and a run's numeric id. The run may be
--- an earlier one than this: a resumed draft keeps the source.json the
--- first attempt uploaded.
function Prerelease.source_valid(text: string, commit: string, digest: string,
                                 run_prefix: string): boolean, string
  local source, why = SOURCE:decode_into(text)
  if source == nil then return false, "source.json is no source record: " .. why end
  if source.commit ~= commit then return false, "source.json names another commit" end
  if source.digest ~= digest then return false, "source.json names another digest" end
  local run_url = source.run_url
  if not String.starts_with(run_url, run_prefix) or
      not run_url:sub(#run_prefix + 1):match("^[0-9]+$") then
    return false, "source.json's run_url is not " .. run_prefix .. "<run id>"
  end
  return true, ""
end

--- Whether `names`, a release's asset names, are exactly the three a
--- published prerelease holds.
function Prerelease.complete_assets(names: {string}): boolean, string
  if #names ~= #Prerelease.assets then
    return false, "the release holds " .. Plural.count(#names, "asset") .. ", not " .. #Prerelease.assets
  end
  local seen: {string:boolean} = {}
  for _, name in ipairs(names) do seen[name] = true end
  for _, name in ipairs(Prerelease.assets) do
    if not seen[name] then return false, "the release holds no " .. name end
  end
  return true, ""
end

--- Whether a draft may hold an asset of this name when it is resumed.
function Prerelease.known_asset(name: string): boolean
  for _, known in ipairs(Prerelease.assets) do
    if name == known then return true end
  end
  return false
end

--- The ids of the releases tagged `tag`, from the decoded pages
--- [`GithubApi.pages`] gathers of the releases list.
function Prerelease.release_ids(pages: {any}, tag: string): {integer}
  local ids: {integer} = {}
  for _, page in ipairs(pages) do
    assert(page is {any} and Json.is_array(page), "a page of the releases list is no array")
    for _, release in ipairs(page) do
      assert(release is {string:any}, "a release is no object")
      if release.tag_name == tag then
        local id = release.id
        assert(id is integer, "release " .. tag .. " has no id")
        ids[#ids + 1] = id
      end
    end
  end
  return ids
end

local function required(env: {string:string}, name: string): string
  local value = env[name]
  assert(value and value ~= "", "missing required environment variable: " .. name)
  return value
end

function Prerelease.stage_context(env: {string:string}): Prerelease.Stage
  return { products = required(env, "PRODUCTS"), release = required(env, "RELEASE"),
    commit = required(env, "SOURCE_COMMIT"), run_url = required(env, "SOURCE_RUN_URL") }
end

--- The product directories under `products`: each entry named
--- `portable-product-*` that is itself a directory, not a link to one,
--- as `find -mindepth 1 -maxdepth 1 -type d` finds them, sorted.
local function product_directories(products: string): {string}
  local found: {string} = {}
  for _, name in ipairs((assert(Fs.list(products)))) do
    if name:match("^portable%-product%-") then
      local path = products .. "/" .. name
      local st = Fs.stat(path)
      if st ~= nil and st.kind == "dir" and Fs.readlink(path) == nil then
        found[#found + 1] = name
      end
    end
  end
  table.sort(found)
  return found
end

--- Checks every lane's product, then writes the release under
--- `s.release`: the cosmic executable, SHA256SUMS, source.json and the
--- notes. Raises on the first product that fails a check.
function Prerelease.stage(s: Prerelease.Stage)
  local found = product_directories(s.products)
  assert(#found == #Prerelease.lanes, "expected " .. Plural.count(#Prerelease.lanes, "product directory", "product directories") ..
      ", found " .. #found)
  for i, lane in ipairs(Prerelease.lanes) do
    assert(found[i] == "portable-product-" .. lane,
      "expected portable-product-" .. lane .. ", found " .. found[i])
  end
  local baseline = read(s.products .. "/portable-product-" .. baseline_lane .. "/cosmic")
  local digest: string | nil = nil
  for _, lane in ipairs(Prerelease.lanes) do
    local product = s.products .. "/portable-product-" .. lane
    for _, name in ipairs({ "cosmic", "executed-cosmic.sha256", "expected-platforms" }) do
      assert(is_file(product .. "/" .. name), product .. ": no file " .. name)
    end
    assert(Prerelease.expects_four(read(product .. "/expected-platforms")),
      product .. ": expected-platforms is not 4")
    local lane_digest, why = Prerelease.manifest_digest(read(product .. "/executed-cosmic.sha256"))
    assert(lane_digest ~= nil, product .. "/executed-cosmic.sha256: " .. why)
    local bytes = read(product .. "/cosmic")
    assert(Hash.hex_sha256(bytes) == lane_digest, product .. ": cosmic is not the bytes it executed")
    assert(bytes == baseline, product .. ": cosmic differs from " .. baseline_lane .. "'s")
    if digest == nil then
      digest = lane_digest
    else
      assert(lane_digest == digest, product .. ": executed another digest")
    end
  end
  local sha = assert(digest)
  assert(Fs.mkdirs(s.release))
  assert(Fs.write(s.release .. "/cosmic", baseline))
  assert(Fs.write(s.release .. "/SHA256SUMS", Prerelease.sums(sha)))
  assert(Fs.write(s.release .. "/source.json", Prerelease.source_json(s.commit, sha, s.run_url)))
  assert(Fs.write(s.release .. "/notes.md", Prerelease.notes(s.commit, sha, s.run_url)))
end

function Prerelease.publish_context(env: {string:string}): Prerelease.Publish
  local client, why = GithubApi.live(env)
  assert(client ~= nil, why)
  return { client = client, repository = required(env, "REPOSITORY"),
    release = required(env, "RELEASE"), commit = required(env, "SOURCE_COMMIT"),
    run_prefix = required(env, "SOURCE_RUN_PREFIX"), temp = required(env, "RUNNER_TEMP") }
end

--- A GET of `path`, a JSON object; raises where there is none.
local function api_object(p: Prerelease.Publish, path: string): {string:any}
  local object, why = GithubApi.object(p.client, "GET", path)
  assert(object ~= nil, why)
  return object
end

--- Whether the API holds `path`: true when it answers 2xx, false for an
--- HTTP 404 and nothing else. Every other failure, a transport error
--- or another status, raises, so it can never lead to creating anything.
local function api_probe(p: Prerelease.Publish, path: string): boolean
  local reply, why = GithubApi.request(p.client, "GET", path)
  assert(reply ~= nil, why)
  if reply.status >= 200 and reply.status <= 299 then return true end
  assert(reply.status == 404, "GET " .. path .. " failed (HTTP status " .. reply.status .. ")")
  return false
end

local function tag_of(p: Prerelease.Publish): string
  return "next-" .. p.commit
end

--- The git object `object` (a ref's or a tag's `object` field) names.
local function target(object: any, what: string): string, string
  assert(object is {string:any}, what .. " names no object")
  local sha, kind = object.sha, object.type
  assert(sha is string and kind is string, what .. " names no object")
  return sha, kind
end

--- The tag names the commit being published. It is resolved as a tag,
--- through git/ref/tags/, and not by commits/<name>, which would also
--- take a branch of that name; an annotated tag is peeled to the commit
--- it tags.
local function verify_tag(p: Prerelease.Publish)
  local tag = tag_of(p)
  local ref = api_object(p, "repos/" .. p.repository .. "/git/ref/tags/" .. tag)
  assert(ref.ref == "refs/tags/" .. tag, tag .. ": the API answered another ref")
  local sha, kind = target(ref.object, tag)
  -- A tag may tag a tag; a chain longer than this is no release tag.
  for _ = 1, 8 do
    if kind ~= "tag" then break end
    local annotated = api_object(p, "repos/" .. p.repository .. "/git/tags/" .. sha)
    sha, kind = target(annotated.object, tag)
  end
  assert(kind == "commit", tag .. " names no commit")
  assert(sha == p.commit, tag .. " names another commit")
end

--- Whether the repository's default branch holds workflows other than
--- `p.commit`'s: the files the compare from the commit to the branch
--- changes include one under .github/workflows/.
local function workflows_moved(p: Prerelease.Publish): boolean
  local repo = api_object(p, "repos/" .. p.repository)
  local branch = repo.default_branch
  assert(branch is string, p.repository .. " names no default branch")
  local compare = api_object(p, "repos/" .. p.repository .. "/compare/" ..
      p.commit .. "..." .. branch)
  local files = compare.files
  assert(files is {any}, "the compare to " .. branch .. " lists no files")
  for _, file in ipairs(files) do
    local name = file is {string:any} and file.filename or nil
    if name is string and name:match("^%.github/workflows/") then return true end
  end
  return false
end

--- Whether the tag exists, naming the commit: made when the API says it
--- is absent. False, with nothing made, when GitHub refuses the tag as
--- it refuses a GITHUB_TOKEN, which holds no `workflows` permission,
--- some refs across a workflow change: an HTTP 403 "Resource not
--- accessible by integration" where the default branch's workflows
--- differ from the commit's. GitHub documents no rule for it: a commit
--- has been tagged while main's actionlint.yml differed from its own, so
--- a differing workflow is only a necessary condition, and the skip asks
--- no more. Any other refusal raises, as does a compare that lists no
--- workflow (past its 300 files, too).
-- TODO: publish with a token that holds the `workflows` permission (a
-- GitHub App's installation token, kept as a secret) rather than
-- GITHUB_TOKEN, so such a commit is tagged too, and drop the skip.
local function ensure_tag(p: Prerelease.Publish): boolean
  local tag = tag_of(p)
  if not api_probe(p, "repos/" .. p.repository .. "/git/ref/tags/" .. tag) then
    local path = "repos/" .. p.repository .. "/git/refs"
    local made, why = GithubApi.request(p.client, "POST", path,
      { ref = "refs/tags/" .. tag, sha = p.commit })
    assert(made ~= nil, why)
    if made.status < 200 or made.status > 299 then
      if made.status == 403 and
          made.body:find("Resource not accessible by integration", 1, true) and
          workflows_moved(p) then
        return false
      end
      error("POST " .. path .. " ref=refs/tags/" .. tag .. " failed (HTTP status " ..
          made.status .. ")", 0)
    end
  end
  verify_tag(p)
  return true
end

--- The release `id`, as GET releases/ID answers: by id, not by tag, as
--- the by-tag endpoint finds no draft.
local function view(p: Prerelease.Publish, id: integer): {string:any}
  return api_object(p, "repos/" .. p.repository .. "/releases/" .. id)
end

--- The names of a release's assets, sorted, and each one's id.
local function assets_of(release: {string:any}): {string}, {string:integer}
  local assets = release.assets
  assert(assets is {any} and Json.is_array(assets), "the release's assets are no array")
  local names: {string} = {}
  local ids: {string:integer} = {}
  for _, asset in ipairs(assets) do
    assert(asset is {string:any}, "an asset is no object")
    local name, id = asset.name, asset.id
    assert(name is string, "an asset has no name")
    assert(id is integer, "asset " .. name .. " has no id")
    names[#names + 1] = name
    ids[name] = id
  end
  table.sort(names)
  return names, ids
end

--- Downloads the asset `name`, whose id is `id`, into `destination`.
local function download(p: Prerelease.Publish, id: integer, name: string, destination: string)
  local ok, why = GithubApi.download(p.client, "repos/" .. p.repository ..
      "/releases/assets/" .. id, destination .. "/" .. name, "application/octet-stream")
  assert(ok, why)
end

--- A directory under the job's temporary directory, made now.
local function fresh(p: Prerelease.Publish, name: string): string
  local path = p.temp .. "/prerelease/" .. name
  local there, why = Fs.exists(path)
  assert(there == false, there and path .. " exists already" or why)
  assert(Fs.mkdirs(path))
  return path
end

local function source_checked(p: Prerelease.Publish, digest: string, path: string)
  local valid, why = Prerelease.source_valid(read(path), p.commit, digest, p.run_prefix)
  assert(valid, path .. ": " .. why)
end

local function same_bytes(expected: string, got: string)
  assert(read(expected) == read(got), got .. " differs from " .. expected)
end

--- The release holds exactly the staged assets: the three names, the
--- staged cosmic and SHA256SUMS byte for byte, and a valid source.json.
local function verify_assets(p: Prerelease.Publish, release: integer, digest: string, name: string)
  local names, ids = assets_of(view(p, release))
  local complete, why = Prerelease.complete_assets(names)
  assert(complete, tag_of(p) .. ": " .. why)
  local destination = fresh(p, name)
  for _, asset in ipairs(Prerelease.assets) do download(p, ids[asset], asset, destination) end
  same_bytes(p.release .. "/cosmic", destination .. "/cosmic")
  same_bytes(p.release .. "/SHA256SUMS", destination .. "/SHA256SUMS")
  source_checked(p, digest, destination .. "/source.json")
end

local function flag(state: {string:any}, name: string): boolean
  local value = state[name]
  assert(value is boolean, "the release's " .. name .. " is no boolean")
  return value
end

--- Publishes the release staged under `p.release` as next-<commit>, or
--- verifies the one already there. A draft left by an interrupted run is
--- resumed only by accepting the assets it holds that are identical to
--- the staged ones. Raises on any failure; the line to print on success,
--- or on a skip ([`ensure_tag`]), a warning annotation.
function Prerelease.publish(p: Prerelease.Publish): string
  local tag = tag_of(p)
  local digest = Hash.hex_sha256(read(p.release .. "/cosmic"))
  -- The get-by-tag endpoint only promises published releases. Listing
  -- releases with authentication also finds an interrupted draft.
  local pages, why = GithubApi.pages(p.client, "repos/" .. p.repository .. "/releases?per_page=100")
  assert(pages ~= nil, why)
  local ids = Prerelease.release_ids(pages, tag)
  assert(#ids <= 1, Plural.count(#ids, "release") .. (#ids == 1 and " is" or " are") .. " tagged " .. tag)
  local release: integer
  if #ids == 1 then
    release = ids[1]
    verify_tag(p)
    local state = view(p, release)
    assert(flag(state, "prerelease"), tag .. " is no prerelease")
    if not flag(state, "draft") then
      verify_assets(p, release, digest, "published")
      return "prerelease already published and verified: " .. tag
    end
  else
    if not ensure_tag(p) then
      return "::warning::prerelease skipped: " .. tag .. ": GitHub refused the tag, " ..
        "the default branch's workflows having moved past it"
    end
    local created, trouble = GithubApi.object(p.client, "POST",
      "repos/" .. p.repository .. "/releases", { tag_name = tag, name = tag,
        body = read(p.release .. "/notes.md"), draft = true, prerelease = true })
    assert(created ~= nil, trouble)
    local created_id = created.id
    assert(created_id is integer, "the created release has no id")
    release = created_id
    verify_tag(p)
  end
  local state = view(p, release)
  local upload_url = state.upload_url
  assert(upload_url is string, tag .. " names no upload URL")
  -- Resume an interrupted draft by accepting only identical existing
  -- assets. source.json may name an earlier successful run for this SHA.
  local existing: {string:boolean} = {}
  local names, asset_ids = assets_of(state)
  for _, name in ipairs(names) do
    assert(Prerelease.known_asset(name), tag .. " holds an unexpected asset: " .. name)
    existing[name] = true
    local destination = fresh(p, "existing-" .. name)
    download(p, asset_ids[name], name, destination)
    if name == "source.json" then
      source_checked(p, digest, destination .. "/" .. name)
    else
      same_bytes(p.release .. "/" .. name, destination .. "/" .. name)
    end
  end
  for _, name in ipairs(Prerelease.assets) do
    if not existing[name] then
      local uploaded, trouble = GithubApi.upload(p.client, upload_url, name,
        read(p.release .. "/" .. name))
      assert(uploaded, tag .. ": " .. trouble)
    end
  end
  verify_assets(p, release, digest, "completed")
  local edited, trouble = GithubApi.object(p.client, "PATCH",
    "repos/" .. p.repository .. "/releases/" .. release, { draft = false, prerelease = true })
  assert(edited ~= nil, trouble)
  verify_tag(p)
  verify_assets(p, release, digest, "published")
  assert(not flag(view(p, release), "draft"), tag .. " is still a draft")
  return "prerelease published and verified: " .. tag
end

--- Runs `action`; a failure is named on stderr and exits 1.
local function command(name: string, argv: {string}, action: function(): string): integer
  local called, answer = pcall(function(): string
    assert(argv[1] == nil, "usage: driver.tl " .. name)
    return action()
  end)
  if not called then
    local _, _ = Fs.put(Fs.stderr, name .. ": " .. tostring(answer) .. "\n")
    return 1
  end
  if answer ~= "" then assert(Fs.put(Fs.stdout, answer .. "\n")) end
  return 0
end

function Prerelease.stage_command(argv: {string}): integer
  return command("prerelease-stage", argv, function(): string
    Prerelease.stage(Prerelease.stage_context(Env.all()))
    return ""
  end)
end

function Prerelease.publish_command(argv: {string}): integer
  return command("prerelease-publish", argv, function(): string
    return Prerelease.publish(Prerelease.publish_context(Env.all()))
  end)
end

return Prerelease
