--- The declarations of the standard library tell the truth about nil: a
--- function declared to answer a value may answer nil only where its type
--- says so, a record field absent where the field is optional, and a
--- parameter a caller may leave out is optional. Each test drives the
--- paths where a value may be nil and asks a checked run
--- (`cosmic test --check-types`) whether a value crossed a typed boundary
--- as a kind its type does not admit; in any other run the tests skip.
--- Until a compile writes the boundary checks (build/type_watch.tl), they skip in a checked run too.

local Archive = require("cosmic.archive")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local Server = require("cosmic.http.server")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")
local Template = require("cosmic.template")
local Time = require("cosmic.time")
local Web = require("cosmic.web")
local Zip = require("cosmic.zip")
local TypeWatch = require("build.type_watch")

--- Fails, listing what `during` met, unless it met nothing.
local function honest(what: string, fn: function())
  local found = TypeWatch.during(fn)
  assert(#found == 0, what .. ": " .. #found .. " violations:\n" .. table.concat(found, "\n"))
end

--- A reader of text that is not valid RFC 3339, HTTP date or POSIX TZ in
--- each way the readers name: a position they stop at answers no value
--- but a reason, and the readers' helpers answer a number or text every
--- time.
local function test_the_time_readers_answer_what_they_declare(tmp: string)
  honest("time", function()
    for _, text in ipairs({
        "2026-13-01", "2026-01-01", "2026-01-01T00:00", "2026-01-01T00:00:00", "2026-01-01T00:00:00.Z",
        "2026-01-01T00:00:00+5", "2026-01-01T00:00:00+24:00", "2026-01-01T00:00:00+00:60",
        "2026-01-01T00:00:00Z[!x=y]", "2026-01-01T00:00:00Z[x=-y]", "2026-01-01T00:00:00Z[../x]",
        "2026-01-01T00:00:00Z[+05:30]", "2026-01-01T00:00:00+05:30[+05:30]",
        "2026-01-01T00:00:00Z[Europe/Berlin]", "2026-01-01T00:00:00Z[Nowhere/Nothing]", "",
    }) do
      local _, _ = Time.parse_rfc3339_zoned(text)
      local _, _ = Time.parse_rfc3339(text)
    end
    for _, text in ipairs({
        "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994",
        "Sun, 99 Nov 1994 08:49:37 GMT", "Xyz, 06 Nov 1994 08:49:37 GMT", "Sun, 06", "garbage",
    }) do
      local _, _ = Time.parse_http(text)
      local _, _ = Time.parse_date(text)
    end
    for _, name in ipairs({ "Europe/Berlin", "UTC", "../x", "/abs", "a//b", "posix/UTC", "bad name" }) do
      local _, _ = Time.zone(name)
    end
    -- A POSIX TZ string read through the host's `TZ`, well and badly formed.
    for _, tz in ipairs({
        "EST5EDT", "EST5EDT,M3.2.0,M11.1.0", "<+0330>-3:30", "AEST-10AEDT,M10.1.0,M4.1.0/3",
        "EST5EDT,J60/-2,300/3:30:15", "EST", "EST5EDT,M13.1.0,M11.1.0", "<+0330", "EST5:60",
        "EST5EDT,M3.2.0", "EST5EDT,M3.2.0,M11.1.0x", "ES5", ":Europe/Berlin", ":/nowhere", "Europe/Berlin",
    }) do
      local _, _ = Time.local_zone({ tz = tz })
    end
    -- The host's zone from the files that name it, present and not.
    local missing = tmp .. "/none"
    assert(Fs.write(tmp .. "/timezone", "# written by hand\n  Asia/Kolkata \n"))
    assert(Fs.write(tmp .. "/garbage", "../../etc/passwd\n"))
    assert(Fs.write(tmp .. "/blank", "\n\n"))
    assert(Fs.symlink(tmp .. "/zoneinfo/Nowhere/Nothing", tmp .. "/unknown"))
    for _, files in ipairs({
        { missing, missing }, { missing, tmp .. "/timezone" }, { tmp .. "/unknown", tmp .. "/garbage" },
        { tmp .. "/unknown", tmp .. "/blank" }, { tmp .. "/timezone", missing },
    }) do
      local _, _ = Time.local_zone({ unset = true, localtime = files[1], timezone = files[2] })
    end
    -- Calendar arithmetic on the default zone, and on a named one.
    local berlin = assert(Time.zone("Europe/Berlin"))
    local from = assert(Time.parse_rfc3339("2026-01-31T12:00:00Z"))
    local to = assert(Time.parse_rfc3339("2026-03-31T11:00:00Z"))
    local _ = Time.between(from, to)
    _ = Time.between(from, to, berlin)
    local _, _ = Time.add_calendar(from, { months = 1 })
    local _, _ = Time.add_calendar(from, { months = 1 }, berlin)
    local _, _ = Time.from_civil(Time.civil(from))
  end)
end

local function test_the_json_readers_and_paths_answer_what_they_declare()
  honest("json", function()
    for _, text in ipairs({
        '{"a":[1,"x",true,false,null,-1.5e3],"b":{}}', "[1,,2]", "{", "}", "]", '{"a" 1}', "[1 2]", "{,}",
        "x", "", '{"a":1,}', "[1,]",
    }) do
      local reader = Json.reader(Stream.from_string(text))
      for _ = 1, 40 do
        local token, _ = reader:next()
        if token == nil then break end
      end
      local json5 = Json.reader(Stream.from_string(text), { json5 = true })
      for _ = 1, 40 do
        local token, _ = json5:next()
        if token == nil then break end
      end
    end
    local value = { a = { 1, 2, { b = true } } }
    local _g, _h = Json.get(value, { "a", 3, "b" })
    _g, _h = Json.get(value, { "a", 3, "b", "c" })
    _g, _h = Json.get(value, { "a", 0 })
    local _p, _w = Json.pointer({ "a", 3 })
    _p, _w = Json.pointer({ "a", 0 })
    _p, _w = Json.pointer({ "a", -1 })
    _p, _w = Json.path({ "a", 3, "it's" })
    _p, _w = Json.path({ "a", 0 })
    for _, text in ipairs({ "$.a", "$..a", "$.a[0]", "$..*", "$[*]", "$.", "$..", "$.1", "$['a']" }) do
      local _, _ = Json.query(text)
    end
  end)
end

local function test_a_range_and_a_tag_list_answer_what_they_declare()
  honest("http server", function()
    for _, header in ipairs({
        '"a"', 'W/"a"', '"a", W/"b", bad, *', '*', ' "a" ,"b"', 'W/', '"unterminated', '', ',,',
    }) do
      local _ = Server.none_match(header, '"a"')
      _ = Server.none_match(header, 'W/"b"')
    end
    local _ = Server.none_match(nil, '"a"')
  end)
end

local function test_a_sandbox_policy_merges_what_it_declares()
  honest("sandbox", function()
    local merged = assert(Sandbox.merge({ limits = { open_files = 10 } },
      { limits = { open_files = 10, processes = 5 } }, { limits = { cpu_seconds = 3 } }))
    local merged_limits = merged.limits
    assert(merged_limits ~= nil and merged_limits.open_files == 10 and merged_limits.processes == 5 and
        merged_limits.cpu_seconds == 3)
    local none, why = Sandbox.merge({ limits = { open_files = 10 } }, { limits = { open_files = 11 } })
    assert(none == nil and why:find("limits.open_files", 1, true), tostring(why))
    local _, _ = Sandbox.merge({}, {})
  end)
end

local record Created
  id: integer
end

--- A typed route reads no slot it declares none for, and is given an
--- empty [`Web.None`] for each, never nil.
local function test_a_typed_route_is_given_an_empty_none_for_an_absent_slot()
  local seen: {string} = {}
  honest("web", function()
    local app = Web.app{ routes = {
      Web.get_typed("/a", Web.input(Web.NONE, Web.NONE, Web.no_body),
        function(_req: Web.Request, p: Web.None, q: Web.None, b: Web.None): Web.Response
          seen[#seen + 1] = type(p) .. type(q) .. type(b)
          return Web.text("ok")
        end),
      Web.post_typed("/b", Web.input(Web.NONE, Web.NONE, Web.json_body(Shape.record_of("Created"))),
        function(_req: Web.Request, p: Web.None, q: Web.None, _b: Created): Web.Response
          seen[#seen + 1] = type(p) .. type(q)
          return Web.text("ok")
        end),
    } }
    local client <close> = Web.test_client(app)
    assert(client:get("/a").status == 200)
    assert(client:post("/b", { json = { id = 1 } }).status == 200)
    assert(client:post("/b", { body = "x", headers = { ["content-type"] = "text/plain" } }).status == 415)
  end)
  assert(seen[1] == "tabletabletable" and seen[2] == "tabletable", table.concat(seen, ","))
end

local function test_sqlite_runs_without_values_as_declared(tmp: string)
  honest("sqlite", function()
    local db = assert(Sqlite.open(tmp .. "/db.sqlite", { writable = true }))
    assert(Sqlite.run(db, "create table t(a integer)"))
    assert(Sqlite.run(db, "insert into t values (1), (2)"))
    assert(#assert(Sqlite.rows(db, "select a from t")) == 2)
    assert(Sqlite.rows_result(db, "select a from t").code == Sqlite.OK)
    assert(Sqlite.run_result(db, "insert into t values (3)").code == Sqlite.OK)
    local query = assert(Sqlite.query(db, "select a from t"))
    local count = 0
    -- (Not `each`, whose iterator answers nil at the end: see the TODO
    -- in cosmic/sqlite.tl.)
    while query:read() ~= nil do count = count + 1 end
    assert(count == 3 and query:failure() == "")
    assert(query:close() == nil)
    assert(db:close())
  end)
end

local function test_a_template_that_starts_with_blank_text_answers_what_it_declares()
  honest("template", function()
    local _, _ = Template.compile("{{type T from m.t}}\n{{mode html}}\nhello", "t.tmpl")
    _, _ = Template.compile("\n{{type T from m.t}}\nhello", "t.tmpl")
    _, _ = Template.compile("hello", "t.tmpl")
    _, _ = Template.compile("{{type T from m.t}}", "t.tmpl")
    _, _ = Template.compile("", "t.tmpl")
  end)
end

local function test_an_archive_extracts_and_a_walk_lists_as_declared(tmp: string)
  honest("archive", function()
    local writer = assert(Stream.create(tmp .. "/a.tar"))
    local tar = Tar.writer(writer)
    assert(tar:add_file("top/bin/tool", "x"))
    assert(tar:add_file("top/other", "y"))
    assert(tar:close())
    local written = assert(Archive.extract(tmp .. "/a.tar", tmp .. "/out", { strip_components = 1 }))
    assert(#written == 2)
    assert(#assert(Archive.extract(tmp .. "/a.tar", tmp .. "/again", { strip_prefix = "top" })) == 2)
    -- A whole number held as a float counts as the integer does.
    local whole = (assert(load("return 1.0")))() as integer
    assert(#assert(Archive.extract(tmp .. "/a.tar", tmp .. "/float", { strip_components = whole })) == 2)
    assert(#assert(Fs.walk(tmp .. "/out")) >= 2)
    assert(#assert(Fs.walk_following(tmp .. "/out")) >= 2)
    assert(#assert(Fs.walk(tmp .. "/out", function(_: string, name: string): boolean
      return name == "other"
    end)) >= 1)
  end)
end

local function test_a_zip_entry_without_extra_bytes_reads_as_declared()
  honest("zip", function()
    local collected = Stream.collect()
    local writer = Zip.writer(collected)
    assert(writer:add_file("a.txt", "hello there", { method = "store" }))
    assert(writer:close())
    local reader = assert(Zip.open_string(collected:result()))
    for _, entry in ipairs((assert(reader:entries()))) do
      local body = assert(entry:open())
      assert((assert(Stream.read_all(body))) == "hello there")
    end
  end)
end
