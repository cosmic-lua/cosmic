--- `cosmic --standalone <file.tl> [args...]`: one file, run against
--- this binary's own embedded standard library and nothing else.
---
--- `cosmic <file.tl>` builds the tree the file sits in first -- stages
--- it into `o/`, compiles every module it holds, and refuses to go on
--- when the running binary is stale against that tree. That is right
--- for a project, and wrong for a script whose job is to repair the
--- tree: `bin/zig`, which rebuilds a stale core, cannot itself need a
--- fresh one. A standalone run reads the one file, checks and compiles
--- it in memory with the embedded compiler, and calls it. Nothing is
--- staged, nothing under `o/` is written, the tree around the file is
--- never read, and the binary's age against that tree does not matter.
---
--- Checking a file types every standard module it requires, which
--- costs far more than running it, so a clean compile is remembered:
--- its Lua is kept under `$XDG_CACHE_HOME/cosmic/standalone` (default
--- `$HOME/.cache/cosmic/standalone`), named by the sha256 of this
--- binary's own boot hash and the file's bytes, so a different binary
--- or a single changed byte compiles afresh. That cache is the one
--- thing a run writes; one that cannot be written is skipped. Cached
--- Lua is run without another check, so the cache lives only where
--- `Fs.cache_dir` vouches no other user can write -- a directory of
--- this user's own, 0700 when made, never a shared fallback such as
--- `/tmp` -- and each file is written 0600; with no such directory
--- (neither variable set, say) every run compiles afresh.
---
--- The file may require `cosmic.*` modules only -- the binary's own,
--- typed from its own sources -- and a `require` of anything else is
--- refused by the checker. The checker is as strict as a tree build's:
--- a warning is refused along with an error.
---
--- What the file returns is its entry point, called as `cosmic
--- <file.tl>` calls one (see `argv`): a function, or a record whose
--- `main` field is one -- the shape that lets a test `require` the same
--- file for its parts.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Removed = require("cosmic.removed")
local Store = require("cosmic.store")
local teal = require("build.teal")
local type compiler = require("build.compiler")

local record standalone
  --- A loaded chunk, or the entry point one returns.
  type Main = function(...: any): (any...)
end

--- A checker environment that answers `cosmic.*` from this binary's own
--- sources and nothing else: no path is searched.
local function environment(built: compiler): compiler.Env | nil, string
  teal.serve_standard(built)
  local env, trouble = built.new_env({
    defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
  })
  if env == nil then
    return nil, trouble
  end
  for _, name in ipairs(Removed.order) do
    env.globals[name] = nil
    env.modules[name] = nil
  end
  return env, ""
end

--- Where a clean compile of `source` by this binary is kept: nil when
--- there is no cache directory `Fs.cache_dir` will vouch for, and so
--- no cache.
local function cached_path(source: string): string | nil
  local dir, _ = Fs.cache_dir("standalone")
  if dir == nil then
    return nil
  end
  local key = Hash.hex_sha256((Store.meta("boot_hash") or "") .. "\0" .. source)
  return dir .. "/" .. key .. ".lua"
end

--- `code`, loaded as `file`'s chunk.
local function loaded(file: string, code: string): standalone.Main | nil, string
  local chunk, chunk_trouble = load(code, "@" .. file, "t")
  if chunk == nil then
    return nil, file .. ": " .. tostring(chunk_trouble)
  end
  return chunk, ""
end

--- `file`'s Teal, checked and compiled to Lua: nil and every complaint
--- the checker has when it is not clean.
local function generate(file: string, source: string): string | nil, string
  local built, load_trouble = teal.load()
  if built == nil then
    return nil, load_trouble
  end
  local env, env_trouble = environment(built)
  if env == nil then
    return nil, env_trouble
  end
  local code, result = built.gen(source, env, nil, "tl")
  local lines: {string} = {}
  if result ~= nil then
    for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
      for _, e in ipairs(group or {}) do
        local where = (e.filename == nil or e.filename == "") and file or e.filename
        local instead = where == file and teal.replacement(e.msg, source, e.y, e.x) or nil
        lines[#lines + 1] = where .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg ..
          (instead ~= nil and " -- " .. instead or "")
      end
    end
  end
  if code == nil or #lines > 0 then
    if #lines == 0 then
      lines[1] = file .. ": the compiler refused it"
    end
    return nil, table.concat(lines, "\n")
  end
  return code, ""
end

--- `file`'s Teal, checked and compiled to a loaded chunk -- from the
--- cache when this binary compiled these exact bytes cleanly before.
function standalone.compile(file: string, source: string): standalone.Main | nil, string
  local cached = cached_path(source)
  local code: string
  if cached ~= nil then
    -- A cache that cannot be read is a miss.
    local read, _ = Fs.read(cached)
    code = read
  end
  if code == nil then
    local generated, trouble = generate(file, source)
    if generated == nil then
      return nil, trouble
    end
    code = generated
    if cached ~= nil then
      local _, _ = Fs.write(cached, code, 0x180)
    end
  end
  return loaded(file, code)
end

--- The entry point `produced` names: itself when it is a function, its
--- `main` field when that is one, nil otherwise.
function standalone.entry(produced: any): standalone.Main | nil
  if produced is standalone.Main then
    return produced
  end
  if produced is {string: any} then
    local main: any = produced.main
    if main is standalone.Main then
      return main
    end
  end
  return nil
end

--- Runs `argv[2]` standalone: `argv` is the whole command line, `cosmic`
--- at slot 0 and `--standalone` at slot 1, so the file sees what follows
--- its own path, and its path at `argv[0]`.
function standalone.run(argv: {integer:string}): integer
  local file = argv[2]
  if file == nil then
    local _, _ = Fs.put(Fs.stderr, "cosmic: usage: cosmic --standalone <file.tl> [args...]\n")
    return 2
  end
  local source, read_trouble = Fs.read(file)
  if source == nil then
    local _, _ = Fs.put(Fs.stderr, "cosmic: " .. read_trouble .. "\n")
    return 1
  end
  local chunk, trouble = standalone.compile(file, source)
  if chunk == nil then
    local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
    return 1
  end
  local main = standalone.entry(chunk())
  if main == nil then
    return 0
  end
  local arguments: {integer:string} = { [0] = file }
  local slot = 3
  while argv[slot] ~= nil do
    arguments[slot - 2] = argv[slot]
    slot = slot + 1
  end
  -- TODO: judge what main returns as cmd/cosmic/main.tl's `exit_status`
  -- does for a file run and -e, complaining with the file's name; until
  -- then an integer out of range reaches the core, which names
  -- cmd.cosmic.main, and text, a table or a float is 0. The fix moves
  -- `exit_status` to a module both can require.
  local status: any = main(arguments)
  if status is integer then
    return status
  end
  return 0
end

return standalone
