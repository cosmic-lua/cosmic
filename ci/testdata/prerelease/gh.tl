-- A stand-in for the gh CLI, for prerelease_test.tl: it answers the
-- `gh api` and `gh release` invocations the publish flow makes from a
-- state directory, FAKE_GH_STATE, standing in for one repository's tags,
-- releases and assets, and appends each invocation to its `calls` file.
-- Run with `cosmic --standalone`. The state directory holds:
--
--   repo                          the repository --repo must name
--   tags/<tag>                    the commit a tag names
--   annotated/<tag>               the tag object a tag's ref names, when
--                                 it is annotated
--   tag-objects/<sha>             the commit a tag object tags
--   branches/<name>               the commit a branch names
--   releases/<id>/tag             a release's tag, and whether it is a
--   releases/<id>/draft           draft and a prerelease ("true" or
--   releases/<id>/prerelease      "false")
--   releases/<id>/assets/<name>   its assets, and the commit publishing
--   releases/<id>/target          it tags when its tag is missing
--   fail/ref                      git/ref/tags/ answers HTTP 500
--   fail/ref-transport            git/ref/tags/ fails before any HTTP
--   fail/transport                every `gh api` fails before any HTTP
--   fail/edit-draft               `release edit` leaves the draft flag
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")

local state = assert(Env.get("FAKE_GH_STATE"), "FAKE_GH_STATE is unset")

local function read(path: string): string return (assert(Fs.read(path))) end
local function write(path: string, data: string) assert(Fs.write(path, data)) end
local function exists(path: string): boolean
  local there, why = Fs.exists(path)
  assert(there ~= nil, why)
  return there
end
local function list(path: string): {string}
  if not exists(path) then return {} end
  return (assert(Fs.list(path)))
end

local function fail(message: string): integer
  assert(Fs.put(Fs.stderr, "gh: " .. message .. "\n"))
  return 1
end

local function out(text: string): integer
  assert(Fs.put(Fs.stdout, text))
  return 0
end

local function json(value: any): string
  return assert(Json.encode(value)) .. "\n"
end

local record Parsed
  positional: {string}
  options: {string:string}
  fields: {string:string}
end

local valued: {string:boolean} = { ["--method"] = true, ["--repo"] = true,
  ["--json"] = true, ["--dir"] = true, ["--pattern"] = true, ["--title"] = true,
  ["--notes-file"] = true }

local function parse(argv: {integer:string}): Parsed
  local p: Parsed = { positional = {}, options = {}, fields = {} }
  local i = 2
  while argv[i] do
    local word = argv[i]
    if word == "-f" then
      local key, value = argv[i + 1]:match("^([^=]+)=(.*)$")
      p.fields[key] = value
      i = i + 2
    elseif valued[word] then
      p.options[word] = assert(argv[i + 1], word .. " needs a value")
      i = i + 2
    elseif word:match("^%-") then
      p.options[word] = "true"
      i = i + 1
    else
      p.positional[#p.positional + 1] = word
      i = i + 1
    end
  end
  return p
end

local function release_ids(): {string}
  local ids = list(state .. "/releases")
  table.sort(ids, function(a: string, b: string): boolean
    return assert(math.tointeger(tonumber(a))) < assert(math.tointeger(tonumber(b)))
  end)
  return ids
end

local function release_of(tag: string): string | nil
  for _, id in ipairs(release_ids()) do
    if read(state .. "/releases/" .. id .. "/tag") == tag then
      return state .. "/releases/" .. id
    end
  end
  return nil
end

--- An API answer as gh prints it: the status line and headers first
--- only under --include, and a failure also named on stderr.
local function http(p: Parsed, status: string, body: string): integer
  local ok = status:match("^2") ~= nil
  if p.options["--include"] then
    out("HTTP/2.0 " .. status .. "\nContent-Type: application/json; charset=utf-8\n\n")
  end
  out(body)
  if ok then return 0 end
  return fail(status:match("^%d+ (.*)$") .. " (HTTP " .. status:match("^%d+") .. ")")
end

local function api(p: Parsed, repo: string): integer
  if exists(state .. "/fail/transport") then
    return fail("error connecting to api.github.com")
  end
  local endpoint = assert(p.positional[1], "api: no endpoint")
  local prefix = "repos/" .. repo .. "/"
  if endpoint:sub(1, #prefix) ~= prefix then return fail("unexpected endpoint " .. endpoint) end
  local rest = endpoint:sub(#prefix + 1)
  local method = p.options["--method"] or "GET"
  if rest == "releases?per_page=100" and method == "GET" then
    assert(p.options["--paginate"] and p.options["--slurp"], "the list is not paginated")
    -- One release to a page, so a caller must gather every page.
    local pages: {any} = {}
    for _, id in ipairs(release_ids()) do
      local dir = state .. "/releases/" .. id
      pages[#pages + 1] = { { id = math.tointeger(tonumber(id)), tag_name = read(dir .. "/tag") } }
    end
    if #pages == 0 then pages[1] = Json.array() end
    return out(json(Json.array(pages)))
  end
  local probed = rest:match("^git/ref/tags/(.+)$")
  if probed and method == "GET" then
    if exists(state .. "/fail/ref-transport") then
      return fail("error connecting to api.github.com")
    end
    if exists(state .. "/fail/ref") then
      return http(p, "500 Internal Server Error", '{"message":"Server Error"}')
    end
    local tag_file = state .. "/tags/" .. probed
    if not exists(tag_file) then return http(p, "404 Not Found", '{"message":"Not Found"}') end
    local object = { sha = read(tag_file), type = "commit" }
    if exists(state .. "/annotated/" .. probed) then
      object = { sha = read(state .. "/annotated/" .. probed), type = "tag" }
    end
    return http(p, "200 OK", json({ ref = "refs/tags/" .. probed, object = object }))
  end
  local tag_object = rest:match("^git/tags/(.+)$")
  if tag_object and method == "GET" then
    local tagged = state .. "/tag-objects/" .. tag_object
    if not exists(tagged) then return http(p, "404 Not Found", '{"message":"Not Found"}') end
    return http(p, "200 OK", json({ sha = tag_object,
      object = { sha = read(tagged), type = "commit" } }))
  end
  -- A name here is a tag's or a branch's, as GitHub resolves it.
  local resolved = rest:match("^commits/(.+)$")
  if resolved and method == "GET" then
    for _, kind in ipairs({ "tags", "branches" }) do
      local named = state .. "/" .. kind .. "/" .. resolved
      if exists(named) then return out(json({ sha = read(named) })) end
    end
    return fail("No commit found for SHA: " .. resolved .. " (HTTP 422)")
  end
  if rest == "git/refs" and method == "POST" then
    local tag = assert(p.fields.ref, "no ref"):match("^refs/tags/(.+)$")
    assert(tag and p.fields.sha, "no tag or sha")
    if exists(state .. "/tags/" .. tag) then return fail("Reference already exists (HTTP 422)") end
    assert(Fs.mkdirs(state .. "/tags"))
    write(state .. "/tags/" .. tag, p.fields.sha)
    return out(json({ ref = p.fields.ref, object = { sha = p.fields.sha } }))
  end
  return fail("unexpected api call " .. method .. " " .. endpoint)
end

local function release(p: Parsed, repo: string): integer
  if p.options["--repo"] ~= repo then return fail("unexpected --repo") end
  local verb, tag = p.positional[1], p.positional[2]
  assert(verb and tag, "release: no verb or tag")
  if verb == "create" then
    if not p.options["--verify-tag"] then return fail("create without --verify-tag") end
    if not exists(state .. "/tags/" .. tag) then return fail("tag " .. tag .. " doesn't exist") end
    local ids = release_ids()
    local id = tostring(#ids == 0 and 1 or assert(math.tointeger(tonumber(ids[#ids]))) + 1)
    local dir = state .. "/releases/" .. id
    assert(Fs.mkdirs(dir .. "/assets"))
    write(dir .. "/tag", tag)
    write(dir .. "/draft", p.options["--draft"] and "true" or "false")
    write(dir .. "/prerelease", p.options["--prerelease"] and "true" or "false")
    write(dir .. "/title", assert(p.options["--title"]))
    write(dir .. "/notes", read(assert(p.options["--notes-file"])))
    return out("https://github.com/" .. repo .. "/releases/tag/untagged-" .. id .. "\n")
  end
  local dir = release_of(tag)
  if dir == nil then return fail("release not found") end
  if verb == "view" then
    local answer: {string:any} = {}
    for field in assert(p.options["--json"]):gmatch("[^,]+") do
      if field == "isDraft" then answer.isDraft = read(dir .. "/draft") == "true"
      elseif field == "isPrerelease" then answer.isPrerelease = read(dir .. "/prerelease") == "true"
      elseif field == "assets" then
        local assets: {any} = {}
        for _, name in ipairs(list(dir .. "/assets")) do assets[#assets + 1] = { name = name } end
        answer.assets = Json.array(assets)
      else return fail("unknown field " .. field) end
    end
    return out(json(answer))
  elseif verb == "download" then
    local destination = assert(p.options["--dir"])
    local pattern = p.options["--pattern"]
    local names: {string} = {}
    for _, name in ipairs(list(dir .. "/assets")) do
      if pattern == nil or name == pattern then names[#names + 1] = name end
    end
    if #names == 0 then return fail("no assets to download") end
    assert(Fs.mkdirs(destination))
    for _, name in ipairs(names) do
      if exists(destination .. "/" .. name) then return fail(name .. " already exists") end
      write(destination .. "/" .. name, read(dir .. "/assets/" .. name))
    end
    return 0
  elseif verb == "upload" then
    local path = assert(p.positional[3], "upload: no file")
    local name = assert(path:match("([^/]+)$"))
    if exists(dir .. "/assets/" .. name) then return fail("asset under the same name already exists") end
    write(dir .. "/assets/" .. name, read(path))
    return 0
  elseif verb == "edit" then
    if p.options["--draft=false"] and not exists(state .. "/fail/edit-draft") then
      write(dir .. "/draft", "false")
      -- Publishing a draft whose tag is missing makes the tag, at the
      -- draft's target.
      if not exists(state .. "/tags/" .. tag) and exists(dir .. "/target") then
        assert(Fs.mkdirs(state .. "/tags"))
        write(state .. "/tags/" .. tag, read(dir .. "/target"))
      end
    end
    if p.options["--prerelease"] then write(dir .. "/prerelease", "true") end
    return out("https://github.com/" .. repo .. "/releases/tag/" .. tag .. "\n")
  end
  return fail("unexpected release verb " .. verb)
end

return function(argv: {integer:string}): integer
  local words: {string} = {}
  local i = 1
  while argv[i] do words[#words + 1] = argv[i]; i = i + 1 end
  local calls = state .. "/calls"
  local logged = exists(calls) and read(calls) or ""
  write(calls, logged .. table.concat(words, " ") .. "\n")
  if Env.get("GH_TOKEN") ~= "fake-token" then return fail("GH_TOKEN is not the job's") end
  local repo = read(state .. "/repo")
  local p = parse(argv)
  if argv[1] == "api" then return api(p, repo) end
  if argv[1] == "release" then return release(p, repo) end
  return fail("unexpected command " .. tostring(argv[1]))
end
