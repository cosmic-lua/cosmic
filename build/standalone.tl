--- `cosmic --standalone <file.tl> [args...]`: one file, run against
--- this binary's own embedded standard library and nothing else.
---
--- `cosmic <file.tl>` builds the tree the file sits in first -- stages
--- it into its build directory, compiles every module it holds, and refuses to go on
--- when the running binary is stale against that tree. That is right
--- for a project, and wrong for a script whose job is to repair the
--- tree: [`bin/zig`], which rebuilds a stale core, cannot itself need a
--- fresh one. A standalone run reads the one file, checks and compiles
--- it in memory with the embedded compiler, and calls it. Nothing is
--- staged, no build directory is written, the tree around the file is
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
--- [`Fs.cache_dir`] vouches no other user can write -- a directory of
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
--- file for its parts. What that returns is the exit status, judged as
--- a file run's is (build/exit_status.tl): nil is 0, and anything but a
--- whole number from 0 to 255, or text naming one, is complained about
--- with the file's name and exits 2.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")
local Globals = require("cosmic.internal.globals")
local GrammarMode = require("build.grammar_mode")
local exit_status = require("build.exit_status")
local log = require("build.logger").log
local Pipeline = require("build.pipeline")

local record standalone
  --- A loaded chunk, or the entry point one returns.
  type Main = function(...: any): (any...)
end

--- Where a clean compile of `source` by this binary is kept: nil when
--- there is no cache directory [`Fs.cache_dir`] will vouch for, and so
--- no cache.
local function cached_path(source: string, variables?: {string:string}): string?
  local dir, _ = Fs.cache_dir("standalone", { environment = variables })
  if dir == nil then
    return nil
  end
  local key = Hash.hex_sha256((Store.meta("boot_hash") or "") .. "\0grammar-new\0" .. source)
  return dir .. "/" .. key .. ".lua"
end

--- `code`, loaded as `file`'s chunk.
local function loaded(file: string, code: string): standalone.Main?, string
  local chunk, chunk_trouble = load(code, "@" .. file, "t", Globals.table())
  if chunk == nil then
    return nil, file .. ": " .. tostring(chunk_trouble)
  end
  return chunk, ""
end

--- `file`'s Teal, checked and compiled to Lua by the new checker ([`build.pipeline`]): nil and every complaint it has when
--- the file is not clean. The standard library's declarations are the new checker's, the ones the tool carries
--- ([`build.checker_declarations`]).
local function generate_new(file: string, source: string, options: Pipeline.Options): string?, string
  return Pipeline.lone(file, source, options)
end

--- `file`'s Teal, checked and compiled to Lua -- from the cache when this
--- binary compiled these exact bytes cleanly before, and kept there when
--- not. The cache is found through `variables` when given (as
--- [`Fs.cache_dir`] finds it), and this process's own otherwise. nil and
--- every complaint of the checker when the file is not clean. Every check
--- creates its own program; previous declarations are not shared. The new
--- checker ([`build.pipeline`]) holds the file to no ceiling and takes `cosmic.*` from this binary. A
--- `COSMIC_GRAMMAR` that names another checker is refused ([`build.grammar_mode`]).
function standalone.code(file: string, source: string, variables?: {string:string}): string?, string
  local mode, mode_trouble = GrammarMode.mode()
  if mode == nil then
    return nil, mode_trouble
  end
  -- What the checker reads besides the file is the declarations of the standard library, which the tool carries (so
  -- they are part of the binary the cache name holds).
  local options, trouble = Pipeline.alone()
  if options == nil then
    return nil, file .. ": " .. trouble
  end
  local cached = cached_path(source, variables)
  local code: string?
  if cached ~= nil then
    -- A cache that cannot be read is a miss.
    local read, _ = Fs.read(cached)
    code = read
  end
  if code == nil then
    local generated, generate_trouble = generate_new(file, source, options)
    if generated == nil then
      return nil, generate_trouble
    end
    code = generated
    if cached ~= nil then
      local _, _ = Fs.write(cached, code, 0x180)
    end
  end
  return code, ""
end

--- The modules `source`, which is `file`'s Teal, requires by a literal name, in the order they stand: read by the syntax tree
--- of the checker that compiles the file ([`standalone.code`]). nil and why where the file does not parse.
function standalone.requires(file: string, source: string): {string}?, string
  local mode, mode_trouble = GrammarMode.mode()
  if mode == nil then
    return nil, mode_trouble
  end
  return Pipeline.requires(file, source)
end

--- `file`'s Teal, checked and compiled to a loaded chunk ([`standalone.code`],
--- loaded as `file`'s).
function standalone.compile(file: string, source: string, variables?: {string:string}): standalone.Main?, string
  local code, trouble = standalone.code(file, source, variables)
  if code == nil then
    return nil, trouble
  end
  return loaded(file, code)
end

--- The entry point `produced` names: itself when it is a function, its
--- `main` field when that is one, nil otherwise.
function standalone.entry(produced: any): standalone.Main?
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

--- Runs `argv[2]` standalone: `argv` is the whole command line, `--standalone`
--- at slot 1, so the file sees what follows its own path, and its path at
--- `argv[0]`. `why`, where given, says what made this run standalone, which
--- a file that does not compile is told beside its refusal: a require of a
--- module that is not `cosmic.*` is refused here and not in the run the
--- caller may have meant.
function standalone.run(argv: {string}, why?: string): integer
  local file = argv[2]
  if file == nil then
    log:complain("usage: cosmic --standalone <file.tl> [args...]")
    return 2
  end
  local source, read_trouble = Fs.read(file)
  if source == nil then
    log:complain(read_trouble)
    return 1
  end
  local chunk, trouble = standalone.compile(file, source)
  if chunk == nil then
    local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
    if why ~= nil then
      local _, _ = Fs.put(Fs.stderr, "cosmic: " .. why .. "\n")
    end
    return 1
  end
  local arguments: mut {string} = { table.unpack(argv, 3) }
  arguments[0] = file
  -- Its top level finds them in `arg`, as `lua file a b` gives them.
  rawset(_G as {string:any}, "arg", arguments)
  local main = standalone.entry(chunk())
  if main == nil then
    return 0
  end
  return exit_status.of(file, main(arguments))
end

return standalone
