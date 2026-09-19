local Fs = require("cosmic.fs")
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

local function test_join_keeps_complete_observations()
  local first: {observations.Observation} = {
    { kind = "s", path = "config", answer = "old" },
  }
  local joined = observations.join(first, {
    { kind = "d", path = "assets", answer = "listing" },
  })
  assert(#joined == 2)
  assert(joined[1].answer == "old" and joined[2].answer == "listing")
  assert(#first == 1)
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
