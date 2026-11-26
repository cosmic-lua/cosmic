--- The fake of core/syscalls_tool_test.tl, a [`cosmic.fake`] main a
--- confined child runs. Its first argument names the case and the rest
--- are that case's words.

local Steps = require("cosmic.fake.steps")

local int = Steps.int

--- Prints `yes` where `step` goes on and `no` where it fails, saying
--- nothing of the failure.
local function either(step: function(): integer?, yes: string, no: string): integer?
  return Steps.print(if Steps.attempt(step) then yes else no end)
end

--- Prints `text` where `step` fails, saying nothing of the failure: the
--- `step || print text` of a shell.
local function unless(step: function(): integer?, text: string): integer?
  if Steps.attempt(step) then return nil end
  return Steps.print(text)
end

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  -- Ends with status `words[1]`, or 2 where it names none.
  exit = function(words: {string}): integer return math.tointeger(tonumber(words[1] or "")) or 2 end,
  cat = function(words: {string}): integer return Steps.cat(words[1]!) or 0 end,
  sleep = function(words: {string}): integer return Steps.sleep(int(words[1]!)) or 0 end,
  -- Run from directory `tmp`, with `words[1]` the real path of link's
  -- target: what of the paths given it reads and writes.
  unveiled = function(words: {string}): integer
    local real = words[1]!
    return Steps.cat("link/f") or Steps.print("") or
      either(function(): integer? return Steps.present("out/f") end, "outside-seen", "outside-absent") or
      Steps.cat(real .. "/f") or Steps.print("") or
      unless(function(): integer? return Steps.write("link/g", "x") end, "read-only") or
      Steps.write("w/f", "w") or Steps.cat("w/f") or Steps.status_field("CapEff") or
      unless(function(): integer?
        return Steps.present("/proc/self/net/dev") or Steps.grep_count("/proc/self/net/dev", ":")
      end, "1") or 0
  end,
  -- What it has of /dev/fd, of directory `words[1]` made above a path
  -- given, of its /tmp, and of /proc.
  mirrored = function(words: {string}): integer
    return Steps.present("/dev/fd/0") or Steps.print("fd") or Steps.mode(words[1]!) or
      Steps.list("/tmp") or Steps.write("/tmp/f", "t") or Steps.cat("/tmp/f") or
      either(function(): integer? return Steps.present("/proc/sys") end, "host-proc", "own-proc") or
      either(function(): integer? return Steps.writable("/proc/self/uid_map") end, "own-writable", "own-read-only") or
      unless(function(): integer? return Steps.writable("/proc/sys/vm/swappiness") end, "sys-read-only") or 0
  end,
  -- Its ids, capabilities, user map and mounts, each section named, and
  -- the Uid that program `words[1]`, a setuid copy of this fake, runs as.
  ids = function(words: {string}): integer
    return Steps.status_field("Uid") or Steps.status_field("Gid") or Steps.status_field("Groups") or
      Steps.status_field("CapEff") or Steps.print("uid_map") or Steps.cat("/proc/self/uid_map") or
      Steps.print("mountinfo") or Steps.cat("/proc/self/mountinfo") or Steps.print("setuid") or
      Steps.run({ words[1]!, "status-field", "Uid" }) or 0
  end,
  ["status-field"] = function(words: {string}): integer
    return Steps.status_field(words[1]!) or 0
  end,
  -- Says `first` where `words[1]` is there, then `last` where `words[2]` is.
  ["first-and-last"] = function(words: {string}): integer
    return Steps.present(words[1]!) or Steps.print("first") or Steps.present(words[2]!) or
      Steps.print("last") or 0
  end,
  -- Run in /tree, with `words[1]` the tree's path on the host: what it
  -- reads and writes at the paths it was given them at.
  placed = function(words: {string}): integer
    return Steps.cat("sub/f") or Steps.print("") or Steps.cwd() or
      either(function(): integer? return Steps.present(words[1]!) end, "own-name", "no-own-name") or
      Steps.write("/tmp/g", "w") or Steps.print("tmp-written") or
      unless(function(): integer? return Steps.write("sub/g", "x") end, "tree-read-only") or 0
  end,
  -- Its pid, as its /proc says, and that /proc's mounts.
  ["pid-and-mounts"] = function(_: {string}): integer
    return Steps.status_field("Pid") or Steps.cat("/proc/self/mountinfo") or 0
  end,
  -- Its pid; whether it killed pid `words[1]`, outside it, and sees it;
  -- its init's name and what its /proc lists.
  outside = function(words: {string}): integer
    local pid = words[1]!
    return Steps.status_field("Pid") or
      either(function(): integer? return Steps.signal("KILL", int(pid)) end, "killed", "spared") or
      either(function(): integer? return Steps.present("/proc/" .. pid) end, "seen", "unseen") or
      Steps.cat("/proc/1/comm") or Steps.list("/proc") or 0
  end,
  -- Sends itself SIGTERM; ends with 3 where that did not end it.
  ["signal-then-exit"] = function(_: {string}): integer return Steps.signal("TERM") or 3 end,
  -- Starts the program and words that follow, leaving it running.
  start = function(argv: {string}): integer return Steps.finish(Steps.start(argv) or 0) end,
  -- Starts the program and words that follow, then says `started`.
  ["start-then-print"] = function(argv: {string}): integer
    return Steps.finish(Steps.start(argv) or Steps.print("started") or 0)
  end,
  -- Runs program `words[1]` (this fake) to start a copy that sleeps and
  -- outlives it, an orphan; then sleeps, and shows its init's name and
  -- what its /proc lists.
  orphan = function(words: {string}): integer
    local program = words[1]!
    return Steps.run({ program, "start", program, "sleep", "100" }) or Steps.sleep(1000) or
      Steps.cat("/proc/1/comm") or Steps.list("/proc") or 0
  end,
  -- Each file of /proc that opens to write, then `done`.
  ["find-writable"] = function(_: {string}): integer
    return Steps.find_writable("/proc") or Steps.print("done") or 0
  end,
  -- Whether /proc/sys's swappiness and hostname open to write.
  ["proc-writes"] = function(_: {string}): integer
    return either(function(): integer? return Steps.writable("/proc/sys/vm/swappiness") end,
      "sys-writable", "sys-read-only") or
      either(function(): integer? return Steps.writable("/proc/sys/kernel/hostname") end,
        "name-writable", "name-read-only") or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls tool fake", cases, argv)
end

return main
