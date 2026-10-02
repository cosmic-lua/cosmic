--- Grades the pack, ledger and kv tasks in an arena, as notes.tl
--- grades notes: the project's tests and format check pass, with
--- recorded tests and examples behind them, cosmic builds the task's
--- executable, and that executable, copied alone into an empty
--- directory and run with an empty environment, does what the task
--- asks.
---
---     cosmic --standalone eval/check/tasks.tl <task> <dir>
---
--- [`eval/check/pack`], `ledger` and `kv` run this on the bootstrap
--- cosmic: it requires `cosmic.*` modules only. The arena's own
--- `bin/cosmic` does the testing and building.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local Time = require("cosmic.time")

local record Tasks
end

local function say(line: string)
  local _, _ = Fs.put(Fs.stdout, "check: " .. line .. "\n")
end

local function status(result: Child.Result): integer
  if result.code ~= nil then
    return result.code
  end
  return 128 + (result.signal or 0)
end

--- Whether a failure's stderr is cosmic's own rather than the tool's.
local function failed_in_cosmic(err: string): boolean
  return err:find("^cosmic") ~= nil or err:find("\ncosmic") ~= nil
end

local function built(output: string, name: string): boolean
  for line in output:gmatch("[^\n]+") do
    local wrote = line:match("^build: PASS %((.*)%)$")
    if wrote ~= nil then
      for each in wrote:gmatch("[^,]+") do
        if String.trim(each) == "o/bin/" .. name then
          return true
        end
      end
    end
  end
  return false
end

local function first_line(text: string): string
  return text:match("^[^\n]*")
end

local function trimmed(text: string): string
  return (text:gsub("\n+$", ""))
end

local function reset_evidence(path: string): boolean, string
  local present, trouble = Fs.exists(path)
  if present == nil then
    return false, trouble
  elseif not present then
    return true, ""
  end
  local db, otrouble = Sqlite.open(path, { writable = true })
  if db == nil then
    return false, otrouble
  end
  local ok, etrouble = db:exec("delete from runs")
  local closed, close_trouble = db:close()
  if not ok then return false, etrouble end
  if not closed then return false, close_trouble end
  return true, ""
end

local function evidence(path: string): integer, integer, string
  local present, trouble = Fs.exists(path)
  if not present then
    return 0, 0, present == nil and trouble or path .. ": no build database"
  end
  local db, otrouble = Sqlite.open(path)
  if db == nil then
    return 0, 0, otrouble
  end
  local rows, rtrouble = Sqlite.text_rows(db, [[
    select i.kind, i.origin, count(*)
    from runs r join inputs i on i.path = r.path
    where r.passed = 1
    group by i.kind, i.origin
  ]], {})
  local _, _ = db:close()
  if rows == nil then
    return 0, 0, rtrouble
  end
  local tests, examples = 0, 0
  for _, row in ipairs(rows) do
    local kind, origin, n = row[1], row[2], math.tointeger(tonumber(row[3])) or 0
    if kind == "test" and origin ~= "doctest" then
      tests = tests + n
    end
    if kind == "example" or origin == "doctest" then
      examples = examples + n
    end
  end
  return tests, examples, ""
end

local record Grade
  dir: string
  name: string
  exe: string
  empty: string
  steps: integer
  failed: boolean
end

local function fail(g: Grade, line: string)
  say("FAIL " .. line)
  g.failed = true
end

local function ok(line: string)
  say("ok   " .. line)
end

local function step(g: Grade, label: string, work: function(out: integer): boolean): boolean
  g.steps = g.steps + 1
  local log = g.dir .. "/check-" .. g.steps .. ".out"
  local out, trouble = Fs.open_write(log)
  if out == nil then
    fail(g, label .. ": " .. trouble)
    return false
  end
  local passed = work(out)
  local _, _ = Fs.close(out)
  if passed then
    ok(label)
    return true
  end
  fail(g, label)
  local read, _ = Fs.read(log)
  local text = read or ""
  if text ~= "" and text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  for line in text:gmatch("([^\n]*)\n") do
    local _, _ = Fs.put(Fs.stdout, "check:   " .. line .. "\n")
  end
  return false
end

local function command_step(g: Grade, argv: {string}, cwd: string): boolean
  return step(g, table.concat(argv, " "), function(out: integer): boolean
    local result, trouble = Child.run(argv, { cwd = cwd, stdout = out, stderr = "stdout",
      timeout_ns = Time.seconds(120) })
    if result == nil then
      local _, _ = Fs.put(out, trouble .. "\n")
      return false
    end
    return status(result) == 0
  end)
end

--- Runs `cosmic fix --check` with the journal set aside: it is prose
--- the task asks for, not a source the task asks to have formatted,
--- and `fix --check` holds a project's Markdown to its link rules.
local function fix_check(g: Grade, cosmic: string, project: string)
  local journal = project .. "/JOURNAL.md"
  local aside = g.dir .. "/JOURNAL.md.aside"
  local moved, _ = Fs.rename(journal, aside)
  command_step(g, { cosmic, "fix", "--check" }, project)
  if moved then
    local back, trouble = Fs.rename(aside, journal)
    if not back then
      say("FAIL could not put JOURNAL.md back from " .. aside .. ": " .. trouble)
      g.failed = true
    end
  end
end

--- Runs the task's executable in the empty directory with an empty
--- environment, answering its result.
local function run(g: Grade, args: {string}, input?: string): Child.Result
  local argv: {string} = { g.empty .. "/" .. g.name }
  for _, word in ipairs(args) do
    argv[#argv + 1] = word
  end
  local result, trouble = Child.run(argv, { cwd = g.empty, env = {}, stdout = "capture",
    stderr = "capture", input = input, timeout_ns = Time.seconds(10) })
  if result == nil then
    return { code = 127, ok = false, timed_out = false, stdout = "", stderr = trouble,
      captured = {}, truncated = false }
  end
  return result
end

local function label(g: Grade, args: {string}): string
  return "./" .. g.name .. " " .. table.concat(args, " ")
end

--- Checks that the executable exits 0 printing exactly `want` on stdout.
local function expect(g: Grade, want: string, args: {string})
  local result = run(g, args)
  local got = trimmed(result.stdout or "")
  if status(result) == 0 and got == want then
    ok(label(g, args) .. " -> " .. first_line(want))
  else
    fail(g, label(g, args) .. ": exit " .. status(result) .. ", got '" .. got ..
      "', wanted '" .. want .. "'; stderr: " .. first_line(result.stderr or ""))
  end
end

--- Checks that the executable fails with a message of its own on stderr,
--- answering that message.
local function refuses(g: Grade, args: {string}): string
  local result = run(g, args)
  local err = result.stderr or ""
  if status(result) == 0 then
    fail(g, label(g, args) .. " exited 0")
  elseif err == "" then
    fail(g, label(g, args) .. " said nothing on stderr")
  elseif failed_in_cosmic(err) then
    fail(g, label(g, args) .. " failed in cosmic, not in " .. g.name .. ": " .. first_line(err))
  else
    ok(label(g, args) .. " -> exit " .. status(result) .. ", stderr: " .. first_line(err))
  end
  return err
end

local function help(g: Grade, words: {string})
  local result = run(g, { "help" })
  local out = trimmed(result.stdout or "")
  if status(result) ~= 0 then
    fail(g, g.name .. " help exited " .. status(result))
    return
  elseif out == "" then
    fail(g, g.name .. " help printed nothing")
    return
  end
  local missing = ""
  for _, word in ipairs(words) do
    if not out:find(word, 1, true) then
      missing = missing .. " " .. word
    end
  end
  if missing ~= "" then
    fail(g, g.name .. " help did not mention:" .. missing)
  else
    ok(g.name .. " help -> mentions " .. table.concat(words, ", "))
  end
end

local function write(g: Grade, path: string, data: string)
  local dir = path:match("^(.*)/[^/]*$")
  if dir ~= nil then
    local _, _ = Fs.mkdirs(g.empty .. "/" .. dir)
  end
  local written, trouble = Fs.write(g.empty .. "/" .. path, data)
  if not written then
    fail(g, "could not write " .. path .. ": " .. trouble)
  end
end

-- pack

--- One ustar header and body for a file named `name` holding `data`.
local function ustar(name: string, data: string): string
  local function field(text: string, width: integer): string
    return text .. string.rep("\0", width - #text)
  end
  local function octal(n: integer, width: integer): string
    return field(string.format("%0" .. (width - 1) .. "o", n), width)
  end
  local head = field(name, 100) .. octal(420, 8) .. octal(0, 8) .. octal(0, 8)
    .. octal(#data, 12) .. octal(0, 12) .. "        " .. "0" .. field("", 100)
    .. "ustar\0" .. "00" .. field("", 32) .. field("", 32) .. octal(0, 8) .. octal(0, 8)
    .. field("", 155)
  head = field(head, 512)
  local sum = 0
  for i = 1, #head do
    sum = sum + head:byte(i)
  end
  head = head:sub(1, 148) .. string.format("%06o\0 ", sum) .. head:sub(157)
  local padding = (512 - #data % 512) % 512
  return head .. data .. string.rep("\0", padding)
end

local function pack(g: Grade)
  local bytes: {string} = {}
  for i = 0, 255 do
    bytes[#bytes + 1] = string.char(i)
  end
  local files: {{string}} = {
    { "a.txt", "alpha\n" },
    { "sub/b.txt", "bravo bravo\n" },
    { "sub/deep/c.bin", table.concat(bytes) },
  }
  local listing, sums: {string}, {string} = {}, {}
  for _, f in ipairs(files) do
    write(g, "src/" .. f[1], f[2])
    listing[#listing + 1] = #f[2] .. "\t" .. f[1]
    sums[#sums + 1] = Hash.hex_sha256(f[2]) .. "\t" .. f[1]
  end
  local want_list = table.concat(listing, "\n")
  local want_sum = table.concat(sums, "\n")
  local magic: {string: function(string): boolean} = {
    ["tar"] = function(s: string): boolean return s:sub(258, 262) == "ustar" end,
    ["tar.gz"] = function(s: string): boolean return s:sub(1, 2) == "\31\139" end,
    ["tgz"] = function(s: string): boolean return s:sub(1, 2) == "\31\139" end,
    ["zip"] = function(s: string): boolean return s:sub(1, 4) == "PK\3\4" end,
  }
  for _, ext in ipairs({ "tar", "tar.gz", "tgz", "zip" }) do
    local archive = "out." .. ext
    expect(g, "", { "create", archive, "src" })
    local data, _ = Fs.read(g.empty .. "/" .. archive)
    if data == nil or not magic[ext](data) then
      fail(g, archive .. " is not a " .. ext .. " file")
    else
      ok(archive .. " is a " .. ext .. " file")
    end
    expect(g, want_list, { "list", archive })
    expect(g, want_sum, { "sum", archive })
    local dest = "dest-" .. ext
    expect(g, "", { "extract", archive, dest })
    local same = true
    for _, f in ipairs(files) do
      local got, _ = Fs.read(g.empty .. "/" .. dest .. "/" .. f[1])
      if got ~= f[2] then
        same = false
        fail(g, "extract " .. archive .. ": " .. dest .. "/" .. f[1] .. " differs")
      end
    end
    if same then ok("extract " .. archive .. " recreates every file") end
  end
  local gz, _ = Fs.read(g.empty .. "/out.tar.gz")
  write(g, "data.bin", gz or "")
  expect(g, want_list, { "list", "data.bin" })
  refuses(g, { "create", "out.rar", "src" })
  refuses(g, { "list", "src/a.txt" })
  refuses(g, { "list", "missing.tar" })

  write(g, "evil.tar", ustar("ok.txt", "fine\n") .. ustar("../evil.txt", "escaped\n")
    .. string.rep("\0", 1024))
  local err = refuses(g, { "extract", "evil.tar", "dest-evil" })
  if not err:find("evil", 1, true) then
    fail(g, "extract evil.tar did not name the entry ../evil.txt")
  end
  local escaped, _ = Fs.exists(g.empty .. "/evil.txt")
  if escaped then
    fail(g, "extract evil.tar wrote evil.txt outside its destination")
  else
    ok("extract evil.tar wrote nothing outside its destination")
  end
  help(g, { "create", "list", "sum", "extract" })
end

-- ledger

local LEDGER_CSV <const> = table.concat({
  "when,amount,category,note",
  "2026-01-31T23:30:00-05:00,12.50,food,\"late dinner, downtown\"",
  "2026-02-01T10:00:00Z,-3.5,food,refund",
  "2026-02-15T12:00:00+01:00,1000,rent,\"multi",
  "line \"\"note\"\"\"",
  "not-a-date,5,food,bad",
  "2026-03-01T00:30:00+01:00,0.25,misc,",
  "2026-02-10T09:00:00Z,abc,food,bad amount",
}, "\n") .. "\n"

--- Whether two decoded JSON values are equal, numbers by value.
local function same(a: any, b: any): boolean
  if a is {any: any} and b is {any: any} then
    for k, v in pairs(a) do
      if not same(v, b[k]) then return false end
    end
    for k in pairs(b) do
      if a[k] == nil then return false end
    end
    return true
  end
  return a == b
end

local function report(g: Grade, args: {string}, want: string): string
  local result = run(g, args)
  local got, trouble = Json.decode(result.stdout or "")
  local wanted = assert(Json.decode(want))
  if status(result) ~= 0 then
    fail(g, label(g, args) .. ": exit " .. status(result) .. "; stderr: " ..
      first_line(result.stderr or ""))
  elseif got == nil then
    fail(g, label(g, args) .. ": stdout is no JSON (" .. trouble .. "): " ..
      first_line(result.stdout or ""))
  elseif not same(got, wanted) then
    fail(g, label(g, args) .. ": got " .. trimmed(result.stdout or "") .. ", wanted " .. want)
  else
    ok(label(g, args) .. " -> " .. (want:gsub("%s*\n%s*", "")))
  end
  return result.stderr or ""
end

local function ledger(g: Grade)
  write(g, "tx.csv", LEDGER_CSV)
  local err = report(g, { "report", "tx.csv" }, [[{"months":[
    {"month":"2026-02","total_cents":100925,"categories":{"food":900,"rent":100000,"misc":25}}],
    "rows":4,"skipped":2}]])
  for _, line in ipairs({ "line 6", "line 8" }) do
    if err:find(line .. "%f[^%d]") then
      ok("stderr names " .. line)
    else
      fail(g, "stderr did not name " .. line .. ": " .. trimmed(err))
    end
  end
  report(g, { "report", "--zone", "America/New_York", "tx.csv" }, [[{"months":[
    {"month":"2026-01","total_cents":1250,"categories":{"food":1250}},
    {"month":"2026-02","total_cents":99675,"categories":{"food":-350,"rent":100000,"misc":25}}],
    "rows":4,"skipped":2}]])
  report(g, { "report", "tx.csv", "--zone", "Europe/Berlin" }, [[{"months":[
    {"month":"2026-02","total_cents":100900,"categories":{"food":900,"rent":100000}},
    {"month":"2026-03","total_cents":25,"categories":{"misc":25}}],
    "rows":4,"skipped":2}]])
  report(g, { "report", "tx.csv", "--zone", "Europe/Berlin", "--from", "2026-02-02",
    "--to", "2026-03-01" }, [[{"months":[
    {"month":"2026-02","total_cents":100000,"categories":{"rent":100000}},
    {"month":"2026-03","total_cents":25,"categories":{"misc":25}}],
    "rows":2,"skipped":2}]])
  report(g, { "report", "tx.csv", "--to", "2026-01-31", "--zone", "America/New_York" },
    [[{"months":[{"month":"2026-01","total_cents":1250,"categories":{"food":1250}}],
    "rows":1,"skipped":2}]])
  write(g, "wrong.csv", "date,amount,category,note\n2026-01-01T00:00:00Z,1,a,\n")
  refuses(g, { "report", "tx.csv", "--zone", "Mars/Olympus" })
  refuses(g, { "report", "missing.csv" })
  refuses(g, { "report", "wrong.csv" })
  refuses(g, { "report", "tx.csv", "--from", "yesterday" })
  help(g, { "report", "--zone", "--from", "--to" })
end

-- kv

--- One raw HTTP exchange with the server: what it answered, or nil.
local function exchange(port: integer, request: string): string | nil, string
  local conn, trouble = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Time.seconds(3) })
  if conn == nil then return nil, trouble end
  local sent, strouble = conn:write(request)
  if not sent then
    local _, _ = conn:close()
    return nil, strouble
  end
  local got = ""
  while true do
    local head, rest = got:match("^(.-\r\n\r\n)(.*)$")
    if head ~= nil then
      local length = math.tointeger(tonumber(head:lower():match("\ncontent%-length:%s*(%d+)")))
      -- RFC 9110 forbids a Content-Length on a 204, which has no body.
      if length == nil and head:match("^HTTP/1%.[01] 204") then
        length = 0
      end
      if length == nil then
        local _, _ = conn:close()
        return nil, "no Content-Length in " .. first_line(head)
      end
      if #rest >= length then break end
    end
    local chunk, rtrouble = conn:read()
    if chunk == nil then
      local _, _ = conn:close()
      if got ~= "" then return got, "" end
      return nil, rtrouble ~= "" and rtrouble or "closed early"
    end
    got = got .. chunk
  end
  local _, _ = conn:close()
  return got, ""
end

local function answers(g: Grade, port: integer, request: string, codes: {string}, body?: string)
  local shown = first_line(request)
  local got, trouble = exchange(port, request)
  if got == nil then
    fail(g, shown .. ": " .. trouble)
    return
  end
  local code = got:match("^HTTP/1%.[01] (%d%d%d)")
  local matched = false
  for _, c in ipairs(codes) do
    if c == code then matched = true end
  end
  local got_body = trimmed(got:match("\r\n\r\n(.*)$") or "")
  if not matched then
    fail(g, shown .. ": status " .. tostring(code) .. ", wanted " .. table.concat(codes, " or "))
  elseif body ~= nil and got_body ~= body then
    fail(g, shown .. ": body '" .. tostring(got_body) .. "', wanted '" .. body .. "'")
  else
    ok(shown .. " -> " .. code)
  end
end

local function kv(g: Grade)
  local out_path = g.dir .. "/check-serve.out"
  local out = assert(Fs.open_write(out_path))
  local server, trouble = Child.start({ g.empty .. "/kv", "serve", "0" }, { cwd = g.empty,
    env = {}, stdout = out, stderr = out })
  local _, _ = Fs.close(out)
  if server == nil then
    fail(g, "kv serve 0 did not start: " .. trouble)
    return
  end
  local port: integer = nil
  local deadline = Time.monotonic_ns() + Time.seconds(5)
  while Time.monotonic_ns() < deadline do
    local text, _ = Fs.read(out_path)
    local found = text ~= nil and text:match("listening on 127%.0%.0%.1:(%d+)\n")
    if found then
      port = math.tointeger(tonumber(found))
      break
    end
    local _, _ = Time.sleep_ns(Time.ms(50))
  end
  if port == nil then
    local text, _ = Fs.read(out_path)
    fail(g, "kv serve 0 printed no 'listening on 127.0.0.1:<port>' line in 5s: " ..
      first_line(text or ""))
    local _, _ = server:close()
    return
  end
  ok("kv serve 0 -> listening on 127.0.0.1:" .. port)
  local base = "http://127.0.0.1:" .. port

  expect(g, "", { "put", base .. "/alpha", "hello" })
  expect(g, "hello", { "get", base .. "/alpha" })
  expect(g, "", { "put", base .. "/beta", "two words" })
  expect(g, "two words", { "get", base .. "/beta" })
  expect(g, "", { "rm", base .. "/alpha" })
  refuses(g, { "get", base .. "/alpha" })
  refuses(g, { "rm", base .. "/alpha" })

  answers(g, port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "beta")
  answers(g, port, "PUT /raw HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc", { "204" })
  answers(g, port, "GET /raw HTTP/1.1\r\nHost: x\r\n\r\n", { "200" }, "abc")
  answers(g, port, "GET /nothing HTTP/1.1\r\nHost: x\r\n\r\n", { "404" })
  answers(g, port, "POST /raw HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", { "400", "405" })
  answers(g, port, "DELETE /raw HTTP/1.1\r\nHost: x\r\n\r\n", { "204" })

  -- A client that sends half a request and waits must not hold up the next.
  local idle, itrouble = Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = Time.seconds(3) })
  if idle == nil then
    fail(g, "idle connection: " .. itrouble)
  else
    local _, _ = idle:write("GET /beta HTTP/1.1\r\nHo")
    local started = Time.monotonic_ns()
    local result = run(g, { "get", base .. "/beta" })
    local took = (Time.monotonic_ns() - started) // Time.ms(1)
    if status(result) == 0 and trimmed(result.stdout or "") == "two words" and took < 3000 then
      ok("get while another client idles mid-request -> answered in " .. took .. " ms")
    else
      fail(g, "get while another client idles mid-request: exit " .. status(result) ..
        " after " .. took .. " ms; stderr: " .. first_line(result.stderr or ""))
    end
    local _, _ = idle:close()
  end

  local stopped, _ = server:stop()
  local result, _ = server:wait(Time.seconds(3))
  if not stopped or result == nil or result.timed_out then
    fail(g, "kv serve did not exit within 3s of SIGTERM")
  elseif status(result) ~= 0 then
    fail(g, "kv serve exited " .. status(result) .. " on SIGTERM, not 0")
  else
    ok("kv serve exits 0 on SIGTERM")
  end
  local _, _ = server:close()
  refuses(g, { "get", base .. "/beta" })
  help(g, { "serve", "put", "get", "rm" })
end

local TASKS <const>: {string: function(Grade)} = { pack = pack, ledger = ledger, kv = kv }

local function grade(name: string, dir: string): integer
  local project = dir .. "/project"
  local cosmic = dir .. "/bin/cosmic"
  local is_project, project_trouble = Fs.is_dir(project)
  if not is_project then
    say("FAIL no project at " .. project ..
      (project_trouble ~= "" and ": " .. project_trouble or ""))
    say("FAIL")
    return 1
  end
  local g: Grade = { dir = dir, name = name, exe = project .. "/o/bin/" .. name,
    empty = dir .. "/empty", steps = 0, failed = false }
  local db = project .. "/o/build.db"
  step(g, "evidence reset " .. db, function(out: integer): boolean
    local reset, trouble = reset_evidence(db)
    if not reset then
      local _, _ = Fs.put(out, trouble .. "\n")
    end
    return reset
  end)
  command_step(g, { cosmic, "test" }, project)
  step(g, "evidence check " .. db, function(out: integer): boolean
    local tests, examples, trouble = evidence(db)
    local _, _ = Fs.put(out, "evidence: " .. tests .. " tests, " .. examples .. " examples " ..
      trouble .. "\n")
    return tests > 0 and examples > 0
  end)
  fix_check(g, cosmic, project)
  local passed = command_step(g, { cosmic, "build" }, project)
  local read, _ = Fs.read(g.dir .. "/check-" .. g.steps .. ".out")
  local st, _ = Fs.stat(g.exe)
  if not passed then
    say("skip o/bin/" .. name .. ": cosmic build failed; not running an earlier build's binary")
  elseif not built(read or "", name) or st == nil or st.kind ~= "file" then
    fail(g, "cosmic build did not produce o/bin/" .. name)
  else
    local bytes, trouble = Fs.read(g.exe)
    local copied = bytes ~= nil
    if copied then copied, trouble = Fs.remove_tree(g.empty) end
    if copied then copied, trouble = Fs.mkdirs(g.empty) end
    if copied then copied, trouble = Fs.write(g.empty .. "/" .. name, assert(bytes), 0x1ed) end
    if not copied then
      fail(g, "could not copy " .. g.exe .. " into " .. g.empty .. ": " .. trouble)
    else
      TASKS[name](g)
    end
  end
  if g.failed then
    say("FAIL")
    return 1
  end
  say("PASS")
  return 0
end

function Tasks.main(argv: {integer: string}): integer
  local name, dir = argv[1], argv[2]
  if name == nil or TASKS[name] == nil or dir == nil or argv[3] ~= nil then
    local _, _ = Fs.put(Fs.stderr, "usage: eval/check/tasks.tl pack|ledger|kv <dir>\n")
    return 2
  end
  local absolute, _ = Fs.absolute(dir)
  return grade(name, absolute or dir)
end

return Tasks
