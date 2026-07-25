--- Build-driver entry points, shared by `--build <mode>` and `-c`:
--- fence the step, then run it.
---
--- The fence is DERIVED, never declared. Because the recipe vocabulary
--- is closed, every verb's signature already says what it touches —
--- `copy <src> <dst>` reads src and writes dst, `compile <bootstrap>
--- <src> <out>` execs the first, reads the second, writes the third.
--- The shapes table below is that knowledge, and it is the whole
--- grant: a rule cannot over-declare its way out of the fence, because
--- a rule declares nothing. (An earlier design carried grants in
--- target-specific make variables, `COSMIC_UNVEIL = $^`; the closed
--- vocabulary made that channel redundant.)
---
--- Both entries also arm line coverage the way the script path does: a
--- driver run in the coverage lane must still report cosmic.build's
--- lines, or every recipe step it executes reads as dead code.

local fs = require("cosmic.fs")
local sandbox = require("cosmic.sandbox")

--- Which argument positions a verb reads, writes, and executes.
--- `rest_*` covers a variadic tail, counting from that position.
local record Shape
  ro: {integer}
  rw: {integer}
  exec: {integer}
  rest_ro: integer
  rest_rw: integer
end

--- One entry per verb in cosmic.build's modes table; the ratchet in
--- driver_test.tl fails if the two ever drift apart.
local shapes: {string: Shape} = {
  -- compile <bootstrap> <src> <out> [flags...]
  compile = {exec = {1}, ro = {2}, rw = {3}, rest_ro = 4},
  -- capture <bootstrap> <out> <script> [args...]
  capture = {exec = {1}, rw = {2}, ro = {3}, rest_ro = 4},
  -- tee <out> <cmd> [args...]
  tee = {rw = {1}, exec = {2}, rest_ro = 3},
  -- test <out> <cmd> [args...]. The out position is a BASE name
  -- (`<out>.got`, `.out`, `.err`, and the step's scratch directory),
  -- and a write grants the parent directory anyway, so naming the base
  -- is exact — and it is the ONLY write this step gets. The verb
  -- points TMP inside that directory, so a test's TEST_TMPDIR lands
  -- there too and needs no grant of its own.
  --
  -- Reads are positions 3..n: the test's own compiled file, then the
  -- transitive import closure the graph put there. A test may read what
  -- it imports and nothing else.
  test = {rw = {1}, exec = {2}, rest_ro = 3},
  -- list <out> [items...] — items are text written into out, not read
  list = {rw = {1}},
  -- copy <src> <dst>
  copy = {ro = {1}, rw = {2}},
  -- link <target> <linkpath> — target is a string in the symlink, not a read
  link = {rw = {2}},
  -- remove <paths...> — unlink needs the parent writable
  remove = {rest_rw = 1},
  -- require-elf <file>
  ["require-elf"] = {ro = {1}},
  -- require-marker <marker> <dir>
  ["require-marker"] = {ro = {2}},
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
--- @return {string} readable paths
--- @return {string} writable paths
--- @return {string} executable paths
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
    if fs.isdir(p) then
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
--- path inside one belongs to the directory holding the `*.gen.tl`.
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
    local gen = fs.glob(at, "*.gen.tl")
    if gen ~= nil and #(gen as {string}) > 0 then -- cast: record union after the guard
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

--- Derive the filesystem policy for one step. Returns nil when the
--- verb has no shape, which the ratchet test makes impossible.
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
local function plan(verb: string, args: {string}): sandbox.Fs | nil
  local shape = shapes[verb]
  if not shape then
    return nil
  end
  local ro_raw, rw_raw, ex, ro_rest = paths_of(shape, args)
  local ro: {string} = {}
  for _, p in ipairs(ro_raw) do
    if fs.exists(p) then
      ro[#ro + 1] = p
    end
  end
  -- A variadic tail is a list of INPUTS, so a directory in one is not
  -- an input — it is a search path the verb hands its child, like
  -- `compile`'s `--include-dir .`. Granting it read would hand over the
  -- whole tree and undo everything the closure just bought. A named
  -- position may still be a directory the verb genuinely walks
  -- (`verdict <o_dir>`, `require-marker <marker> <dir>`), which is why
  -- the two are separated rather than filtered together.
  for _, p in ipairs(ro_rest) do
    if fs.isfile(p) then
      ro[#ro + 1] = p
    end
  end
  local rw: {string} = {}
  for _, p in ipairs(rw_raw) do
    rw[#rw + 1] = nearest_existing(p)
  end
  if verb == "test" then
    -- A test reads what it imports, and the graph has already put that
    -- in the line: positions 3..n are its own compiled file followed by
    -- its transitive closure, each granted by `rest_ro` above. Nothing
    -- broader — an earlier draft granted the whole build root, which is
    -- every other module's output.
    --
    -- Its own SOURCE directory is the one path argv does not name, and
    -- it is where `testdata/` lives. Derived rather than declared: the
    -- first read position is the test's built file, so stripping the
    -- build root off it gives the directory the fixtures are in.
    local root = os.getenv("COSMIC_EXEC_ROOT") or "o"
    local built = args[3]
    if built and built:sub(1, #root + 1) == root .. "/" then
      local src = fs.dirname(built:sub(#root + 2))
      if fs.isdir(src) then
        ro[#ro + 1] = src
      end
    end
  end
  if verb == "exec" then
    -- Tightened from the phase-1 stand-in, which granted "." — the
    -- whole working tree — because there was no notion of a unit yet.
    -- There is now: 2d's Units investigation found that the one
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
      if fs.exists(args[i]) then
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
    if fs.isdir(root) then
      rw[#rw + 1] = root
    end
  end
  -- The runtime floor. A derived fence still needs what ANY cosmic
  -- process touches regardless of its arguments, which the make rules
  -- spell as unveil_base/unveil_dev: without it the first step to open
  -- /dev/urandom or exec an APE dies, which is exactly how the enforce,
  -- build, and offline lanes went red when this shipped without one.
  local tmp = os.getenv("TMPDIR") or "/tmp"
  if fs.isdir(tmp) then
    rw[#rw + 1] = tmp
  end
  local cov = os.getenv("COSMIC_COVERAGE")
  if cov ~= nil and fs.isdir(cov) then
    rw[#rw + 1] = cov
  end
  for _, dev in ipairs({"/dev/null"}) do
    if fs.exists(dev) then
      rw[#rw + 1] = dev
    end
  end
  for _, dev in ipairs({"/dev/random", "/dev/urandom"}) do
    if fs.exists(dev) then
      ro[#ro + 1] = dev
    end
  end
  if arg[-1] ~= nil and fs.exists(arg[-1]) then
    ex[#ex + 1] = arg[-1]
  end
  -- The APE loader, beside every binary this build execs (the repo
  -- stages o/bin/ape for exactly this): a fat APE that cannot reach its
  -- loader fails with ENOEXEC, which reads like a corrupt binary rather
  -- than a denied path.
  local loaders: {string} = {}
  for _, prog in ipairs(ex) do
    local sibling = fs.join(fs.dirname(prog), "ape")
    if fs.exists(sibling) then
      loaders[#loaders + 1] = sibling
    end
  end
  for _, l in ipairs(loaders) do
    ex[#ex + 1] = l
  end
  return {ro = ro, rw = rw, exec = ex}
end

--- Apply the derived fence.
---
--- best_effort, because `unveil()` no-ops without Landlock: a host that
--- cannot enforce runs unfenced rather than refusing to build, the same
--- posture the make rules take, with CI's enforce lane as the proof it
--- is live where it counts. A host that CAN enforce but fails to is a
--- different thing entirely — that is a fence that silently is not
--- there, so it fails the step loudly instead.
--- OFF until a Landlock host proves it. Shipping it on turned the
--- enforce, build, and offline lanes red at once: the derivation was
--- right about the arguments and silent about everything else a
--- process needs — the APE loader, `/dev/urandom`, the paths a child's
--- own argv names — and no host available while writing it could
--- enforce anything (`sandbox.available().fs` is false without
--- Landlock, so every local run was a no-op). `COSMIC_FENCE=1` turns
--- it on; the canary in build_test asserts it denies. Flipping the
--- default is its own change, gated on that canary passing in CI.
--- @return boolean
local function fence_enabled(): boolean
  return os.getenv("COSMIC_FENCE") == "1"
end

--- @param verb string The verb name
--- @param args {string} Its arguments
--- @return string|nil Error message when an enforceable fence failed
local function fence(verb: string, args: {string}): string | nil
  if not fence_enabled() then
    return nil
  end
  local fs_policy = plan(verb, args)
  if fs_policy == nil then
    return nil
  end
  local ok, err = sandbox.apply({fs = fs_policy, best_effort = true})
  if not ok then
    return "fence for '" .. verb .. "' failed: " .. (err or "unknown error")
  end
  return nil
end

--- Run one driver entry with line coverage armed.
--- @param run function(): integer The entry to run
--- @return integer Exit code from the entry
local function with_coverage(run: function(): integer): integer
  local cov_dump: function() = nil
  if os.getenv("COSMIC_COVERAGE") then
    cov_dump = require("cosmic.coverage").enable_from_env()
  end
  local code = run()
  if cov_dump then
    cov_dump()
  end
  return code
end

--- `--build <mode> <args>...`: one recipe step, named directly.
--- @param mode string The mode name
--- @param argv {string} The mode's arguments
--- @return integer Exit code
local function build(mode: string, argv: {string}): integer
  return with_coverage(function(): integer
      local b = require("cosmic.build")
      local ferr = fence(mode, argv)
      if ferr ~= nil then
        io.stderr:write("cosmic --build: " .. ferr .. "\n")
        return 1
      end
      return b.main(mode, table.unpack(argv))
    end)
end

--- `-c '<line>'`: one recipe line from make, run as argv (`SHELL :=
--- cosmic`). Parsed first, fenced from the parse, then dispatched.
--- @param line string The recipe line
--- @return integer Exit code
local function recipe(line: string): integer
  return with_coverage(function(): integer
      local b = require("cosmic.build")
      local verb, args, err = b.parse(line)
      if err ~= nil then
        io.stderr:write("cosmic -c: " .. err .. "\n")
        return 1
      end
      if verb == nil then
        return 0
      end
      local ferr = fence(verb, args)
      if ferr ~= nil then
        io.stderr:write("cosmic -c: " .. ferr .. "\n")
        return 1
      end
      return b.dispatch(verb, args)
    end)
end

local record DriverModule
  build: function(mode: string, argv: {string}): integer
  recipe: function(line: string): integer
  plan: function(verb: string, args: {string}): sandbox.Fs | nil
  shapes: {string: Shape}
end

local M: DriverModule = {
  build = build,
  recipe = recipe,
  plan = plan,
  shapes = shapes,
}

return M
