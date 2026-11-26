--- The fake of the confine tests (build/confine_test.tl,
--- build/confine_tool_test.tl, build/confine_forbid_tool_test.tl,
--- build/test_sandbox_system_confined_test.tl and those of
--- build/must_confine_fixture.tl),
--- run as a [`cosmic.fake`] main by a process [`build.confine`] confines.
--- Its first argument names the case and the rest are that case's words.

local Env = require("cosmic.env")
local Steps = require("cosmic.fake.steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Ends with status `words[1]`, or 2 where it names none.
  exit = function(words: {string}): integer return math.tointeger(tonumber(words[1] or "")) or 2 end,
  write = function(words: {string}): integer return Steps.write(words[1]!, words[2]!) or 0 end,
  -- Its working directory, as the whole of file `words[1]`.
  cwd = function(words: {string}): integer return Steps.cwd(words[1]!) or 0 end,
  -- Ends with 3 where `words[1]`, which it was not given, is there.
  exists = function(words: {string}): integer
    if Steps.exists(words[1]!) then return 3 end
    return 0
  end,
  -- Ends with 3 where `words[1]`, which a confined process is given, is
  -- not there.
  ["present-or-3"] = function(words: {string}): integer
    if Steps.exists(words[1]!) then return 0 end
    return 3
  end,
  -- Ends with 3 where `words[1]` is there; copies `words[2]` to
  -- `words[3]` where it is not.
  ["exists-or-copy"] = function(words: {string}): integer
    if Steps.exists(words[1]!) then return 3 end
    return Steps.copy(words[2]!, words[3]!) or 0
  end,
  -- As exists-or-copy, then counts the lines of its network's devices
  -- where it has them.
  ["exists-copy-count"] = function(words: {string}): integer
    if Steps.exists(words[1]!) then return 3 end
    local stopped = Steps.copy(words[2]!, words[3]!)
    if stopped ~= nil then return stopped end
    Steps.attempt(function(): integer?
      return Steps.present("/proc/self/net/dev") or Steps.grep_count("/proc/self/net/dev", ":")
    end)
    return 0
  end,
  -- Reads `words[1]`/f, and says whether `words[2]`/f, not given it, is there.
  ["given-hidden"] = function(words: {string}): integer
    local stopped = Steps.cat(words[1]! .. "/f") or Steps.print("")
    if stopped ~= nil then return stopped end
    local seen = Steps.attempt(function(): integer? return Steps.present(words[2]! .. "/f") end)
    return Steps.print(if seen then "hidden-seen" else "hidden-absent" end) or 0
  end,
  -- Writes /tmp/f and reads it back, then names TMPDIR.
  ["tmp-write-and-env"] = function(_: {string}): integer
    return Steps.write("/tmp/f", "x") or Steps.cat("/tmp/f") or Steps.env_of("TMPDIR") or 0
  end,
  -- Makes the directory COSMIC_PORTABLE_CACHE names and lists it, then
  -- names it.
  ["cache-dir"] = function(_: {string}): integer
    local cache = Env.get("COSMIC_PORTABLE_CACHE") or ""
    return Steps.mkdirs(cache) or Steps.list(cache) or Steps.print(cache) or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("confine fake", cases, argv)
end

return main
