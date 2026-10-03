--- `cosmic sandbox` (build/sandbox.tl) starting this program, past its
--- launcher, in each sandbox it offers: what the program is given, what
--- it is not, and that its exit status is the verb's. The verb runs in
--- this process; its start hands the program what this program needs
--- to start (build.this_program). Where the host refuses a sandbox the
--- verb exits 125, saying why, and the case is skipped where the
--- platform could have given one (build.sandbox_skip).

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local confine = require("build.confine")
local sandbox = require("build.sandbox")
local sandbox_skip = require("build.sandbox_skip")
local this_program = require("build.this_program")

--- The program itself (`tool`), which the verb starts; /proc, which it
--- reads of itself; and `nests`, for a program in a root of its own.
Test.needs{ host = { "/proc" }, tool = true, nests = true }

local record Ran
  code: integer
  out: string
  err: string
end

--- Runs `cosmic sandbox <options> -- <this program> -e <chunk> <args>`,
--- the program given what it needs to start, its output in `tmp`.
local function run(tmp: string, options: {string}, chunk: string, args?: {string}): Ran
  local started = this_program.program({ "-e", chunk })
  local argv: {integer:string} = { [0] = "cosmic", [1] = "sandbox" }
  local count = 1
  local function add(word: string)
    count = count + 1
    argv[count] = word
  end
  for _, path in ipairs(confine.itself()) do
    add("--read")
    add(path)
  end
  for _, word in ipairs({ "--read", "/proc", "--write", "/dev/null" }) do add(word) end
  for _, word in ipairs(options) do add(word) end
  add("--")
  for _, word in ipairs(started.argv) do add(word) end
  for _, word in ipairs(args or {}) do add(word) end
  local out_path = tmp .. "/out"
  local out = assert(Fs.open_write(out_path))
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = sandbox.run(argv, {
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    start = function(command: {string}, opts: Child.Options): Child.Handle | nil, string
      opts.stdout = out
      opts.stderr = out
      opts.env = started.options.env
      opts.fds = started.options.fds
      return Child.start(command, opts)
    end,
  })
  assert(Fs.close(out))
  ran.out = assert(Fs.read(out_path))
  return ran
end

--- Whether `ran` is a sandbox the host refused, skipping the test
--- where the platform could have given one.
local function refused(ran: Ran): boolean
  if ran.code ~= sandbox.NOT_STARTED then return false end
  sandbox_skip.refused("no sandbox for the program: " .. ran.err)
  return true
end

--- What the chunk reports of the given file and the hidden one, each
--- by its absolute name.
local REPORT <const> = 'local Fs = require("cosmic.fs") local given, hidden = ... ' ..
  'Fs.put(1, (Fs.read(given) or select(2, Fs.read(given))) .. "\\n" .. ' ..
  '(Fs.read(hidden) == nil and "hidden-unread" or "hidden-read") .. "\\n") return 7'

local function files(tmp: string): string, string
  local given, hidden = tmp .. "/given", tmp .. "/hidden"
  assert(Fs.mkdirs(given))
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(given .. "/f", "in"))
  assert(Fs.write(hidden .. "/f", "out"))
  return given, hidden
end

local function test_unveiled_the_program_reads_only_what_it_is_given(tmp: string)
  local given, hidden = files(tmp)
  local ran = run(tmp, { "--read", given, "--offline" }, REPORT, { given .. "/f", hidden .. "/f" })
  if refused(ran) then return end
  assert(ran.code == 7, tostring(ran.code) .. ": " .. ran.err .. ran.out)
  assert(ran.out == "in\nhidden-unread\n", ran.out)
end

local function test_landlocked_the_program_reads_only_what_it_is_given(tmp: string)
  local given, hidden = files(tmp)
  local ran = run(tmp, { "--landlock", "--read", given }, REPORT, { given .. "/f", hidden .. "/f" })
  if refused(ran) then return end
  assert(ran.code == 7, tostring(ran.code) .. ": " .. ran.err .. ran.out)
  assert(ran.out == "in\nhidden-unread\n", ran.out)
end

--- A program a signal ends exits 128 plus its number, as a shell has it.
local function test_a_program_a_signal_ends_exits_128_and_its_number(tmp: string)
  local ran = run(tmp, { "--landlock" }, 'local sys = require("cosmic.sys") ' ..
    'sys.kill(sys.getpid(), sys.SIGKILL)')
  if refused(ran) then return end
  assert(ran.code == 128 + 9, tostring(ran.code) .. ": " .. ran.err .. ran.out)
end
