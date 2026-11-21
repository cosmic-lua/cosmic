local Attempts = require("cosmic.web.attempts")
local Clock = require("cosmic.clock")
local Web = require("cosmic.web")

--- A clock a test moves by hand.
local record Fake
  mut now: integer
end

local function limiter(fake: Fake, limit: integer, window_ns: integer, max_keys?: integer): Attempts.Limiter
  return Attempts.limiter{ limit = limit, window_ns = window_ns, max_keys = max_keys,
    now_ns = function(): integer return fake.now end }
end

local function test_a_key_is_refused_after_limit_failures_until_the_oldest_ages_out()
  local fake: Fake = { now = 1000 }
  local l = limiter(fake, 3, 100)
  for _ = 1, 3 do
    assert(l:allowed("k"))
    l:failed("k")
    fake.now = fake.now + 10
  end
  -- failures at 1000, 1010, 1020; now 1030
  assert(not l:allowed("k"))
  local wait = l:wait_ns("k")
  assert(wait == 70, tostring(wait))
  fake.now = 1099
  assert(l:wait_ns("k") == 1, "one nanosecond before the oldest ages out")
  fake.now = 1100
  assert(l:allowed("k") and l:wait_ns("k") == 0, "the oldest failure counts for exactly window_ns")
  l:failed("k")
  assert(l:wait_ns("k") == 10, "the window slides to the next oldest, at 1010")
end

local function test_fewer_than_limit_failures_never_refuse()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 2, 100)
  l:failed("k")
  fake.now = 99
  assert(l:allowed("k"))
  l:failed("k")
  assert(not l:allowed("k"))
  fake.now = 100
  assert(l:allowed("k"), "the first failure aged out, one is left")
end

local function test_reset_forgets_a_key_and_keys_are_independent()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 1, 100)
  l:failed("a")
  assert(not l:allowed("a"))
  assert(l:allowed("b"), "another key is not counted")
  l:reset("a")
  assert(l:allowed("a"))
  l:reset("never seen")
end

local function test_a_failure_recorded_while_refused_pushes_the_refusal_later()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 2, 100)
  l:failed("k")
  fake.now = 10
  l:failed("k")
  fake.now = 50
  l:failed("k")
  local wait = l:wait_ns("k")
  assert(wait == 60, "the oldest kept is now the one at 10: " .. tostring(wait))
end

local function test_max_keys_drops_aged_out_keys_first()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 1, 100, 2)
  l:failed("old")
  fake.now = 50
  l:failed("held")
  fake.now = 120
  l:failed("new")
  assert(not l:allowed("held"), "a key still refused is kept while an aged one can go")
  assert(not l:allowed("new"))
end

local function test_max_keys_drops_the_key_whose_newest_failure_is_oldest()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 2, 1000, 2)
  l:failed("a")
  fake.now = 10
  l:failed("b")
  fake.now = 20
  l:failed("a")
  fake.now = 30
  l:failed("c")
  -- b's newest is 10, a's is 20: b goes.
  assert(not l:allowed("a"), "a keeps both failures")
  l:failed("b")
  assert(l:allowed("b"), "b started over with one failure")
  assert(l:allowed("c"))
end

local function test_a_flood_of_new_keys_pushes_out_the_oldest_eighth()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 1, Clock.minutes(5), 16)
  l:failed("victim")
  for i = 1, 15 do
    fake.now = fake.now + 1
    l:failed("flood" .. tostring(i))
  end
  assert(not l:allowed("victim"), "at max_keys nothing is dropped yet")
  fake.now = fake.now + 1
  l:failed("flood16")
  assert(l:allowed("victim"), "the victim's newest failure was oldest")
  assert(l:allowed("flood1"), "two keys, an eighth of 16, went")
  assert(not l:allowed("flood2"))
  assert(not l:allowed("flood16"))
end

local function test_the_count_of_keys_stays_right_through_ageing_and_resets()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 1, 100, 3)
  for _ = 1, 5 do
    l:failed("a")
    l:failed("b")
    l:reset("b")
    l:reset("b")
    fake.now = fake.now + 100
    assert(l:allowed("a"), "a aged out")
  end
  l:failed("a")
  l:failed("b")
  l:failed("c")
  assert(not l:allowed("a") and not l:allowed("b") and not l:allowed("c"),
    "three keys fit max_keys of 3: none is dropped early")
end

local function test_a_huge_window_does_not_overflow_the_wait()
  local fake: Fake = { now = 1000 }
  local l = limiter(fake, 1, math.maxinteger)
  l:failed("k")
  fake.now = 2000
  assert(not l:allowed("k"))
  assert(l:wait_ns("k") == math.maxinteger - 1000)
end

local function test_a_clock_that_repeats_or_steps_back_keeps_the_count()
  local fake: Fake = { now = 500 }
  local l = limiter(fake, 2, 100)
  l:failed("k")
  fake.now = 400
  l:failed("k")
  assert(not l:allowed("k"))
  assert(l:wait_ns("k") == 100, "the step back is read as 500 again")
  fake.now = 600
  assert(l:allowed("k"))
end

local record Case
  opts: Attempts.Options
  name: string
end

local function test_options_that_are_not_positive_integers_raise_naming_the_option()
  local cases: {Case} = {
    { opts = { limit = 0, window_ns = 1 }, name = "limit" },
    { opts = { limit = 1, window_ns = 0 }, name = "window_ns" },
    { opts = { limit = 1, window_ns = 1, max_keys = 0 }, name = "max_keys" },
  }
  for _, case in ipairs(cases) do
    local ok, why = pcall(Attempts.limiter, case.opts)
    assert(not ok and tostring(why):find(case.name, 1, true) ~= nil, tostring(why))
  end
end

local function test_retry_after_rounds_up_to_whole_seconds_of_at_least_one()
  assert(Attempts.retry_after(1) == "1")
  assert(Attempts.retry_after(0) == "1")
  assert(Attempts.retry_after(Clock.seconds(2)) == "2")
  assert(Attempts.retry_after(Clock.seconds(2) + 1) == "3")
end

local function test_too_many_answers_429_with_retry_after()
  local fake: Fake = { now = 0 }
  local l = limiter(fake, 1, Clock.seconds(30))
  local app = Web.app{
    sink = { line = function(_self: Web.Sink, _text: string) end },
    routes = { Web.post("/login", function(req: Web.Request): Web.Response
      local wait = l:wait_ns("login")
      if wait > 0 then return Attempts.too_many(wait) end
      if req:text() ~= "right" then
        l:failed("login")
        return Web.text("wrong", { status = 401 })
      end
      l:reset("login")
      return Web.text("in")
    end) },
  }
  local client = Web.test_client(app)
  assert(client:post("/login", { body = "wrong" }).status == 401)
  fake.now = Clock.seconds(10)
  local res = client:post("/login", { body = "right" })
  assert(res.status == 429 and res.headers["retry-after"] == "20", tostring(res.headers["retry-after"]))
  assert((res.headers["content-type"] or ""):find("problem+json", 1, true) ~= nil)
  assert(res:text():find("Too many failed attempts", 1, true) ~= nil)
  local body = Attempts.too_many(1, "slow down").body
  assert(body is string and body:find("slow down", 1, true) ~= nil)
  fake.now = Clock.seconds(30)
  assert(client:post("/login", { body = "right" }).status == 200)
end

local function tally(fake: Fake, window_ns: integer, max_keys?: integer): Attempts.Tally
  return Attempts.tally{ window_ns = window_ns, max_keys = max_keys, now_ns = function(): integer
    return fake.now
  end }
end

local function test_a_tally_counts_each_key_in_a_window_its_first_count_begins()
  local fake: Fake = { now = 1000 }
  local t = tally(fake, 100)
  assert(t:count("k") == 0 and t:wait_ns("k") == 0)
  assert(t:add("k", 3) == 3)
  fake.now = 1040
  assert(t:add("k", 2) == 5 and t:count("k") == 5)
  assert(t:wait_ns("k") == 60, tostring(t:wait_ns("k")))
  assert(t:count("other") == 0, "a key counts alone")
  fake.now = 1099
  assert(t:count("k") == 5 and t:wait_ns("k") == 1)
  fake.now = 1100
  assert(t:count("k") == 0 and t:wait_ns("k") == 0, "the window lasts exactly window_ns")
  assert(t:add("k", 1) == 1, "a count after the window begins a new one")
  assert(t:wait_ns("k") == 100)
end

local function test_a_tally_past_max_keys_drops_ended_windows_and_else_every_key()
  local fake: Fake = { now = 0 }
  local t = tally(fake, 100, 2)
  t:add("a", 1)
  fake.now = 50
  t:add("b", 1)
  fake.now = 120
  t:add("c", 1)
  assert(t:count("b") == 1, "a live key was dropped while an ended one could go")
  fake.now = 130
  t:add("d", 1)
  assert(t:count("b") == 0 and t:count("c") == 0 and t:count("d") == 1,
    "with no ended window, every key starts over")
  t:add("d", 1)
  assert(t:count("d") == 2, "a held key is no new key")
end

local function test_a_tally_holds_a_clock_that_goes_back_to_its_last_reading()
  local fake: Fake = { now = 1000 }
  local t = tally(fake, 100)
  t:add("k", 1)
  fake.now = 900
  assert(t:count("k") == 1 and t:wait_ns("k") == 100)
end

local function test_a_tally_refuses_a_window_or_max_keys_below_1()
  local ok, why = pcall(Attempts.tally, { window_ns = 0 })
  assert(not ok and tostring(why):find("window_ns must be an integer of at least 1", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Attempts.tally, { window_ns = 1, max_keys = 0 })
  assert(not ok and tostring(why):find("max_keys must be an integer of at least 1", 1, true) ~= nil, tostring(why))
end
