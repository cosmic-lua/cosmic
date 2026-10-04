--- [`build/zig_fetch.tl`]'s parts: the sources a download tries, the
--- rounds over them held to their limits, a failed install's cleanup and
--- the sweep of a dead install's scratch directory. No test reaches the
--- network: every download is a stand-in or answered by a scripted
--- server.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local ZigFetch = require("build.zig_fetch")

local function test_a_failed_install_leaves_no_scratch_directory(tmp: string)
  local cache = tmp .. "/cache"
  local zig, trouble = ZigFetch.install(cache, cache .. "/0.16.0-x86_64-linux", "0.16.0",
    "x86_64-linux", nil)
  assert(zig == nil and trouble:find("sha256", 1, true) ~= nil)
  assert(table.concat(assert(Fs.list(cache)), " ") == ".scratch-gate", "a scratch wrapper was left behind")
end

local function test_sources_try_a_few_shuffled_mirrors_then_ziglang_org()
  local mirrors = { "https://a", "https://b", "https://c", "https://d", "https://e", "https://f" }
  -- Swapping each place from the last down with the first rotates the
  -- list left by one: b c d e f a.
  local urls = ZigFetch.sources("0.16.0", "zig.tar.xz", mirrors, function(_: integer): integer
    return 1
  end)
  local want = {
    "https://b/zig.tar.xz?source=cosmic",
    "https://c/zig.tar.xz?source=cosmic",
    "https://d/zig.tar.xz?source=cosmic",
    "https://e/zig.tar.xz?source=cosmic",
    "https://ziglang.org/download/0.16.0/zig.tar.xz",
  }
  assert(table.concat(urls, " ") == table.concat(want, " "), table.concat(urls, " "))
  -- Picking each place itself leaves the list as it was.
  local kept = ZigFetch.sources("0.16.0", "zig.tar.xz", mirrors, function(n: integer): integer
    return n
  end)
  assert(kept[1] == "https://a/zig.tar.xz?source=cosmic", kept[1])
  local few = ZigFetch.sources("0.16.0", "zig.tar.xz", { "https://m" })
  assert(#few == 2 and few[1] == "https://m/zig.tar.xz?source=cosmic")
end

local function failed(reason: string): Http.DownloadResult
  return { kind = "failed", reason = reason }
end

local function mismatch(reason: string): Http.DownloadResult
  return { kind = "digest_mismatch", reason = reason, algorithm = "sha256", expected = "abc", actual = "def" }
end

local downloaded: Http.DownloadResult = { kind = "downloaded", reason = "" }

--- Answers each explicit outcome in turn, writing the successful file,
--- and records calls, options and pauses. Only pauses and `per_call_ns`
--- advance the clock.
local function scripted(replies: {string:{Http.DownloadResult}}, calls: {string},
                        sleeps: {integer}, per_call_ns?: integer, seen?: {Http.Options}): ZigFetch.Fetcher
  local served: {string:integer} = {}
  local clock = 0
  return {
    download = function(url: string, path: string, opts: Http.Options): Http.DownloadResult
      assert(opts.sha256 == "abc")
      assert(opts.connect_timeout_ns > 0 and opts.low_speed_bytes >= 1024 and
          opts.low_speed_ns > 0, "an attempt has no stall guard")
      assert(Fs.exists(path) == false, "an attempt started over an earlier file")
      calls[#calls + 1] = url
      if seen ~= nil then
        seen[#seen + 1] = opts
      end
      clock = clock + (per_call_ns or 0)
      served[url] = (served[url] or 0) + 1
      local reply = replies[url][served[url]] or replies[url][#replies[url]]
      if reply.kind == "downloaded" then
        assert(Fs.write(path, "tarball"))
      end
      return reply
    end,
    sleep = function(ns: integer)
      sleeps[#sleeps + 1] = ns
      clock = clock + ns
    end,
    now = function(): integer
      return clock
    end,
  }
end

local function test_fetch_falls_through_a_failing_source_to_the_next(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local path = tmp .. "/zig.tar.xz"
  assert(Fs.write(path, "left over"))
  local ok, trouble = ZigFetch.fetch({ "http://one", "http://two" }, path, "abc", scripted({
    ["http://one"] = { failed("couldn't connect") },
    ["http://two"] = { downloaded },
  }, calls, sleeps))
  assert(ok, trouble)
  assert(#calls == 2 and calls[1] == "http://one" and calls[2] == "http://two")
  assert(#sleeps == 0)
  assert(Fs.read(path) == "tarball")
end

local function test_fetch_moves_past_a_sha_mismatch_and_never_asks_that_source_again(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local ok, trouble = ZigFetch.fetch({ "http://bad", "http://slow" }, tmp .. "/z", "abc", scripted({
    ["http://bad"] = { mismatch("z: sha256 mismatch: want abc, got def") },
    ["http://slow"] = { failed("timed out"), downloaded },
  }, calls, sleeps))
  assert(ok, trouble)
  assert(table.concat(calls, " ") == "http://bad http://slow http://slow", table.concat(calls, " "))
  assert(#sleeps == 1 and sleeps[1] > 0, "no pause before the second round")
end

local function test_fetch_names_every_source_when_all_fail(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local ok, trouble = ZigFetch.fetch({ "http://one", "http://two", "http://three" }, tmp .. "/z", "abc",
    scripted({
      ["http://one"] = { failed("couldn't connect") },
      ["http://two"] = { mismatch("z: sha256 mismatch: want abc, got def") },
      ["http://three"] = { { kind = "http_status", reason = "HTTP 404", status = 404 } },
    }, calls, sleeps))
  assert(not ok)
  assert(trouble:find("http://one: couldn't connect", 1, true) ~= nil, trouble)
  assert(trouble:find("http://two: z: sha256 mismatch", 1, true) ~= nil, trouble)
  assert(trouble:find("http://three: HTTP 404", 1, true) ~= nil, trouble)
  assert(trouble:find("http://three: http://three", 1, true) == nil, trouble)
  -- Bounded: two sources a round for three rounds, and the bad one once.
  assert(#calls == 7, tostring(#calls))
  assert(#sleeps == 2 and sleeps[2] > sleeps[1], "the pause does not grow")
  assert(Fs.exists(tmp .. "/z") == false)
end

local function test_fetch_asks_the_fallback_again_after_a_mismatch(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local ok, trouble = ZigFetch.fetch({ "http://mirror", "http://fallback" }, tmp .. "/z", "abc",
    scripted({
      ["http://mirror"] = { mismatch("z: sha256 mismatch: want abc, got def") },
      ["http://fallback"] = { mismatch("z: sha256 mismatch: want abc, got 123"), downloaded },
    }, calls, sleeps))
  assert(ok, trouble)
  assert(table.concat(calls, " ") == "http://mirror http://fallback http://fallback",
    table.concat(calls, " "))
end

--- Mirrors are held to a ceiling cut to what is left of the budget;
--- the fallback has none, and once the budget is spent it is tried one
--- last time on its own.
local function test_fetch_bounds_mirrors_by_the_budget_and_never_the_fallback(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local seen: {Http.Options} = {}
  -- Each attempt takes five minutes, and the budget is twelve.
  local ok, trouble = ZigFetch.fetch({ "http://mirror", "http://fallback" }, tmp .. "/z", "abc",
    scripted({
      ["http://mirror"] = { failed("timed out") },
      ["http://fallback"] = { failed("stalled") },
    }, calls, sleeps, Clock.minutes(5), seen))
  assert(not ok)
  assert(table.concat(calls, " ") ==
      "http://mirror http://fallback http://mirror http://fallback http://fallback",
    table.concat(calls, " "))
  -- The first mirror attempt gets the whole 3 minutes; the second, 10
  -- minutes and a 2 s pause in, the 118 s left.
  assert(seen[1].timeout_ns == Clock.minutes(3), tostring(seen[1].timeout_ns))
  assert(seen[3].timeout_ns == Clock.seconds(118), tostring(seen[3].timeout_ns))
  assert(seen[1].low_speed_bytes == 64 * 1024)
  for _, i in ipairs({ 2, 4, 5 }) do
    assert(seen[i].timeout_ns == nil,
      "the fallback has a ceiling")
    assert(seen[i].low_speed_bytes == 1024 and seen[i].low_speed_ns == Clock.seconds(60))
  end
  assert(trouble:find("mirrors out of time; every source failed after 5 attempts", 1, true) ~= nil,
    trouble)
  assert(trouble:find("http://mirror: timed out (after 300 s)", 1, true) ~= nil, trouble)
end

--- A real structured download classifies a scripted wrong body as a
--- mismatch, so the mirror is barred and the fallback remains retryable.
local function test_fetch_sees_a_real_mismatch(tmp: string)
  local calls: {string} = {}
  local fetcher: ZigFetch.Fetcher = {
    download = function(url: string, path: string, opts: Http.Options): Http.DownloadResult
      calls[#calls + 1] = url
      opts.script = { "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nwrong" }
      return Http.download_result(url, path, opts)
    end,
    sleep = function(_: integer) end,
    now = function(): integer return 0 end,
  }
  local ok, trouble = ZigFetch.fetch({ "http://127.0.0.1/a", "http://127.0.0.1/b" }, tmp .. "/z",
    string.rep("0", 64), fetcher)
  assert(not ok)
  assert(trouble:find("sha256 mismatch", 1, true) ~= nil, trouble)
  -- The mirror once; the fallback, never barred, each round.
  assert(table.concat(calls, " ") ==
      "http://127.0.0.1/a http://127.0.0.1/b http://127.0.0.1/b http://127.0.0.1/b",
    table.concat(calls, " "))
  assert(Fs.exists(tmp .. "/z") == false)
end

local function test_sweep_removes_only_a_provably_dead_owner(tmp: string)
  local cache = tmp .. "/cache"
  local dead = cache .. "/.scratch.dead"
  assert(Fs.mkdirs(dead))
  assert(Fs.write(dead .. "/owner", ""))
  local missing = cache .. "/.scratch.missing"
  assert(Fs.mkdirs(missing))
  local legacy = cache .. "/.work.2147483646"
  assert(Fs.mkdirs(legacy))
  local _, _ = ZigFetch.install(cache, cache .. "/install", "0.16.0", "x86_64-linux", nil)
  assert(Fs.exists(dead) == false)
  assert(Fs.exists(missing) == true)
  assert(Fs.exists(legacy) == true)
end

local function test_limits_preserve_native_nanoseconds()
  local options = ZigFetch.limits(Clock.ms(1500) + 1, 1024, Clock.ms(1500), Clock.ms(7) + 1)
  assert(options.connect_timeout_ns == Clock.ms(1500) + 1 and options.low_speed_ns == Clock.ms(1500))
  assert(options.timeout_ns == Clock.ms(7) + 1)
  assert(options.low_speed_bytes == 1024)
  local brief = ZigFetch.limits(1, 1024, 1)
  assert(brief.connect_timeout_ns == 1 and brief.low_speed_ns == 1 and brief.timeout_ns == nil)
end

local function test_fetch_classifies_mismatches_independently_of_reason_text(tmp: string)
  local calls: {string} = {}
  local sleeps: {integer} = {}
  local ok, why = ZigFetch.fetch({ "wrong", "transport", "status", "fallback" }, tmp .. "/z", "abc", scripted({
    wrong = { mismatch("unexpected bytes") },
    transport = { failed("sha256 mismatch in transport's own diagnostic") },
    status = { { kind = "http_status", reason = "sha256 mismatch", status = 503 } },
    fallback = { failed("retry"), downloaded },
  }, calls, sleeps))
  assert(ok, why)
  assert(table.concat(calls, " ") == "wrong transport status fallback transport status fallback")
end
