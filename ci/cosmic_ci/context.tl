local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local State = require("cosmic_ci.state")

-- Every driver subcommand reads its context from the environment instead of
-- eight positional arguments a workflow step used to spell out: the
-- workflow sets GITHUB_WORKSPACE, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT,
-- RUNNER_TEMP and COSMIC_WORKER once per job (TARGET once per `platform`
-- job), rather than on every step.
local record Context
  db: string
  root: string
  run: string
  attempt: string
  worker: string
  work: string
  products: string
end

local function required(name: string): string
  local value = Env.get(name)
  assert(value and value ~= "", "missing required environment variable: " .. name)
  return value
end

-- All driver state lives under $RUNNER_TEMP/cosmic-ci/: the operations
-- database, the platform work directory, and the provenance products
-- directory. The scratch directory is resolved as an external path --
-- outside the candidate, symlinks rejected -- BEFORE anything is created
-- there, so a RUNNER_TEMP pointed inside the candidate is refused without
-- leaving anything behind; only then is it created. RUNNER_TEMP's parent
-- for this purpose is RUNNER_TEMP itself, which always exists in CI.
local function scratch_path(): string
  return required("RUNNER_TEMP") .. "/cosmic-ci"
end

function Context.read(): Context
  -- Resolved, not asserted canonical: the workspace is the runner's own
  -- path, and the self-check's scratch sits behind a symlink on macOS.
  local root = State.canonical_directory(required("GITHUB_WORKSPACE"))
  local agents_exists = Predicate.exists(root .. "/AGENTS.md")
  assert(agents_exists, "GITHUB_WORKSPACE is not a candidate checkout root")
  local scratch = State.external_path(scratch_path(), root)
  assert(Fs.mkdirs(scratch))
  return {
    db = State.external_path(scratch .. "/operations.db", root),
    root = root,
    run = required("GITHUB_RUN_ID"),
    attempt = required("GITHUB_RUN_ATTEMPT"),
    worker = required("COSMIC_WORKER"),
    work = State.external_path(scratch .. "/platform", root),
    products = scratch .. "/products",
  }
end

function Context.target(): string
  return required("TARGET")
end

-- `summarize` runs whenever the driver bootstrapped (`if: always()`),
-- including after a failed self-check, so it must not depend on the full
-- candidate/worker contract Context.read() enforces -- it only reads the
-- operations database, so it needs nothing but RUNNER_TEMP.
function Context.database(): string
  return scratch_path() .. "/operations.db"
end

return Context
