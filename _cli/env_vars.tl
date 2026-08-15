--- The COSMIC_* environment variable registry (#1003).
--- One table, two roles. A PUBLIC row is a knob a person sets, and
--- `--help` renders exactly these rows; an INTERNAL row is set by the
--- build or the toolchain for its own children, declared here so the
--- split is a checkable fact instead of a prose claim. The ratchet
--- (`_build/env_vars_test.tl`) scans the tree both ways: a variable
--- code reads that this table does not carry fails the gate, and so
--- does a row nothing reads — the two ways the old hand-typed help
--- section drifted.

--- One variable: its name, what setting it does, and whether a person
--- is meant to set it.
local record Var
  name: string
  desc: string
  public: boolean
end

local VARS < const >: {Var} = {
  -- Public: knobs a person sets.
  {name = "COSMIC_FENCE", public = true,
    desc = "0 opts out of the derived build sandbox (on by default)"},
  {name = "COSMIC_FAIL_FAST", public = true,
    desc = "nonempty stops a batched compile at its first failure"},
  {name = "COSMIC_JOBS", public = true,
    desc = "build parallelism (default: one job per cpu)"},
  {name = "COSMIC_MAKE_ROOT", public = true,
    desc = "name the project root instead of using the cwd"},
  {name = "COSMIC_VERSION", public = true,
    desc = "the --version stamp, when no .version is committed"},
  {name = "COSMIC_COVERAGE", public = true,
    desc = "directory to dump line-coverage .cov files into"},
  {name = "COSMIC_INSTRUMENTATION", public = true,
    desc = "1 emits timing spans to stderr"},
  {name = "COSMIC_LOG_LEVEL", public = true,
    desc = "cosmic.log's threshold"},
  {name = "COSMIC_NO_REQUIRE_HINTS", public = true,
    desc = "disable helpful module-not-found suggestions"},
  {name = "COSMIC_NO_WELCOME", public = true,
    desc = "suppress welcome message on first run"},
  {name = "COSMIC_FULL_TRACEBACK", public = true,
    desc = "show full stack traceback including internal frames"},
  {name = "COSMIC_DEBUG", public = true,
    desc = "1 traces env.d loading on stderr (names only, never values)"},
  {name = "COSMIC_ENFORCE", public = true,
    desc = "1 fails sandbox tests that would otherwise skip"},
  {name = "COSMIC_FIXPOINT", public = true,
    desc = "1 runs the gated two-build fixpoint test"},
  {name = "COSMIC_BENCHMARK_MIN_MS", public = true,
    desc = "--benchmark's per-run timing floor, in milliseconds"},
  {name = "COSMIC_TL_CACHE_DIR", public = true,
    desc = "where compiled-script caches live"},
  {name = "COSMIC_EMBED", public = true,
    desc = "env fallback for --embed (colon-separated paths)"},
  {name = "COSMIC_OUTPUT", public = true,
    desc = "env fallback for --output"},
  {name = "COSMIC_EXTRACT", public = true,
    desc = "env fallback for --extract"},
  -- Internal: the build sets these for its own children.
  {name = "COSMIC_MAKE", public = false,
    desc = "the engine a recipe line runs under"},
  {name = "COSMIC_MAKE_GEN", public = false,
    desc = "the converge generation counter"},
  {name = "COSMIC_MAKE_STEP", public = false,
    desc = "marks the converging build's child as a gate step"},
  {name = "COSMIC_EXEC_ROOT", public = false,
    desc = "the root an exec step may write beneath"},
}

--- Every declared name, as a set, for the ratchet's membership check.
--- @return {string: boolean} Declared names, public and internal alike
local function names(): {string: boolean}
  local out: {string: boolean} = {}
  for _, v in ipairs(VARS) do
    out[v.name] = true
  end
  return out
end

--- The public rows rendered as help lines, aligned like the module
--- list: two leading spaces, names padded to the longest.
--- @return {string} One line per public variable
local function help_lines(): {string}
  local max_len = 0
  for _, v in ipairs(VARS) do
    if v.public and #v.name > max_len then
      max_len = #v.name
    end
  end
  local out: {string} = {}
  for _, v in ipairs(VARS) do
    if v.public then
      out[#out + 1] = "  " .. v.name ..
      string.rep(" ", max_len - #v.name + 2) .. v.desc
    end
  end
  return out
end

local record EnvVarsModule
  type Var = Var
  rows: {Var}
  names: function(): {string: boolean}
  help_lines: function(): {string}
end

local M: EnvVarsModule = {
  rows = VARS,
  names = names,
  help_lines = help_lines,
}

return M
