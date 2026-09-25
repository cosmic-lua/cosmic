-- The prerelease gate, for prerelease.yml's publish job: `stage` checks
-- the products every platform leg uploaded name the same bytes, which
-- each leg executed, and stages the release from them; `publish` makes
-- that release the immutable next-<commit> prerelease, or verifies the
-- one already there. Neither executes a byte it reads: the candidate
-- product is data here. `publish` drives the GitHub API through the `gh`
-- CLI, found on PATH, which reads GH_TOKEN from the environment it
-- inherits.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")

local record Prerelease
  --- The platform legs, in the order `sort` lists their products.
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
  --- SOURCE_COMMIT, SOURCE_RUN_PREFIX and RUNNER_TEMP, with `gh` found
  --- on its PATH and run in all of it, GH_TOKEN included.
  record Publish
    gh: string
    env: {string:string}
    repository: string
    release: string
    commit: string
    run_prefix: string
    temp: string
  end
end

Prerelease.lanes = { "alpine-x86_64", "linux-aarch64", "linux-x86_64", "macos-aarch64" }
--- The lane whose bytes every other lane's must equal.
local baseline_lane <const> = "linux-x86_64"
Prerelease.assets = { "cosmic", "SHA256SUMS", "source.json" }

-- A command's output holds the whole list of releases, which grows by
-- one each commit to main: well past Child's 16 MiB default before
-- anything else would give out.
local capture_limit <const> = 1 << 30

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

--- Whether an expected-platforms file says 4, as `test "$(cat f)" = 4`
--- held it.
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

--- source.json for the staged release: the object `jq -n` wrote, laid
--- out as jq lays it out, keys in byte order.
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
  local source, why = Json.decode_object(text)
  if source == nil then return false, "source.json is no JSON object: " .. why end
  if source.commit ~= commit then return false, "source.json names another commit" end
  if source.digest ~= digest then return false, "source.json names another digest" end
  local run_url = source.run_url
  if not run_url is string then return false, "source.json's run_url is no string" end
  if run_url:sub(1, #run_prefix) ~= run_prefix
      or not run_url:sub(#run_prefix + 1):match("^[0-9]+$") then
    return false, "source.json's run_url is not " .. run_prefix .. "<run id>"
  end
  return true, ""
end

--- The HTTP status `gh api --include` printed: the second field of the
--- last line that begins `HTTP/<version> <digits>`, as
--- `awk '/^HTTP\/[0-9.]+ [0-9]+/ { code=$2 }'` found it. nil when no
--- line does, as when the request never reached the API.
function Prerelease.http_status(output: string): string | nil
  local code: string | nil = nil
  for line in output:gmatch("[^\n]+") do
    if line:match("^HTTP/[0-9.]+ [0-9]") then
      code = line:match("^[^ \t]+[ \t]+([^ \t]+)")
    end
  end
  return code
end

--- Whether `names`, a release's asset names, are exactly the three a
--- published prerelease holds.
function Prerelease.complete_assets(names: {string}): boolean, string
  if #names ~= #Prerelease.assets then
    return false, "the release holds " .. #names .. " assets, not " .. #Prerelease.assets
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

--- The ids of the releases tagged `tag`, from the pages
--- `gh api --paginate --slurp` gathers of the releases list.
function Prerelease.release_ids(text: string, tag: string): {integer}
  local pages, why = Json.decode_array(text)
  assert(pages ~= nil, "the releases list is no JSON array: " .. why)
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
  assert(#found == #Prerelease.lanes, "expected " .. #Prerelease.lanes ..
    " product directories, found " .. #found)
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
  local gh, why = Proc.find("gh", required(env, "PATH"))
  assert(gh ~= nil, "no gh on PATH: " .. why)
  required(env, "GH_TOKEN")
  return { gh = gh, env = env, repository = required(env, "REPOSITORY"),
    release = required(env, "RELEASE"), commit = required(env, "SOURCE_COMMIT"),
    run_prefix = required(env, "SOURCE_RUN_PREFIX"), temp = required(env, "RUNNER_TEMP") }
end

--- Runs gh with `args`, stdin empty, its stderr this process's. Its
--- stdout is captured when `stdout` is "capture", else "inherit" or
--- "null". The result, whatever gh answered.
local function gh_run(p: Prerelease.Publish, args: {string}, stdout: string): Child.Result
  local argv: {string} = { p.gh }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, { env = p.env, stdin = "null",
    stdout = stdout, capture_limit = capture_limit })
  assert(result ~= nil, "gh " .. args[1] .. ": " .. trouble)
  assert(not result.truncated, "gh " .. args[1] .. ": output past the capture limit")
  return result
end

--- Runs gh with `args`, which must succeed; its stdout, when captured.
local function gh(p: Prerelease.Publish, args: {string}, stdout?: string): string
  local result = gh_run(p, args, stdout or "inherit")
  assert(result.ok, "gh " .. table.concat(args, " ") .. " failed")
  return result.stdout or ""
end

local function gh_object(p: Prerelease.Publish, args: {string}): {string:any}
  local text = gh(p, args, "capture")
  local value, why = Json.decode_object(text)
  assert(value ~= nil, "gh " .. table.concat(args, " ") .. ": no JSON object: " .. why)
  return value
end

--- Whether the API holds `endpoint`: true when gh fetches it, false for
--- an HTTP 404 and nothing else. Every other failure, a transport error
--- or another status, raises, so it can never lead to creating anything.
local function api_probe(p: Prerelease.Publish, endpoint: string): boolean
  local result = gh_run(p, { "api", "--include", endpoint }, "capture")
  if result.ok then return true end
  local status = Prerelease.http_status(result.stdout or "")
  assert(status == "404", "gh api " .. endpoint .. " failed (HTTP status " ..
    tostring(status) .. ")")
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
--- it tags. A deliberate change from the shell script, which checked
--- commits/<tag>: a branch named for the tag passed it.
local function verify_tag(p: Prerelease.Publish)
  local tag = tag_of(p)
  local ref = gh_object(p, { "api", "repos/" .. p.repository .. "/git/ref/tags/" .. tag })
  assert(ref.ref == "refs/tags/" .. tag, tag .. ": the API answered another ref")
  local sha, kind = target(ref.object, tag)
  -- A tag may tag a tag; a chain longer than this is no release tag.
  for _ = 1, 8 do
    if kind ~= "tag" then break end
    local annotated = gh_object(p, { "api", "repos/" .. p.repository .. "/git/tags/" .. sha })
    sha, kind = target(annotated.object, tag)
  end
  assert(kind == "commit", tag .. " names no commit")
  assert(sha == p.commit, tag .. " names another commit")
end

--- The tag exists, naming the commit: made when the API says it is absent.
local function ensure_tag(p: Prerelease.Publish)
  local tag = tag_of(p)
  if not api_probe(p, "repos/" .. p.repository .. "/git/ref/tags/" .. tag) then
    gh(p, { "api", "--method", "POST", "repos/" .. p.repository .. "/git/refs",
      "-f", "ref=refs/tags/" .. tag, "-f", "sha=" .. p.commit }, "null")
  end
  verify_tag(p)
end

local function view(p: Prerelease.Publish, fields: string): {string:any}
  return gh_object(p, { "release", "view", tag_of(p), "--repo", p.repository,
    "--json", fields })
end

local function asset_names(p: Prerelease.Publish): {string}
  local assets = view(p, "assets").assets
  assert(assets is {any} and Json.is_array(assets), "the release's assets are no array")
  local names: {string} = {}
  for _, asset in ipairs(assets) do
    assert(asset is {string:any}, "an asset is no object")
    local name = asset.name
    assert(name is string, "an asset has no name")
    names[#names + 1] = name
  end
  table.sort(names)
  return names
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
local function verify_assets(p: Prerelease.Publish, digest: string, name: string)
  local complete, why = Prerelease.complete_assets(asset_names(p))
  assert(complete, tag_of(p) .. ": " .. why)
  local destination = fresh(p, name)
  gh(p, { "release", "download", tag_of(p), "--repo", p.repository, "--dir", destination })
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
--- the staged ones. Raises on any failure; the line to print on success.
function Prerelease.publish(p: Prerelease.Publish): string
  local tag = tag_of(p)
  local digest = Hash.hex_sha256(read(p.release .. "/cosmic"))
  -- The get-by-tag endpoint only promises published releases. Listing
  -- releases with authentication also finds an interrupted draft.
  local ids = Prerelease.release_ids(gh(p, { "api", "--paginate", "--slurp", "--method", "GET",
    "repos/" .. p.repository .. "/releases?per_page=100" }, "capture"), tag)
  assert(#ids <= 1, #ids .. " releases are tagged " .. tag)
  if #ids == 1 then
    verify_tag(p)
    local state = view(p, "isDraft,isPrerelease")
    assert(flag(state, "isPrerelease"), tag .. " is no prerelease")
    if not flag(state, "isDraft") then
      verify_assets(p, digest, "published")
      return "prerelease already published and verified: " .. tag
    end
  else
    ensure_tag(p)
    gh(p, { "release", "create", tag, "--repo", p.repository, "--verify-tag",
      "--title", tag, "--notes-file", p.release .. "/notes.md", "--prerelease", "--draft" })
    verify_tag(p)
  end
  -- Resume an interrupted draft by accepting only identical existing
  -- assets. source.json may name an earlier successful run for this SHA.
  local existing: {string:boolean} = {}
  for _, name in ipairs(asset_names(p)) do
    assert(Prerelease.known_asset(name), tag .. " holds an unexpected asset: " .. name)
    existing[name] = true
    local destination = fresh(p, "existing-" .. name)
    gh(p, { "release", "download", tag, "--repo", p.repository, "--pattern", name,
      "--dir", destination })
    if name == "source.json" then
      source_checked(p, digest, destination .. "/" .. name)
    else
      same_bytes(p.release .. "/" .. name, destination .. "/" .. name)
    end
  end
  for _, name in ipairs(Prerelease.assets) do
    if not existing[name] then
      gh(p, { "release", "upload", tag, p.release .. "/" .. name, "--repo", p.repository })
    end
  end
  verify_assets(p, digest, "completed")
  gh(p, { "release", "edit", tag, "--repo", p.repository, "--draft=false", "--prerelease" })
  verify_tag(p)
  verify_assets(p, digest, "published")
  assert(not flag(view(p, "isDraft"), "isDraft"), tag .. " is still a draft")
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
