--- The recipe steps that do real work — `compile`, `capture`,
--- `record` — and the content-keyed skip that lets them not do it.
---
--- Split from `_cli.build.steps` when the skip outgrew the 500-line
--- cap, on the seam the verbs already had: steps.tl owns the cheap
--- bookkeeping verbs (copy, tee, write-list, asserts), this file owns
--- the two that spawn a child per source and the shared `run_into`
--- contract they write through.
---
--- **The skip.** Make schedules on mtime, and mtimes lie in exactly
--- the situations that hurt: a branch switch restamps every source, a
--- CI cache restore sits under a fresh checkout, a `touch` storm — and
--- the graph re-runs the world to reproduce bytes it already has. So
--- a step that is about to do expensive work first asks a question
--- mtime cannot answer: are the BYTES of my inputs exactly the ones
--- that produced the recorded result? `<out>.in` records the answer —
--- a hash over the step's stable argv, a fixed set of behavior
--- switches from the environment, and the bytes of every input file
--- (the source, the declared closure, and the tool stamps riding in
--- the line). A hit re-stamps the output for make and does nothing; a
--- miss runs the child and re-records.
---
--- Three rules keep it honest:
--- - **Only lines that declare inputs get the skip.** The graph's
---   compile and record lines carry `--deps` (and the compile line its
---   tool stamps); a bare `compile` — the generator mini-graph's
---   spelling, which does its own scheduling and expects a dispatched
---   compile to COMPILE — has no input list to key on, and never skips.
--- - **Only a recorded PASS short-circuits a record.** A failing test
---   deserves to run again, and a SKIP is an answer about the
---   environment, which the key cannot see in full — so both drop the
---   record instead of writing one.
--- - **The output must still be the recorded output.** The key names
---   the output's own hash, so a corrupted or hand-edited artifact is
---   recompiled rather than trusted.
---
--- `.in` is written PLAINLY, not write-if-changed: nothing schedules
--- on its mtime, and an always-fresh write makes it a probe — its
--- mtime moves exactly when the step really ran, which is what the
--- tests observe. Decision record: docs/decisions/d18-step-skip.md.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local modules = require("_cli.build.modules")

--- The one prefix a recipe step's failure wears; see steps.tl.
local function fail(msg: string): integer
  io.stderr:write("cosmic -c: " .. msg .. "\n")
  return 1
end

--- Environment switches that change what a step's child DOES, folded
--- into the key by name=value. Everything else in the environment is
--- assumed inert — the same assumption make itself already makes, so
--- the skip is never less honest than the scheduler above it.
local ENV_SWITCHES < const >: {string} = {
  "CI", "COSMIC_COVERAGE", "COSMIC_FENCE", "COSMIC_FIXPOINT",
  "COSMIC_BENCHMARK_MIN_SECONDS",
}

--- The key over a step's meaning: its stable argv (relative paths and
--- flags — never the absolute driver path, whose identity is the tool
--- stamp's job), the behavior switches, and the bytes of every input.
--- @param label {string} Stable argv fragments
--- @param inputs {string} Files whose BYTES are the meaning
--- @return string|nil The key, or nil when an input cannot be read
local function inkey(label: {string}, inputs: {string}): string | nil
  local parts: {string} = {}
  for _, l in ipairs(label) do
    parts[#parts + 1] = l
    parts[#parts + 1] = "\0"
  end
  for _, name in ipairs(ENV_SWITCHES) do
    parts[#parts + 1] = name .. "=" .. env.get_or(name, "")
    parts[#parts + 1] = "\0"
  end
  for _, p in ipairs(inputs) do
    local body = fs.read(p)
    if not (body is string) then
      return nil
    end
    parts[#parts + 1] = p
    parts[#parts + 1] = "\0"
    parts[#parts + 1] = body
    parts[#parts + 1] = "\0"
  end
  return hash.sha256_hex(table.concat(parts))
end

--- Whether a `.got` records a PASS. The file holds the exit code plus
--- a trailing newline, so this matches the digit, not the bytes.
--- @param path string The `.got` path
--- @return boolean True when the recorded run passed
local function got_pass(path: string): boolean
  local body = fs.read(path)
  return body is string and body:match("^0%s*$") ~= nil
end

--- Read a recorded `<out>.in` into its two fields.
--- @param path string The record's path
--- @return string|nil The input key
--- @return string The output hash ("" when the record has none)
local function recorded(path: string): string | nil, string
  local body = fs.read(path)
  if not (body is string) then
    return nil, ""
  end
  local rin = body:match("^in (%x+)")
  local rout = body:match("\nout (%x+)") or ""
  return rin, rout
end

--- Run argv, pass stderr through, and write stdout to out only when
--- the content changed, so an unchanged result does not touch the
--- output's mtime. (Moved verbatim from steps.tl; see the restamp
--- comment there for why an unchanged result still touches the mtime.)
local function run_into(argv: {string}, out: string): integer
  local result, serr = child.run(argv)
  if not result then
    return fail("spawn " .. argv[1] .. " failed: " .. tostring(serr))
  end
  local r = result as child.Result -- cast: record union after guard
  if r.stderr and r.stderr ~= "" then
    io.stderr:write(r.stderr)
  end
  if not r.ok then
    return r.code or 1
  end
  local existing = fs.read(out)
  if existing == r.stdout then
    -- Same bytes, new schedule: a target whose mtime never advances
    -- stays out of date forever. Content decides what the file IS; the
    -- timestamp records that it was brought up to date.
    local ok, terr = fs.touch(out)
    if not ok then
      io.stderr:write("restamp " .. out .. " failed: " ..
        (terr or "unknown error") .. "\n")
    end
    return 0
  end
  fs.makedirs(fs.dirname(out))
  local ok, werr = fs.write(out, r.stdout)
  if not ok then
    return fail("write " .. out .. " failed: " .. (werr or "unknown error"))
  end
  return 0
end

--- compile <bootstrap> <src> <out> [flags...] [--deps <inputs>...]
--- Always a STRICT compile under LUA_PATH=";;" (see steps.tl history).
--- Everything after --deps is an INPUT — the source closure and the
--- tool stamps the rule names — granted to the fence, keyed by the
--- skip, and never forwarded to the child.
local function do_compile(args: {string}): integer
  local src, out = args[2], args[3]
  if not out then
    return fail("usage: compile <bootstrap> <src> <out> [flags...]"
      .. " [--deps <path>...]")
  end
  local label: {string} = {"compile"}
  local inputs: {string} = {src}
  local in_deps = false
  for i = 2, #args do
    if args[i] == "--deps" then
      in_deps = true
    elseif in_deps then
      inputs[#inputs + 1] = args[i]
    else
      label[#label + 1] = args[i]
    end
  end
  local key: string | nil = nil
  if in_deps then
    key = inkey(label, inputs)
  end
  local record_path = out .. ".in"
  if key is string then
    local rin, rout = recorded(record_path)
    if rin == key then
      local body = fs.read(out)
      if body is string and hash.sha256_hex(body) == rout then
        local ok, terr = fs.touch(out)
        if ok then
          return 0
        end
        io.stderr:write("restamp " .. out .. " failed: " ..
          (terr or "unknown error") .. "\n")
      end
    end
  end
  env.set("LUA_PATH", ";;")
  local argv: {string} = {args[1]}
  for i = 4, #args do
    -- Forwarding an input as an argument was a silent disaster once
    -- already (see the history in steps.tl): stop at --deps.
    if args[i] == "--deps" then
      break
    end
    table.insert(argv, args[i])
  end
  table.insert(argv, "--compile-strict")
  table.insert(argv, src)
  local code = run_into(argv, out)
  if code == 0 and key is string then
    local body = fs.read(out)
    if body is string then
      fs.write(record_path, "in " .. key .. "\nout " ..
        hash.sha256_hex(body) .. "\n")
    end
  end
  return code
end

--- capture <bootstrap> <out> <script+args...> — run a script under the
--- bootstrap and write its stdout to out if changed. No skip: its one
--- caller declares no inputs, and a captured script may read anything.
local function do_capture(args: {string}): integer
  local bootstrap, out = args[1], args[2]
  if not out or not args[3] then
    return fail("usage: capture <bootstrap> <out> <script> [args...]")
  end
  local argv: {string} = {bootstrap}
  for i = 3, #args do
    table.insert(argv, args[i])
  end
  return run_into(argv, out)
end

--- record <out> <cmd> [args...] [--deps <inputs>...] — run one test
--- file, writing the `<out>.got`/`.out`/`.err` contract testrun owns,
--- and then **always succeed** (grading is `--report`'s job; see the
--- history in steps.tl). The skip may stand in for a run whose inputs
--- are byte-identical AND whose recorded verdict was a PASS: a `.got`
--- of 0 restamps and the child never spawns. A recorded failure or
--- skip always re-runs — a failure deserves the retry, and a skip is a
--- statement about the environment the key cannot see in full.
local function do_record(args: {string}): integer
  local out = args[1]
  if not out or not args[2] then
    return fail("usage: record <out> <cmd> [args...]")
  end
  local argv: {string} = {}
  local deps: {string} = {}
  local in_deps = false
  for i = 2, #args do
    if args[i] == "--deps" then
      in_deps = true
    elseif in_deps then
      deps[#deps + 1] = args[i]
    else
      argv[#argv + 1] = args[i]
    end
  end
  local key: string | nil = nil
  local record_path = out .. ".in"
  if in_deps then
    -- The label is the argv MINUS the driver's absolute path (its
    -- identity is the record stamp, an input below) and minus input
    -- files, which are keyed by bytes: the target and the closure.
    local label: {string} = {"record"}
    local inputs: {string} = {}
    for i = 2, #argv do
      if fs.isfile(argv[i]) then
        inputs[#inputs + 1] = argv[i]
      else
        label[#label + 1] = argv[i]
      end
    end
    for _, d in ipairs(deps) do
      inputs[#inputs + 1] = d
    end
    inputs[#inputs + 1] = "o/.stamp/record"
    key = inkey(label, inputs)
  end
  if key is string then
    local rin = recorded(record_path)
    if rin == key and got_pass(out .. ".got") then
      local ok, terr = fs.touch(out .. ".got")
      if ok then
        return 0
      end
      io.stderr:write("restamp " .. out .. ".got failed: " ..
        (terr or "unknown error") .. "\n")
    end
  end
  modules.attach(argv, out, fs.abspath("."), deps)
  local scratch = fs.abspath(out .. ".tmp.d")
  env.set("TMP", scratch)
  fs.makedirs(scratch)
  fs.unlink(out .. ".got") -- freshness: an early testrun exit writes none
  local testrun = require("cosmic.testrun")
  testrun.run(argv, out)
  if not fs.isfile(out .. ".got") then
    return fail("record " .. out .. ": no result recorded")
  end
  if key is string and got_pass(out .. ".got") then
    fs.write(record_path, "in " .. key .. "\n")
  else
    fs.unlink(record_path)
  end
  return 0
end

local record WorkModule
  inkey: function(label: {string}, inputs: {string}): string | nil
  compile: function(args: {string}): integer
  capture: function(args: {string}): integer
  record: function(args: {string}): integer
  run_into: function(argv: {string}, out: string): integer
end

local M: WorkModule = {
  inkey = inkey,
  compile = do_compile,
  capture = do_capture,
  record = do_record,
  run_into = run_into,
}

return M
