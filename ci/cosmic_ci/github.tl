--- What the driver's lookups of GitHub (queue_seed.tl, commit_verdicts.tl)
--- ask of the world, as one record a test replaces: the API's answers,
--- the clock, a wait, and the places a step's words go. The live one asks
--- the API through the `gh` CLI, found on PATH, which reads GH_TOKEN from
--- the environment it inherits, as prerelease.tl and report.tl do, so
--- the token, the proxy settings and the pagination are gh's own.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
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
  --- What runs `gh` with `args`, ended after `seconds`: its standard
  --- output, or nil and why it failed.
  type Runner = function(args: {string}, seconds: integer): string | nil, string
  type Fetch = function(path: string, paginate: boolean, seconds: integer): {any} | nil, string
  type Delete = function(path: string, seconds: integer): boolean, string
  --- [`Host`]'s `fetch` and `delete`, over `run`: `gh api [--paginate
  --- --slurp] PATH`, whose answer is decoded (`--slurp` gathers the pages
  --- into one array), and `gh api -X DELETE PATH`.
  over: function(run: Runner): Fetch, Delete
  --- The host that asks the API in `env`, the process's environment.
  live: function(env: {string:string}): Host
  --- Whether `text` is a whole commit id.
  is_commit: function(text: string): boolean
  --- `host`'s `print` and `summary` of `line`.
  say: function(host: Host, line: string)
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

function Github.say(host: Github.Host, line: string)
  host.print(line)
  host.summary(line)
end

function Github.harness_moved(git: function(argv: {string}): integer | nil, base: string): boolean
  if git({ "cat-file", "-e", base .. "^{commit}" }) ~= 0 then return false end
  -- `:/` names the path from the repository's root, where the driver runs in ci/.
  return git({ "diff", "--quiet", base, "HEAD", "--", ":/build/harness_epoch.tl" }) == 1
end

function Github.over(run: Github.Runner): Github.Fetch, Github.Delete
  local function fetch(path: string, paginate: boolean, seconds: integer): {any} | nil, string
    local args: {string} = { "api" }
    if paginate then
      args[#args + 1] = "--paginate"
      args[#args + 1] = "--slurp"
    end
    args[#args + 1] = path
    local text, why = run(args, seconds)
    if text == nil then return nil, why end
    if paginate then
      local pages, trouble = Json.decode_array(text)
      if pages == nil then return nil, "gh api " .. path .. ": " .. trouble end
      return pages, ""
    end
    local page, trouble = Json.decode_object(text)
    if page == nil then return nil, "gh api " .. path .. ": " .. trouble end
    return { page }, ""
  end
  local function delete(path: string, seconds: integer): boolean, string
    local text, why = run({ "api", "-X", "DELETE", path }, seconds)
    return text ~= nil, why
  end
  return fetch, delete
end

function Github.live(env: {string:string}): Github.Host
  local gh = Proc.find("gh", env.PATH or "")
  local git = Proc.find("git", env.PATH or "")
  local function run_git(argv: {string}): integer | nil
    if git == nil then return nil end
    local words: {string} = { git }
    for _, word in ipairs(argv) do words[#words + 1] = word end
    local result = Child.run(words, { env = env, stdin = "null", stdout = "null", stderr = "null" })
    return result ~= nil and result.code or nil
  end
  local function run(args: {string}, seconds: integer): string | nil, string
    if gh == nil then return nil, "no gh on PATH" end
    local argv: {string} = { gh }
    for _, word in ipairs(args) do argv[#argv + 1] = word end
    local result, trouble = Child.run(argv, { env = env, stdin = "null", stdout = "capture",
      stderr = "inherit", timeout_ns = Time.seconds(seconds) })
    if result == nil then return nil, "gh " .. args[1] .. ": " .. trouble end
    if not result.ok then
      return nil, "gh " .. table.concat(args, " ") .. (result.timed_out and " timed out" or " failed")
    end
    return result.stdout or "", ""
  end
  local fetch, delete = Github.over(run)
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
