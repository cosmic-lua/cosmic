--- The fake of the child policy tests (cosmic/child_policy_test.tl and
--- those of build/child_policy_fixture.tl), run as a [`cosmic.fake`]
--- main under each policy a test checks. Its first argument names
--- the case and the rest are that case's words; a path in place of a
--- case is a script it is the interpreter of (`#!` and its path), and it
--- prints that script's body past its first line.

local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  -- Each file named, or stdin where none is.
  cat = function(paths: {string}): integer
    if #paths == 0 then return Steps.cat() or 0 end
    for _, path in ipairs(paths) do
      local stopped = Steps.cat(path)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  present = function(words: {string}): integer return Steps.present(words[1]!) or 0 end,
  ls = function(words: {string}): integer return Steps.ls(words[1]!) or 0 end,
  append = function(words: {string}): integer return Steps.append(words[1]!, words[2]!) or 0 end,
  ["env-of"] = function(words: {string}): integer return Steps.env_of(words[1]!) or 0 end,
  rlimit = function(words: {string}): integer return Steps.rlimit(words[1]!) or 0 end,
  -- Each field of /proc/self/status named.
  ["status-field"] = function(names: {string}): integer
    for _, name in ipairs(names) do
      local stopped = Steps.status_field(name)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  connect = function(words: {string}): integer return Steps.connect(words[1]!) or 0 end,
  ["connect-tcp"] = function(words: {string}): integer
    return Steps.connect_tcp(words[1]!, Steps.int(words[2]!)) or 0
  end,
  ["loopback-tcp"] = function(words: {string}): integer
    return Steps.loopback_tcp(words[1]!) or 0
  end,
  ["loopback-unix"] = function(words: {string}): integer
    return Steps.loopback_unix(words[1]!) or 0
  end,
  ["sleep-forever"] = function(_: {string}): integer return Steps.sleep_forever() end,
  ["start-isolated"] = function(words: {string}): integer
    return Steps.start_isolated(words[1]!) or 0
  end,
  -- The program and words that follow, isolated to its own files.
  ["run-isolated"] = function(argv: {string}): integer return Steps.run_isolated(argv) or 0 end,
  -- As run-isolated, with a loopback of 127.0.0.1.
  ["run-looped"] = function(argv: {string}): integer
    return Steps.run_isolated(argv, { "127.0.0.1" }) or 0
  end,
  -- Starts the program and words past the count that many times.
  ["start-count"] = function(words: {string}): integer
    local argv: mut {string} = {}
    for i = 2, #words do argv[#argv + 1] = words[i] end
    return Steps.finish(Steps.start_count(Steps.int(words[1]!), argv) or 0)
  end,
  -- Makes file `words[1]` holding `words[2]`, and reads it back.
  ["create-and-cat"] = function(words: {string}): integer
    return Steps.create(words[1]!, words[2]!) or Steps.cat(words[1]!) or 0
  end,
  -- Makes `$TMPDIR/made` holding x, and reads it back.
  ["tmp-create-and-cat"] = function(_: {string}): integer
    local made = (Env.get("TMPDIR") or "") .. "/made"
    return Steps.create(made, "x") or Steps.cat(made) or 0
  end,
  -- Names TMPDIR, makes /tmp/n and reads it, and lists /tmp.
  ["tmp-use"] = function(_: {string}): integer
    return Steps.env_of("TMPDIR") or Steps.create("/tmp/n", "x") or Steps.cat("/tmp/n") or
      Steps.ls("/tmp") or 0
  end,
  -- Copies program `words[1]` (this fake) to /tmp/mine/p, makes it
  -- executable, names TMPDIR, and runs the copy.
  ["copy-and-run"] = function(words: {string}): integer
    return Steps.mkdirs("/tmp/mine") or Steps.copy(words[1]!, "/tmp/mine/p") or
      Steps.chmod("/tmp/mine/p", "755") or Steps.env_of("TMPDIR") or Steps.run({ "/tmp/mine/p", "print" }) or 0
  end,
  -- Reads /dev/null, and finds /dev/zero there.
  devices = function(_: {string}): integer
    return Steps.cat("/dev/null") or Steps.present("/dev/zero") or 0
  end,
  -- Its Uid, Gid and user map, then makes file `made`.
  ["ids-and-create"] = function(_: {string}): integer
    return Steps.status_field("Uid") or Steps.status_field("Gid") or
      Steps.cat("/proc/self/uid_map") or Steps.create("made", "x") or 0
  end,
  -- Its Uid, directory `words[1]`'s `inside`, and `words[2]` appended to its `made`.
  ["uid-read-append"] = function(words: {string}): integer
    local dir = words[1]!
    return Steps.status_field("Uid") or Steps.cat(dir .. "/inside") or
      Steps.append(dir .. "/made", words[2]!) or 0
  end,
  -- Its Uid, then sleeps `words[1]` milliseconds.
  ["uid-then-sleep"] = function(words: {string}): integer
    return Steps.status_field("Uid") or Steps.sleep(Steps.int(words[1]!)) or 0
  end,
  -- In directory `words[1]`: reads inside, appends more to open, reads
  -- open and third.
  ["read-append-read"] = function(words: {string}): integer
    local dir = words[1]!
    return Steps.cat(dir .. "/inside") or Steps.append(dir .. "/open", "more") or
      Steps.cat(dir .. "/open") or Steps.cat(dir .. "/third") or 0
  end,
  -- In directory `words[1]`: reads inside and makes made holding y;
  -- given `again`, reads made back.
  ["read-create"] = function(words: {string}): integer
    local dir = words[1]!
    local stopped = Steps.cat(dir .. "/inside") or Steps.create(dir .. "/made", "y")
    if stopped ~= nil or words[2] ~= "again" then return stopped or 0 end
    return Steps.cat(dir .. "/made") or 0
  end,
  create = function(words: {string}): integer
    return Steps.create(words[1]!, words[2]!) or 0
  end,
  chmod = function(words: {string}): integer
    return Steps.chmod(words[1]!, words[2]!) or 0
  end,
  -- Each pair of words is a file and its text.
  write = function(words: {string}): integer
    for i = 1, #words, 2 do
      local stopped = Steps.write(words[i]!, words[i + 1]!)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  env = function(names: {string}): integer
    for _, name in ipairs(names) do
      local stopped = Steps.env_of(name)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  rlimits = function(names: {string}): integer
    for _, name in ipairs(names) do
      local stopped = Steps.rlimit(name)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  ["fd-closed"] = function(words: {string}): integer
    return Steps.fd_closed(Steps.int(words[1] or "")) or 0
  end,
  -- Uses the directory the policy's `tmp` gives it: names it, writes
  -- its first word to a note there and reads it back, and, given
  -- `deep`, makes a file two directories down.
  ["use-tmp"] = function(words: {string}): integer
    local tmp = Env.get("TMPDIR") or ""
    local stopped = Steps.env_of("TMPDIR") or Steps.write(tmp .. "/note", words[1]!) or Steps.cat(tmp .. "/note")
    if stopped ~= nil or words[2] ~= "deep" then return stopped or 0 end
    return Steps.mkdirs(tmp .. "/sub/deeper") or Steps.create(tmp .. "/sub/deeper/f", "x") or 0
  end,
  -- Writes `$TMPDIR/f`, then sleeps until it is ended.
  ["write-tmp-and-wait"] = function(_: {string}): integer
    local stopped = Steps.write((Env.get("TMPDIR") or "") .. "/f", "x")
    if stopped ~= nil then return stopped end
    while true do assert(Clock.sleep(Clock.seconds(1))) end
  end,
}

local function main(argv: {string}): integer
  local name = argv[1] or ""
  local words: mut {string} = {}
  for i = 2, #argv do words[#words + 1] = argv[i] end
  if name:sub(1, 1) == "/" then
    local text, trouble = Fs.read(name)
    if text == nil then return Steps.fail(name, tostring(trouble)) end
    return Steps.put(1, text:match("^[^\n]*\n(.*)$") or "") or 0
  end
  local case = cases[name]
  if case == nil then return Steps.fail("child policy fake", "no case " .. name) end
  return case(words)
end

return main
