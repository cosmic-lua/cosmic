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
  local ok, value, found = observations.capture(function(): any
    assert(Fs.read(path) == "hello")
    return produced
  end)
  assert(ok and value == produced)
  assert(sys.open == original)
  assert(#found == 1 and found[1].kind == "o" and found[1].path == path)
end

local function test_capture_restores_after_an_error()
  local original = sys.open
  local ok, failure = observations.capture(function()
    error("expected")
  end)
  assert(not ok and tostring(failure):find("expected", 1, true) ~= nil)
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
  local ok, _, found = observations.call(function()
    assert(sys.stat(path))
    assert(Fs.write(path, "xx"))
  end, nil)
  assert(ok)
  assert(found[1].answer ~= observations.stat_answer(path))

  local ok_directory, _, directory_found = observations.call(function()
    assert(sys.readdir(tmp))
    assert(Fs.write(tmp .. "/added", ""))
  end, nil)
  assert(ok_directory)
  assert(directory_found[1].answer ~= observations.directory_answer(tmp))
end

local function test_records_stat_directory_and_open_queries(tmp: string)
  assert(Fs.write(tmp .. "/file", "contents"))
  local ok, _, found = observations.call(function()
    assert(Fs.exists(tmp .. "/missing") == false)
    assert(Fs.list(tmp))
    assert(Fs.read(tmp .. "/file"))
  end, nil)
  assert(ok)
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
  local ok = observations.call(function() error("deliberate") end, nil)
  assert(not ok)
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
  local ok, trouble, found = observations.call(function()
    Env.get("HOME")
    assert(Fs.mkdtemp("cosmic-observed-"))
    assert(Child.run({ "/bin/sh", "-c", "true" }))
  end, nil)
  assert(ok, trouble)
  local kinds: {string:integer} = {}
  for _, observation in ipairs(found) do
    kinds[observation.kind] = (kinds[observation.kind] or 0) + 1
  end
  -- At least the explicit read; `Fs.mkdtemp` and `Child.run` consult
  -- a platform-dependent number of variables themselves.
  assert(kinds.e >= 1)
  assert(kinds.p == 1)
  assert(kinds.m == 1)
end

--- A request over the network and a change of directory are answers no
--- key can hold; a scripted request connects nowhere and is not one.
local function test_network_and_chdir_are_unkeyable_observations(tmp: string)
  local here = assert(sys.getcwd())
  local chdir, open = sys.chdir, Http.open
  local ok, trouble, found = observations.call(function()
    assert(sys.chdir(tmp))
    assert(sys.chdir(here))
    -- An unsupported scheme fails before any connection, and is noted
    -- all the same: the wrapper cannot tell which requests would connect.
    Http.open("ftp://example.invalid/")
    local scripted = assert(Http.get("http://example.invalid/",
      { script = { "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" } }))
    assert(scripted.status == 200)
  end, nil)
  assert(ok, trouble)
  local unkeyable: {string} = {}
  for _, observation in ipairs(found) do
    if observation.kind == "x" then unkeyable[#unkeyable + 1] = observation.path end
  end
  assert(#unkeyable == 3 and unkeyable[1] == tmp and unkeyable[2] == here and
    unkeyable[3] == "ftp://example.invalid/", table.concat(unkeyable, " "))
  assert(sys.chdir == chdir and Http.open == open, "a wrapper was left installed")
end
