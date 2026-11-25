--- The fake of core/promises_child_test.tl, run as a [`cosmic.fake`]
--- main under each set of promises the test checks. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("build.fake_steps")

local function int(word: string): integer
  return math.tointeger(tonumber(word)) or -1
end

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  -- What the basics allow, in directory `words[1]`: prints, writes,
  -- appends and reads file f, makes d/e and a pipe, shows f's mode and
  -- d's names, and the filter's status fields.
  basics = function(words: {string}): integer
    local dir = words[1]!
    return Steps.print("hello") or Steps.write(dir .. "/f", "world") or
      Steps.append(dir .. "/f", "again") or Steps.cat(dir .. "/f") or Steps.mkdirs(dir .. "/d/e") or
      Steps.mkfifo(dir .. "/fifo") or Steps.mode(dir .. "/f") or Steps.ls(dir .. "/d") or
      Steps.status_field("Seccomp") or Steps.status_field("NoNewPrivs") or 0
  end,
  -- Sends signal `words[1]` to pid `words[2]`, or to itself.
  signal = function(words: {string}): integer
    local pid = words[2]
    return Steps.signal(words[1]!, if pid ~= nil then int(pid) else nil end) or 0
  end,
  ["sleep-forever"] = function(_: {string}): integer return Steps.sleep_forever() end,
  -- Runs the program and words that follow, as a shell runs one.
  run = function(argv: {string}): integer return Steps.run(argv) or 0 end,
  chmod = function(words: {string}): integer return Steps.chmod(words[1]!, words[2]!) or 0 end,
  connect = function(words: {string}): integer return Steps.connect(words[1]!) or 0 end,
  ["connect-tcp"] = function(words: {string}): integer
    return Steps.connect_tcp(words[1]!, int(words[2]!)) or 0
  end,
  setrlimit = function(words: {string}): integer
    return Steps.setrlimit(words[1]!, int(words[2]!)) or 0
  end,
  -- Sets limit `words[1]` to `words[2]`, then to `words[3]`.
  ["set-twice"] = function(words: {string}): integer
    return Steps.setrlimit(words[1]!, int(words[2]!)) or Steps.setrlimit(words[1]!, int(words[3]!)) or 0
  end,
  rlimit = function(words: {string}): integer return Steps.rlimit(words[1]!) or 0 end,
  ["status-field"] = function(words: {string}): integer
    return Steps.status_field(words[1]!) or 0
  end,
}

local function main(argv: {string}): integer
  local name = argv[1] or ""
  local words: mut {string} = {}
  for i = 2, #argv do words[#words + 1] = argv[i] end
  local case = cases[name]
  if case == nil then return Steps.fail("promises child fake", "no case " .. name) end
  return case(words)
end

return main
