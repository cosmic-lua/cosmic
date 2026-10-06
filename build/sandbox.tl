--- `cosmic sandbox`: runs a program held to nothing at all but what the
--- command line grants (`cosmic help sandbox`), by [`cosmic.sandbox`]'s
--- policy and [`Child.run`]. This module reads the command line, builds
--- the policy from it and reports how the program ended; what holds the
--- program is [`Child.start`]'s.
---
--- THE COMMAND LINE is read by hand, not by [`Flags.parse`] over the whole
--- line, which would take an option after the program for its own: the
--- first word that is no option, or the one after a `--`, is the program,
--- and every word after it is the program's argument, untouched
--- ([`verb.program_slot`]). The words before it are what [`Flags.parse`] reads,
--- against the options [`cosmic.cli`] names, so `--opt value` and
--- `--opt=value` are both taken and help lists exactly what is read.
---
--- THE POLICY is each flag's field of a [`Sandbox.Policy`], written as the
--- JSON a policy holds and read back by [`PolicyJson.decode`], so a flag is
--- judged by the strict decoder, which names what it refuses by JSON
--- Pointer. There are no policy files: they wait on the design's
--- narrow-only form, since a file is input from elsewhere.
---
--- A SEALED RUN: `--database`, `--modules` and `--closure` each name the
--- database the program runs on ([`Sandbox.Policy`]'s `database`), the
--- program being this program's core and the words after it the main's
--- arguments. `--database` takes a file as it is. `--modules` and
--- `--closure` seal one first, through [`Store.seal`], into a directory
--- of the run's own that the program's user can search, removed when it
--- ends: the named modules (the first the main, and no requires followed),
--- or the closure of the literal requires of a script, compiled here, in this unsealed process,
--- by [`standalone.code`] (what a file run as `--standalone` is) and
--- sealed as the main. A command line that names two of the three, or
--- `--closure` with `--cosmic`, a module no store holds (a script's
--- require of one included) or a `--database` that is not there is refused (2); a script that cannot be read or does
--- not compile, or a seal that cannot be written, is a start that failed
--- (125).
---
--- Like `cosmic json` it ends in no verdict line, and prints nothing of
--- its own when the program starts: its exit status is the program's.
--- That is the program's code; 128 and the signal's number when a signal
--- ended it, as a shell reports it; 124 when `--timeout` ended it. Of its
--- own: 2 for a command line it refuses, 125 for a start that failed
--- (the reason on standard error, `cosmic: sandbox: <reason>`: what the
--- policy needs that this host lacks, or an `--connect`, which waits for
--- the relay), 126 for a program that is there and cannot be run and 127
--- for one that is not.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local ast = require("build.ast")
local bare = require("build.bare")
local plural = require("build.plural")
local standalone = require("build.standalone")
local teal = require("build.teal")
local verb_spec = require("build.verb_spec")

--- The `cosmic sandbox` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` complains and starts: what a test stands in for.
  record Io
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- Runs the program to its end, as [`Child.run`] does, which is what
    --- it is when nil.
    run: function(argv: {string}, opts: Child.Options): Child.Result | nil, string
  end
end

--- The exit status of a program ended for running past `--timeout`, as
--- coreutils' `timeout` gives it.
local TIMED_OUT <const> = 124
--- The exit status of a start that failed.
local START_FAILED <const> = 125
--- The exit status of a program that is there and cannot be run.
local NOT_EXECUTABLE <const> = 126
--- The exit status of a program that is not there.
local NOT_FOUND <const> = 127

local spec = Cli.verbs.sandbox.spec

--- The longest `--timeout`, a year, well inside what a start accepts.
local MOST_SECONDS <const> = 31536000

--- Whether a flag of `spec` takes a value, read as [`Flags.parse`] does.
local function takes_value(name: string): boolean
  local entry = spec[name]
  return entry is Flags.Option and entry.value ~= nil
end

--- The slot of the program in `argv` (the verb at slot 1): the first word
--- after the options that is not one, or the word after a `--`; nil when
--- there is none. An option that takes a value takes the next word, whatever
--- it is, unless the value is attached (`--read=x`); [`Flags.parse`] judges
--- the rest. Everything from the program on is the program's own.
--- @param argv the command line, the verb at slot 1
--- @return the program's slot, or nil
function verb.program_slot(argv: {integer:string}): integer | nil
  local slot = 2
  while argv[slot] ~= nil do
    local word = argv[slot]
    if word == "--" then
      if argv[slot + 1] ~= nil then return slot + 1 end
      return nil
    elseif word:sub(1, 1) ~= "-" or word == "-" then
      return slot
    elseif not word:find("=", 1, true) and takes_value(word) then
      slot = slot + 1
    end
    slot = slot + 1
  end
  return nil
end

--- A whole number from `least` to `most` in decimal, or nil.
local function whole(text: string, least: integer, most: integer): integer | nil
  if not text:match("^%d+$") or #text > 18 then return nil end
  local number = math.tointeger(tonumber(text))
  if number == nil or number < least or number > most then return nil end
  return number
end

--- The options of `spec` that give a limit, each with the field it
--- sets and the least it takes.
local limits <const>: {{string}} = {
  { "--open-files", "open_files", "1" },
  { "--file-bytes", "file_bytes", "0" },
  { "--cpu-seconds", "cpu_seconds", "1" },
  { "--processes", "processes", "1" },
}

--- What the line holds besides the policy.
local record Request
  --- The policy the flags give, as the table a policy's JSON holds.
  policy: {string:any}
  --- `--database`'s path as given, or nil.
  database: string | nil
  --- `--modules`' names, the first the main, or nil.
  modules: {string} | nil
  --- Whether `--closure` was given: the program's first argument is the
  --- script to seal and run.
  closure: boolean
  --- The descriptors to hand the program.
  fds: {integer:integer}
  --- The wall-clock limit, in nanoseconds, or nil for none.
  timeout_ns: integer | nil
  --- The directory the program starts in, which a relative grant or
  --- program is taken from; nil for this process's own.
  cwd: string | nil
  --- The program and its arguments.
  argv: {string}
end

--- The policy `parsed` names, as the table a policy's JSON holds.
local function table_of(parsed: Flags.Parsed): {string:any} | nil, string
  local policy: {string:any} = {}
  local function list(name: string): {string}
    return parsed.all[name] or {}
  end
  local grants: {{string:string}} = {}
  local function grant(name: string, letters: string)
    for _, path in ipairs(list(name)) do
      grants[#grants + 1] = { path = path, letters = letters }
    end
  end
  grant("--read", "r")
  grant("--run", "rx")
  grant("--write", "rwc")
  for _, text in ipairs(list("--path")) do
    local letters, path = text:match("^([^:]*):(.+)$")
    if letters == nil then
      return nil, "--path takes LETTERS:PATH, as rwc:work, not " .. text
    end
    grants[#grants + 1] = { path = path, letters = letters }
  end
  if #grants > 0 then policy.grants = grants end
  local profiles: {string} = {}
  if parsed.set["--system"] then profiles[#profiles + 1] = "system" end
  if parsed.set["--cosmic"] then profiles[#profiles + 1] = "cosmic" end
  if #profiles > 0 then policy.profiles = profiles end
  local function copy(name: string, field: string)
    if #list(name) > 0 then policy[field] = list(name) end
  end
  copy("--isolate", "isolate")
  copy("--promise", "promises")
  copy("--connect", "connect")
  copy("--loopback", "loopback")
  copy("--env", "env")
  if parsed.set["--tmp"] then policy.tmp = true end
  local set_env: {string:string} = {}
  for _, text in ipairs(list("--set-env")) do
    local name, value = text:match("^([^=]+)=(.*)$")
    if name == nil then
      return nil, "--set-env takes NAME=VALUE, as LANG=C, not " .. text
    end
    if set_env[name] ~= nil and set_env[name] ~= value then
      return nil, "--set-env " .. name .. " is given two values"
    end
    set_env[name] = value
  end
  if next(set_env) ~= nil then policy.set_env = set_env end
  local held: {string:integer} = {}
  for _, entry in ipairs(limits) do
    local name, field, least = entry[1], entry[2], math.tointeger(tonumber(entry[3]))
    local given = list(name)
    if #given > 1 then return nil, name .. " is given more than once" end
    if given[1] ~= nil then
      local number = whole(given[1], least, math.maxinteger)
      if number == nil then
        return nil, name .. " takes a whole number, " .. least .. " or more, not " .. given[1]
      end
      held[field] = number
    end
  end
  if next(held) ~= nil then policy.limits = held end
  local users = list("--user")
  if #users > 1 then return nil, "--user is given more than once" end
  if users[1] ~= nil then
    local uid, gid = users[1]:match("^(%d+):(%d+)$")
    if uid == nil then uid = users[1]:match("^(%d+)$") end
    local user = uid ~= nil and whole(uid, 1, 4294967294) or nil
    local group = gid ~= nil and whole(gid, 1, 4294967294) or nil
    if user == nil or (gid ~= nil and group == nil) then
      return nil, "--user takes UID or UID:GID, whole numbers from 1 to 4294967294, not " .. users[1]
    end
    policy.user, policy.group = user, group
  end
  return policy, ""
end

--- The last slot of `argv` that holds a word, the verb's own at slot 1.
local function last_slot(argv: {integer:string}): integer
  local slot = 1
  while argv[slot + 1] ~= nil do slot = slot + 1 end
  return slot
end

--- What `argv` asks for, or nil and why it is refused.
local function request_of(argv: {integer:string}): Request | nil, string
  local at = verb.program_slot(argv)
  local last = at ~= nil and at - 1 or last_slot(argv)
  local words: {integer:string} = {}
  for slot = 2, last do words[slot - 1] = argv[slot] end
  local parsed, trouble = Flags.parse(words, 1, spec)
  if parsed == nil then return nil, trouble end
  local policy, why = table_of(parsed)
  if policy == nil then return nil, why end
  local request: Request = {
    policy = policy, fds = {}, argv = {}, closure = parsed.set["--closure"] == true,
  }
  local databases = parsed.all["--database"] or {}
  if #databases > 1 then return nil, "--database is given more than once" end
  request.database = databases[1]
  local listed = parsed.all["--modules"] or {}
  if #listed > 1 then return nil, "--modules is given more than once" end
  if listed[1] ~= nil then
    local names: {string} = {}
    local seen: {string:boolean} = {}
    for name in (listed[1] .. ","):gmatch("([^,]*),") do
      if name == "" then
        return nil, "--modules takes module names separated by commas, as cosmic.json,cosmic.fs, " ..
          "not " .. listed[1]
      end
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    request.modules = names
  end
  local given: {string} = {}
  if request.closure then given[#given + 1] = "--closure" end
  if request.modules ~= nil then given[#given + 1] = "--modules" end
  if request.database ~= nil then given[#given + 1] = "--database" end
  if #given > 1 then
    return nil, table.concat(given, " and ") .. " are exclusive: each names the database the " ..
      "program runs on, which only one can"
  end
  if request.closure and parsed.set["--cosmic"] then
    return nil, "--closure and --cosmic are exclusive: --closure runs the script on a database of " ..
      "its own, which holds the modules it requires and not this program's file"
  end
  if at == nil then
    if #given == 1 and not request.closure then
      -- No command is this program's core on the database, with no arguments.
      local own, own_trouble = Proc.executable()
      if own == nil then return nil, "this program has no file to run: " .. own_trouble end
      request.argv[1] = own
    elseif request.closure then
      return nil, "--closure runs a script: give this program and then the script after the " ..
        "options, as -- cosmic run.tl"
    else
      return nil, "give a program to run, after the options and a --"
    end
  elseif request.closure and argv[at + 1] == nil then
    return nil, "--closure runs a script: give it after the program, as -- cosmic run.tl"
  end
  for _, text in ipairs(parsed.all["--fd"] or {}) do
    local number = whole(text, 3, 255)
    if number == nil then
      return nil, "--fd takes a descriptor from 3 to 255 (0 to 2 are always the program's), not " .. text
    end
    request.fds[number] = number
  end
  local seconds = parsed.all["--timeout"] or {}
  if #seconds > 1 then return nil, "--timeout is given more than once" end
  if seconds[1] ~= nil then
    local number = whole(seconds[1], 1, MOST_SECONDS)
    if number == nil then
      return nil, "--timeout takes a whole number of seconds, 1 to " .. MOST_SECONDS ..
        ", not " .. seconds[1]
    end
    request.timeout_ns = number * 1000000000
  end
  local cwd = parsed.all["--cwd"] or {}
  if #cwd > 1 then return nil, "--cwd is given more than once" end
  request.cwd = cwd[1]
  if at ~= nil then
    for slot = at, last_slot(argv) do request.argv[#request.argv + 1] = argv[slot] end
  end
  return request, ""
end

--- The policy `request` holds, on `database` where it runs on one, or nil
--- and why it is refused.
local function policy_of(request: Request, database: string | nil): Sandbox.Policy | nil, string
  local fields = request.policy
  if database ~= nil then
    -- The text holds the file's digest as well as its path.
    local bytes, read_trouble = Fs.read(database)
    if bytes == nil then return nil, "sandbox: database " .. read_trouble end
    fields.database = { path = database, sha256 = Hash.hex_sha256(bytes) }
  end
  local json, json_why = Json.encode(fields)
  if json == nil then return nil, json_why end
  return PolicyJson.decode(json)
end

--- `path` as the policy holds a database: absolute, with no "..", from
--- `cwd` (this process's own directory where nil).
local function absolute(path: string, cwd: string | nil): string | nil, string
  if cwd ~= nil and path:sub(1, 1) ~= "/" then path = cwd .. "/" .. path end
  local real, why = sys.realpath(path)
  if real == nil then return nil, path .. ": " .. why end
  return real, ""
end

--- A directory of this run's own, which `held` keeps to be removed after the
--- run, that the user the program runs as can search and read: a root
--- caller's program runs as a user of its own, which the 0700 directory
--- [`Fs.mkdtemp`] makes (and the cache's) is shut to. The directory's
--- parents are the temporary directory's, which must be open to that user
--- too; the start says which is not.
local function scratch(held: {string}): string | nil, string
  if held[1] ~= nil then return held[1], "" end
  local dir, why = Fs.mkdtemp("sandbox-")
  if dir == nil then return nil, why end
  held[1] = dir
  local opened, open_why = sys.chmod(dir, tonumber("755", 8))
  if not opened then return nil, dir .. ": " .. tostring(open_why) end
  return dir, ""
end

--- The module a sealed script is, named `main`: Lua that runs `code`, the
--- Lua of `file`, as `cosmic --standalone` does -- its `arg` the
--- program's, its entry (a function, or a record's `main`) called with
--- them -- and answers its status. The script's own text is on the
--- first line, so an error's line is the file's.
local function script_chunk(file: string, code: string): string
  return string.format("local file = %q return function(args) args[0] = file rawset(_G, 'arg', " ..
      "args) local produced = (function(...) %s\nend)() local main = produced " ..
      "if type(produced) == 'table' then main = produced.main end " ..
      "if type(main) ~= 'function' then return 0 end return main(args) end", file, code)
end

--- Whether `name` is a module the core itself holds ([`cosmic.sys`]), which
--- no database carries and every program has.
local function preloaded(name: string): boolean
  return package.preload[name] ~= nil
end

--- `names` without the core's own modules.
local function stored(names: {string}): {string}
  local out: {string} = {}
  for _, name in ipairs(names) do
    if not preloaded(name) then out[#out + 1] = name end
  end
  return out
end

--- What sealing a program came to: the database's path, or why there is
--- none, and whether the command line is to blame.
local record Sealing
  path: string | nil
  why: string
  refused: boolean
end

--- Seals `names` (the main among them, or `opts.extra`) into a directory
--- of this run's own ([`scratch`]), and answers the database's path there,
--- or why not, and whether the command line is to blame (a name no store
--- holds).
local function sealed(names: {string}, opts: Store.SealOptions, held: {string}): Sealing
  local dir, dir_why = scratch(held)
  if dir == nil then return { why = dir_why, refused = false } end
  local path = dir .. "/program.db"
  local ok, digest, why = pcall(Store.seal, names, path, opts)
  if not ok then
    -- Store.seal raises, with its position, for a name no store holds.
    return { why = (tostring(digest):gsub("^.-:%d+: store: ", ""):gsub("^store: ", "")), refused = true }
  end
  if digest == nil then return { why = why, refused = false } end
  return { path = path, why = "", refused = false }
end

--- Seals the program of `file`, run as `--closure` asks: the closure of
--- the modules its source requires by a literal name (not a type-only
--- require, which Teal erases), and the file compiled as the standalone
--- compiler does, as the main. The database's path, or why not.
local function seal_script(file: string, cwd: string | nil, held: {string}): Sealing
  local at = file
  if cwd ~= nil and file:sub(1, 1) ~= "/" then at = cwd .. "/" .. file end
  local source, read_trouble = Fs.read(at)
  if source == nil then return { why = read_trouble, refused = false } end
  local code, trouble = standalone.code(file, source)
  if code == nil then return { why = trouble, refused = false } end
  local built, load_trouble = teal.load()
  if built == nil then return { why = load_trouble, refused = false } end
  local parsed, parse_trouble = ast.parse(built, source, file)
  if parsed == nil then return { why = parse_trouble, refused = false } end
  local found, roots_trouble = ast.all_requires(built, parsed)
  if found == nil then return { why = roots_trouble, refused = false } end
  -- What the generated Lua names is what the program loads.
  local roots: {string} = {}
  for _, name in ipairs(found) do
    if not preloaded(name) and (code:find('"' .. name .. '"', 1, true) or
        code:find("'" .. name .. "'", 1, true)) then
      roots[#roots + 1] = name
    end
  end
  local ok, names = pcall(Store.closure, roots)
  if not ok then
    return { why = file .. ": " .. (tostring(names):gsub("^.-:%d+: store: ", "")), refused = true }
  end
  local chunk, chunk_trouble = load(script_chunk(file, code), "@" .. file, "t")
  if chunk == nil then return { why = file .. ": " .. tostring(chunk_trouble), refused = false } end
  return sealed(names, { extra = {
    name = "main", bytecode = string.dump(chunk), source = source, requires = roots } }, held)
end

--- What Child adds to a name it could not find, which the verb, that
--- looks a name up on the PATH itself, makes no use of.
local function without_hint(why: string): string
  return (why:gsub(': "[^"]*" is run as a path, with no PATH search; Proc%.find%b() answers ' ..
      'where a shell would find it$', ""))
end

--- The exit status of a start that failed with `why`, and `why` as the
--- verb says it: 127 where the failure is the program not being found,
--- 126 where it is there and this process cannot run it, and otherwise 125,
--- whatever else the program's state is (a grant it lacks, a missing
--- directory).
local function failed_start(program: string, cwd: string | nil, why: string): integer, string
  local said = without_hint(why)
  if program:find("/", 1, true) then
    if cwd ~= nil and program:sub(1, 1) ~= "/" then program = cwd .. "/" .. program end
    local ok, _, errno = sys.access(program, sys.X_OK)
    if not ok and errno == sys.ENOENT and
        said:find(Fs.basename(program) .. ": No such file or directory", 1, true) then
      return NOT_FOUND, said
    elseif not ok and errno == sys.EACCES then
      return NOT_EXECUTABLE, said
    end
    return START_FAILED, said
  end
  local found = Proc.find_result(program)
  if found.kind == "not_found" and said:find(found.reason, 1, true) then return NOT_FOUND, said end
  if found.kind == "not_executable" and said:find(found.reason, 1, true) then
    return NOT_EXECUTABLE, said
  end
  return START_FAILED, said
end

local standard: verb.Io = { err = bare.err, run = Child.run }

--- [`verb.run`], with the directories it makes for a sealed database put
--- in `held`.
local function execute(argv: {integer:string}, io: verb.Io | nil, held: {string}): integer
  local to = io or standard
  local complain = bare.complainer("sandbox", to.err)
  -- TODO: serve `cosmic sandbox connect HOST PORT`, the relay's client
  -- that ssh's ProxyCommand runs, once the relay exists (the design's
  -- phase 6), and delete this refusal. Until then a program named
  -- `connect` runs as `cosmic sandbox -- connect`.
  if argv[2] == "connect" then
    complain("connect is the relay's client, which is not yet available: it needs the relay")
    return START_FAILED
  end
  local request, trouble = request_of(argv)
  if request == nil then
    complain(trouble .. "; see `cosmic help sandbox`")
    return bare.refused
  end
  local database: string | nil
  local sealing: Sealing | nil
  if request.database ~= nil then
    local path, why = absolute(request.database, request.cwd)
    sealing = { path = path, why = why, refused = true }
  elseif request.modules ~= nil then
    -- The first is the main, which the core runs; the rest are what it
    -- requires, as the program's whole set.
    if preloaded(request.modules[1]) then
      sealing = { why = request.modules[1] .. " is the core's own, which has no main to run",
        refused = true }
    else
      sealing = sealed(stored(request.modules), { main = request.modules[1] }, held)
    end
  elseif request.closure then
    sealing = seal_script(request.argv[2], request.cwd, held)
    -- The script is the program's main, whose arguments are the rest.
    if sealing.path ~= nil then table.remove(request.argv, 2) end
  end
  if sealing ~= nil then
    if sealing.path == nil then
      complain(sealing.refused and sealing.why .. "; see `cosmic help sandbox`" or sealing.why)
      return sealing.refused and bare.refused or START_FAILED
    end
    database = sealing.path
  end
  local policy, why = policy_of(request, database)
  if policy == nil then
    -- The module's own name, which the verb's repeats.
    complain((why:gsub("^sandbox: ", "")))
    return bare.refused
  end
  local run = to.run or Child.run
  -- TODO: have the child end with this process where this one is ended by
  -- SIGKILL, which no handler sees: PR_SET_PDEATHSIG in the child, once
  -- Child.Options has an option for it. Until then only SIGINT and SIGTERM
  -- (Child.run's guard) end it, and a killed verb leaves it running.
  local result, started = run(request.argv, {
    policy = policy, fds = request.fds, timeout_ns = request.timeout_ns, cwd = request.cwd,
  })
  if result == nil then
    local code, said = failed_start(request.argv[1], request.cwd, started)
    complain(said)
    return code
  end
  if result.timed_out then
    complain("timed out after " .. plural.count(request.timeout_ns // 1000000000, "second"))
    return TIMED_OUT
  end
  return Child.shell_status(result)
end

--- Runs the command line `argv`, the verb at slot 1, and answers the
--- exit status ([`build/sandbox.tl`]'s head says what each means).
--- @param argv the command line
--- @param io where it complains and starts, or the process's own
--- @return the exit status
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  -- The directory a sealed database was written in, removed whatever the
  -- run's end.
  local held: {string} = {}
  local status = execute(argv, io, held)
  if held[1] ~= nil then
    local _, _ = Fs.remove_tree(held[1])
  end
  return status
end

verb.spec = {
  name = "sandbox",
  guide = "a program held to what you grant it",
  tests = { "build.sandbox_test", "build.sandbox_tool_test", "build.sandbox_seal_tool_test",
    "build.sandbox_closure_tool_test" },
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  program_slot = verb.program_slot,
  takes = "options, then a program and its arguments",
  exits = "`sandbox` prints nothing of its own when the program starts and exits with the program's status, 128 and the signal's number when a signal ended it, or 124 when `--timeout` did; it exits 2 when it refuses its command line, 125 when the start failed, 126 when the program cannot be run and 127 when it is not there.",
  passthrough = "its output and exit status are the program's (build/sandbox_test.tl)",
}

return verb
