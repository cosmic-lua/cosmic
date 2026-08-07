--- `run <path> [args…]` — build, then run that source against the tree.
---
--- **Paths, never binary names.** The rejected form is `run [binary]`
--- — build, then exec `o/bin/<name>` — and it has no caller, here or
--- anywhere: a built binary is already executable, so that verb buys a
--- rebuild for two saved tokens. The source form is what every caller
--- in this repo needs and none of them can spell otherwise:
--- `_perf/run.tl` and `_perf/gate.tl` (four documented commands),
--- `_docs/publish.tl` from `docs.yml`, and `_types/gentype.tl` after a
--- pin bump. `run cosmic` refuses, naming `o/bin/cosmic`.
---
--- It is `test`'s shape with a different contract: build the stage, then
--- spawn the target with its own closure as the resolution set. That is
--- what makes `skills/optimize/SKILL.md`'s "measures whatever `o/` happens to
--- hold" warning retire by construction — the run is what makes `o/`
--- fresh. See docs/design/make/resolution.md.

local child = require("cosmic.child")
local fd = require("cosmic.fd")
local fs = require("cosmic.fs")
local unix = require("cosmo.unix")
local modules = require("_cli.build.modules")
local deps = require("_make.deps")
local generate = require("_make.generate")
local graph = require("_make.graph")
local project = require("_make.project")
local stage = require("_make.stage")
local types = require("_make.types")

local type File = types.File
local type Project = types.Project

--- The target's own arguments, as `split` found them.
local target_argv: {string} = {}

--- The manifest for a run lands under the build directory, keyed by the
--- target's own path — the same mirror rule every other output follows,
--- so two runs of two targets do not share one file.
--- @param path string The target path, relative to the root
--- @return string The manifest's output base
local function out_base(path: string): string
  return project.out_dir(path) .. ".run"
end

--- The project file for a path, or nil when the model does not have one.
--- @param proj Project The scanned project
--- @param path string A path, as typed
--- @return File|nil The file
local function file_of(proj: Project, path: string): File | nil
  local want = fs.relpath(fs.abspath(path), proj.root) or path
  for _, f in ipairs(proj.files) do
    if f.path == want or f.path == path then
      return f
    end
  end
  return nil
end

--- Refuse in the shape the rest of the verbs refuse in.
--- @param detail string What was wrong
--- @return integer Exit code
local function refuse(detail: string): integer
  io.stderr:write("make: " .. detail .. "\n")
  return stage.verdict("run", false, "bad target")
end

--- `run`'s pre-flight, for `_make.law`: exactly one path, and it names
--- a source the model knows.
---
--- A binary name gets its own sentence rather than "no such selection":
--- it is the rejected `run [binary]` spelling, so it is the one wrong
--- guess worth answering precisely.
--- @param proj Project The scanned project
--- @param paths {string} The selection paths, as typed
--- @return boolean Whether the selection names something
--- @return string The complaint, ready for stderr
local function resolve(proj: Project, paths: {string}): boolean, string
  if #paths ~= 1 then
    return false, "make: run takes exactly one path"
  end
  if file_of(proj, paths[1]) ~= nil then
    return true, ""
  end
  for _, b in ipairs(proj.binaries) do
    if b.name == paths[1] then
      return false, "make: run takes a path, not a binary name; " ..
      "build it and run " .. project.out_dir("bin/" .. b.name)
    end
  end
  return false, "make: no such source: " .. paths[1]
end

--- Split a passthrough verb's argv into its target and the target's own
--- arguments.
---
--- Here rather than in the registry's argv scan because it is `run`'s
--- rule, not the scan's: everything after the one path belongs to the
--- program. Refusing a leading `-` is right for a selection and wrong
--- here -- `run _perf/run.tl --out o/perf/x.json` is the whole point,
--- and those flags are the harness's.
--- The target's arguments are kept HERE rather than handed back to the
--- registry, next to the rule that produced them -- the same shape
--- `--baseline` and `--fix` have over there, for the same reason: it is
--- not a selection, it is what the verb does with the one it has.
--- @param argv {string} The full `--make` argv
--- @param from integer The first index after the verb name
--- @return string|nil The target path, or nil when none was given
--- @return string The complaint when there is no target
local function split(argv: {string}, from: integer): string | nil, string
  local path: string | nil = nil
  target_argv = {}
  for i = from, #argv do
    local a = argv[i]
    if path == nil and a:sub(1, 1) ~= "-" then
      path = a
    elseif path ~= nil then
      target_argv[#target_argv + 1] = a
    else
      return nil, "make: run takes a path first, got '" .. a .. "'"
    end
  end
  if path == nil then
    return nil, "make: run needs a path"
  end
  return path, ""
end

--- Build, then run.
--- @param proj Project The scanned project
--- @param path string The target source, relative to the root
--- @param cosmic string Absolute path to this binary
--- @param prepare function(Project, string): boolean, string The stage builder
--- @return integer Exit code
local function run(proj: Project, path: string, cosmic: string,
    prepare: function(Project, string): (boolean, string)): integer
  local ok, detail = resolve(proj, {path})
  if not ok then
    return refuse(detail)
  end
  local ready, perr = prepare(proj, cosmic)
  if not ready then
    return stage.verdict("run", false, perr)
  end
  local self = file_of(proj, path) as File -- cast: resolve() proved it
  local built = deps.built_paths(deps.closure(proj, self, deps.index(proj)))
  local target_lua = deps.built_path(self.path, project.BUILD_DIR)
  -- prepare_stage builds nothing when the project declares no binary,
  -- so `run` would spawn a target it never compiled. Generate inputs,
  -- then build the target and its runtime closure directly, so the
  -- spawn resolves against fresh o/ output the way the with-a-binary
  -- path (which compiles the whole tree) already does.
  if #proj.binaries == 0 then
    local gok, gerr = generate.sources(proj, cosmic)
    if not gok then
      return stage.verdict("run", false, gerr or "generate failed")
    end
    local code, cerr = graph.run(proj, target_lua, {}, cosmic, built)
    if code ~= 0 then
      if cerr and cerr ~= "" then
        io.stderr:write(cerr .. "\n")
      end
      return stage.verdict("run", false, "build")
    end
  end
  local child_argv: {string} = {cosmic, target_lua}
  modules.attach(child_argv, out_base(self.path), proj.root, built)
  for _, a in ipairs(target_argv) do
    child_argv[#child_argv + 1] = a
  end
  -- stdio inherited: `run` is a passthrough, and a harness that prints
  -- a line per scenario is unreadable buffered to the end. stdin is the
  -- parent's fd 0 handed through a DUP, not the "inherit" string (which
  -- resolve_stdio reads as literal pipe DATA): the dup lets the child
  -- read the real terminal, and closing our copy after cannot touch the
  -- true stdin.
  local dup0, derr = unix.dup(0)
  if dup0 == nil then
    return stage.verdict("run", false, "dup stdin: " .. tostring(derr))
  end
  local stdin0 = fd.wrap(dup0)
  -- TRANSITIONAL dual-shape dispatch (delete at the next pin advance,
  -- #981-class): the pinned binary's child.run returns a Result with
  -- spawn_error folded in; the tree's returns Result | nil, string.
  -- cast: transitional dual-shape call
  local run_dual = child.run as function({string}, child.Options): (any, any)
  local res_any, rerr = run_dual(child_argv,
    {cwd = proj.root, stdout = "inherit", stderr = "inherit", stdin = stdin0})
  local _ok, _err = stdin0:close()
  -- cast: transitional dual-shape probe
  local spawn_err = res_any ~= nil and (res_any as {string: any}).spawn_error or rerr
  if res_any == nil or spawn_err ~= nil then
    return stage.verdict("run", false, tostring(spawn_err or "start failed"))
  end
  local res = res_any as child.Result -- cast: transitional dual-shape result
  if not res.ok then
    -- The TARGET's exit code, not a verdict's: `run` is a passthrough,
    -- and a caller that branches on it is asking about the program.
    return res.code or 1
  end
  return 0
end

local record RunModule
  out_base: function(path: string): string
  split: function(argv: {string}, from: integer): string | nil, string
  resolve: function(proj: Project, paths: {string}): boolean, string
  run: function(proj: Project, path: string, cosmic: string,
  prepare: function(Project, string): (boolean, string)): integer
end

local M: RunModule = {
  out_base = out_base,
  split = split,
  resolve = resolve,
  run = run,
}

return M
