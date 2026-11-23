local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Poll = require("cosmic.poll")
local Review = require("cosmic_ci.review")

--- What a fake host saw, and what it answers.
local record Seen
  gets: mut {string}
  runs: mut {string}
  started: mut {{string}}
  mut cwd: string
  mut env: {string:string}
  mut closed: integer
  mut waited: integer
  said: mut {string}
  warned: mut {string}
  --- The tokens the GET answers, one each, in turn; "" answers a refusal.
  tokens: mut {string}
  --- How many waits time out before pi exits, and its status then.
  timeouts: integer
  status: integer
  --- The wait after which a signal is caught, 0 for none.
  mut signal_after: integer
  mut userns: boolean
  --- The command `run` fails, "" for none.
  mut failing: string
  mut clock: integer
end

local function result(code: integer): Child.Result
  return { code = code, ok = code == 0, timed_out = false, captured = {}, truncated = false }
end

local function fake(seen: Seen): Review.Host
  return {
    get = function(url: string, headers: {string:string}): Http.Body?, string
      local got = url .. " " .. tostring(headers["Authorization"])
      seen.gets[#seen.gets + 1] = got
      local token = table.remove(seen.tokens, 1)
      if token == nil or token == "" then return nil, "refused" end
      return { status = 200, body = '{"value":"' .. token .. '"}', headers = {} }, ""
    end,
    run = function(argv: {string}): Child.Result?, string
      local line = table.concat(argv, " ")
      seen.runs[#seen.runs + 1] = line
      if argv[1] == seen.failing then return result(1), "" end
      return result(0), ""
    end,
    start = function(argv: {string}, env: {string:string}, cwd: string): Review.Started?, string
      seen.started[#seen.started + 1] = argv
      seen.cwd = cwd
      seen.env = env
      return {
        wait = function(ns: integer): Child.Result?, string
          seen.waited = seen.waited + 1
          seen.clock = seen.clock + ns
          if seen.waited <= seen.timeouts then return nil, Poll.TIMEOUT end
          return result(seen.status), ""
        end,
        close = function()
          seen.closed = seen.closed + 1
        end,
      }, ""
    end,
    exists = function(_path: string): boolean
      return seen.userns
    end,
    now = function(): integer
      return seen.clock
    end,
    sleep = function(ns: integer)
      seen.clock = seen.clock + ns
    end,
    cancelled = function(): integer
      if seen.signal_after > 0 and seen.waited >= seen.signal_after then return 15 end
      return 0
    end,
    say = function(line: string)
      seen.said[#seen.said + 1] = line
    end,
    warn = function(line: string)
      seen.warned[#seen.warned + 1] = line
    end,
  }
end

local function new_seen(tokens: {string}, timeouts: integer): Seen
  local copy: mut {string} = {}
  for i, token in ipairs(tokens) do copy[i] = token end
  return { gets = {}, runs = {}, started = {}, cwd = "", env = {}, closed = 0, waited = 0,
    said = {}, warned = {}, tokens = copy, timeouts = timeouts, status = 3, signal_after = 0,
    userns = false, failing = "", clock = 0 }
end

local function env(temp: string): mut {string:string}
  return { RUNNER_TEMP = temp, ACTIONS_ID_TOKEN_REQUEST_URL = "https://mint/?x=1",
    ACTIONS_ID_TOKEN_REQUEST_TOKEN = "secret", GITHUB_WORKSPACE = "/work/cosmic",
    GH_TOKEN = "bot", HOME = "/home/runner" }
end

--- Waits of a second for 9 minutes: a refresh at 4 and at 8.
local NINE_MINUTES <const> = 9 * 60

local function test_review_refreshes_the_token_every_four_minutes(tmp: string)
  local seen = new_seen({ "one", "two", "three" }, NINE_MINUTES)
  seen.userns = true
  assert(Review.review(env(tmp), fake(seen)) == 3)
  assert(#seen.gets == 3, tostring(#seen.gets))
  assert(seen.gets[1] == "https://mint/?x=1&audience=https://api.anthropic.com bearer secret")
  local file = tmp .. "/review-identity/token"
  assert(assert(Fs.read(file)) == "three")
  assert(seen.said[1] == "::add-mask::one" and seen.said[3] == "::add-mask::three")
  assert(seen.runs[1] == "sudo sysctl -qw kernel.apparmor_restrict_unprivileged_userns=0")
  assert(seen.runs[2] == "gh auth setup-git")
  assert(assert(seen.started[1])[1] == "npx" and seen.cwd == "/work/cosmic")
  assert(seen.env["ANTHROPIC_IDENTITY_TOKEN_FILE"] == file)
  assert(seen.env["ACTIONS_ID_TOKEN_REQUEST_URL"] == nil)
  assert(seen.env["ACTIONS_ID_TOKEN_REQUEST_TOKEN"] == nil)
  assert(seen.env["GH_TOKEN"] == "bot" and seen.env["HOME"] == "/home/runner")
  assert(#seen.warned == 0 and seen.closed == 1)
end

local function test_review_skips_the_sysctl_where_the_kernel_has_none(tmp: string)
  local seen = new_seen({ "one" }, 0)
  assert(Review.review(env(tmp), fake(seen)) == 3)
  assert(#seen.runs == 1 and seen.runs[1] == "gh auth setup-git")
end

local function test_review_fails_before_pi_without_a_token(tmp: string)
  local seen = new_seen({}, 0)
  assert(Review.review(env(tmp), fake(seen)) == 1)
  assert(#seen.gets == 3, "each mint is tried 3 times")
  assert(#seen.started == 0 and #seen.runs == 0)
  assert(seen.warned[1] == "review: could not mint the identity token: refused")
end

local function test_a_mint_is_tried_again(tmp: string)
  local seen = new_seen({ "", "", "one" }, 0)
  assert(Review.review(env(tmp), fake(seen)) == 3)
  assert(#seen.warned == 0 and seen.clock >= Clock.seconds(10))
end

local function test_a_failed_refresh_keeps_the_last_token(tmp: string)
  local seen = new_seen({ "one", "", "", "", "", "", "", "two" }, 5 * 60)
  assert(Review.review(env(tmp), fake(seen)) == 3)
  assert(assert(Fs.read(tmp .. "/review-identity/token")) == "two")
  assert(#seen.gets == 8, "a failed refresh is made again 20 seconds on, not every second")
  assert(#seen.warned == 2 and seen.warned[1] == "review: could not refresh the identity token: refused")
end

local function test_a_signal_ends_pi(tmp: string)
  local seen = new_seen({ "one" }, 1000)
  seen.signal_after = 2
  assert(Review.review(env(tmp), fake(seen)) == 128 + 15)
  assert(seen.waited == 2 and seen.closed == 1)
  assert(seen.warned[1] == "review: ended by signal 15")
end

local function test_a_failed_setup_starts_no_pi(tmp: string)
  local seen = new_seen({ "one" }, 0)
  seen.failing = "gh"
  assert(Review.review(env(tmp), fake(seen)) == 1)
  assert(#seen.started == 0)
  assert(seen.warned[1] == "review: gh auth setup-git failed: status 1")
end

local function test_a_missing_variable_is_named(tmp: string)
  local without = env(tmp)
  without["ACTIONS_ID_TOKEN_REQUEST_URL"] = nil
  local seen = new_seen({ "one" }, 0)
  assert(Review.review(without, fake(seen)) == 1)
  assert(#seen.gets == 0)
  assert(seen.warned[1] == "review: ACTIONS_ID_TOKEN_REQUEST_URL is not set: the job needs id-token: write")
end
