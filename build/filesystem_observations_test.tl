local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")

local function test_round_trips_every_path_byte()
  local path = "a b\n" .. string.char(0) .. "z"
  local decoded = assert(observations.decode(observations.encode({
    { kind = "s", path = path, answer = "" },
  })))
  assert(#decoded == 1)
  assert(decoded[1].kind == "s")
  assert(decoded[1].path == path)
  assert(observations.decode("plain/old/read.txt") == nil)
  assert(observations.key_part("s", "a\nb", "c") ~=
    observations.key_part("s", "a", "b\nc"))
end

local function test_capture_preserves_a_produced_table_and_restores(tmp: string)
  local path = tmp .. "/loaded"
  assert(Fs.write(path, "hello"))
  local original = sys.open
  local produced = { answer = 42 }
  local c = observations.capture(function(): any
    assert(Fs.read(path) == "hello")
    return produced
  end)
  local found = c.reads
  assert(c.ok and c.produced == produced)
  assert(sys.open == original)
  assert(#found == 1 and found[1].kind == "o" and found[1].path == path)
end

local function test_capture_restores_after_an_error()
  local original = sys.open
  local c = observations.capture(function()
    error("expected")
  end)
  assert(not c.ok and tostring(c.produced):find("expected", 1, true) ~= nil)
  assert(sys.open == original)
end

local function test_join_deduplicates_only_identical_observations()
  local first: {observations.Observation} = {
    { kind = "s", path = "config", answer = "old" },
    { kind = "s", path = "config", answer = "old" },
  }
  local joined = observations.join(first, {
    { kind = "s", path = "config", answer = "old" },
    { kind = "s", path = "config", answer = "new" },
    { kind = "d", path = "assets", answer = "listing" },
  })
  assert(#joined == 3)
  assert(joined[1].answer == "old" and joined[2].answer == "new")
  assert(joined[3].answer == "listing")
  assert(#first == 2)
end

local function test_captures_answers_when_the_query_occurs(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "x"))
  local run = observations.call(function()
    assert(sys.stat(path))
    assert(Fs.write(path, "xx"))
  end, nil)
  assert(run.passed, run.message)
  assert(run.reads[1].answer ~= observations.stat_answer(path))

  local directory_run = observations.call(function()
    assert(sys.readdir(tmp))
    assert(Fs.write(tmp .. "/added", ""))
  end, nil)
  assert(directory_run.passed, directory_run.message)
  assert(directory_run.reads[1].answer ~= observations.directory_answer(tmp))
end

local function test_records_stat_directory_and_open_queries(tmp: string)
  assert(Fs.write(tmp .. "/file", "contents"))
  local run = observations.call(function()
    assert(Fs.exists(tmp .. "/missing") == false)
    assert(Fs.list(tmp))
    assert(Fs.read(tmp .. "/file"))
  end, nil)
  assert(run.passed, run.message)
  local found = run.reads
  assert(found[1].kind == "s" and found[1].path == tmp .. "/missing")
  assert(found[2].kind == "d" and found[2].path == tmp)
  assert(found[3].kind == "o" and found[3].path == tmp .. "/file")
end

local function test_stat_answer_changes_for_deletion_and_metadata(tmp: string)
  local path = tmp .. "/file"
  assert(Fs.write(path, "same bytes"))
  local before = observations.stat_answer(path)
  assert(sys.chmod(path, 0x180))
  local changed = observations.stat_answer(path)
  assert(changed ~= before)
  assert(Fs.remove(path))
  assert(observations.stat_answer(path) ~= changed)
end

local function test_directory_answer_changes_for_an_added_entry(tmp: string)
  local before = observations.directory_answer(tmp)
  assert(Fs.write(tmp .. "/new", ""))
  assert(observations.directory_answer(tmp) ~= before)
end

local function test_restores_all_wrappers_after_an_error()
  local open, stat, readdir = sys.open, sys.stat, sys.readdir
  local run = observations.call(function() error("deliberate") end, nil)
  assert(not run.passed and run.message:find("deliberate", 1, true) ~= nil, run.message)
  assert(sys.open == open)
  assert(sys.stat == stat)
  assert(sys.readdir == readdir)
end

--- `key_part` hex-encodes both the path and the answer; these literals
--- pin the encoding for the bytes most likely to break a lookup-table
--- rewrite of it: NUL, newline, DEL, and 0xff, plus a multibyte UTF-8
--- path, none of which are ASCII letters or digits.
local function test_key_part_matches_known_hex_for_edge_bytes()
  local edges = string.char(0x00, 0x0a, 0x7f, 0xff)
  assert(observations.key_part("s", edges, "") == "s 000a7fff ")
  assert(observations.key_part("o", "", edges) == "o  000a7fff")
  assert(observations.key_part("d", "caf\xc3\xa9", "x") == "d 636166c3a9 78")
end

local function test_getenv_environ_spawn_and_mkdtemp_are_observed()
  local run = observations.call(function()
    Env.get("HOME")
    assert(Fs.mkdtemp("cosmic-observed-"))
    assert(Child.run({ "/bin/sh", "-c", "true" }))
  end, nil)
  assert(run.passed, run.message)
  local kinds: {string:integer} = {}
  for _, observation in ipairs(run.reads) do
    kinds[observation.kind] = (kinds[observation.kind] or 0) + 1
  end
  -- At least the explicit read; `Fs.mkdtemp` and `Child.run` consult
  -- a platform-dependent number of variables themselves.
  assert(kinds.e >= 1)
  assert(kinds.p == 1)
  assert(kinds.m == 1)
end

--- A request over the network is an answer no key can hold; a scripted
--- request connects nowhere and is not one.
local function test_a_network_request_is_an_unkeyable_observation()
  local open = Http.open
  local run = observations.call(function()
    -- An unsupported scheme fails before any connection, and is noted
    -- all the same: the wrapper cannot tell which requests would connect.
    Http.open("ftp://example.invalid/")
    local scripted = assert(Http.get("http://example.invalid/",
      { script = { "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" } }))
    assert(scripted.status == 200)
  end, nil)
  assert(run.passed, run.message)
  local unkeyable: {string} = {}
  for _, observation in ipairs(run.reads) do
    if observation.kind == "x" then unkeyable[#unkeyable + 1] = observation.path end
  end
  assert(#unkeyable == 1 and unkeyable[1] == "ftp://example.invalid/",
    table.concat(unkeyable, " "))
  assert(Http.open == open, "a wrapper was left installed")
end

--- A change of directory is a stat of where it went, and a relative
--- path is noted as the absolute one it names from wherever the call
--- was made.
local function test_a_relative_path_is_noted_from_the_working_directory(tmp: string)
  local here = assert(sys.getcwd())
  assert(Fs.mkdirs(tmp .. "/away"))
  local away = assert(sys.realpath(tmp .. "/away"))
  assert(Fs.write(away .. "/f", "x"))
  local chdir = sys.chdir
  local run = observations.call(function()
    assert(sys.chdir(away))
    assert(Fs.read("f") == "x")
    assert(sys.chdir(here))
    local _ = sys.stat("nowhere-relative")
  end, nil)
  assert(run.passed, run.message)
  local noted: {string} = {}
  for _, observation in ipairs(run.reads) do
    assert(observation.kind ~= "x", observation.path)
    if observation.kind == "s" or observation.kind == "o" then
      noted[#noted + 1] = observation.kind .. " " .. observation.path
    end
  end
  local text = table.concat(noted, "\n")
  assert(text:find("s " .. away .. "\n", 1, true), text)
  assert(text:find("o " .. away .. "/f\n", 1, true), text)
  assert(text:find("s " .. here .. "\n", 1, true), text)
  assert(text:find("s " .. here .. "/nowhere-relative", 1, true), text)
  assert(not text:find("o f\n", 1, true), text)
  assert(sys.chdir == chdir, "a wrapper was left installed")
end
