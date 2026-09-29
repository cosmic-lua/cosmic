--- `cosmic fetch` run as this program: no verdict line, exit 2 for a
--- refused command line and 1 for a fetch that fails, all offline (a
--- closed local port). The fetches themselves are in `fetch_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start, and a closed local port.
Test.needs{ tool = true, network = { "127.0.0.1" } }

local function cosmic(dir: string, words: {string}): integer, string, string
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ms = 30000,
  })
  local result = assert(Child.run(started.argv, started.options))
  return result.code, result.stdout or "", result.stderr or ""
end

local function test_a_refusal_is_two_and_prints_no_verdict(tmp: string)
  local code, out, err = cosmic(tmp, { "fetch", "notaurl" })
  assert(code == 2 and out == "", out)
  assert(err:find("cosmic: fetch: ", 1, true) == 1, err)
  assert(not err:find("fetch: FAIL", 1, true), err)
end

local function test_a_failed_fetch_is_one_and_prints_no_verdict(tmp: string)
  local code, out, err = cosmic(tmp, { "fetch", "http://127.0.0.1:1/" })
  assert(code == 1 and out == "", out)
  assert(not err:find("fetch: FAIL", 1, true), err)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local code, out, err = cosmic(tmp, { "fetch", "--help" })
  assert(code == 0, err)
  assert(out:find("cosmic fetch", 1, true) and out:find("--sha256", 1, true), out)
end

--- The verb's own interrupt wiring, run as a process: a `Child.guard`,
--- `Http.download` asking it between chunks, the guard closed after. The
--- interrupt is sent from inside the download (its second ask, so a
--- chunk is already written), which makes it deterministic where a timed
--- kill of a slow server would not be.
-- TODO: send the SIGINT to a real `cosmic fetch -o` against a local
-- server that sends one chunk and then waits, once the tree has a
-- socket module that can bind and accept; only the wiring is run
-- here, since fetch itself needs a URL to fetch, and build/fetch_test.tl
-- covers the verb's cancelled path in process.
local function test_an_interrupted_download_leaves_no_file_and_dies_of_the_signal(tmp: string)
  local fixture = tmp .. "/interrupted.tl"
  assert(Fs.write(fixture, [[
local Child = require("cosmic.child")
local Http = require("cosmic.http")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local guard = assert(Child.guard())
  local asked = 0
  local body = string.rep("z", 300000)
  local ok, why = Http.download("http://cosmic.test/", argv[1] .. "/target", {
    script = { "HTTP/1.1 200 OK\r\nContent-Length: " .. #body ..
      "\r\nConnection: close\r\n\r\n" .. body },
    cancelled = function(): boolean
      asked = asked + 1
      if asked == 2 then assert(sys.kill(sys.getpid(), sys.SIGINT)) end
      return guard:cancelled() ~= 0
    end,
  })
  assert(not ok and why == "cancelled", tostring(why))
  assert(guard:close())
  return 0
end
]]))
  local started = this_program.program({ "--standalone", fixture, tmp },
    { stdout = "capture", stderr = "capture", timeout_ms = 30000 })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.signal == sys.SIGINT,
    "code=" .. tostring(result.code) .. " signal=" .. tostring(result.signal) ..
    " " .. tostring(result.stderr))
  assert(Fs.stat(tmp .. "/target") == nil, "the target was created")
  for _, name in ipairs((assert(Fs.list(tmp)))) do
    assert(name == "interrupted.tl", "left behind: " .. name)
  end
end
