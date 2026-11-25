--- The fake of core/grants_child_test.tl, run as a [`cosmic.fake`]
--- main under each set of grants the test checks. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("build.fake_steps")

local int = Steps.int

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  cat = function(words: {string}): integer return Steps.cat(words[1]!) or 0 end,
  ls = function(words: {string}): integer return Steps.ls(words[1]!) or 0 end,
  -- File `words[1]`, then the names in directory `words[2]`.
  ["cat-ls"] = function(words: {string}): integer
    return Steps.cat(words[1]!) or Steps.ls(words[2]!) or 0
  end,
  writable = function(words: {string}): integer return Steps.writable(words[1]!) or 0 end,
  truncate = function(words: {string}): integer return Steps.truncate(words[1]!) or 0 end,
  -- Opens `words[1]` to write, and only then empties it.
  ["writable-truncate"] = function(words: {string}): integer
    return Steps.writable(words[1]!) or Steps.truncate(words[1]!) or 0
  end,
  ["truncate-unwritten"] = function(words: {string}): integer
    return Steps.truncate_unwritten(words[1]!) or 0
  end,
  create = function(words: {string}): integer return Steps.create(words[1]!, words[2]!) or 0 end,
  mkdirs = function(words: {string}): integer return Steps.mkdirs(words[1]!) or 0 end,
  mkfifo = function(words: {string}): integer return Steps.mkfifo(words[1]!) or 0 end,
  rm = function(words: {string}): integer return Steps.rm(words[1]!) or 0 end,
  rename = function(words: {string}): integer return Steps.rename(words[1]!, words[2]!) or 0 end,
  -- In directory `words[1]`: makes a file, directories, a pipe; renames
  -- the file and removes it and the deepest directory.
  ["make-and-remove"] = function(words: {string}): integer
    local dir = words[1]!
    return Steps.create(dir .. "/new", "hello") or Steps.mkdirs(dir .. "/sub/deeper") or
      Steps.mkfifo(dir .. "/fifo") or Steps.rename(dir .. "/new", dir .. "/renamed") or
      Steps.rm(dir .. "/renamed") or Steps.rmdir(dir .. "/sub/deeper") or 0
  end,
  -- Runs the program and words that follow, as a shell runs one.
  run = function(argv: {string}): integer return Steps.run(argv) or 0 end,
  connect = function(words: {string}): integer return Steps.connect(words[1]!) or 0 end,
  ["connect-tcp"] = function(words: {string}): integer
    return Steps.connect_tcp(words[1]!, int(words[2]!)) or 0
  end,
  ["sleep-forever"] = function(_: {string}): integer return Steps.sleep_forever() end,
  -- Sends signal `words[1]` to pid `words[2]`, or to itself.
  signal = function(words: {string}): integer
    local pid = words[2]
    return Steps.signal(words[1]!, if pid ~= nil then int(pid) else nil end) or 0
  end,
  -- Writes its pid to `words[1]`, then sleeps until it is ended.
  ["write-pid-and-sleep"] = function(words: {string}): integer
    return Steps.write_pid(words[1]!) or Steps.sleep_forever()
  end,
  -- Starts program `words[1]` (this fake) to write its pid to the file
  -- `words[2]` and sleep, waits for that file, and sends the pid SIGKILL.
  ["start-and-kill"] = function(words: {string}): integer
    local stopped = Steps.start({ words[1]!, "write-pid-and-sleep", words[2]! }) or Steps.wait_for(words[2]!)
    if stopped ~= nil then return Steps.finish(stopped) end
    local pid = Steps.pid_in(words[2]!)
    if pid == nil then return Steps.finish(1) end
    return Steps.finish(Steps.signal("KILL", pid) or 0)
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("grants child fake", cases, argv)
end

return main
