--- `cosmic fetch` run as this program: no verdict line, exit 2 for a
--- refused command line and 1 for a fetch that fails, and a download
--- interrupted by a signal, all offline on the loopback. The fetches
--- themselves are in `fetch_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local Time = require("cosmic.time")

--- The program itself, which its tests start, and a local port: closed,
--- or one a test serves.
Test.needs{ tool = true, network = { "127.0.0.1" } }

local function cosmic(dir: string, words: {string}): integer, string, string
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30),
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

--- The verb's own interrupt wiring, run as a process: a [`Child.guard`],
--- [`Http.download`] asking it between chunks, the guard closed after. The
--- interrupt is sent from inside the download (its second ask, so a
--- chunk is already written); the next test sends it from outside.
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
    { stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.signal == sys.SIGINT,
    "code=" .. tostring(result.code) .. " signal=" .. tostring(result.signal) ..
    " " .. tostring(result.stderr))
  assert(Fs.stat(tmp .. "/target") == nil, "the target was created")
  for _, name in ipairs((assert(Fs.list(tmp)))) do
    assert(name == "interrupted.tl", "left behind: " .. name)
  end
end

--- A real `cosmic fetch -o` against a local server that sends part of a
--- body and then waits: SIGINT, sent once the part is on disk, ends it
--- of the signal, leaving no file behind.
local function test_a_fetch_interrupted_mid_body_leaves_no_file(tmp: string)
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Time.seconds(20) }))
  local url = "http://127.0.0.1:" .. server.address.port .. "/big"
  local started = this_program.program({ "fetch", "-o", tmp .. "/target", url },
    { cwd = tmp, stdout = "null", stderr = "capture" })
  local child <close> = assert(Child.start(started.argv, started.options))
  local conn <close> = assert(server:accept())
  local request = ""
  while not request:find("\r\n\r\n", 1, true) do
    request = request .. assert(conn:read())
  end
  assert(request:find("GET /big HTTP/1.1\r\n", 1, true) == 1, request)
  local part = string.rep("z", 4096)
  assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n" .. part))
  -- The part is on disk once some file in the directory holds it.
  local written = false
  for _ = 1, 2000 do
    for _, name in ipairs((assert(Fs.list(tmp)))) do
      local st = Fs.stat(tmp .. "/" .. name)
      if st ~= nil and st.size >= #part then written = true end
    end
    if written then break end
    assert(sys.nanosleep(Time.ms(10)))
  end
  assert(written, "the part never reached the disk")
  assert(child:stop(sys.SIGINT))
  local result = assert(child:wait(Time.seconds(20)))
  assert(result.signal == sys.SIGINT,
    "code=" .. tostring(result.code) .. " signal=" .. tostring(result.signal) ..
    " " .. tostring(result.stderr))
  assert(#(assert(Fs.list(tmp))) == 0, "left behind: " .. table.concat(assert(Fs.list(tmp)), ","))
end
