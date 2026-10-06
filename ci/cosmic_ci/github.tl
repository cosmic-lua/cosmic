--- What the driver's lookups of GitHub (queue_seed.tl, commit_verdicts.tl)
--- ask of the world, as one record a test replaces: the API's answers,
--- the clock, a wait, and the places a step's words go. The live one asks
--- the API through [`GithubApi`], whose token comes from GH_TOKEN or
--- GITHUB_TOKEN in the environment and goes to the API's origin alone.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local GithubApi = require("cosmic_ci.github_api")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")

local record Github
  --- What a lookup asks of the world. A call that fails answers nil and
  --- why (a lookup never fails its step); none of these raises.
  record Host
    --- The pages of GET `path`, each as the API's JSON decoded: one
    --- where `paginate` is false, every page where it is true. A call
    --- that takes longer than `seconds` fails.
    fetch: Fetch
    --- DELETE `path`.
    delete: Delete
    --- The time, in seconds since the epoch.
    now: function(): integer
    --- Waits `seconds`.
    sleep: function(seconds: integer)
    --- A line of the step's outputs ($GITHUB_OUTPUT), `name=value`.
    output: function(line: string)
    --- A line on the step's standard output.
    print: function(line: string)
    --- A line of the job's summary ($GITHUB_STEP_SUMMARY), if it has one.
    summary: function(line: string)
    --- Whether the checkout's build/harness_epoch.tl differs from the
    --- commit `base`'s: false where it cannot say.
    moved: function(base: string): boolean
  end
  type Fetch = function(path: string, paginate: boolean, seconds: integer): {any} | nil, string
  type Delete = function(path: string, seconds: integer): boolean, string
  --- [`Host`]'s `fetch` and `delete`, over `client`: a GET whose JSON is
  --- decoded, a listing's pages following the `Link` header's next URL,
  --- and a DELETE.
  over: function(client: GithubApi.Client): Fetch, Delete
  --- The host that asks the API in `env`, the process's environment. A
  --- lookup fails, saying why, where `env` holds no token. `test` is
  --- [`GithubApi.live`]'s.
  live: function(env: {string:string}, test?: GithubApi.Live): Host
  --- Whether `text` is a whole commit id.
  is_commit: function(text: string): boolean
  --- `host`'s `print` and `summary` of `line`.
  say: function(host: Host, line: string)
  --- `host.fetch`, with the reason a failed lookup gives printed, so a
  --- step's log says why it asked again.
  ask: function(host: Host, path: string, paginate: boolean, seconds: integer): {any} | nil
  --- Whether `base`'s build/harness_epoch.tl differs from the checkout's
  --- HEAD's, asked of git through `git`, which runs a git command line and
  --- answers its exit status (nil where it could not run). Only a
  --- difference answers true: no git, a base it does not hold, or any
  --- other refusal is no sign that it moved.
  harness_moved: function(git: function(argv: {string}): integer | nil, base: string): boolean
end

function Github.is_commit(text: string): boolean
  return #text == 40 and text:match("^[0-9a-f]+$") ~= nil
end

function Github.ask(host: Github.Host, path: string, paginate: boolean, seconds: integer): {any} | nil
  local pages, why = host.fetch(path, paginate, seconds)
  if pages == nil then host.print("lookup failed: " .. why) end
  return pages
end

function Github.say(host: Github.Host, line: string)
  host.print(line)
  host.summary(line)
end

function Github.harness_moved(git: function(argv: {string}): integer | nil, base: string): boolean
  if git({ "cat-file", "-e", base .. "^{commit}" }) ~= 0 then return false end
  -- `:/` names the path from the repository's root, where the driver runs in ci/.
  return git({ "diff", "--quiet", base, "HEAD", "--", ":/build/harness_epoch.tl" }) == 1
end

function Github.over(client: GithubApi.Client): Github.Fetch, Github.Delete
  local function fetch(path: string, paginate: boolean, seconds: integer): {any} | nil, string
    if paginate then return GithubApi.pages(client, path, seconds) end
    local text, why = GithubApi.get(client, path, seconds)
    if text == nil then return nil, why end
    local page, trouble = Json.decode_object(text)
    if page == nil then return nil, "GET " .. path .. ": " .. trouble end
    return { page }, ""
  end
  local function delete(path: string, seconds: integer): boolean, string
    return GithubApi.delete(client, path, seconds)
  end
  return fetch, delete
end

-- A limit decided for good: no test runs the system's git, so `run_git`
-- and `moved` below are checked only against recordings of git's answers
-- (github_test.tl), never against git. A pathspec git refuses, or a
-- failure of its own (a repository it finds unsafe, "dubious
-- ownership", say), answers a status other than 1 and reads as "the
-- harness did not move": every test then stands on the verdicts it
-- would, which costs a stale verdict at worst, never a failed run.
function Github.live(env: {string:string}, test?: GithubApi.Live): Github.Host
  local git = Proc.find("git", env.PATH or "")
  local function run_git(argv: {string}): integer | nil
    if git == nil then return nil end
    local words: {string} = { git }
    for _, word in ipairs(argv) do words[#words + 1] = word end
    local result = Child.run(words, { env = env, stdin = "null", stdout = "null", stderr = "null" })
    return result ~= nil and result.code or nil
  end
  local client, absent = GithubApi.live(env, test)
  local fetch, delete: Github.Fetch, Github.Delete
  if client ~= nil then
    fetch, delete = Github.over(client)
  else
    fetch = function(_path: string, _paginate: boolean, _seconds: integer): {any} | nil, string
      return nil, absent
    end
    delete = function(_path: string, _seconds: integer): boolean, string
      return false, absent
    end
  end
  local function line(fd: integer, text: string)
    local _, _ = Fs.put(fd, text .. "\n")
  end
  return {
    fetch = fetch,
    delete = delete,
    now = function(): integer return Time.now_ns() // 1000000000 end,
    sleep = function(seconds: integer)
      local _, _ = Time.sleep_ns(Time.seconds(seconds))
    end,
    -- $GITHUB_OUTPUT, standard output for a run by hand.
    output = function(text: string)
      local file = env.GITHUB_OUTPUT
      if file ~= nil and file ~= "" then
        local _, _ = Fs.append(file, text .. "\n")
      else
        line(Fs.stdout, text)
      end
    end,
    print = function(text: string) line(Fs.stdout, text) end,
    summary = function(text: string)
      local file = env.GITHUB_STEP_SUMMARY
      if file ~= nil and file ~= "" then
        local _, _ = Fs.append(file, text .. "\n")
      end
    end,
    moved = function(base: string): boolean return Github.harness_moved(run_git, base) end,
  }
end

return Github
