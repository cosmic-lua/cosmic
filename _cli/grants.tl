--- What each recipe verb may touch, derived from its own argv.
---
--- Split from the dispatcher because it is the fence's whole knowledge
--- and the dispatcher's only use of it is one call: a recipe line is
--- `verb arg arg arg`, and which positions are reads, writes and execs
--- is a property of the verb. There is no declaration channel -- the
--- argument positions ARE the declaration, which is what makes a rule
--- unable to over-declare its way out of the fence.

local fs = require("cosmic.fs")
local sandbox = require("cosmic.sandbox")

local record Shape
  ro: {integer}
  rw: {integer}
  exec: {integer}
  rest_ro: integer
  rest_rw: integer
end

--- Which argument positions a verb reads, writes, and executes.
--- `rest_*` covers a variadic tail, counting from that position.
--- One entry per verb in _cli.build's modes table; the ratchet in
--- driver_test.tl fails if the two ever drift apart.
--- Verbs whose child runs the Teal type checker, and therefore reads
--- the checker's own inputs rather than only the paths in its argv.
--- `capture` and `tee` are here because a captured script may compile
--- (the type-check and format gates run that way).
local compiles: {string: boolean} = {
  compile = true,
  capture = true,
  tee = true,
}

--- The checker's configuration file, read from the project root.
local TLCONFIG < const > = "tlconfig.lua"

--- The APE's embedded filesystem root. Paths under it are inside the
--- running executable, not on the host's.
local ZIP_ROOT < const > = "/zip"

--- Is this path inside the executable's own zip rather than on the
--- filesystem the kernel enforces against?
--- @param path string The path to test
--- @return boolean True when it is zip-internal
local function in_zip(path: string): boolean
  return path == ZIP_ROOT or path:sub(1, #ZIP_ROOT + 1) == ZIP_ROOT .. "/"
end

--- What a TEST may read and exec beyond the project: the operating
--- system. Enumerated rather than "/" so the grant is a list somebody
--- chose, and so a write still needs naming.
local RUNTIME_RO: {string} = {
  "/etc", "/sys", "/usr", "/bin", "/sbin", "/lib", "/lib64",
}

--- What a test may WRITE outside its own outputs, which is the shorter
--- and more interesting list.
---
--- `/dev/ptmx` and `/dev/pts` are a pty — the slave appears under
--- `/dev/pts`, so that one is a write. `/dev/shm` is shared memory.
---
--- `/proc` is here rather than in the read-only list above because
--- configuring your own user namespace means writing your own
--- `/proc/<pid>/uid_map`, `setgroups` and `gid_map`. Read-only, the
--- open fails and `cosmic/quicksand` reports what a kernel without
--- namespace support reports — so the tests SKIPPED, stayed green, and
--- the sandbox suite quietly stopped testing the sandbox. Three lines
--- of `write_file` going cold in the ratchet is all that showed.
---
--- Not `/proc/self`: a landlock rule binds the inode it opened, and
--- `/proc/self` resolves to `/proc/<pid>` for whoever opens it, so a
--- rule made by the parent covers nothing a child writes.
---
--- NOT `/tmp`: the fence's write boundary is "a test writes only its
--- own outputs", and the system scratch is an output of nobody's. A
--- test that wants a temp dir has TEST_TMPDIR, and one that needs a
--- SHORT path (a unix socket) has TMPDIR, which the driver pins.
local RUNTIME_RW: {string} = {
  "/proc", "/dev/ptmx", "/dev/pts", "/dev/shm",
}

local shapes: {string: Shape} = {
  -- compile <bootstrap> <src> <out> [flags...]
  compile = {exec = {1}, ro = {2}, rw = {3}, rest_ro = 4},
  -- capture <bootstrap> <out> <script> [args...]
  capture = {exec = {1}, rw = {2}, ro = {3}, rest_ro = 4},
  -- tee <out> <cmd> [args...]
  tee = {rw = {1}, exec = {2}, rest_ro = 3},
  -- record <out> <cmd> [args...]. The out position is a BASE name
  -- (`<out>.got`, `.out`, `.err`, and the step's scratch directory),
  -- and a write grants the parent directory anyway, so naming the base
  -- is exact — and it is the ONLY write this step gets. The verb
  -- points TMP inside that directory, so a test's TEST_TMPDIR lands
  -- there too and needs no grant of its own.
  --
  -- Reads are positions 3..n: the test's own compiled file, then the
  -- transitive import closure the graph put there. A test may read what
  -- it imports and nothing else.
  record = {rw = {1}, exec = {2}, rest_ro = 3},
  -- write-list <out> [items...] — items are text written in, not read
  ["write-list"] = {rw = {1}},
  copy = {ro = {1}, rw = {2}}, -- copy <src> <dst>
  -- link <target> <linkpath> — target is a string in the symlink, not a read
  link = {rw = {2}},
  -- remove <paths...> — unlink needs the parent writable
  remove = {rest_rw = 1},
  -- assert-elf <file>
  ["assert-elf"] = {ro = {1}},
  -- assert-marker <marker> <dir>
  ["assert-marker"] = {ro = {2}},
  -- verdict <o_dir> <stages...> — reads each stage's summary under o_dir
  verdict = {ro = {1}},
  -- exec <program> [args...]: a foreign program's reads are not
  -- derivable — a compiler reads headers nobody listed — so it gets the
  -- UNITS its argv touches rather than those arguments, plus the build
  -- root to write into. See the exec block in plan().
  exec = {exec = {1}, ro = {}, rw = {}, rest_ro = 2},
}

--- Collect the paths a shape names, by role.
--- @param shape Shape The verb's argument shape
--- @param args {string} The verb's arguments
--- @return {string} readable paths named by position
--- @return {string} writable paths
--- @return {string} executable paths
--- @return {string} readable paths from the variadic tail
local function paths_of(shape: Shape, args: {string}): {string}, {string}, {string}, {string}
  local ro: {string} = {}
  local rw: {string} = {}
  local ex: {string} = {}
  local ro_rest: {string} = {}
  local function take(into: {string}, positions: {integer})
    for _, i in ipairs(positions or {}) do
      if args[i] ~= nil then
        into[#into + 1] = args[i]
      end
    end
  end
  take(ro, shape.ro)
  take(rw, shape.rw)
  take(ex, shape.exec)
  if shape.rest_ro ~= nil then
    for i = shape.rest_ro, #args do
      ro_rest[#ro_rest + 1] = args[i]
    end
  end
  if shape.rest_rw ~= nil then
    for i = shape.rest_rw, #args do
      rw[#rw + 1] = args[i]
    end
  end
  return ro, rw, ex, ro_rest
end

--- The nearest ancestor of `path` that exists, "." if none does.
---
--- Landlock rules are opened, so a rule naming a path that does not
--- exist yet fails the WHOLE restrict — and a fence that fails is a
--- fence that is not there. Outputs are named before they exist, so
--- every write grant walks up to something openable.
--- @param path string A path that may not exist
--- @return string An existing directory
local function nearest_existing(path: string): string
  local p = fs.dirname(path)
  for _ = 1, 64 do
    if p == "" or p == "." then
      return "."
    end
    if fs.is_dir(p) then
      return p
    end
    p = fs.dirname(p)
  end
  return "."
end

--- The directory of the unit that owns `path`.
---
--- Every output under `o/` comes from a unit: a directory that declares
--- it, a scope of inputs that is also its grant set, and an output path
--- derived from its position (see the Units section of the design). A
--- *generation* unit is the one kind that spans a whole subtree, so a
--- path inside one belongs to the directory holding the `*_gen.tl`.
--- Everything else belongs to its own directory, which is not a
--- fallback but the rule: a package IS a directory with sources in it.
--- @param path string A path, relative or absolute
--- @return string The owning unit's directory
local function unit_dir(path: string): string
  local dir = fs.dirname(path)
  local at = dir
  for _ = 1, 64 do
    if at == "" or at == "." or at == "/" then
      break
    end
    local gen = fs.glob(at, "*_gen.tl")
    if gen ~= nil and #(gen) > 0 then
      return at
    end
    local up = fs.dirname(at)
    if up == at then
      break
    end
    at = up
  end
  return dir
end

--- Derive the filesystem policy for one step.
---
--- **Two different nils, and the caller must tell them apart.** Bare
--- nil is "no shape" -- nothing to fence, which the ratchet test makes
--- impossible for a real verb. Nil WITH an error is "could not be
--- derived", a failure: read the two the same way and the step runs
--- unfenced exactly when something is already wrong.
---
--- Writes grant the parent DIRECTORY, never the file: creating and
--- unlinking are rights on the directory, so a grant on the file
--- itself would deny `copy` its own mkdir and `remove` its own unlink.
--- Reads that do not exist are dropped rather than granted — the verb
--- reports its own "cannot open" error, and keeping the rule out is
--- what stops one missing input from silently disabling the fence.
--- @param verb string The verb name
--- @param args {string} Its arguments
--- @return sandbox.Fs | nil The derived policy
--- @return string | nil Why derivation failed, when it did
local function plan(verb: string, args: {string}): sandbox.Fs | nil, string | nil
  local shape = shapes[verb]
  if not shape then
    return nil
  end
  local ro_raw, rw_raw, ex_raw, ro_rest = paths_of(shape, args)
  -- The same rule the reads below follow, and for the same reason:
  -- landlock rules are OPENED, so naming a path that is not there fails
  -- the WHOLE restrict -- and a fence that fails to construct is not a
  -- fence, it is an error where the verb's own refusal belongs. `exec
  -- sh -c true` is the case in hand: the verb exists to refuse a
  -- program outside the build root, and `sh` is a bare name that
  -- resolves to nothing, so the policy died on it and the test that
  -- asserts the refusal saw a sandbox error instead.
  --
  -- Dropping the rule costs nothing: the program is not there, so
  -- granting exec on it protects no one, and whatever the verb does
  -- next it does with an honest error of its own.
  -- Predates sandbox.Fs.optional (#989); keep until the pin advance.
  local ex: {string} = {}
  for _, p in ipairs(ex_raw) do
    if fs.is_present(p) then
      ex[#ex + 1] = p
    end
  end
  local ro: {string} = {}
  for _, p in ipairs(ro_raw) do
    if fs.is_present(p) then
      ro[#ro + 1] = p
    end
  end
  -- A variadic tail is a list of INPUTS, so a directory in one is not
  -- an input — it is a search path the verb hands its child, like
  -- `compile`'s `--include-dir .`. Granting it read would hand over the
  -- whole tree and undo everything the closure just bought. A named
  -- position may still be a directory the verb genuinely walks
  -- (`verdict <o_dir>`, `assert-marker <marker> <dir>`), which is why
  -- the two are separated rather than filtered together.
  for _, p in ipairs(ro_rest) do
    if fs.is_file(p) then
      ro[#ro + 1] = p
    end
  end
  local rw: {string} = {}
  for _, p in ipairs(rw_raw) do
    -- Create the output's directory before asking which one it is.
    -- Landlock rules are OPENED, so a grant naming a path that does not
    -- exist fails the whole restrict -- and walking up from a
    -- not-yet-created output bottomed out at ".", handing the verb the
    -- entire project tree. On a cold build that was every step: the
    -- fence was widest exactly when the tree was emptiest. The verbs
    -- all `makedirs` their own outputs anyway, so this is the same
    -- directory a moment earlier, and now it is the one that is
    -- granted.
    --
    -- A makedirs that FAILS must not fall through to the walk-up: the
    -- walk-up is the wide grant this exists to avoid, so taking it on
    -- the error path hands the whole tree away exactly when something
    -- is already wrong. Refuse the plan instead -- a fence that cannot
    -- be derived is not a fence to widen.
    -- Refuse means FAIL, and the error is what says so: a bare nil here
    -- reads as "no shape", turning the wide fence this avoids into no
    -- fence at all.
    local dir = fs.dirname(p)
    if dir ~= "" and dir ~= "." then
      local ok, merr = fs.make_dirs(dir)
      if not ok then
        return nil, "cannot create " .. dir .. ": "
        .. (merr or "unknown error")
      end
    end
    rw[#rw + 1] = nearest_existing(p)
  end
  if verb == "record" then
    -- **A test may READ the project it belongs to, and WRITE only its
    -- own outputs.** That is the line, and it is narrower than it
    -- sounds: the write grant is the `.got` base alone (which the
    -- shape names), exec is the floor, and there is no network.
    --
    -- The read half was once "what it imports and nothing else",
    -- derived from the closure the graph already put in the line. It
    -- does not survive contact with real tests, and the two that broke
    -- say why: `_types/gentl_test.tl` reads the pinned `tl.tl` -- a
    -- project input, verified by digest, that no import names -- and
    -- `_build/workflows_test.tl` reads `.github/workflows`, which the
    -- model prunes as a dotfile and which is the whole SUBJECT of that
    -- ratchet. Neither is expressible as an import, and a fence that
    -- forces a ratchet test to stop reading the thing it ratchets is
    -- not protecting anything.
    --
    -- Narrowing this again needs a channel for "I read this file"
    -- that is not `require`, which the design deliberately does not
    -- have yet (docs/design/make/engine.md). Until then the honest
    -- boundary is the one above, stated rather than implied.
    ro[#ro + 1] = "."
    -- ...and EXEC (ro is read-only now): tests exec project binaries.
    ex[#ex + 1] = "."
    -- And the RUNTIME, because a test is arbitrary code that uses the
    -- operating system on purpose: this repo's own tests allocate ptys
    -- (`/dev/ptmx`), count their file descriptors (`/proc/self/fd`),
    -- resolve names (`/etc/resolv.conf`, `/etc/hosts`) and exec
    -- helpers. A derived grant cannot see any of that -- argv says
    -- `run this compiled file` and nothing about what the file does.
    --
    -- So what a test is fenced FROM is writing: its `.got` base and
    -- TMPDIR, which the shape names, and nothing else. That is a real
    -- boundary and it is the one worth having here; claiming a narrower
    -- one would mean a fence that fails honest tests, which is how a
    -- fence gets turned off.
    for _, dir in ipairs(RUNTIME_RO) do
      if fs.is_present(dir) then
        ro[#ro + 1] = dir
        ex[#ex + 1] = dir
      end
    end
    for _, dev in ipairs(RUNTIME_RW) do
      if fs.is_present(dev) then
        rw[#rw + 1] = dev
      end
    end
  end
  if verb == "exec" then
    -- Tightened from the phase-1 stand-in, which granted "." — the
    -- whole working tree — because there was no notion of a unit yet.
    -- There is now: the Units investigation found that the one
    -- abstraction the evidence earns is `unit_dir(path)`, precisely
    -- because a fence wants a DIRECTORY where a stage wants a file
    -- list. So exec reads the units its argv touches, and nothing else.
    --
    -- Still derivation, not declaration: no rule says what its unit is,
    -- the paths in the line do. The program's own unit is always
    -- included, so a step with no path arguments still reads the
    -- directory it was run from rather than nothing at all.
    local units: {string: boolean} = {}
    units[unit_dir(args[1] or ".")] = true
    for i = 2, #args do
      if fs.is_present(args[i]) then
        units[unit_dir(args[i])] = true
      end
    end
    local names: {string} = {}
    for dir in pairs(units) do
      names[#names + 1] = dir
    end
    table.sort(names)
    for _, dir in ipairs(names) do
      ro[#ro + 1] = dir
    end
    local root = os.getenv("COSMIC_EXEC_ROOT") or "o"
    if fs.is_dir(root) then
      rw[#rw + 1] = root
    end
  end
  -- A step that runs the type checker reads two things its argv does
  -- not name: `tlconfig.lua` and the include directories modules
  -- resolve through. Derived from the same place the compile step finds
  -- them -- `cosmic.teal` -- rather than listed here, so a change to
  -- the include path cannot leave the fence behind. Without these the
  -- fence denies every real compile, which is the concrete reason it
  -- could not become the default.
  if compiles[verb] then
    if fs.is_file(TLCONFIG) then
      ro[#ro + 1] = TLCONFIG
    end
    -- Required HERE rather than at the top of the module: acquiring
    -- cosmic.teal loads the ~15k-line compiler, and EVERY recipe step
    -- goes through this file. `plan` runs only behind the fence gate,
    -- so inside this branch the cost is paid by a fenced compile alone.
    local teal = require("cosmic.teal")
    for _, dir in ipairs(teal.default_include_dirs()) do
      -- Real host paths only. Two of the include dirs live INSIDE the
      -- executable's own zip (`/zip/.types`, `/zip/.tl`), where
      -- `fs.is_dir` answers yes -- cosmic's own syscall shims see them
      -- -- and the kernel knows nothing at all. Handing one to Landlock
      -- fails the whole policy with EBADFD, which took the fenced
      -- compile down entirely rather than denying anything. They need
      -- no grant either way: they are bytes in a file the exec grant
      -- already covers.
      if not in_zip(dir) and fs.is_dir(dir) then
        ro[#ro + 1] = dir
      end
    end
  end
  -- The runtime floor. A derived fence still needs what ANY cosmic
  -- process touches regardless of its arguments, which the make rules
  -- spell as unveil_base/unveil_dev: without it the first step to open
  -- /dev/urandom or exec an APE dies, which is exactly how the enforce,
  -- build, and offline lanes went red when this shipped without one.
  local tmp = os.getenv("TMPDIR") or "/tmp"
  if fs.is_dir(tmp) then
    rw[#rw + 1] = tmp
  end
  -- Coverage output, created before it is granted for the same reason
  -- the write grants above are: a landlock rule is an open, so a
  -- directory that does not exist yet gets no rule -- and a step whose
  -- coverage directory it creates ITSELF therefore always missed.
  --
  -- The failure is quiet in the worst way. Nothing errors: the step
  -- runs, the tests pass, and the `.cov` dump is simply denied at exit,
  -- so what shows up is the RATCHET, three recipe-path files at once
  -- (`_cli/build/steps.tl` 182/237 -> 33/230) reading like a code
  -- change that deleted the tests.
  --
  -- Asked through `cosmic.coverage`, not by reading the variable here.
  -- `COSMIC_COVERAGE` is overloaded: `1` means "collect" and names no
  -- directory (that is what the make rules set on a coverage step),
  -- while any other value IS the directory. Reading it raw and calling
  -- `makedirs` on it creates a directory literally named `1` in the
  -- project root. One definition of that rule, and it is over there.
  local cov = require("cosmic.coverage").dir_from_env()
  if cov ~= nil then
    local _ok, _err = fs.make_dirs(cov)
    if fs.is_dir(cov) then
      rw[#rw + 1] = cov
    end
  end
  if fs.is_present("/dev/null") then
    rw[#rw + 1] = "/dev/null"
  end
  for _, dev in ipairs({"/dev/random", "/dev/urandom"}) do
    if fs.is_present(dev) then
      ro[#ro + 1] = dev
    end
  end
  if arg[-1] ~= nil and fs.is_present(arg[-1]) then
    ex[#ex + 1] = arg[-1]
  end
  -- The APE loader. A fat APE is a shell prologue the kernel will not
  -- load, so every spawn goes through a small loader; cosmo's execve
  -- (libc/proc/execve-sysv.c) probes /usr/bin/ape, $TMPDIR/.ape-<v>,
  -- $HOME/.ape-<v>, ./.ape-<v>, then /bin/sh, whose prologue extracts
  -- a fresh loader into ${TMPDIR:-${HOME:-.}}. Deny every probe and
  -- the parent reports ENOEXEC, which reads like a corrupt binary.
  --
  -- Each loader FILE that exists gets exec: a file grant runs the
  -- loader without opening the directory around it -- granting the
  -- extraction DIRECTORY handed every step rw+exec on the entire home
  -- when TMPDIR was unset. The scratch TMPDIR gets exec too (rw
  -- above): the driver seeds $HOME's loaders into it before fencing
  -- (see driver.tl), because execve caches TMPDIR/HOME at process
  -- startup and a NESTED driver cannot read $HOME to find one here.
  if fs.is_dir(tmp) then
    ex[#ex + 1] = tmp
  end
  local loaders: {string} = {"/usr/bin/ape"}
  for _, base in ipairs({tmp, os.getenv("HOME") or "", "."}) do
    if base ~= "" and fs.is_dir(base) then
      local found = fs.glob(base, ".ape-*")
      if found ~= nil then
        for _, f in ipairs(found as {string}) do -- cast: nil-checked above
          loaders[#loaders + 1] = f
        end
      end
    end
  end
  for _, f in ipairs(loaders) do
    if fs.is_file(f) then
      ex[#ex + 1] = f
    end
  end
  return {ro = ro, rw = rw, exec = ex}
end

local record GrantsModule
  shapes: {string: Shape}
  plan: function(verb: string, args: {string}): sandbox.Fs | nil, string | nil
end

local M: GrantsModule = {
  shapes = shapes,
  plan = plan,
}

return M
