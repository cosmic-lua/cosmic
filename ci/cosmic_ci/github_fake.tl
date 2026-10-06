--- A [`Github.Host`] for tests, with no network or clock: the API's
--- answers are canned JSON, served through a fake [`GithubApi.Send`] to the
--- live host's own `fetch` and `delete`; the clock stands still but for
--- a wait, and every call, output and line is kept to read back. Test
--- support.
local Github = require("cosmic_ci.github")
local GithubApi = require("cosmic_ci.github_api")
local Json = require("cosmic.json")

local record GithubFake
  record Fake
    host: Github.Host
    --- Each request, as its method and the path below the API's address
    --- (`GET repos/o/r/actions/runs`), in order.
    calls: {string}
    --- Each line of the step's outputs, summary and standard output.
    outputs: {string}
    summaries: {string}
    printed: {string}
    --- Each wait, in seconds.
    sleeps: {integer}
    --- The time, in seconds, which each wait moves on.
    clock: integer
    --- Whether the checkout's harness moved from the base asked after.
    moved: boolean
    --- The bases asked after.
    asked: {string}
  end
  --- The JSON the API answers `path`'s `nth` ask (the first is 1), nil to
  --- fail it with a 500. An array answers a listing: each element is one
  --- page, linked to the next as GitHub's `Link` header does.
  type Answer = function(path: string, nth: integer): string | nil
  --- The time a fake starts at, in seconds since the epoch.
  START: integer
  --- A fake answering through `answer`; `refuse` names the cache ids a
  --- DELETE fails for.
  new: function(answer: Answer, refuse?: {string}): Fake
  --- What `output`, `summary` and `printed` hold, each line ending in a
  --- newline, as the files the live host appends to would.
  text: function(lines: {string}): string
  --- How many of `fake`'s calls have `needle` in them.
  count: function(fake: Fake, needle: string): integer
end

GithubFake.START = 1790000000

function GithubFake.text(lines: {string}): string
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. "\n"
end

function GithubFake.count(fake: GithubFake.Fake, needle: string): integer
  local n = 0
  for _, call in ipairs(fake.calls) do
    if call:find(needle, 1, true) then n = n + 1 end
  end
  return n
end

function GithubFake.new(answer: GithubFake.Answer, refuse?: {string}): GithubFake.Fake
  local refused: {string:boolean} = {}
  for _, id in ipairs(refuse or {}) do refused[id] = true end
  local asks: {string:integer} = {}
  local fake: GithubFake.Fake = { calls = {}, outputs = {}, summaries = {}, printed = {}, sleeps = {},
    clock = GithubFake.START, moved = false, asked = {}, host = nil as Github.Host }
  local origin <const> = "https://api.test"
  local function reply(status: integer, body: string, headers?: {string:string}): GithubApi.Reply
    return { status = status, body = body, headers = headers or {} }
  end
  local function send(request: GithubApi.Request): GithubApi.Reply | nil, string
    local path = request.url:sub(#origin + 2)
    fake.calls[#fake.calls + 1] = request.method .. " " .. path
    if request.method == "DELETE" then
      if refused[path:match("[^/]*$")] then return reply(403, '{"message":"refused"}') end
      return reply(204, "")
    end
    local at, number = path:match("^(.-)#page=(%d+)$")
    local asked = at or path
    asks[asked] = (asks[asked] or 0) + (at and 0 or 1)
    local text = answer(asked, asks[asked])
    if text == nil then return reply(500, "") end
    local pages = Json.decode_array(text)
    if pages == nil then return reply(200, text) end
    local index = math.tointeger(tonumber(number) or 1) as integer
    local more = index < #pages
    -- The fake's own marker, not GitHub's `page` parameter, keeps the
    -- path the answer is keyed by.
    return reply(200, assert(Json.encode(pages[index])),
      more and { link = '<' .. origin .. "/" .. asked .. "#page=" .. (index + 1) .. '>; rel="next"' } or nil)
  end
  local fetch, delete = Github.over({ send = send, base = origin,
    fetch = function(_url: string, _path: string): boolean, string return false, "no download" end })
  fake.host = {
    fetch = fetch,
    delete = delete,
    now = function(): integer return fake.clock end,
    sleep = function(seconds: integer)
      fake.sleeps[#fake.sleeps + 1] = seconds
      fake.clock = fake.clock + seconds
    end,
    output = function(line: string) fake.outputs[#fake.outputs + 1] = line end,
    print = function(line: string) fake.printed[#fake.printed + 1] = line end,
    summary = function(line: string) fake.summaries[#fake.summaries + 1] = line end,
    moved = function(base: string): boolean
      fake.asked[#fake.asked + 1] = base
      return fake.moved
    end,
  }
  return fake
end

return GithubFake
