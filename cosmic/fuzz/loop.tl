--- Worker loop: capture before execution, corpus before generated inputs.
local budget = require("cosmic.fuzz.budget")
local fs = require("cosmic.fs")
local errno = require("cosmic.errno")
local rand = require("cosmic.rand")
local shrink = require("cosmic.fuzz.shrink")
local source = require("cosmic.fuzz.source")
local storage = require("cosmic.fuzz.storage")
local types = require("cosmic.fuzz.types")

local function run(opts: types.Options, dir: string): types.Result
  local r = storage.new(opts.name, opts.seed)
  local path = fs.join(dir, "current.json")
  local instruction_budget = opts.budget or budget.default
  local function capture(phase: string, input?: string): boolean
    r.phase, r.has_input, r.input = phase, input ~= nil, input or ""
    local ok, err = storage.write(path, r)
    if not ok then r.status, r.message = "error", "capture: " .. tostring(err) end
    return ok
  end
  local function attempt(input: string, phase?: string): boolean
    if not capture(phase or "check", input) then return false end
    local result = budget.attempt(opts.check, input, instruction_budget)
    if result.held then return true end
    r.status, r.message, r.failure_kind = "failure", result.message, result.kind
    if r.failure_kind == "budget" then r.status = "timeout" end
    return false
  end
  local function minimize(draws: {source.Draw})
    if r.status ~= "failure" then return end
    -- Preserve the first failure even if a shrink candidate crashes or hangs.
    local ok, err = storage.write(fs.join(dir, "original.json"), r)
    if not ok then r.status, r.message = "error", tostring(err); return end
    local expected_kind = r.failure_kind
    local best_input, best_message = r.input, r.message
    local best_draws, candidate_draws = r.draws, 0
    local function generate_candidate(rec: source.Recorder): string
      local input = opts.gen(rec)
      candidate_draws = #rec.draws
      return input
    end
    local function candidate(input: string): boolean, string
      if not capture("shrink", input) then return true end
      local result = budget.attempt(opts.check, input, instruction_budget)
      if not result.held and result.kind == expected_kind then
        best_input, best_message = input, result.message
        best_draws = candidate_draws
        return false, result.message
      end
      return true
    end
    shrink.shrink(generate_candidate, candidate, draws)
    if r.status == "error" then return end
    r.input, r.message, r.draws = best_input, best_message, best_draws
    r.has_input, r.phase = true, "check"
  end
  if opts.replay_input ~= nil then
    r.iteration = 1
    if attempt(opts.replay_input, "replay") then r.status = "pass" end
    return r
  end
  local corpus_dir = fs.join(opts.corpus_dir or "testdata/fuzz", opts.name)
  local corpus_stat, stat_err = fs.stat(corpus_dir)
  if not corpus_stat and errno.name_in(stat_err) ~= "ENOENT" then
    r.status, r.message = "error", "corpus: " .. tostring(stat_err); return r
  end
  if corpus_stat then
    if not fs.is_dir(corpus_dir) then
      r.status, r.message = "error", "corpus path is not a directory"; return r
    end
    local found, err = fs.glob(corpus_dir, "*.input")
    if not found then r.status, r.message = "error", tostring(err); return r end
    if found.errors and #found.errors > 0 then
      r.status, r.message = "error", "cannot enumerate corpus"; return r
    end
    table.sort(found)
    for _, file in ipairs(found) do
      local input, why = fs.read(file)
      if not input then r.status, r.message = "error", tostring(why); return r end
      r.iteration = r.corpus + 1
      if not attempt(input, "corpus") then return r end
      r.corpus = r.corpus + 1
    end
  end
  for i = 1, opts.iters do
    r.iteration, r.draws = i, 0
    if not capture("generate") then return r end
    local rec = source.new(rand.insecure_source(opts.seed + i))
    local generated, input = pcall(opts.gen, rec)
    if not generated then
      r.status, r.failure_kind, r.message = "error", "generator", tostring(input)
      return r
    end
    r.draws = #rec.draws
    if not attempt(input) then
      minimize(rec.draws)
      return r
    end
    r.generated = r.generated + 1
  end
  r.status, r.phase, r.has_input, r.input = "pass", "complete", false, ""
  return r
end

return {run = run}
