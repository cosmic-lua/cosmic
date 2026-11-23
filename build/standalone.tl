--- `cosmic --standalone <file.tl> [args...]`: one file, run against
--- this binary's own embedded standard library and nothing else.
---
--- `cosmic <file.tl>` of a file that requires a module of its project
--- builds the tree the file sits in first -- stages it into its build
--- directory, compiles every module it holds, and refuses to go on when
--- the running binary is stale against that tree; of one that requires
--- only `cosmic.*` modules, it runs as this does ([`standalone.runs_alone`]).
--- Building is right for a project, and wrong for a script whose job is
--- to repair the tree: [`bin/zig`], which rebuilds a stale core, cannot itself need a
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
local Compiled = require("cosmic.internal.compiled")
local Globals = require("cosmic.internal.globals")
local exit_status = require("build.exit_status")
local type importer = require("build.importer")
local log = require("build.logger").log

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

--- The Lua of a `require` that answers each of `modules` by its name, and asks `load_module` for any other.
local OWN_REQUIRE <const> = "local modules, load_module = ... " ..
  "return function(name) local found = modules[name] if found ~= nil then return found end return load_module(name) end"

--- `code`, Lua the checker wrote of `file`, loaded as `file`'s chunk, its globals `env`.
local function loaded_in(file: string, code: string, env: {string: any}): standalone.Main?, string
  local chunk, chunk_trouble = Compiled.load(code, "@" .. file, env)
  if chunk == nil then
    return nil, file .. ": " .. tostring(chunk_trouble)
  end
  return chunk, ""
end

--- `code`, Lua the checker wrote of `file`, loaded as `file`'s chunk, with a `require` that answers each of
--- `modules` by its name, as a module the binary does not hold: the module of an MCP server a snippet of cosmic agent
--- requires ([`build.agent_worker`]).
function standalone.loaded_with<M>(file: string, code: string, modules: {string: M}): standalone.Main?, string
  local globals = Globals.table()
  local own: mut {string: any} = {}
  for k, v in pairs(globals) do own[k] = v end
  local made = assert(load(OWN_REQUIRE, "=own_require", "t", {}))
  own["require"] = made(modules, globals["require"])
  return loaded_in(file, code, own)
end

--- `file`'s Teal, checked and compiled to Lua -- from the cache when this
--- binary compiled these exact bytes cleanly before, and kept there when
--- not. The cache is found through `variables` when given (as
--- [`Fs.cache_dir`] finds it), and this process's own otherwise. nil and
--- every complaint of the checker when the file is not clean. Every check
--- creates its own program; previous declarations are not shared. The new
--- checker ([`build.pipeline`]) holds the file to no ceiling and takes `cosmic.*` from this binary. With `own`, as `cosmic -e` asks, the file
--- may also require the tool's own modules, which the checker types from their sources ([`build.standard_text`]'s `own`),
--- and it is checked each time and kept nowhere.
function standalone.code(file: string, source: string, variables?: {string:string}, own?: boolean,
                         outcome?: importer.Outcome): string?, string
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
    -- they are part of the binary the cache name holds), read only for a file the cache does not hold. So is the checker
    -- itself: a cached run loads none of its hundred modules (build/standalone_test.tl holds it to that).
    local Pipeline = require("build.pipeline")
    local options, trouble = Pipeline.alone()
    if options == nil then
      return nil, file .. ": " .. trouble
    end
    if own == true then
      options = { globals = options.globals, types = options.types,
        standard = Pipeline.carried_own(), project = options.project }
    end
    -- A file's entry point is held to a declaration, as `cosmic fix` holds it in a tree; a chunk's exit code is not.
    local generated, generate_trouble = Pipeline.lone(file, source, options, nil, own ~= true)
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
  return require("build.pipeline").requires(file, source)
end

--- The modules `source` requires, in the order they stand, as its tokens alone say ([`lang.lexer`], which loads
--- nothing of the checker): each `require "name"` and `require("name")`. nil where `require` stands in any other
--- form (a name that is no literal, `pcall(require, name)`) or the source does not lex, since only the checker can
--- tell what such a file requires. A field or method of that name (`x.require`) is no require.
function standalone.literal_requires(source: string): {string}?
  local Lexer = require("lang.lexer")
  local lexed = Lexer.lex(source, "")
  if #lexed.errors > 0 then
    return nil
  end
  local tokens = lexed.tokens
  local kinds, texts, values = tokens.kind, tokens.text, tokens.value
  local found: mut {string} = {}
  for i = 1, #kinds do
    local before = kinds[i - 1]
    if kinds[i] == "identifier" and texts[i] == "require" and before ~= "." and before ~= ":" then
      local at = if kinds[i + 1] == "(" then i + 2 else i + 1 end
      local name = values[at]
      if kinds[at] ~= "string" or name == nil or (at == i + 2 and kinds[at + 1] ~= ")") then
        return nil
      end
      found[#found + 1] = name
    end
  end
  return found
end

--- Whether `cosmic <file>` runs `file` as `--standalone` does, by its path and `source` alone: where it is no
--- program's main (`cmd/<name>/main.tl`, whose run serves its `static/` and documents its program from the build)
--- and no test (`_test.tl`, whose tests the tree's compile gives it), and requires by a literal name only
--- `cosmic.*` modules ([`standalone.literal_requires`]), which the binary carries. Such a file
--- compiles alone as it would in its tree, and a standalone run of it builds nothing. Whether the tree is
--- cosmic's own, whose `cosmic.*` modules are its sources and not the binary's, the caller says.
function standalone.runs_alone(file: string, source: string): boolean
  if file:match("_test%.tl$") ~= nil or ("/" .. file):match("/cmd/[^/]+/main%.tl$") ~= nil then
    return false
  end
  local required = standalone.literal_requires(source)
  if required == nil then
    return false
  end
  for _, name in ipairs(required) do
    if name:sub(1, 7) ~= "cosmic." then
      return false
    end
  end
  return true
end

--- `file`'s Teal, checked and compiled to a loaded chunk ([`standalone.code`],
--- loaded as `file`'s, or as the module `module`'s where given, as its tree loads it), `own` and `outcome` as it says
--- there.
function standalone.compile(file: string, source: string, variables?: {string:string}, own?: boolean,
                            outcome?: importer.Outcome, module?: string): standalone.Main?, string
  local code, trouble = standalone.code(file, source, variables, own, outcome)
  if code == nil then
    return nil, trouble
  end
  return loaded_in(module or file, code, Globals.table())
end

--- The entry point `produced` names: itself when it is a function, its
--- `main` field when that is one, nil otherwise.
function standalone.entry(produced: any): standalone.Main?
  if produced is standalone.Main then -- checked: is_on_record
    return produced
  end
  if produced is {string: any} then -- checked: is_on_record
    local main: any = produced.main -- checked: map_field
    if main is standalone.Main then -- checked: is_on_record
      return main
    end
  end
  return nil
end

--- The first module `file` requires by a literal name that is no `cosmic.*` module but a file of the project the file sits
--- in: found as `<name>.tl`, `<name>/init.tl` or `<name>.tmpl` (the name's dots as slashes) beside the file or in a directory
--- above it, as far up as the root `cosmic <file>` would build as the project: the working directory when the file sits
--- under it, the file's own directory otherwise (`root_of` in [`build.dispatch`]). nil where there is none, or the file does
--- not parse.
local function project_module(file: string, source: string): string?
  local required, _ = standalone.requires(file, source)
  if required == nil then
    return nil
  end
  local absolute, _ = Fs.absolute(file)
  if absolute == nil then
    return nil
  end
  local here, _ = Fs.absolute(".")
  local top = if here ~= nil and Fs.within(absolute, here) then here else Fs.dirname(absolute) end
  for _, name in ipairs(required) do
    if name:sub(1, 7) ~= "cosmic." and name ~= "cosmic" then
      local stem = name:gsub("%.", "/")
      local directory = Fs.dirname(absolute)
      while true do
        for _, candidate in ipairs({ stem .. ".tl", stem .. "/init.tl", stem .. ".tmpl" }) do
          local there_status, _ = Fs.status(directory .. "/" .. candidate)
          local there = there_status ~= nil and there_status.exists
          if there == true then
            return name
          end
        end
        local parent = Fs.dirname(directory)
        if directory == top or parent == directory then
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
--- `name`, where given, is the module the file is, as a file run that runs it alone names it: its chunk is loaded as
--- that module's, as its tree loads it (a traceback and coverage name the module), and its top level finds the name
--- as its `...`, as `require` hands a module its own.
function standalone.run(argv: {string}, why?: string, name?: string): integer
  -- `--check` stands before the file and takes nothing after it: the file is checked as a run checks it, and not run.
  local only = argv[2] == "--check"
  local file = argv[if only then 3 else 2 end]
  if file == nil or (only and argv[4] ~= nil) then
    log:complain("usage: cosmic --standalone [--check] <file.tl> [args...] (--check takes the file alone)")
    return 2
  end
  local source, read_trouble = Fs.read(file)
  if source == nil then
    log:complain(tostring(read_trouble))
    return 1
  end
  local outcome: importer.Outcome = { refused = false }
  local chunk, trouble = standalone.compile(file, source, nil, nil, outcome, name)
  if chunk == nil then
    local shown = require("build.error_render").annotated(trouble, function(named: string): string?
      local text, _ = Fs.read(named)
      return text
    end)
    local _, _ = Fs.put(Fs.stderr, shown .. "\n")
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
  rawset(_G as {string:any}, "arg", arguments) -- checked: cast_refused, unchecked_binding
  local main = standalone.entry(chunk(name))
  if main == nil then
    return 0
  end
  return exit_status.of(file, main(arguments))
end

return standalone
