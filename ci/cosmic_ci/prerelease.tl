-- The prerelease gate, for prerelease.yml's publish job: `stage` checks
-- the products every platform leg uploaded name the same bytes, which
-- each leg executed, and stages the release from them; `publish` makes
-- that release the immutable <YYYYMMDD>-<commit> prerelease, or verifies the
-- one already there. Neither executes a byte it reads: the candidate
-- product is data here. `publish` drives the GitHub API through
-- [`GithubApi`], whose token comes from GH_TOKEN or GITHUB_TOKEN.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local ArtifactRow = require("cosmic_ci.artifact_row")
local GithubApi = require("cosmic_ci.github_api")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")
local Plural = require("cosmic_ci.plural")
local String = require("cosmic.string")
local StepEnv = require("cosmic_ci.step_env")

local record Prerelease
  --- The platform legs, in the byte order of their products'
  --- directories' names, the order `stage` expects them in.
  lanes: function(): {string}
  --- The assets a published prerelease holds, and the order a resumed
  --- draft uploads the missing ones in.
  assets: function(): {string}
  --- The `YYYYMMDD` of a committer date as the API writes it
  --- (`YYYY-MM-DDTHH:MM:SSZ`, UTC); raises on any other form.
  commit_day: function(date: string): string
  --- What `stage` reads from its environment: PRODUCTS, RELEASE,
  --- SOURCE_COMMIT and SOURCE_RUN_URL.
  record Stage
    mut products: string
    release: string
    commit: string
    run_url: string
    --- Runs the released tool once, as the host that stages it can, and raises where it does not: the release is
    --- not the bytes any lane ran, so this is the first time they run.
    mut smoke: function(path: string)
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
    mut temp: string
    --- The UTC day of the commit's committer date, `YYYYMMDD`, which
    --- names the tag; `publish` reads it from the API when nil.
    mut date?: string
  end
  --- The release `publish` makes: a draft prerelease.
  record NewRelease
    tag_name: string
    name: string
    body: string
    draft: boolean
    prerelease: boolean
  end
  --- The ids of the drafts a page of the releases list holds, and
  --- whether the list's drafts end there.
  record Drafts
    ids: {integer}
    ends: boolean
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

local LANES <const>: {string} = { "alpine-x86_64", "linux-aarch64", "linux-x86_64", "macos-aarch64" }

function Prerelease.lanes(): {string}
  return LANES
end

--- The lane whose bytes every other lane's must equal.
local baseline_lane <const> = "linux-x86_64"
local ASSETS <const>: {string} = { "cosmic", "SHA256SUMS", "source.json" }

function Prerelease.assets(): {string}
  return ASSETS
end

--- The type each asset is uploaded as, as gh guessed it from the name.
local asset_types: {string:string} = { ["source.json"] = "application/json",
  SHA256SUMS = "text/plain" }

local function read(path: string): string return (assert(Fs.read(path))) end

local function is_file(path: string): boolean
  local st, _ = Fs.stat(path)
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
function Prerelease.manifest_digest(text: string): string?, string
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
    "The same Cosmic bytes were tested by all four native workers: Linux x86_64, " ..
    "Linux aarch64, macOS aarch64, and Alpine x86_64, but for the row that names the checkout each built them " ..
    "in. The release (SHA-256 `" .. digest .. "`) is those bytes minus that row, normalised by a vacuum and " ..
    "three header counters of the database. " ..
    "Each worker uploaded its executed-byte attestation of them, and the provenance join " ..
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
  if #names ~= #ASSETS then
    return false, "the release holds " .. Plural.count(#names, "asset") .. ", not " .. tostring(#ASSETS)
  end
  local seen: mut {string:boolean} = {}
  for _, name in ipairs(names) do seen[name] = true end
  for _, name in ipairs(ASSETS) do
    if seen[name] ~= true then return false, "the release holds no " .. name end
  end
  return true, ""
end

--- Whether a draft may hold an asset of this name when it is resumed.
function Prerelease.known_asset(name: string): boolean
  for _, known in ipairs(ASSETS) do
    if name == known then return true end
  end
  return false
end

--- One release of the releases list. The flags and ids are `any` so that a
--- release without them is refused by name ([`Prerelease.draft_ids`]).
local record ReleaseRow
  id?: any
  draft?: any
  tag_name?: any
end
local RELEASE_ROW <const> = Shape.record_of("ReleaseRow")

--- The ids of the drafts tagged `tag` on `page`, one page of 100 of the
--- releases list as the API's JSON, and whether the list's drafts end
--- there: the page holds a release that is no draft, or fewer than 100.
--- GitHub lists drafts before every other release, which nothing
--- documents; a draft after one that is no draft raises, since a draft
--- the scan would pass over unseen is one the publish would make again
--- beside it.
function Prerelease.draft_ids(page: string, tag: string): Prerelease.Drafts
  local items, why: {any}?, string = Shape.decode_into(page, Shape.list(Shape.any))
  assert(items ~= nil, "a page of the releases list is no array: " .. why)
  local ids: mut {integer} = {}
  local published = false
  for _, item in ipairs(items) do
    local release, trouble = RELEASE_ROW:into(item)
    assert(release ~= nil, "a release is no object: " .. trouble)
    local draft = release.draft
    assert(draft is boolean, "release " .. tostring(release.tag_name) .. " has no draft flag")
    if not draft then
      published = true
    elseif published then
      error("the releases list holds draft " .. tostring(release.tag_name) ..
          " after a published release, which the publish's search for its draft assumes it does not")
    elseif release.tag_name == tag then
      local id = release.id
      assert(id is integer, "release " .. tag .. " has no id")
      ids[#ids + 1] = id
    end
  end
  return { ids = ids, ends = published or #items < 100 }
end

local required <const> = StepEnv.required

--- Runs the tool at `path` with `help`, its portable cores unpacked in a directory of its own, and raises unless it
--- answers.
function Prerelease.smoke(path: string)
  local cache = assert(Fs.mkdtemp("cosmic-release-smoke-"))
  local env = Env.all()
  env["COSMIC_PORTABLE_CACHE"] = cache
  local result, trouble = Child.run({ path, "help" }, { env = env })
  local _, _ = Fs.remove_tree(cache)
  assert(result ~= nil, path .. ": " .. tostring(trouble))
  assert(result.ok, path .. ": help failed")
end

function Prerelease.stage_context(env: {string:string}): Prerelease.Stage
  return { products = required(env, "PRODUCTS"), release = required(env, "RELEASE"),
    commit = required(env, "SOURCE_COMMIT"), run_url = required(env, "SOURCE_RUN_URL"),
    smoke = Prerelease.smoke }
end

--- The product directories under `products`: each entry named
--- `portable-product-*` that is itself a directory, not a link to one,
--- as `find -mindepth 1 -maxdepth 1 -type d` finds them, sorted.
local function product_directories(products: string): {string}
  local found: mut {string} = {}
  for _, name in ipairs((assert(Fs.list(products)))) do
    if name:match("^portable%-product%-") then
      local path = products .. "/" .. name
      local st, _ = Fs.stat(path)
      local link, _ = Fs.readlink(path)
      if st ~= nil and st.kind == "dir" and link == nil then
        found[#found + 1] = name
      end
    end
  end
  table.sort(found)
  return found
end

--- Checks every lane's product, then writes the release under
--- `s.release`: the cosmic executable, SHA256SUMS, source.json and the
--- notes. The executable is the lanes' tool minus the `built_from` row,
--- normalised by a vacuum and three header counters ([`ArtifactRow.with`]);
--- the lanes agree on those bytes, which `executed-cosmic.sha256` names, and
--- SHA256SUMS names them. It is run once (`s.smoke`) before anything is
--- published. Raises on the first product that fails a check.
function Prerelease.stage(s: Prerelease.Stage)
  local found = product_directories(s.products)
  assert(#found == #LANES, "expected " .. Plural.count(#LANES, "product directory", "product directories") ..
      ", found " .. tostring(#found))
  for i, lane in ipairs(LANES) do
    assert(found[i] == "portable-product-" .. lane,
      "expected portable-product-" .. lane .. ", found " .. assert(found[i]))
  end
  -- Each lane ran the tool CI built in the checkout of its own runner, and the tool records that checkout
  -- (`built_from`), which differs from a lane to a lane. What the lanes agree on, and what is released, is that
  -- tool without the row: a release is built from no checkout, and a project in a checkout of the path CI built in
  -- would otherwise be taken for cosmic's own tree.
  local scratch = s.products .. "/stripping.db"
  local baseline = ArtifactRow.with(read(s.products .. "/portable-product-" .. baseline_lane .. "/cosmic"), scratch, nil)
  local digest: string? = nil
  for _, lane in ipairs(LANES) do
    local product = s.products .. "/portable-product-" .. lane
    for _, name in ipairs({ "cosmic", "executed-cosmic.sha256", "expected-platforms" }) do
      assert(is_file(product .. "/" .. name), product .. ": no file " .. name)
    end
    assert(Prerelease.expects_four(read(product .. "/expected-platforms")),
      product .. ": expected-platforms is not 4")
    local lane_digest, why = Prerelease.manifest_digest(read(product .. "/executed-cosmic.sha256"))
    assert(lane_digest ~= nil, product .. "/executed-cosmic.sha256: " .. why)
    local bytes = ArtifactRow.with(read(product .. "/cosmic"), scratch, nil)
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
  assert(Fs.write(s.release .. "/cosmic", baseline, 0x1ed))
  s.smoke(s.release .. "/cosmic")
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

--- A GET of `path`, a JSON object's text; raises where there is none.
local function api_object(p: Prerelease.Publish, path: string): string
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
  assert(reply.status == 404, "GET " .. path .. " failed (HTTP status " .. tostring(reply.status) .. ")")
  return false
end

--- The tag a commit is published under: the UTC day of its committer
--- date, so a rerun of the same commit gives the same tag, then the
--- commit. There is no semver and no alias that moves.
local function tag_of(p: Prerelease.Publish): string
  local date = p.date
  assert(date ~= nil, "the tag's date is not read yet")
  return date .. "-" .. p.commit
end

function Prerelease.commit_day(date: string): string
  local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T%d%d:%d%d:%d%dZ$")
  assert(year ~= nil and month ~= nil and day ~= nil, "the commit's committer date is no UTC time: " .. date)
  return year .. month .. day
end

--- A commit as the API answers it: the committer date is all `publish` reads.
local record CommitPerson
  date?: any
end
local record CommitInner
  committer?: CommitPerson
end
local record CommitJson
  commit?: CommitInner
end
local COMMIT_JSON <const> = Shape.record_of("CommitJson")

--- The UTC day the commit was committed, from the API.
local function committed_day(p: Prerelease.Publish): string
  local path = "repos/" .. p.repository .. "/commits/" .. p.commit
  local decoded, why = COMMIT_JSON:decode_into(api_object(p, path))
  assert(decoded ~= nil, "GET " .. path .. ": " .. why)
  local inner = decoded.commit
  local person = if inner ~= nil then inner.committer else nil end
  local date = if person ~= nil then person.date else nil end
  assert(date is string, "GET " .. path .. " names no committer date")
  return Prerelease.commit_day(date)
end

--- The pages of 100 the releases list serves: GitHub stops at its 1000th,
--- a page past that answering 422 or not by the server it reaches.
local list_pages <const> = 10

--- What a release answered by tag is read for: its id, which must be an integer.
local record ReleaseId
  id?: any
end
local RELEASE_ID <const> = Shape.record_of("ReleaseId")

--- The ids of the releases tagged with `p`'s tag, a draft's among them.
--- The list of releases serves only its first 1000, so it is not read
--- whole: a published release is asked for by its tag, which answers
--- none but a published one, and the list is read only while its
--- releases are drafts, which it lists before every other
--- ([`Prerelease.draft_ids`] raises where it does not), so the first page
--- that holds one that is no draft ends it. A draft made or deleted
--- between two pages' requests shifts them, so an id is taken once. A
--- transport error or a status but 2xx and 404 raises, so neither can
--- lead to making anything.
local function release_ids(p: Prerelease.Publish): {integer}
  local tag = tag_of(p)
  local ids: mut {integer} = {}
  local taken: mut {integer:boolean} = {}
  local by_tag = "repos/" .. p.repository .. "/releases/tags/" .. tag
  local found, why = GithubApi.request(p.client, "GET", by_tag)
  assert(found ~= nil, why)
  if found.status ~= 404 then
    assert(found.status >= 200 and found.status <= 299,
      "GET " .. by_tag .. " failed (HTTP status " .. tostring(found.status) .. ")")
    local published, decode_trouble = RELEASE_ID:decode_into(found.body)
    assert(published ~= nil, "GET " .. by_tag .. ": " .. decode_trouble)
    local id = published.id
    assert(id is integer, "release " .. tag .. " has no id")
    ids[#ids + 1] = id
    taken[id] = true
  end
  for page = 1, list_pages do
    local path = "repos/" .. p.repository .. "/releases?per_page=100&page=" .. tostring(page)
    local reply, trouble = GithubApi.request(p.client, "GET", path)
    assert(reply ~= nil, trouble)
    assert(reply.status >= 200 and reply.status <= 299,
      "GET " .. path .. " failed (HTTP status " .. tostring(reply.status) .. ")")
    local drafts = Prerelease.draft_ids(reply.body, tag)
    for _, id in ipairs(drafts.ids) do
      if taken[id] == nil then
        taken[id] = true
        ids[#ids + 1] = id
      end
    end
    if drafts.ends then return ids end
  end
  error("the releases list's first " .. tostring(list_pages * 100) .. " are all drafts")
end

--- The git object a ref or a tag names.
local record GitObject
  sha?: any
  type?: any
end
--- A ref or an annotated tag as the API answers it.
local record GitRef
  ref?: any
  object?: GitObject
end
local GIT_REF <const> = Shape.record_of("GitRef")

--- The git object `object` (a ref's or a tag's `object` field) names.
local function target(object: GitObject?, what: string): string, string
  assert(object ~= nil, what .. " names no object")
  local sha, kind = object.sha, object.type
  assert(sha is string and kind is string, what .. " names no object")
  return sha, kind
end

--- The ref or annotated tag at `path`, read from the API.
local function git_ref(p: Prerelease.Publish, path: string): GitRef
  local ref, why = GIT_REF:decode_into(api_object(p, path))
  assert(ref ~= nil, "GET " .. path .. ": " .. why)
  return ref
end

--- The tag names the commit being published. It is resolved as a tag,
--- through git/ref/tags/, and not by commits/<name>, which would also
--- take a branch of that name; an annotated tag is peeled to the commit
--- it tags.
local function verify_tag(p: Prerelease.Publish)
  local tag = tag_of(p)
  local ref = git_ref(p, "repos/" .. p.repository .. "/git/ref/tags/" .. tag)
  assert(ref.ref == "refs/tags/" .. tag, tag .. ": the API answered another ref")
  local sha, kind = target(ref.object, tag)
  -- A tag may tag a tag; a chain longer than this is no release tag.
  for _ = 1, 8 do
    if kind ~= "tag" then break end
    local annotated = git_ref(p, "repos/" .. p.repository .. "/git/tags/" .. sha)
    sha, kind = target(annotated.object, tag)
  end
  assert(kind == "commit", tag .. " names no commit")
  assert(sha == p.commit, tag .. " names another commit")
end

--- The repository as the API answers a GET of it.
local record Repository
  default_branch?: any
end
local REPOSITORY <const> = Shape.record_of("Repository")

--- A file of a compare.
local record ChangedFile
  filename?: any
end
--- A compare of two commits as the API answers it.
local record Comparison
  files?: {ChangedFile}
end
local COMPARISON <const> = Shape.record_of("Comparison")

--- Whether the repository's default branch holds workflows other than
--- `p.commit`'s: the files the compare from the commit to the branch
--- changes include one under .github/workflows/.
local function workflows_moved(p: Prerelease.Publish): boolean
  local path = "repos/" .. p.repository
  local repo, why = REPOSITORY:decode_into(api_object(p, path))
  assert(repo ~= nil, "GET " .. path .. ": " .. why)
  local branch = repo.default_branch
  assert(branch is string, p.repository .. " names no default branch")
  local compare_path = "repos/" .. p.repository .. "/compare/" .. p.commit .. "..." .. branch
  local compare, trouble = COMPARISON:decode_into(api_object(p, compare_path))
  assert(compare ~= nil, "GET " .. compare_path .. ": " .. trouble)
  local files = compare.files
  assert(files ~= nil, "the compare to " .. branch .. " lists no files")
  for _, file in ipairs(files) do
    local name = file.filename
    if name is string and name:match("^%.github/workflows/") ~= nil then return true end
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
          made.body:find("Resource not accessible by integration", 1, true) ~= nil and
          workflows_moved(p) then
        return false
      end
      error("POST " .. path .. " ref=refs/tags/" .. tag .. " failed (HTTP status " ..
          tostring(made.status) .. ")", 0)
    end
  end
  verify_tag(p)
  return true
end

--- An asset of a release.
local record AssetRow
  name?: any
  id?: any
end
--- A release as GET releases/ID answers it.
local record ReleaseView
  prerelease?: any
  draft?: any
  upload_url?: any
  assets?: {AssetRow}
end
local RELEASE_VIEW <const> = Shape.record_of("ReleaseView")

--- The release `id`, as GET releases/ID answers: by id, not by tag, as
--- the by-tag endpoint finds no draft.
local function view(p: Prerelease.Publish, id: integer): ReleaseView
  local path = "repos/" .. p.repository .. "/releases/" .. tostring(id)
  local release, why = RELEASE_VIEW:decode_into(api_object(p, path))
  assert(release ~= nil, "GET " .. path .. ": " .. why)
  return release
end

--- The names of a release's assets, sorted, and each one's id.
local function assets_of(release: ReleaseView): {string}, {string:integer}
  local assets = release.assets
  assert(assets ~= nil, "the release's assets are no array")
  local names: mut {string} = {}
  local ids: mut {string:integer} = {}
  -- TODO: an asset whose `state` is not "uploaded" is what a run that
  -- died mid-upload leaves: delete it (`DELETE releases/assets/ID`) and
  -- upload it again. Until then a re-run fails on it (it is listed as an
  -- asset, so its download or comparison fails) until someone deletes it
  -- by hand.
  for _, asset in ipairs(assets) do
    local name, id = asset.name, asset.id
    assert(name is string, "an asset has no name")
    assert(id is integer, "asset " .. name .. " has no id")
    names[#names + 1] = name
    ids[name] = id
  end
  table.sort(names)
  return names, ids
end

-- Not verified against a live release: that GitHub answers an asset
-- request made as bytes with a redirect to a signed URL on another host
-- (or the bytes themselves, which `download` also takes), and that the
-- uploads host takes a body of ~17 MB sent without `Expect`.

--- Downloads the asset `name`, whose id is `id`, into `destination`.
local function download(p: Prerelease.Publish, id: integer, name: string, destination: string)
  local ok, why = GithubApi.download(p.client, "repos/" .. p.repository ..
      "/releases/assets/" .. tostring(id), destination .. "/" .. name, "application/octet-stream")
  assert(ok, why)
end

--- A directory under the job's temporary directory, made now.
local function fresh(p: Prerelease.Publish, name: string): string
  local path = p.temp .. "/prerelease/" .. name
  local there, why = Fs.exists(path)
  assert(there ~= nil, why)
  assert(not there, path .. " exists already")
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
  for _, asset in ipairs(ASSETS) do
    download(p, assert(ids[asset]), asset, destination)
  end
  same_bytes(p.release .. "/cosmic", destination .. "/cosmic")
  same_bytes(p.release .. "/SHA256SUMS", destination .. "/SHA256SUMS")
  source_checked(p, digest, destination .. "/source.json")
end

local function flag(value: any, name: string): boolean
  assert(value is boolean, "the release's " .. name .. " is no boolean")
  return value
end

--- Publishes the release staged under `p.release` as <YYYYMMDD>-<commit>, or
--- verifies the one already there. A draft left by an interrupted run is
--- resumed only by accepting the assets it holds that are identical to
--- the staged ones. Raises on any failure; the line to print on success,
--- or on a skip ([`ensure_tag`]), a warning annotation.
function Prerelease.publish(p: Prerelease.Publish): string
  if p.date == nil then p.date = committed_day(p) end
  local tag = tag_of(p)
  local digest = Hash.hex_sha256(read(p.release .. "/cosmic"))
  local ids = release_ids(p)
  assert(#ids <= 1, Plural.count(#ids, "release") .. (if #ids == 1 then " is" else " are" end) .. " tagged " .. tag)
  local release: integer
  if #ids == 1 then
    release = assert(ids[1])
    verify_tag(p)
    local state = view(p, release)
    assert(flag(state.prerelease, "prerelease"), tag .. " is no prerelease")
    if not flag(state.draft, "draft") then
      verify_assets(p, release, digest, "published")
      return "prerelease already published and verified: " .. tag
    end
  else
    if not ensure_tag(p) then
      return "::warning::prerelease skipped: " .. tag .. ": GitHub refused the tag, " ..
        "the default branch's workflows having moved past it"
    end
    local made: Prerelease.NewRelease = { tag_name = tag, name = tag,
      body = read(p.release .. "/notes.md"), draft = true, prerelease = true }
    local created_text, trouble = GithubApi.object(p.client, "POST",
      "repos/" .. p.repository .. "/releases", made)
    assert(created_text ~= nil, trouble)
    local created, created_trouble = RELEASE_ID:decode_into(created_text)
    assert(created ~= nil, "the created release: " .. created_trouble)
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
  local existing: mut {string:boolean} = {}
  local names, asset_ids = assets_of(state)
  for _, name in ipairs(names) do
    assert(Prerelease.known_asset(name), tag .. " holds an unexpected asset: " .. name)
    existing[name] = true
    local destination = fresh(p, "existing-" .. name)
    download(p, assert(asset_ids[name]), name, destination)
    if name == "source.json" then
      source_checked(p, digest, destination .. "/" .. name)
    else
      same_bytes(p.release .. "/" .. name, destination .. "/" .. name)
    end
  end
  for _, name in ipairs(ASSETS) do
    if existing[name] ~= true then
      local uploaded, trouble = GithubApi.upload(p.client, upload_url, name,
        read(p.release .. "/" .. name), asset_types[name])
      assert(uploaded, tag .. ": " .. trouble)
    end
  end
  verify_assets(p, release, digest, "completed")
  local edited, trouble = GithubApi.object(p.client, "PATCH",
    "repos/" .. p.repository .. "/releases/" .. tostring(release), { draft = false, prerelease = true })
  assert(edited ~= nil, trouble)
  verify_tag(p)
  verify_assets(p, release, digest, "published")
  assert(not flag(view(p, release).draft, "draft"), tag .. " is still a draft")
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
  if answer is string and answer ~= "" then assert(Fs.put(Fs.stdout, answer .. "\n")) end
  return 0
end

function Prerelease.stage_command(argv: {string}): integer
  return command("prerelease-stage", argv, function(): string
    Prerelease.stage(Prerelease.stage_context(Env.all()))
    return ""
  end)
end

function Prerelease.publish_command(argv: {string}, context?: Prerelease.Publish): integer
  return command("prerelease-publish", argv, function(): string
    return Prerelease.publish(context or Prerelease.publish_context(Env.all()))
  end)
end

return Prerelease
