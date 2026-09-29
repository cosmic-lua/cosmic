--- A stand-in program for a test that needs an outside program to start
--- -- a fake zig, codesign or cosmic, a process to leave running --
--- without the system's shell. It is a host program of this core, laid
--- out as `cosmic build --host` lays one out: a static executable of
--- the core and a small database, which the kernel runs directly and
--- which reads only itself. A caller that starts it with no environment
--- and no descriptors of its own, as bin/zig, codesign's verifier and
--- the eval grader start theirs, starts it all the same. This program,
--- past its launcher (`Proc.relaunch`), could not be started so.
---
--- `build` makes one, in a few milliseconds past reading the core, and
--- `place` copies it where a test needs one, with the script it runs.
--- A test that builds one declares nothing for it: the build runs
--- nothing and reads only this program's core and the rows of modules
--- its test's import closure holds (build/stand_in_probe.tl, which the
--- stand-in runs, and what that requires).
---
--- The script is `<its path>.do` when that exists. Failing that, it is
--- the body of the file its first argument names, past its first line,
--- where that is a regular file whose first line starts `#!`: a file
--- starting `#!<stand-in>` and nothing more runs its body, as a shell
--- script does, on every system, however one splits the words after
--- `#!`. Failing both, it is the first argument itself. Its arguments
--- are the rest: every one for a `.do` script, and those after the
--- first otherwise. Commands are split on `;` and newlines, each a verb
--- and its words:
---
---     print T          T and a newline, to stdout
---     eprint T         T and a newline, to stderr
---     write F T        T and a newline, as the whole of file F
---     append F T       T and a newline, at the end of file F
---     cat [F]          file F, or stdin to its end, to stdout
---     cat-quiet F      file F to stdout, or nothing where it cannot be read
---     ls D             the names in directory D, sorted, a line each
---     exit N           ends with status N
---     signal S [P]     sends SIGS (TERM, INT, KILL, HUP) to itself, and
---                      waits to end of it -- two seconds at most, after
---                      which it says so and ends with status 4; or to
---                      pid P, negated for a process group, as kill(2)
---                      takes it, or `@F` for the one file F holds, and
---                      goes on. 0 and -1, which name no one process or
---                      group, fail
---     trap N           holds SIGINT and SIGTERM (`Child.guard`) and ends
---                      with status N once one arrives: checked between
---                      commands and while it sleeps or waits; `trap -`
---                      holds them and goes on, as a shell's `trap ''`
---                      does -- though, caught rather than ignored, not
---                      for a program it starts
---     sleep MS         sleeps MS milliseconds
---     sleep-forever    sleeps until it is ended
---     wait-for F       waits until file F exists
---     exists P N       ends with status N if P exists
---     copy A B         file A's bytes as the whole of file B
---     cwd [F]          its working directory and a newline, to stdout or F
---     mkfifo P         makes a named pipe at P
---     mkdirs D         makes directory D and its parents
---     grep-count F T   how many lines of file F hold T, to stdout
---     status-field K   its line of /proc/self/status that names K
---     run P [T]        starts P, with T its one argument, and waits for
---                      it, as a shell runs one: what P leaves running
---                      runs on, and none of it is adopted here; ends
---                      with P's status where it fails (128 past a
---                      signal), and 127 where P cannot start, as after
---                      a `trap`: a process holds one guard at once
---     start P [T]      starts P, with T its one argument, and goes on
---                      without waiting for it, as a shell's `P &` does:
---                      it outlives the script, which then ends by
---                      `sys.exit`, past what would end it
---     fd-closed N      ends with status 1 unless descriptor N is
---                      closed, and 2 when N names no descriptor
---     write-fd N T     T and a newline, to descriptor N
---     env-of NAME      `NAME=` and the variable's value, or `NAME unset`,
---                      and a newline, to stdout: unlike `$NAME`, it
---                      tells an empty variable from an unset one
---     present P        fails unless P exists, as `test -e` does
---     connect P        connects to the unix socket file P, saying
---                      `connected` or why not, a line to stdout
---     writable P       fails unless file P opens to write, appending
---                      and writing nothing, as `: >> P` does, but never
---                      making it
---     mode P           P's permission bits in octal and a newline, to
---                      stdout, as `stat -c %a` prints them
---     find-writable D  each regular file beneath D that opens to write,
---                      as `writable` opens one, a line each: a link is
---                      neither listed nor walked into, as `find D -type
---                      f` walks, and a file is listed only where it
---                      leads to one too, as `test -f` takes it; a
---                      directory it cannot list is passed over
---
--- A verb, its first word and the rest are split at the blanks between
--- them, however many, which go; the rest keeps its own spacing. In a
--- command's words, `$@` is its arguments joined by spaces, `$DIR` the
--- directory it sits in, and `$NAME` the environment variable NAME, empty
--- when unset, each put in once: what is put in is not read for a `$`
--- again. A command written `[w] ...` runs only when its first
--- argument is `w`. A command that fails says why on stderr and ends
--- with status 1; an unknown verb ends with 2. The script's end is
--- status 0.
---
--- Commands chain as a shell's do, left to right, at an `&&` or `||`
--- standing between blanks: `A && B` runs B only where A went on, and
--- `A || B` runs B only where A would have ended the script -- failed,
--- or exited -- and goes on as B does. What a failure a `||` takes up
--- would have said is not said. A chain that ends the script ends it
--- with the status of the last command run.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local artifact = require("build.artifact")
local bind = require("build.bind")
local schema = require("build.schema")
-- Required, not only named, so the module and what it requires are of
-- the import closure of every test that builds a stand-in, whose store
-- then holds the rows `database` copies; loading it defines its verbs
-- and nothing more.
local _ = require("build.stand_in_probe")
-- What the core itself requires of the program it runs, beside its
-- main module: `cosmic.errors`, for an uncaught error's guidance
-- (core/main.c's `ask_guidance`), and `cosmic.removed`, for what to
-- write instead of a name the runtime removes (core/surface.c's
-- `removed_message`). Required so they are of the closure too.
local type _ = require("cosmic.errors")
local _ = require("cosmic.removed")

local record stand_in
end

local text = bind.text

--- The stand-in's program, which it carries with the modules it
--- requires, the whole of what it runs.
local probe_module <const> = "build.stand_in_probe"

--- The name the stand-in carries `probe_module`'s bytecode under, as
--- its main module: under neither `build.*` nor `cosmic.*`, so, as a
--- program `cosmic build --host` makes, its main loads untrusted
--- (core/store.c's `names_trusted_kind`).
local main_module <const> = "stand_in.main"

--- What the core requires of any program it runs, beside its main
--- module (see the requires above).
local core_requires <const>: {string} = { "cosmic.errors", "cosmic.removed" }

--- One module the stand-in carries, with what it requires.
local record Carried
  name: string
  requires: {string}
end

--- The modules `probe_module` loads, itself first, then
--- `core_requires`, each once: the ones this program's own `imports`
--- rows record it requiring, and theirs in turn. A raw
--- `cosmic.internal.*` value is no row of any database, since the core
--- hands each wrapper its own (core/store.c's `raw_modules`), so those
--- are left out.
local function carried(): {Carried} | nil, string
  local order: {Carried} = {}
  local seen: {string:boolean} = {}
  local pending: {string} = { probe_module }
  for _, name in ipairs(core_requires) do pending[#pending + 1] = name end
  while #pending > 0 do
    local name = table.remove(pending, 1)
    if not seen[name] and name:sub(1, #"cosmic.internal.") ~= "cosmic.internal." then
      seen[name] = true
      local requires, trouble = Store.requires(name)
      if requires == nil then return nil, name .. ": " .. trouble end
      order[#order + 1] = { name = name, requires = requires }
      for _, required in ipairs(requires) do pending[#pending + 1] = required end
    end
  end
  return order
end

--- The database the stand-in carries, as bytes, written through
--- `path`: the rows of `carried`'s modules, as this program carries
--- them, with their import edges -- `probe_module`'s under
--- `main_module`, named its main module -- and the runtime basis this
--- program runs on. Of what a program `cosmic build` makes carries
--- (`build.embed`'s `database`), it leaves out the rest of the standard
--- library, its declarations, time zones, bill of materials and CA
--- roots, which the probe never reads, and the error catalog, so an
--- uncaught error of the stand-in's prints its message and trace with
--- no guidance beneath.
local function database(path: string): string | nil, string
  local modules, closure_trouble = carried()
  if modules == nil then return nil, closure_trouble end
  local _, _ = Fs.remove(path)
  local db, open_trouble = Sqlite.open(path, true)
  if db == nil then return nil, path .. ": " .. open_trouble end
  local statements: {string} = {}
  for _, statement in ipairs(schema.settings("")) do statements[#statements + 1] = statement end
  for _, statement in ipairs(schema.create("")) do statements[#statements + 1] = statement end
  for _, statement in ipairs(statements) do
    local ok, failure = db:exec(statement)
    if not ok then
      local _, _ = db:close()
      return nil, failure
    end
  end
  local basis = Store.meta("runtime_basis")
  if basis == nil or basis == "" then
    local _, _ = db:close()
    return nil, "the running binary names no runtime basis"
  end
  local made, trouble = Sqlite.transact(db, function(): boolean, string
    for _, module in ipairs(modules) do
      local bytecode, bytecode_trouble = Store.bytecode(module.name)
      if bytecode == nil then return false, module.name .. ": " .. bytecode_trouble end
      local name = module.name == probe_module and main_module or module.name
      -- A module's kind is all the runtime reads of a row but its
      -- bytecode: `cosmic.*` modules of kind "module" load trusted, as
      -- the binary's own, and the main, under no such name, does not.
      local ok, insert_trouble = Sqlite.run(db, "INSERT INTO modules (path, file, kind, " ..
        "source_hash, key, bytecode, tests, source) VALUES (?1, '', ?2, x'', x'', ?3, '', x'')",
        { text(name), text(name == main_module and "main" or "module"), bind.blob(bytecode) })
      if not ok then return false, name .. ": " .. insert_trouble end
      for _, required in ipairs(module.requires) do
        local edge, edge_trouble = Sqlite.run(db,
          "INSERT INTO imports (path, requires) VALUES (?1, ?2)", { text(name), text(required) })
        if not edge then return false, edge_trouble end
      end
    end
    local meta: {{string}} = {
      { "main", main_module }, { "runtime_basis", basis },
    }
    for _, pair in ipairs(meta) do
      local ok, meta_trouble = Sqlite.run(db, "INSERT INTO meta (key, value) VALUES (?1, ?2)",
        { text(pair[1]), text(pair[2]) })
      if not ok then return false, meta_trouble end
    end
    return true, ""
  end)
  local _, _ = db:close()
  if not made then return nil, trouble end
  local bytes, read_trouble = Fs.read(path)
  local _, _ = Fs.remove(path)
  if bytes == nil then return nil, read_trouble end
  return bytes
end

--- Builds a stand-in under `dir`, made if it is not there, and answers
--- the executable's path, `dir/probe`: this program's own core, as
--- `cosmic build --host` lays one out (`artifact.host_program`), with a
--- database of `probe_module`, its main under `main_module`, and the
--- modules it and the core require, taken from the ones this program
--- carries (`database`). Nothing is compiled and nothing of this program
--- runs, so a test that builds one needs no `tool`: what it carries is
--- its test's import closure, and the core is the runtime its verdict is
--- keyed by.
function stand_in.build(dir: string): string | nil, string
  local made, trouble = Fs.mkdirs(dir)
  if not made then return nil, trouble end
  local core, core_trouble = artifact.trusted_core()
  if core == nil then return nil, "building the stand-in: " .. core_trouble end
  local bytes, database_trouble = database(dir .. "/probe.db")
  if bytes == nil then return nil, "building the stand-in: " .. database_trouble end
  local program, program_trouble = artifact.host_program(core, bytes)
  if program == nil then return nil, "building the stand-in: " .. program_trouble end
  local out = dir .. "/probe"
  local written, write_trouble = Fs.write(out, program, 0x1ed)
  if not written then return nil, write_trouble end
  return out, ""
end

--- Copies the stand-in `probe` to `path`, executable -- a copy, not a
--- symbolic link, since it finds its script beside the path it
--- resolves itself to -- and writes `script` to `path .. ".do"`, when
--- one is given, for it to run.
-- TODO: make a hard link to `probe` where one can be made (the same
-- file system), falling back to this copy, once cosmic.sys carries
-- link: a checked core's probe is 39.5 MB, about 0.2 s a copy.
function stand_in.place(probe: string, path: string, script?: string): boolean, string
  local bytes, trouble = Fs.read(probe)
  if bytes == nil then return false, trouble end
  local written, write_trouble = Fs.write(path, bytes, 0x1ed)
  if not written then return false, write_trouble end
  if script ~= nil then
    return Fs.write(path .. ".do", script)
  end
  return true, ""
end

return stand_in
