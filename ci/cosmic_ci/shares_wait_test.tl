--- `wait`, which `checked` runs before it gathers the shares' verdicts,
--- against the API's JSON through cosmic_ci/github_fake.tl: no network
--- and a clock that only a wait moves.
local GithubFake = require("cosmic_ci.github_fake")
local SharesWait = require("cosmic_ci.shares_wait")
local Time = require("cosmic.time")

local START <const> = GithubFake.start()
local JOBS <const> = "s1 s2 s3 s4"

--- A job as the API lists it: `name status conclusion`, with `-` for no
--- conclusion, and `started` seconds ago where given.
local function job(name: string, status: string, conclusion: string, ago?: integer): string
  local started = "null"
  if ago ~= nil then
    started = '"' .. Time.format_rfc3339((START - ago) * 1000000000, nil, { digits = 0 }) .. '"'
  end
  return '{"name":"' .. name .. '","status":"' .. status .. '","conclusion":' ..
    (if conclusion == "-" then "null" else ('"' .. conclusion .. '"') end) .. ',"started_at":' .. started .. "}"
end

local function listed(...: string): string
  return '{"total_count":' .. tostring(select("#", ...)) .. ',"jobs":[' .. table.concat({ ... }, ",") .. "]}"
end

--- The four shares, each `done`, else running since a minute ago.
local function shares(done: {string:string}): {string}
  local out: mut {string} = {}
  for _, name in ipairs({ "s1", "s2", "s3", "s4" }) do
    local conclusion = done[name]
    out[#out + 1] = if conclusion ~= nil then job(name, "completed", conclusion, 600)
      else job(name, "in_progress", "-", 60) end
  end
  return out
end

--- `wait` against listings `answers`, one a lookup and the last again
--- once they run out ("FAIL" fails one), a wait of 10 s for 100 s in all.
local function wait(answers: {string}, extra?: {string:string}): GithubFake.Fake, integer
  local asked = 0
  local fake = GithubFake.new(function(_path: string, _nth: integer): string?
    asked = asked + 1
    local text = answers[math.min(asked, #answers)]
    if text == "FAIL" then return nil end
    return text
  end)
  local env: mut {string:string} = { REPOSITORY = "o/r", RUN_ID = "7", JOBS = JOBS,
    WAIT_SECONDS = "10", LIMIT_SECONDS = "100" }
  for name, value in pairs(extra or {}) do env[name] = value end
  return fake, SharesWait.wait(env, fake.host)
end

local function outputs(fake: GithubFake.Fake): string
  return GithubFake.text(fake.outputs)
end

local function passed(): string
  return listed(table.unpack(shares({ s1 = "success", s2 = "success", s3 = "success", s4 = "success" })))
end

--- The run's jobs, not one attempt's, are asked: a re-run of the failed
--- jobs lists the ones it carried over only there.
local function test_all_four_shares_passing_is_success()
  local fake, code = wait({ passed() })
  assert(code == 0 and outputs(fake) == "result=success\nfailed=\n", outputs(fake))
  assert(fake.calls[1] == "GET repos/o/r/actions/runs/7/jobs?per_page=100", fake.calls[1])
  assert(#fake.sleeps == 0)
end

--- A share still running is waited for, and the wait ends once the
--- last has passed.
local function test_a_running_share_is_waited_for()
  local running = listed(table.unpack(shares({ s1 = "success", s2 = "success", s3 = "success" })))
  local fake, code = wait({ running, running, passed() })
  assert(code == 0 and outputs(fake) == "result=success\nfailed=\n", outputs(fake))
  assert(#fake.sleeps == 2 and fake.sleeps[1] == 10, #fake.sleeps)
end

--- One share that did not pass ends the wait at once, whatever the
--- others are doing, and is named: a gather never starts on fewer than
--- four passing shares.
local function test_a_share_that_did_not_pass_is_failure_at_once()
  for _, conclusion in ipairs({ "failure", "cancelled", "skipped", "timed_out" }) do
    local fake, code = wait({ listed(table.unpack(shares({ s2 = conclusion }))) })
    assert(code == 0 and outputs(fake) == "result=failure\nfailed=s2 (" .. conclusion .. ")\n", outputs(fake))
    assert(#fake.sleeps == 0)
  end
end

--- A job that is none of the four does not count, and a share not listed
--- yet is not a pass.
local function test_a_share_not_listed_is_not_a_pass()
  local three = listed(job("s1", "completed", "success", 60), job("s2", "completed", "success", 60),
    job("s3", "completed", "success", 60), job("other", "completed", "success", 60))
  local fake, code = wait({ three })
  assert(code == 0 and outputs(fake) == "result=timeout\nfailed=\n", outputs(fake))
  assert(#fake.sleeps == 10, #fake.sleeps)
end

--- A queued share has no start to bound, and the wait ends by its own
--- limit.
local function test_a_share_that_never_starts_is_a_timeout()
  local queued = listed(job("s1", "queued", "-"), job("s2", "queued", "-"), job("s3", "queued", "-"), job("s4", "queued", "-"))
  local fake, code = wait({ queued })
  assert(code == 0 and outputs(fake) == "result=timeout\nfailed=\n", outputs(fake))
  assert(fake.clock - START <= 100 and fake.clock - START >= 90, fake.clock - START)
end

--- A share that runs past its own timeout (plus a margin) fails the
--- wait, whatever the API says of it.
local function test_a_share_past_its_timeout_is_failure()
  local stuck = listed(job("s1", "completed", "success", 60), job("s2", "in_progress", "-", 2000),
    job("s3", "completed", "success", 60), job("s4", "completed", "success", 60))
  local fake, code = wait({ stuck }, { SHARE_SECONDS = "1620" })
  assert(code == 0, outputs(fake))
  assert(outputs(fake):find("result=failure\nfailed=s2 (still running 1620 s", 1, true) ~= nil, outputs(fake))
end

--- A listing that fails, or holds no jobs, is asked again, until the limit.
local function test_a_failed_lookup_is_asked_again()
  local fake, code = wait({ "FAIL", '{"total_count":0}', passed() })
  assert(code == 0 and outputs(fake) == "result=success\nfailed=\n", outputs(fake))
  assert(#fake.sleeps == 2)
  fake, code = wait({ "FAIL" })
  assert(code == 0 and outputs(fake) == "result=timeout\nfailed=\n", outputs(fake))
end

--- A job listed twice (a re-run's) is read by its newest start.
local function test_the_newest_run_of_a_share_counts()
  local twice = listed(job("s1", "completed", "failure", 900), job("s1", "completed", "success", 100),
    job("s2", "completed", "success", 100), job("s3", "completed", "success", 100), job("s4", "completed", "success", 100))
  local fake, code = wait({ twice })
  assert(code == 0 and outputs(fake) == "result=success\nfailed=\n", outputs(fake))
end

local function test_an_unreadable_environment_is_refused()
  local bad: {{string:string}} = {
    { RUN_ID = "7", JOBS = JOBS },
    { REPOSITORY = "o/r", JOBS = JOBS },
    { REPOSITORY = "o/r", RUN_ID = "7" },
    { REPOSITORY = "o/r", RUN_ID = "7", JOBS = JOBS, LIMIT_SECONDS = "long" },
    { REPOSITORY = "o/r", RUN_ID = "7", JOBS = JOBS, WAIT_SECONDS = "-1" },
  }
  for _, env in ipairs(bad) do
    local fake = GithubFake.new(function(_path: string, _nth: integer): string? return passed() end)
    assert(SharesWait.wait(env, fake.host) == 2 and #fake.calls == 0 and #fake.outputs == 0)
  end
end

--- A queued share with a start the API lists is bounded by the limit
--- alone, not by the share's own timeout.
local function test_a_queued_share_with_a_start_is_not_bounded_by_it()
  local queued = listed(job("s1", "completed", "success", 60), job("s2", "queued", "-", 2000),
    job("s3", "completed", "success", 60), job("s4", "completed", "success", 60))
  local fake, code = wait({ queued }, { SHARE_SECONDS = "1620" })
  assert(code == 0 and outputs(fake) == "result=timeout\nfailed=\n", outputs(fake))
end

--- Where the run saves (HOLD), a failed share is reported once every
--- share completed, so the rows saved are all there; elsewhere at once.
local function test_a_saving_run_waits_for_every_share_before_a_failure()
  local failing = listed(table.unpack(shares({ s2 = "failure" })))
  local done = listed(table.unpack(shares({ s1 = "success", s2 = "failure", s3 = "success", s4 = "success" })))
  local fake, code = wait({ failing, failing, done }, { HOLD = "1" })
  assert(code == 0 and outputs(fake) == "result=failure\nfailed=s2 (failure)\n", outputs(fake))
  assert(#fake.sleeps == 2, #fake.sleeps)
  fake, code = wait({ failing })
  assert(code == 0 and outputs(fake) == "result=failure\nfailed=s2 (failure)\n" and #fake.sleeps == 0, outputs(fake))
end

--- A share still running when the limit ends a saving run's wait is a
--- timeout, not a failure, whatever else failed; a share past its own
--- timeout is waited for there, not reported.
local function test_a_saving_run_with_a_share_unfinished_is_a_timeout()
  local failing = listed(table.unpack(shares({ s2 = "failure" })))
  local fake, code = wait({ failing }, { HOLD = "1" })
  assert(code == 0 and outputs(fake) == "result=timeout\nfailed=s2 (failure)\n", outputs(fake))
  local stuck = listed(job("s1", "completed", "success", 60), job("s2", "in_progress", "-", 2000),
    job("s3", "completed", "success", 60), job("s4", "completed", "success", 60))
  fake, code = wait({ stuck }, { HOLD = "1", SHARE_SECONDS = "1620" })
  assert(code == 0 and outputs(fake) == "result=timeout\nfailed=\n", outputs(fake))
end

--- The listing is read in full: shares the API lists only on its second
--- page (linked as GitHub's `Link` header does) count.
local function test_shares_on_a_later_page_count()
  local first = listed(job("other", "completed", "success", 60), job("s1", "completed", "success", 60),
    job("s2", "completed", "success", 60))
  local second = listed(job("s3", "completed", "success", 60), job("s4", "completed", "success", 60))
  local fake, code = wait({ "[" .. first .. "," .. second .. "]" })
  assert(code == 0 and outputs(fake) == "result=success\nfailed=\n", outputs(fake))
  assert(#fake.calls == 2, #fake.calls)
end
