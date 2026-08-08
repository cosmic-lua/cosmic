--- Examples for cosmic.sandbox, the one in-process containment door.
--- Applying is irreversible, so each example runs the sandboxed code
--- in a subprocess via cosmic.child and captures the result.

-- Example_apply demonstrates the one-call policy: a filesystem
-- allowlist and a syscall pledge together. Inside the subprocess,
-- reads outside the allowlist fail once apply returns.
local function Example_apply()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local cosmic = arg[-1]
  local script = [[
local sandbox = require("cosmic.sandbox")
local applied, err = sandbox.apply{
  fs = { ro = { "/etc" }, rw = { "/tmp" } },
  sys = { promises = "stdio rpath wpath" },
  best_effort = true,
}
assert(applied, err)
io.write("sandboxed\n")
]]
  local r = check.must(child.run({cosmic, "-e", script}))
  io.write(r.stdout)
  -- Output:
  -- sandboxed
end

-- Example_availability shows the enforceability report: what THIS host
-- can enforce, per section, and the boolean shorthand. A best_effort
-- apply returns the same record shape saying what it actually did.
local function Example_availability()
  local sandbox = require("cosmic.sandbox")
  local a = sandbox.availability()
  io.write(type(a.fs) == "boolean" and "fs known\n" or "fs unknown\n")
  io.write(type(sandbox.is_available()) == "boolean" and "one answer\n" or "?\n")
  -- Output:
  -- fs known
  -- one answer
end

-- Example_merge composes policies the way quicksand composes Box
-- options: path lists concat and dedupe, scalars take the later value.
local function Example_merge()
  local sandbox = require("cosmic.sandbox")
  local base = {fs = {ro = {"/etc"}}}
  local extra = {fs = {ro = {"/usr"}, optional = true}}
  local merged = sandbox.merge(base, extra)
  io.write(#merged.fs.ro, " ro paths\n")
  -- Output:
  -- 2 ro paths
end

-- Suppress unused warnings for examples
local _ = {Example_apply, Example_availability, Example_merge}
