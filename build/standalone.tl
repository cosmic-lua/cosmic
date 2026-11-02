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
--- `cosmic --standalone --check <file.tl>` types the file as a run does, prints the same refusals and exits 1 on any, 0 when
--- there are none, and never calls the file: a gate on one script that reads neither the tree around it nor its siblings.
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
local type importer = require("build.importer")
local log = require("build.logger").log
local Pipeline = require("build.pipeline")

local record standalone
  --- A loaded chunk, or the entry point one returns.
  type Main = function(...: any): (any...)
end

--- Where a clean compile of `source` by this binary is kept: nil when
--- there is no cache directory [`Fs.cache_dir`] will vouch for, and so
--- no cache.
local function cached_path(source: string, variables?: {string:string}, own?: boolean): string?
  local dir, _ = Fs.cache_dir("standalone", { environment = variables })
  if dir == nil then
    return nil
  end
  -- A chunk that takes the tool's own modules is checked against more than a file is, so its Lua is kept apart.
  local key = Hash.hex_sha256((Store.meta("boot_hash") or "") .. "\0grammar-new\0" .. (if own == true then "own\0" else "" end) ..
      source)
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

--- `file`'s Teal, checked and compiled to Lua -- from the cache when this
--- binary compiled these exact bytes cleanly before, and kept there when
--- not. The cache is found through `variables` when given (as
--- [`Fs.cache_dir`] finds it), and this process's own otherwise. nil and
--- every complaint of the checker when the file is not clean. Every check
--- creates its own program; previous declarations are not shared. The new
--- checker ([`build.pipeline`]) holds the file to no ceiling and takes `cosmic.*` from this binary. A
--- `COSMIC_GRAMMAR` that names another checker is refused ([`build.grammar_mode`]). With `own`, as `cosmic -e` asks, the file
--- may also require the tool's own modules, which the checker types from their sources ([`build.standard_text`]'s `own`),
--- and it is checked each time and kept nowhere.
function standalone.code(file: string, source: string, variables?: {string:string}, own?: boolean,
                         outcome?: importer.Outcome): string?, string
  local mode, mode_trouble = GrammarMode.mode()
  if mode == nil then
    return nil, mode_trouble
  end
  -- A chunk of `-e` is not kept: it is checked against more than a file is, runs once and is written afresh each time.
  local cached: string? = nil
  if own ~= true then cached = cached_path(source, variables) end
  local code: string?
  if cached ~= nil then
    -- A cache that cannot be read is a miss.
    local read, _ = Fs.read(cached)
    code = read
  end
  if code == nil then
    -- What the checker reads besides the file is the declarations of the standard library, which the tool carries (so
    -- they are part of the binary the cache name holds), read only for a file the cache does not hold.
    local options, trouble = Pipeline.alone()
    if options == nil then
      return nil, file .. ": " .. trouble
    end
    if own == true then
      options = { globals = options.globals, ceilings = options.ceilings, types = options.types,
        standard = Pipeline.carried_own(), project = options.project }
    end
    local generated, generate_trouble = Pipeline.lone(file, source, options)
    if generated == nil then
      if outcome ~= nil then outcome.refused = true end
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
--- loaded as `file`'s), `own` and `outcome` as it says there.
function standalone.compile(file: string, source: string, variables?: {string:string}, own?: boolean,
                            outcome?: importer.Outcome): standalone.Main?, string
  local code, trouble = standalone.code(file, source, variables, own, outcome)
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

--- The first module `file` requires by a literal name that is no `cosmic.*` module but a file of the project the file sits
--- in: found as `<name>.tl`, `<name>/init.tl` or `<name>.tmpl` (the name's dots as slashes) beside the file or in a directory
--- above it. nil where there is none, or the file does not parse.
local function project_module(file: string, source: string): string?
  local required, _ = standalone.requires(file, source)
  if required == nil then
    return nil
  end
  local absolute, _ = Fs.absolute(file)
  if absolute == nil then
    return nil
  end
  for _, name in ipairs(required) do
    if name:sub(1, 7) ~= "cosmic." and name ~= "cosmic" then
      local stem = name:gsub("%.", "/")
      local directory = Fs.dirname(absolute)
      while true do
        for _, candidate in ipairs({ stem .. ".tl", stem .. "/init.tl", stem .. ".tmpl" }) do
          local there, _ = Fs.exists(directory .. "/" .. candidate)
          if there == true then
            return name
          end
        end
        local parent = Fs.dirname(directory)
        if parent == directory then
          break
        end
        directory = parent
      end
    end
  end
  return nil
end

--- Runs `argv[2]` standalone, or with `--check` at slot 2 checks `argv[3]` and does not run it (exit 0 when it is clean; when not,
--- the refusals on standard error and [`exit_status.uncompiled`]): `argv` is the whole command line, `--standalone`
--- at slot 1, so the file sees what follows its own path, and its path at
--- `argv[0]`. `why`, where given, says what made this run standalone, which
--- a file that does not compile is told beside its refusal: a require of a
--- module that is not `cosmic.*` is refused here and not in the run the
--- caller may have meant. A file the checker refuses or that does not parse exits [`exit_status.uncompiled`].
function standalone.run(argv: {string}, why?: string): integer
  -- `--check` stands before the file and takes nothing after it: the file is checked as a run checks it, and not run.
  local only = argv[2] == "--check"
  local file = argv[if only then 3 else 2 end]
  if file == nil or (only and argv[4] ~= nil) then
    log:complain("usage: cosmic --standalone [--check] <file.tl> [args...] (--check takes the file alone)")
    return 2
  end
  local source, read_trouble = Fs.read(file)
  if source == nil then
    log:complain(read_trouble)
    return 1
  end
  local outcome: importer.Outcome = { refused = false }
  local chunk, trouble = standalone.compile(file, source, nil, nil, outcome)
  if chunk == nil then
    local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
    if why ~= nil then
      local _, _ = Fs.put(Fs.stderr, "cosmic: " .. why .. "\n")
    end
    if outcome.refused then
      local needed = project_module(file, source)
      if needed ~= nil then
        local _, _ = Fs.put(Fs.stderr, "cosmic: " .. file .. " belongs to a project (it requires " .. needed ..
            ", a module of the project), and --standalone finds only cosmic.* modules: drop --standalone, or check it " ..
            "with `cosmic fix " .. file .. "`\n")
      end
    end
    return if outcome.refused then exit_status.uncompiled else 1 end
  end
  if only then
    return 0
  end
  -- `arg[0]` is the script, so the table is keyed by position and not a sequence.
  local arguments: mut {integer: string} = {}
  for slot = 3, #argv do arguments[slot - 2] = assert(argv[slot]) end
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
