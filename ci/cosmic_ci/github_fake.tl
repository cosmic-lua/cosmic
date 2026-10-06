--- A [`Github.Host`] for tests, with no network, `gh` or clock: the API's
--- answers are canned, written as the JSON `gh api` would print, and
--- decoded by the live host's own `fetch`; the clock stands still but for
--- a wait, and every call, output and line is kept to read back. Test
--- support.
local Github = require("cosmic_ci.github")

local record GithubFake
  record Fake
    host: Github.Host
    --- Each call to `gh`, its arguments blank-separated, in order.
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
  --- The text `gh` prints for `path`'s `nth` ask (the first is 1), nil to
  --- fail it.
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
  local fetch, delete = Github.over(function(args: {string}, _seconds: integer): string | nil, string
    fake.calls[#fake.calls + 1] = table.concat(args, " ")
    local path = args[#args]
    if args[2] == "-X" then
      if refused[path:match("[^/]*$")] then return nil, "refused" end
      return "", ""
    end
    asks[path] = (asks[path] or 0) + 1
    local text = answer(path, asks[path])
    if text == nil then return nil, "failed" end
    return text, ""
  end)
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
