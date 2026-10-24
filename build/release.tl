--- `cosmic release`: finds cosmic's own releases, picks one, and
--- downloads and verifies it. A release is the `next-<commit>`
--- prerelease ci/cosmic_ci/prerelease.tl publishes for a commit on main,
--- holding three assets: `cosmic`, `SHA256SUMS` (`<sha256>  cosmic`) and
--- `source.json` (the commit, the digest and the run that made it).
---
--- The releases are found through their tags and main's history. The
--- API's list of releases is no use: it serves only the first 1000, page
--- 11 answering 422 or not by the server it reaches, and orders them by
--- the day of each tagged commit, so a draft published days after its
--- commit lands among the old. Instead the API's git matching-refs names
--- every `next-` tag in one request (all of them, a few hundred bytes
--- each); main's commits are read newest first, a page of 100 at a time;
--- and each commit that has a tag is asked for its release by the tag,
--- until enough are found. ci/cosmic_ci/prerelease.tl makes the tag
--- before the draft, so a tag may have only a draft, or nothing, behind
--- it: the API answers 404 for either, and the commit is passed over. So
--- the newest release is that of the latest commit on main that has one,
--- three requests. The history read ends once every tagged commit has
--- been passed, or at its end, and fails rather than answer in part past
--- 100 pages. A draft, a release not tagged `next-<40 hex>` and one
--- missing any of the three assets, or with others, are passed over.
---
--- With no criterion the newest is picked. `--commit <hex>` keeps the
--- release whose commit starts with the hex (7 to 40 digits), and
--- `--until <time>` those published at or before an RFC 3339 time, or by
--- the end of a date in UTC: main's commits are read from the last one
--- made by then (a release is published after its commit), and the
--- first whose release was published by then is the pick. Both may be
--- given. A prefix that matches two releases is refused, naming both.
---
--- A `--commit` reads no history: matching-refs names the tags
--- `next-<prefix>` starts, and each is asked for its release by its tag,
--- so a prefix naming more than 10 tags is refused as too short to tell
--- one. A full commit names its one tag without asking. Its matches are
--- sorted newest first by when they were published.
---
--- A release is verified before anything about it is printed or kept:
--- its SHA256SUMS names one digest for `cosmic`, and its source.json
--- names the tag's commit and that digest. A binary written anywhere is
--- downloaded beside its target and renamed into place only once its
--- sha256 is that digest, so a failed check leaves nothing. The trust
--- rests on TLS to GitHub: the assets are not signed, so the checks
--- catch a release that disagrees with itself or a broken transfer, not
--- a forged release.
---
--- What it does with the release:
---
--- * nothing given: prints the release as the three lines of
---   ci/cosmic-driver.pin (commit, URL, sha256), or with `--json` an
---   object, without downloading the binary.
--- * `--list`: prints the matches, up to `-n` (20 by default), in main's
---   order, latest commit first (by `--commit`, newest published first):
---   the publication time and commit, a line each, or with `--json` an
---   array. Each costs a request, against an unauthenticated limit of 60
---   an hour. Nothing is downloaded or verified.
--- * `-o <file>`: writes the binary there, mode 0755.
--- * `--cache`: writes it where bin/cosmic-bootstrap caches the pin's,
---   `$XDG_CACHE_HOME/cosmic/bootstrap/cosmic-<sha256>`, and prints that
---   path, as an absolute `XDG_CACHE_HOME` or `HOME` names it ([`Fs.cache_dir`];
---   bin/cosmic-bootstrap also takes a relative `XDG_CACHE_HOME`, which
---   this does not). A file already there whose sha256 is the digest is kept, and
---   made executable, as a run cut off before its chmod would leave it.
--- * `--pin <file>`: writes the three pin lines there, once the binary's
---   bytes are verified: streamed and hashed when neither `-o` nor
---   `--cache` keeps them.
---
--- `GH_TOKEN`, when set, goes with the API's requests, and with nothing
--- else, lifting the unauthenticated rate limit of 60 an hour; a GitHub
--- Actions step sets it from `github.token`. Every redirect must stay on
--- https.
---
--- It prints no summary: its output is data for a pipe. Exits 0 when it
--- did what was asked, 1 when it could not (no connection, no matching
--- release, a release that fails verification, a write that failed), 2
--- for a command line it refused.
---
--- The repository is cosmic-lua/cosmic, fixed: a fork's releases are
--- not the ones the pin and bin/cosmic-bootstrap name.

local bare = require("build.bare")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local plural = require("build.plural")
local Shape = require("cosmic.shape")
local Signal = require("cosmic.signal")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")
local verb_spec = require("build.verb_spec")

--- The `cosmic release` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given. False and why when the bytes
    --- did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- For a test, in place of the network: the [`Http.Options.script`]
    --- of each request in turn, a request past the last answered by an
    --- empty reply.
    script?: {{string}}
    --- In place of GitHub's, for a test whose script cannot answer TLS:
    --- the API's URL of the repository and the prefix of a release's asset URLs,
    --- which the printed and pinned URLs still name GitHub's.
    api?: string
    downloads?: string
    --- Called with each API request's URL before it is sent, for a test
    --- to see what was asked.
    requested?: function(url: string)
    --- The variables read (`GH_TOKEN`, `XDG_CACHE_HOME`, `HOME`), by
    --- name; the process's own when nil.
    env?: {string:string}
  end
  --- One release as it is picked and printed.
  record Release
    tag: string
    commit: string
    --- When it was published, as RFC 3339 in UTC.
    published_at: string
    --- The binary's download URL, as ci/cosmic-driver.pin names it.
    url: string
  end
  --- The digest SHA256SUMS names for `cosmic`, or nil and why.
  sums_digest: function(text: string): string | nil, string
  --- The three lines of ci/cosmic-driver.pin for a release.
  pin_text: function(commit: string, digest: string): string
end

local spec <const> = assert((assert(Cli.verbs["release"])).spec)

local usage = "cosmic release [--commit <hex>] [--until <time>] " ..
  "[--list [-n <count>] | -o <file> | --cache] [--pin <file>] [--json]"

local repository <const> = "cosmic-lua/cosmic"
local api <const> = "https://api.github.com/repos/" .. repository
local downloads <const> = "https://github.com/" .. repository .. "/releases/download/"
local per_page <const> = 100
--- The most tags a `--commit` prefix may name, each a request: more is a
--- prefix too short to tell one release, and would cost about what
--- reading every page does.
local max_tags <const> = 10
--- The most pages of main's history one scan reads, against a runaway:
--- 10000 commits, past the first release.
local max_pages <const> = 100
local default_count <const> = 20
--- What SHA256SUMS or source.json may weigh; each is a line or two.
local max_small <const> = 65536

--- One asset of a release, as the API lists it.
local record Asset
  name: string
end
--- One release, as the API lists it. Only what is read is kept.
local record ApiRelease
  tag_name: string
  draft: boolean
  prerelease: boolean
  published_at: string | nil
  assets: {Asset}
end
local RELEASE_SPEC <const> = Shape.record({
  tag_name = Shape.string,
  draft = Shape.boolean,
  prerelease = Shape.boolean,
  published_at = Shape.optional(Shape.string),
  assets = Shape.list(Shape.record({ name = Shape.string })),
})
--- One commit as the API lists main's history; only its hash is read.
local record Commit
  sha: string
end
local HISTORY_SPEC <const> = Shape.list(Shape.record({ sha = Shape.string }))

--- One ref as git matching-refs lists it: `refs/tags/<tag>`.
local record Ref
  ref: string
end
local REFS_SPEC <const> = Shape.list(Shape.record({ ref = Shape.string }))

--- What source.json says.
local record Source
  commit: string
  digest: string
end
local SOURCE_SPEC <const> = Shape.record({ commit = Shape.string, digest = Shape.string })

local required_assets <const> = { "cosmic", "SHA256SUMS", "source.json" }

--- The release's binary URL, as bin/cosmic-bootstrap requires the pin to
--- name it.
local function binary_url(commit: string): string
  return downloads .. "next-" .. commit .. "/cosmic"
end

function verb.sums_digest(text: string): string | nil, string
  local found: string | nil = nil
  for line in text:gmatch("[^\n]+") do
    -- `*` marks a digest of a file read in binary mode, as sha256sum -b writes it.
    local digest, name = line:match("^(%x+) [ *](.+)$")
    if digest ~= nil and name == "cosmic" then
      if found ~= nil then return nil, "SHA256SUMS names cosmic twice" end
      if #digest ~= 64 then return nil, "SHA256SUMS's digest for cosmic is not a sha256" end
      found = digest:lower()
    end
  end
  if found == nil then return nil, "SHA256SUMS names no digest for cosmic" end
  return found, ""
end

function verb.pin_text(commit: string, digest: string): string
  return commit .. "\n" .. binary_url(commit) .. "\n" .. digest .. "\n"
end

--- The release `r` names, or nil when it is not a published prerelease
--- holding the three assets and no others, as ci/cosmic_ci/prerelease.tl
--- publishes one.
local function usable(r: ApiRelease): verb.Release | nil
  local published = r.published_at
  if r.draft or not r.prerelease or published == nil or #r.assets ~= #required_assets then
    return nil
  end
  local commit = r.tag_name:match("^next%-(%x+)$")
  if commit == nil or #commit ~= 40 or commit:find("[A-F]") ~= nil then return nil end
  local names: {string:boolean} = {}
  for _, asset in ipairs(r.assets) do names[asset.name] = true end
  for _, name in ipairs(required_assets) do
    if names[name] ~= true then return nil end
  end
  return { tag = r.tag_name, commit = commit, published_at = published, url = binary_url(commit) }
end

--- How many requests a run has made, which picks each one's script.
local record Requests
  made: integer
end

local standard: verb.Io = { out = bare.out, err = bare.err }

--- `cosmic release [options]`: returns the exit code.
--- @param argv the command line, `release` at slot 1
--- @param io where output, complaints and requests go; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("release", to.err)
  local function refuse(why: string): integer
    complain(why .. "; " .. usage)
    return bare.refused
  end
  local function fail(why: string): integer
    complain(why)
    return bare.failed
  end
  local function getenv(name: string): string
    local env = to.env
    if env ~= nil then return env[name] or "" end
    return Env.get_or(name, "")
  end

  local flags, trouble = Flags.parse(argv, 2, spec)
  if flags == nil then return refuse(trouble) end
  local parsed: Flags.Parsed = flags
  if #parsed.words ~= 0 then
    return refuse("takes no words, but was given " .. plural.count(#parsed.words, "word"))
  end
  local prefix = parsed.values["--commit"]
  if prefix ~= nil then
    if #prefix < 7 or #prefix > 40 or prefix:find("[^%x]") ~= nil then
      return refuse("--commit wants 7 to 40 hex digits, not " .. prefix)
    end
    prefix = prefix:lower()
  end
  -- The last moment a release may have been published at.
  local until_ns: integer | nil = nil
  local until_text = parsed.values["--until"]
  if until_text ~= nil then
    local ns, _ = Time.parse_rfc3339(until_text)
    if ns == nil then
      local day, _ = Time.parse_date(until_text)
      if day ~= nil then ns = day + Clock.seconds(86400) - 1 end
    end
    if ns == nil then
      return refuse("--until wants an RFC 3339 time or a date, not " .. until_text)
    end
    until_ns = ns
  end
  local listing = parsed.set["--list"] == true
  local as_json = parsed.set["--json"] == true
  local target = parsed.values["-o"]
  local to_cache = parsed.set["--cache"] == true
  local pin = parsed.values["--pin"]
  if target == "" then return refuse(bare.empty_file .. " after -o") end
  if pin == "" then return refuse(bare.empty_file .. " after --pin") end
  local count = default_count
  local count_text = parsed.values["-n"]
  if count_text ~= nil then
    if not listing then return refuse("-n counts what --list prints") end
    local n = math.tointeger(tonumber(count_text))
    if n == nil or n < 1 or count_text:match("^%d+$") == nil then
      return refuse("-n wants a whole number from 1, not " .. count_text)
    end
    count = n
  end
  if listing and (target ~= nil or to_cache or pin ~= nil) then
    return refuse("--list downloads nothing, so there is nothing for -o, --cache or --pin")
  end
  if target ~= nil and to_cache then
    return refuse("give -o or --cache, not both")
  end
  if as_json and (target ~= nil or to_cache or pin ~= nil) then
    return refuse("--json shapes what is printed with no -o, --cache or --pin")
  end

  local repo_url = to.api or api
  local releases_url = repo_url .. "/releases"
  local assets_url = to.downloads or downloads
  local token = getenv("GH_TOKEN")
  local https_only: {string} = { "https" }
  local requests: Requests = { made = 0 }
  --- The options of one request. Only an API call has `headers`, and it
  --- takes no redirect: its token is for the API's own origin, and an
  --- answer that moved (a renamed repository) fails rather than be
  --- followed.
  local function never(): boolean return false end
  local function options(headers?: {string:string}, sha256?: string, cancelled?: function(): boolean): Http.Options
    requests.made = requests.made + 1
    local script: {string} | nil = nil
    local scripts = to.script
    if scripts ~= nil then
      script = scripts[requests.made]
      if script == nil then script = { "" } end
    end
    -- The API's answer names the digest each download is checked
    -- against, so it trusts the minimal roots (and $SSL_CERT_FILE's),
    -- not every root the binary carries, as `cosmic refresh` does.
    return { script = script, headers = headers, follow = headers == nil, sha256 = sha256,
      redirect_protocols = https_only, cancelled = cancelled or never, roots = "minimal" }
  end

  --- One request to the API: the body, or nil and why. A 404 is nil and "".
  local function call(url: string): string | nil, string
    local headers: {string:string} = {
      ["Accept"] = "application/vnd.github+json",
      ["X-GitHub-Api-Version"] = "2022-11-28",
      ["User-Agent"] = "cosmic-release",
    }
    if token ~= "" then headers["Authorization"] = "Bearer " .. token end
    local requested = to.requested
    if requested ~= nil then requested(url) end
    local got, why = Http.get(url, options(headers))
    if got == nil then return nil, url .. ": " .. why end
    local status = tostring(got.status)
    if got.status == 404 then return nil, "" end
    if got.status == 403 or got.status == 429 then
      local hint = ""
      if token == "" then hint = " (set GH_TOKEN to lift the unauthenticated limit)" end
      return nil, url .. ": HTTP " .. status .. ", likely the API's rate limit" .. hint
    end
    if got.status < 200 or got.status >= 300 then
      return nil, url .. ": HTTP " .. status
    end
    return got.body, ""
  end

  local function wanted(r: verb.Release): boolean
    if prefix ~= nil and r.commit:sub(1, #prefix) ~= prefix then return false end
    if until_ns ~= nil then
      local at, _ = Time.parse_rfc3339(r.published_at)
      if at == nil or at > until_ns then return false end
    end
    return true
  end

  -- The matches, newest first: up to `need` of them from main's history,
  -- or every one a `--commit` names.
  local function matches(need: integer): {verb.Release} | nil, string
    local found: {verb.Release} = {}
    local seen: {string:boolean} = {}
    local function take(r: ApiRelease)
      local release = usable(r)
      if release ~= nil and seen[release.tag] == nil and wanted(release) then
        seen[release.tag] = true
        found[#found + 1] = release
      end
    end
    local function sorted(): {verb.Release}
      -- RFC 3339 in UTC, as the API writes every time, sorts as text.
      table.sort(found, function(a: verb.Release, b: verb.Release): boolean
        if a.published_at ~= b.published_at then return a.published_at > b.published_at end
        return a.tag > b.tag
      end)
      return found
    end
    if prefix ~= nil then
      local tags: {string} = {}
      if #prefix == 40 then
        tags[1] = "next-" .. prefix
      else
        local url = repo_url .. "/git/matching-refs/tags/next-" .. prefix
        local text, why = call(url)
        -- No match answers `[]`, so a 404 is a repository not found.
        if text == nil then
          if why == "" then why = url .. ": HTTP 404" end
          return nil, why
        end
        local refs, shape_trouble: {Ref} | nil, string = Shape.decode_into(text, REFS_SPEC)
        if refs == nil then return nil, url .. ": no list of refs: " .. shape_trouble end
        if #refs > max_tags then
          return nil, plural.count(#refs, "tag") .. " start with next-" .. prefix .. "; give more of it"
        end
        for _, ref in ipairs(refs) do
          local tag = ref.ref:match("^refs/tags/(next%-%x+)$")
          if tag ~= nil then tags[#tags + 1] = tag end
        end
      end
      for _, tag in ipairs(tags) do
        local url = releases_url .. "/tags/" .. tag
        local text, why = call(url)
        -- A tag with no release, or only a draft's, answers 404.
        if text == nil and why ~= "" then return nil, why end
        if text ~= nil then
          local r, shape_trouble: ApiRelease | nil, string =
            Shape.decode_into(text, RELEASE_SPEC, { null_value = Json.null })
          if r == nil then return nil, url .. ": no release: " .. shape_trouble end
          take(r)
        end
      end
      return sorted(), ""
    end
    -- Each commit that has a `next-` tag, and how many of them the
    -- history read has yet to pass.
    local tagged: {string:boolean} = {}
    local unpassed = 0
    local refs_url = repo_url .. "/git/matching-refs/tags/next-"
    local refs_text, refs_why = call(refs_url)
    if refs_text == nil then
      if refs_why == "" then refs_why = refs_url .. ": HTTP 404" end
      return nil, refs_why
    end
    local refs, refs_trouble: {Ref} | nil, string = Shape.decode_into(refs_text, REFS_SPEC)
    if refs == nil then return nil, refs_url .. ": no list of refs: " .. refs_trouble end
    for _, ref in ipairs(refs) do
      local commit = ref.ref:match("^refs/tags/next%-(%x+)$")
      if commit ~= nil and #commit == 40 and tagged[commit:lower()] == nil then
        tagged[commit:lower()] = true
        unpassed = unpassed + 1
      end
    end
    if unpassed == 0 then return found, "" end
    local asked: {string:boolean} = {}
    local query = "?sha=main&per_page=" .. tostring(per_page)
    if until_ns ~= nil then
      query = query .. "&until=" .. Time.format_rfc3339(until_ns, nil, { digits = 0 })
    end
    for page = 1, max_pages do
      local url = repo_url .. "/commits" .. query .. "&page=" .. tostring(page)
      local text, why = call(url)
      if text == nil then
        if why == "" then why = url .. ": HTTP 404" end
        return nil, why
      end
      local commits, shape_trouble: {Commit} | nil, string = Shape.decode_into(text, HISTORY_SPEC)
      if commits == nil then return nil, url .. ": no list of commits: " .. shape_trouble end
      for _, commit in ipairs(commits) do
        -- History that grew between two pages' requests repeats a commit.
        if tagged[commit.sha] == true and asked[commit.sha] == nil then
          asked[commit.sha] = true
          unpassed = unpassed - 1
          local release_url = releases_url .. "/tags/next-" .. commit.sha
          local release_text, release_why = call(release_url)
          if release_text == nil and release_why ~= "" then return nil, release_why end
          if release_text ~= nil then
            local r, release_trouble: ApiRelease | nil, string =
              Shape.decode_into(release_text, RELEASE_SPEC, { null_value = Json.null })
            if r == nil then return nil, release_url .. ": no release: " .. release_trouble end
            take(r)
            if #found >= need then return found, "" end
          end
          if unpassed == 0 then return found, "" end
        end
      end
      if #commits < per_page then return found, "" end
    end
    return nil, repo_url .. ": main's history runs past " .. plural.count(max_pages, "page") ..
      " with tags not yet passed"
  end

  local function written(ok: boolean, why: string): integer
    return bare.written(complain, ok, why)
  end

  if listing then
    local found, why = matches(count)
    if found == nil then return fail(why) end
    local shown: {verb.Release} = {}
    for _, r in ipairs(found) do
      if #shown == count then break end
      shown[#shown + 1] = r
    end
    if as_json then
      if #shown == 0 then return written(to.out("[]\n")) end
      local encoded = assert(Json.encode_any(shown, { pretty = true }))
      return written(to.out(encoded .. "\n"))
    end
    local lines: {string} = {}
    for _, r in ipairs(shown) do lines[#lines + 1] = r.published_at .. "  " .. r.commit .. "\n" end
    return written(to.out(table.concat(lines)))
  end

  local found, why = matches(1)
  if found == nil then return fail(why) end
  local release = found[1]
  if release == nil then
    local where = ""
    if prefix ~= nil and #prefix == 40 then
      where = ", by its tag"
    elseif prefix ~= nil then
      where = ", among the tags next-" .. prefix .. " starts"
    end
    if until_text ~= nil then where = where .. ", published by --until " .. until_text end
    return fail("no release matches" .. where)
  end
  local second = found[2]
  if prefix ~= nil and second ~= nil then
    return fail("the commits of two releases start with " .. tostring(prefix) .. ", " .. release.commit ..
        " and " .. second.commit .. "; give more of it")
  end

  local function small(name: string): string | nil, string
    local url = assets_url .. release.tag .. "/" .. name
    local response, open_trouble = Http.open(url, options())
    if response == nil then return nil, url .. ": " .. open_trouble end
    local body, read_trouble: string | nil, string = nil, ""
    if response.status >= 200 and response.status < 300 then
      -- One byte past the cap tells a body at it from one over it.
      body, read_trouble = Stream.read_all(Stream.limit(response, max_small + 1))
    end
    local _, _ = response:close()
    if response.status < 200 or response.status >= 300 then
      return nil, url .. ": HTTP " .. tostring(response.status)
    end
    if body == nil then return nil, url .. ": " .. read_trouble end
    if #body > max_small then
      return nil, url .. ": more than " .. plural.count(max_small, "byte")
    end
    return body, ""
  end
  local sums, sums_trouble = small("SHA256SUMS")
  if sums == nil then return fail(sums_trouble) end
  local summed, digest_trouble = verb.sums_digest(sums)
  if summed == nil then return fail(release.tag .. ": " .. digest_trouble) end
  local digest: string = summed
  local source_text, source_trouble = small("source.json")
  if source_text == nil then return fail(source_trouble) end
  local source, decode_trouble: Source | nil, string = Shape.decode_into(source_text, SOURCE_SPEC)
  if source == nil then
    return fail(release.tag .. ": source.json is no source record: " .. decode_trouble)
  end
  if source.commit ~= release.commit then
    return fail(release.tag .. ": source.json names commit " .. source.commit)
  end
  if source.digest ~= digest then
    return fail(release.tag .. ": source.json names digest " .. source.digest .. ", SHA256SUMS " .. digest)
  end

  if target == nil and not to_cache and pin == nil then
    if as_json then
      local encoded = assert(Json.encode({ tag = release.tag, commit = release.commit,
        published_at = release.published_at, url = release.url, sha256 = digest }, { pretty = true }))
      return written(to.out(encoded .. "\n"))
    end
    return written(to.out(verb.pin_text(release.commit, digest)))
  end

  local binary = assets_url .. release.tag .. "/cosmic"
  local function download_until(path: string, cancelled: function(): boolean): boolean, string
    local result = Http.download_result(binary, path, options(nil, digest, cancelled))
    if result.kind == "downloaded" then return Fs.chmod(path, 0x1ed) end
    if result.kind == "http_status" then
      return false, binary .. ": HTTP " .. tostring(result.status)
    end
    if result.kind == "digest_mismatch" then
      return false, binary .. ": sha256 mismatch: want " .. digest .. ", got " .. tostring(result.actual)
    end
    return false, binary .. ": " .. result.reason
  end
  --- Downloads the binary to `path`, renamed into place once verified.
  --- Held for the download and closed however it leaves, a guard ends it
  --- on SIGINT or SIGTERM with no temporary file left, and closing it
  --- delivers the signal again, so the process still dies of it. A guard
  --- that cannot be had leaves the download uninterruptible.
  local function download(path: string): boolean, string
    local held, _ = Signal.guard()
    if held == nil then return download_until(path, never) end
    local guard <close> = held
    return download_until(path, function(): boolean return guard:cancelled() ~= 0 end)
  end

  local kept: string | nil = nil
  if target ~= nil then
    local ok, download_trouble = download(target)
    if not ok then return fail(download_trouble) end
  elseif to_cache then
    local dir, dir_trouble = Fs.cache_dir("bootstrap", { environment = to.env })
    if dir == nil then return fail(dir_trouble) end
    local path = dir .. "/cosmic-" .. digest
    local have, _ = Fs.read(path)
    if have == nil or Hash.hex_sha256(have) ~= digest then
      local ok, download_trouble = download(path)
      if not ok then return fail(download_trouble) end
    else
      local ok, chmod_trouble = Fs.chmod(path, 0x1ed)
      if not ok then return fail(chmod_trouble) end
    end
    kept = path
  else
    -- Only the pin is kept, so the bytes are hashed as they arrive.
    local response, open_trouble = Http.open(binary, options())
    if response == nil then return fail(binary .. ": " .. open_trouble) end
    local hashing = assert(Stream.hashing("sha256"))
    local copied, copy_trouble: integer | nil, string = nil, ""
    if response.status >= 200 and response.status < 300 then
      copied, copy_trouble = Stream.copy(response, hashing)
    end
    local _, _ = response:close()
    if response.status < 200 or response.status >= 300 then
      return fail(binary .. ": HTTP " .. tostring(response.status))
    end
    if copied == nil then return fail(binary .. ": " .. copy_trouble) end
    local got = Codec.hex((assert(hashing:digest())))
    if got ~= digest then
      return fail(binary .. ": sha256 mismatch: want " .. digest .. ", got " .. got)
    end
  end

  if pin ~= nil then
    local ok, write_trouble = Fs.write(pin, verb.pin_text(release.commit, digest))
    if not ok then return fail(write_trouble) end
  end
  if kept ~= nil then return written(to.out(kept .. "\n")) end
  return bare.ok
end

--- The `release` verb as [`build/verb_list.tl`] lists it. Reads GitHub's
--- releases, never the tree: never stale-checked (`bare` in
--- build/verb_spec.tl).
verb.spec = {
  name = "release",
  guide = "none: finds and fetches cosmic's own releases, described by `cosmic help release`",
  tests = { "build.release_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "the criteria a release must meet",
  exits = "`release` prints the release, the list or the cached path and nothing after, and exits 0 when it " ..
    "did what was asked, 1 when it could not, 2 for a command line it refused.",
  passthrough = "every case reaches GitHub's API, so build/release_test.tl holds it over a scripted transport",
}

return verb
