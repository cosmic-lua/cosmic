--- Isolated byte-string fuzzing with captured failures and corpus replay.
--- run checks testdata/fuzz/<name>/*.input before a deterministic generated
--- sample (256 iterations, seed 1). FUZZ_SEED/FUZZ_ITERS override defaults;
--- explicit options override the environment. Test files declare those env
--- inputs and `reads: testdata/fuzz` so the test cache sees their dependencies.
--- Each property runs in a child that re-enters the same script. Names must
--- be unique in that script; setup outside run must tolerate re-entry.
--- Checks must derive their assertions from the input bytes for standalone
--- replay. A replay that passes does not erase the original failure.
--- Failures are saved under the test step's $TMP/fuzz or o/fuzz. promote is the
--- explicit operation that copies a captured input into the source corpus.
local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local generate = require("cosmic.fuzz.generate")
local source = require("cosmic.fuzz.source")
local storage = require("cosmic.fuzz.storage")
local types = require("cosmic.fuzz.types")
local worker = require("cosmic.fuzz.worker")

local function integer_env(name: string, fallback: integer): integer | nil
  local raw = env.get(name)
  if not raw then return fallback end
  return math.tointeger(tonumber(raw))
end

--- Render a result for a test failure or command-line diagnostic.
local function describe(r: types.Result): string
  return string.format("%s: %s seed=%d iteration=%d generated=%d corpus=%d: %s%s",
    r.name, r.status, r.seed, r.iteration, r.generated, r.corpus, r.message,
    r.saved_input ~= "" and ("; input=" .. r.saved_input .. "; replay=" .. r.reproduction) or "")
end

--- Assert a result in a test. A worker's unselected sibling is allowed;
--- the supervising parent still requires the selected property's completion.
local function assert_ok(r: types.Result)
  check.truthy(r.status == "pass" or r.status == "skipped", describe(r))
end

--- Run an isolated property and return a structured, explicitly classified result.
local function run(opts: types.Options): types.Result
  local seed = opts.seed or integer_env("FUZZ_SEED", 1)
  local iters = opts.iters or integer_env("FUZZ_ITERS", 256)
  local r = storage.new(opts.name, seed or 1)
  local function failed(message: string): types.Result
    r.status, r.message = "error", message
    return r
  end
  if env.get("FUZZ_ISOLATE") then return failed("ambient FUZZ_ISOLATE is not supported") end
  if not opts.name:match("^[%w_.-]+$") or opts.name == "." or opts.name == ".." then
    return failed("property name must contain only letters, digits, _, . or -")
  end
  if not seed or not iters or iters < 0 or iters > 1000000000 then
    return failed("seed and iterations must be integers; iterations must be in 0..1000000000")
  end
  if (opts.budget and opts.budget < 1) or (opts.timeout_ms and opts.timeout_ms < 1) then
    return failed("budget and timeout_ms must be positive")
  end
  -- Copy options: worker-selected replay must not mutate a caller's reusable record.
  local settings: types.Options = {name = opts.name, gen = opts.gen, check = opts.check,
    seed = seed, iters = iters, budget = opts.budget, timeout_ms = opts.timeout_ms,
    corpus_dir = opts.corpus_dir, artifact_dir = opts.artifact_dir, replay_input = opts.replay_input}
  local entered = worker.enter(settings)
  if entered then return entered end
  local test_output = env.get("TEST_TMPDIR") and env.get("TMP")
  local root = opts.artifact_dir or fs.join(test_output or "o", "fuzz")
  local made, err = fs.make_dirs(root)
  if not made then return failed("artifact directory: " .. tostring(err)) end
  local dir, why = fs.temp_dir(fs.join(root, opts.name .. "-XXXXXX"))
  if not dir then return failed("run directory: " .. tostring(why)) end
  r = worker.supervise(settings, dir)
  if r.status ~= "pass" and r.has_input and opts.replay_input == nil then
    local replay_dir, replay_err = fs.temp_dir(fs.join(dir, "replay-XXXXXX"))
    if replay_dir then
      settings.replay_input = r.input
      local replayed = worker.supervise(settings, replay_dir)
      if replayed.status == "error" then
        r.reproduction = "unavailable"
        r.message = r.message .. "; replay: " .. replayed.message
      elseif replayed.status == r.status and replayed.failure_kind == r.failure_kind
      and replayed.signal == r.signal then
        r.reproduction = "reproduced"
      else
        r.reproduction = "not_reproduced"
      end
    else
      r.reproduction = "unavailable"
      r.message = r.message .. "; replay directory: " .. tostring(replay_err)
    end
  end
  if r.status == "pass" then
    local removed, remove_err = fs.remove_all(dir)
    if not removed then return failed("cleanup: " .. tostring(remove_err)) end
  else
    local saved, save_err = storage.save(dir, r)
    if not saved then
      r.status, r.message = "error", r.message .. "; save failed: " .. tostring(save_err)
    end
  end
  return r
end

local record FuzzModule
  type Options = types.Options
  type Result = types.Result
  type Recorder = source.Recorder
  type Draw = source.Draw
  replay_source: function(draws: {source.Draw}): source.Recorder
  run: function(opts: types.Options): types.Result
  assert_ok: function(result: types.Result)
  describe: function(result: types.Result): string
  promote: function(result: types.Result, corpus_dir: string): boolean, string
  read_result: function(path: string): types.Result | nil, string
  bytes: function(src: source.Recorder, max_len: integer): string
  mutate: function(src: source.Recorder, sample: string, edits: integer): string
end
local M: FuzzModule = {run = run, assert_ok = assert_ok, describe = describe,
  promote = storage.promote, read_result = storage.read, bytes = generate.bytes,
  mutate = generate.mutate, replay_source = source.replay}
return M
