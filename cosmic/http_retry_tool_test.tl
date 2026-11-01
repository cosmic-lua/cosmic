--- The wait of [`Http.Options.retry`] ended by a caught signal, in a
--- process of its own so that the signal comes while the wait sleeps:
--- apart from cosmic/http_retry_test.tl's so those stand while the tree
--- moves.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local _ = require("build.standalone")
--- What the scripts its tests run standalone require, which a child
--- is typed and run against only where the closure holds it (`lua`).
local type _ = require("cosmic.http")

--- The program itself, which a test starts only to run a script
--- standalone (`lua`, [`build.standalone`]).
Test.policy{ cpu_features = true, profiles = { "cosmic" } }

--- A request that is told to wait 30 seconds before its retry is ended
--- by a SIGINT its guard catches during the wait: the call fails
--- "interrupted", the guard still reads the signal, and the wait does
--- not run out.
local function test_a_caught_signal_ends_the_wait_before_a_retry(tmp: string)
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Signal = require("cosmic.signal")
return function(argv: {string}): integer
  local marker = argv[1] or ""
  local guard = assert(Signal.guard())
  local reply = "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\nContent-Length: 0\r\n" ..
    "Connection: close\r\n\r\n"
  local began = Clock.monotonic_ns()
  assert(Fs.write(marker, ""))
  local got, why = Http.get("http://cosmic.test/", {
    retry = { attempts = 2 },
    script = { reply, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" },
  })
  local took = Clock.monotonic_ns() - began
  local caught = assert(guard:release())
  local _, _ = Fs.put(Fs.stdout, tostring(got) .. " " .. why .. " " .. tostring(caught) ..
    " " .. tostring(took < Clock.seconds(10)))
  return 0
end
]]))
  local marker = tmp .. "/marker"
  local started = this_program.program({ "--standalone", script, marker },
    { stdout = "capture", stderr = "capture" })
  local child = assert(Child.start(started.argv, started.options))
  for _ = 1, 2000 do
    if Fs.stat(marker) ~= nil then break end
    assert(sys.nanosleep(Clock.ms(10)))
  end
  assert(Fs.stat(marker) ~= nil, "the client never reached its request")
  -- Long enough for the client to read the 429 and begin its wait.
  assert(sys.nanosleep(Clock.ms(500)))
  assert(child:stop(sys.SIGINT))
  local result = assert(child:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  local said = result.stdout or ""
  assert(said == "nil interrupted " .. tostring(sys.SIGINT) .. " true", said)
end
