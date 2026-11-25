--- The file tools, read, write and edit, and sql over what is kept, run
--- unsandboxed in a directory of their own.

local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sessions = require("cosmic.agent.sessions")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

Test.policy{ env = { "TMPDIR" } }

-- What a tool gives the model at most.
local MAX_LINES <const> = 2000
local MAX_BYTES <const> = 50 * 1024

local keyed = agent_fixture.keyed
local slurp = agent_fixture.slurp
local scratch = agent_fixture.scratch
local run = agent_fixture.run

local function test_read_gives_lines_and_says_where_to_go_on()
  local dir = scratch()
  assert(Fs.write(dir .. "/f.txt", "one\ntwo\nthree\nfour\n"))
  local all = run("read", { path = "f.txt" }, dir)
  assert(not all.is_error and all.text == "one\ntwo\nthree\nfour", all.text)
  local part = run("read", { path = dir .. "/f.txt", offset = 2, limit = 2 }, "/")
  assert(part.text:find("^two\nthree\n\n%[1 line more%. Use offset=4") ~= nil, part.text)
  local past = run("read", { path = "f.txt", offset = 9 }, dir)
  assert(past.is_error and past.text:find("beyond the end") ~= nil, past.text)
  local missing = run("read", { path = "nope.txt" }, dir)
  assert(missing.is_error, missing.text)
  local bad = run("read", { path = "f.txt", limit = "two" }, dir)
  assert(bad.is_error and bad.text:find("limit must be an integer") ~= nil, bad.text)
  local big: mut {string} = {}
  for i = 1, MAX_LINES + 5 do big[i] = "x" end
  assert(Fs.write(dir .. "/big.txt", table.concat(big, "\n")))
  local cut = run("read", { path = "big.txt" }, dir)
  assert(cut.text:find("%[Showing lines 1%-2000 of 2005%. Use offset=2001") ~= nil, cut.text:sub(-100))
  assert(Fs.write(dir .. "/wide.txt", string.rep("y", MAX_BYTES + 1)))
  assert(run("read", { path = "f.txt", limit = 0 }, dir).is_error)
  assert(Fs.write(dir .. "/full.txt", string.rep("z", MAX_BYTES)))
  assert(run("read", { path = "full.txt" }, dir).text == string.rep("z", MAX_BYTES))
  local wide = run("read", { path = "wide.txt" }, dir)
  assert(wide.text:find("^%[Line 1 is") ~= nil, wide.text)
end

local function test_write_makes_its_directories()
  local dir = scratch()
  local r = run("write", { path = "a/b/c.txt", content = "hi" }, dir)
  assert(not r.is_error and r.text == "Successfully wrote 2 bytes to a/b/c.txt", r.text)
  assert(slurp(dir .. "/a/b/c.txt") == "hi")
  assert(run("write", { path = "x" }, dir).is_error)
end

local function test_edit_replaces_each_unique_match()
  local dir = scratch()
  local file = dir .. "/e.txt"
  assert(Fs.write(file, "alpha\nbeta\ngamma\n"))
  local r = run("edit", { path = "e.txt", edits = {
    { oldText = "gamma", newText = "GAMMA" }, { oldText = "alpha", newText = "ALPHA" } } }, dir)
  assert(not r.is_error and r.text == "Successfully replaced 2 block(s) in e.txt.", r.text)
  assert(slurp(file) == "ALPHA\nbeta\nGAMMA\n")
  -- The shapes some models send: one object, a JSON string, or oldText alone.
  assert(not run("edit", { path = "e.txt", edits = { oldText = "beta", newText = "b" } }, dir).is_error)
  assert(not run("edit", { path = "e.txt", edits = '[{"oldText":"b\\n","newText":"B\\n"}]' }, dir).is_error)
  assert(not run("edit", { path = "e.txt", oldText = "ALPHA", newText = "a" }, dir).is_error)
  assert(slurp(file) == "a\nB\nGAMMA\n")
  local missing = run("edit", { path = "e.txt", edits = { { oldText = "zeta", newText = "" } } }, dir)
  assert(missing.is_error and missing.text:find("Could not find edits%[0%]") ~= nil, missing.text)
  assert(Fs.write(file, "x x"))
  local twice = run("edit", { path = "e.txt", edits = { { oldText = "x", newText = "y" } } }, dir)
  assert(twice.is_error and twice.text:find("Found more than one occurrence") ~= nil, twice.text)
  assert(Fs.write(file, "abcdef"))
  local overlap = run("edit", { path = "e.txt", edits = {
    { oldText = "abc", newText = "" }, { oldText = "cde", newText = "" } } }, dir)
  assert(overlap.is_error and overlap.text:find("overlap") ~= nil, overlap.text)
  assert(run("edit", { path = "e.txt", edits = { { oldText = "", newText = "z" } } }, dir).is_error)
  assert(run("edit", { path = "e.txt", edits = { { oldText = 1 } } }, dir).is_error)
  assert(run("edit", { path = "e.txt" }, dir).is_error)
  assert(run("edit", { path = "none.txt", edits = { { oldText = "a", newText = "b" } } }, dir).is_error)
  assert(slurp(file) == "abcdef")
  -- A CRLF file is matched with LF, and keeps CRLF.
  assert(Fs.write(file, "one\r\ntwo\r\n"))
  assert(not run("edit", { path = "e.txt", edits = { { oldText = "one\ntwo", newText = "1\n2" } } }, dir).is_error)
  assert(slurp(file) == "1\r\n2\r\n")
end

local function test_sql_reads_what_is_kept()
  local db = assert(Sessions.open(scratch() .. "/sessions.db"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  local lines: mut {string} = {}
  for i = 1, 3000 do lines[#lines + 1] = "line " .. tostring(i) end
  lines[#lines + 1] = "needle in the haystack"
  local out = assert(Sessions.output(db, id, { tool = "bash", input = '{"command":"make"}',
    text = table.concat(lines, "\n"), is_error = false }))
  local ctx: Tools.Context = { cwd = "/", db = db, session = id }
  local found = Tools.run("sql", { query = "SELECT rowid, snippet(outputs_fts, 0, '>>', '<<', '...', 64) " ..
      "AS s FROM outputs_fts WHERE outputs_fts MATCH '\"haystack\"'" }, ctx)
  assert(found.text:find(string.format("^rowid\ts\n%d\t.*>>haystack<<", out)) ~= nil, found.text)
  local part = Tools.run("sql", { query = "SELECT substr(text, instr(text, 'needle'), 6) AS n, NULL AS z, " ..
      "?1 AS here FROM outputs WHERE id = " .. tostring(out) }, ctx)
  assert(part.text == "n\tz\there\nneedle\tNULL\t" .. tostring(id), part.text)
  assert(Tools.run("sql", { query = "SELECT id FROM outputs WHERE id = 99" }, ctx).text == "id\n\n[No rows.]")
  local whole = Tools.run("sql", { query = "SELECT printf('%.60000c', 'x') AS big" }, ctx)
  assert(#whole.text < MAX_BYTES + 200 and whole.text:find("^big\nxxx") ~= nil and
      whole.text:find("[Stopped after 1 row,", 1, true) ~= nil, whole.text:sub(-300))
  local many = Tools.run("sql", { query = "SELECT value FROM generate_series(1, 5000)" }, ctx)
  assert(many.text:find("[Stopped after 1999 rows,", 1, true) ~= nil, many.text:sub(-200))
  local lined = Tools.run("sql", { query = "SELECT replace(printf('%.3000c', 'x'), 'x', 'a' || char(10))" }, ctx)
  local _, shown = lined.text:gsub("\n", "")
  assert(shown < MAX_LINES + 3 and lined.text:find("[Stopped after 1 row,", 1, true) ~= nil, lined.text:sub(-200))
  -- A cell cut to the limit keeps whole characters.
  local wide = Tools.run("sql", { query = "SELECT 'x' || replace(printf('%.40000c', 'x'), 'x', 'é') AS e" }, ctx)
  assert(wide.text:find("[Stopped after 1 row,", 1, true) ~= nil and utf8.len(wide.text) ~= nil, wide.text:sub(-200))
  local copy = scratch() .. "/copy.db"
  assert(Tools.run("sql", { query = "VACUUM INTO '" .. copy .. "'" }, ctx).is_error)
  assert(Tools.run("sql", { query = "ATTACH '" .. copy .. "' AS b" }, ctx).is_error)
  assert(not assert(Fs.status(copy)).exists)
  local write = Tools.run("sql", { query = "DELETE FROM outputs" }, ctx)
  assert(write.is_error and write.text:find("runs only queries", 1, true) ~= nil, write.text)
  assert(Tools.run("sql", { query = "SELECT count(*) FROM outputs" }, ctx).text == "count(*)\n1")
  assert(Tools.run("sql", { query = "SELEC" }, ctx).is_error)
  assert(Tools.run("sql", { query = 1 }, ctx).is_error)
  assert(Tools.run("sql", { query = "SELECT 1" }, { cwd = "/" }).is_error)
  local memory = assert(Sessions.open(":memory:"))
  assert(Tools.run("sql", { query = "SELECT 1" }, { cwd = "/", db = memory }).text:find("no file") ~= nil)
  -- A run that ended inside a tool call is settled with an error result.
  local s = Agent.new({ model = "m", effort = "low", sign = keyed("k"), system = "", cwd = "/", db = db, id = id,
    messages = {
      { role = "user", content = "go" },
      { role = "assistant", content = { { type = "tool_use", id = "t9", name = "bash", input = { command = "x" } } } },
    } })
  assert(s:settle())
  assert(#s.messages == 3 and assert(Json.encode(s.messages[3])):find('"tool_use_id":"t9"', 1, true) ~= nil)
  assert(s:settle() and #s.messages == 3)
  local loaded = assert(Sessions.load(db, id))
  assert(#loaded.messages == 1 and loaded.model == "m")
  local _, _ = db:close()
end

local function names(tools: {Tools.Tool}): string
  local out: mut {string} = {}
  for _, t in ipairs(tools) do out[#out + 1] = t.name end
  return table.concat(out, " ")
end

local function test_the_run_description_is_its_template_filled()
  local tool = assert(Tools.find(Tools.all(), "run"), "run is a tool")
  -- The slot is filled, and `{{` written as text in the template stands as it is.
  assert(tool.description:find("(its start and end past 8KB)", 1, true) ~= nil, tool.description)
  assert(tool.description:find("-> {{path, line, text}}:", 1, true) ~= nil, tool.description)
  assert(tool.description:find("^Run a program in cosmic, ") ~= nil, tool.description)
  -- No line ending after the example's last line, as the words were before the template.
  assert(tool.description:sub(-4) == " end", tool.description)
end

local function test_tools_are_values_to_pick_and_make()
  assert(names(Tools.all()) == "read bash run jobs edit write sql", names(Tools.all()))
  assert(names(Tools.default()) == "read run edit write", names(Tools.default()))
  -- With sql left out, run tells the model how to read what is kept.
  local run_tool = assert(Tools.find(Tools.default(), "run"))
  assert(run_tool.description:find("Host.history(query)", 1, true) ~= nil and
      run_tool.description:find("Tables: sessions", 1, true) ~= nil, run_tool.description)
  assert(table.concat(run_tool.guidelines, " "):find("Host.history", 1, true) ~= nil)
  assert(names(Tools.only(Tools.all(), { "sql", "read", "nope" })) == "read sql")
  assert(names(Tools.without(Tools.all(), { "run" })) == "read bash jobs edit write sql")
  assert(assert(Tools.find(Tools.all(), "edit")).name == "edit" and Tools.find(Tools.default(), "bash") == nil)
  -- A hint names only tools offered.
  local dir = scratch()
  assert(Fs.write(dir .. "/wide.txt", string.rep("w", 60000)))
  local wide = Tools.dispatch(Tools.default(), "read", { path = "wide.txt" }, { cwd = dir, tools = Tools.default() })
  assert(wide.text:find("Use run: read wide.txt", 1, true) ~= nil and wide.text:find("bash") == nil, wide.text:sub(-200))
  assert(Tools.run("read", { path = "wide.txt" }, { cwd = dir }).text:find("Use bash: sed", 1, true) ~= nil)
  assert(Tools.dispatch(Tools.default(), "bash", { command = "true" }, { cwd = dir }).text == "Tool bash not found")
  -- Each call gives a new list: a change to one is not seen in the next.
  local mine = Tools.all()
  table.remove(mine, 1)
  assert(#Tools.all() == 7 and #mine == 6)
  -- A tool of one's own: offered to the model, and run when it calls it.
  local none: {string: Json.Value} = {}
  local now: Tools.Tool = { name = "now", snippet = "Say the time", guidelines = { "Ask now for the time." },
    description = "The time.", schema = { type = "object", properties = none },
    run = function(_: Tools.Object, c: Tools.Context): Tools.Result
      return { text = "noon in " .. c.cwd, is_error = false }
    end }
  local a = agent_fixture.api({ { content = { { type = "tool_use", id = "t1", name = "now", input = none },
    { type = "tool_use", id = "t2", name = "bash", input = { command = "true" } } }, stop_reason = "tool_use" },
    { content = { { type = "text", text = "ok" } }, stop_reason = "end_turn" } })
  local s = Agent.new({ sign = keyed("k"), cwd = "/", base_url = "https://api.test", send = a.send, tools = { now } })
  assert(s.system:find("- now: Say the time", 1, true) ~= nil and s.system:find("- Ask now for the time.", 1, true) ~= nil)
  assert(s.system:find("bash", 1, true) == nil, s.system)
  assert(s:prompt("what time is it?"))
  local listed = agent_fixture.sent(a, 1)["tools"]
  assert(listed ~= nil)
  local offered = assert(Json.encode(listed))
  assert(offered == '[{"cache_control":{"type":"ephemeral"},"description":"The time.","input_schema":{"properties":{},"type":"object"},"name":"now"}]', offered)
  local answers = agent_fixture.said(a, 2)
  assert(answers:find('"content":"noon in /"', 1, true) ~= nil, answers)
  assert(answers:find("Tool bash not found", 1, true) ~= nil, answers)
end

--- `--tools` names the tools a session offers: the API is shown those alone, and a call of another is refused.
local function test_a_session_offers_the_tools_named()
  local offered = assert(Tools.named("run, read"))
  assert(names(offered) == "read run", names(offered))
  -- Tools.changed adds to and takes from a set: bash and jobs added, write taken out (sql is not there to take).
  local more = assert(Tools.changed(Tools.default(), "bash,jobs"))
  assert(names(more) == "read bash run jobs edit write", names(more))
  local fewer = assert(Tools.changed(Tools.default(), nil, "sql, write"))
  assert(names(fewer) == "read run edit", names(fewer))
  local changed = names(assert(Tools.changed(Tools.default(), "bash,sql", "write")))
  assert(changed == "read bash run edit sql", changed)
  local _, none_why = Tools.changed(Tools.default(), nil, "read,run,edit,write")
  assert(assert(none_why) == "no tool is left to offer")
  local _, lone_why = Tools.changed(Tools.default(), "jobs")
  assert(assert(lone_why):find("offer bash too", 1, true) ~= nil)
  local _, typo_why = Tools.changed(Tools.default(), "bsh")
  assert(assert(typo_why):find("no tool bsh", 1, true) == 1)
  local _, all_why = Tools.named("all")
  assert(assert(all_why):find("no tool all", 1, true) == 1)
  local _, unknown_why = Tools.named("run,nope")
  local unknown = assert(unknown_why)
  assert(unknown:find("no tool nope; the tools are read, bash", 1, true) == 1, unknown)
  local _, empty_why = Tools.named(" , ")
  assert(assert(empty_why) == "name at least one tool")
  local _, jobs_why = Tools.named("run,jobs")
  assert(assert(jobs_why):find("offer bash too", 1, true) ~= nil)
  local shown = assert(Json.encode(Tools.definitions(offered)))
  -- The last tool shown is the cache breakpoint, which every session's prefix shares; with no bash, run names no
  -- Host.bash.
  local _, marks = shown:gsub('"cache_control"', "")
  assert(marks == 1 and shown:find('"cache_control":{"type":"ephemeral"},"description":"Run', 1, true) ~= nil, shown)
  assert(shown:find("Host.bash", 1, true) == nil, shown)
  assert(assert(Json.encode(Tools.definitions(Tools.all()))):find("Host.bash", 1, true) ~= nil)
end
