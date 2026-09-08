--- Records shared by the fuzz runner, worker and persistent results.
local source = require("cosmic.fuzz.source")

--- A byte-string property. Names must be unique within the entry script.
local record Options
  name: string
  gen: function(src: source.Recorder): string
  check: function(input: string): boolean, string
  seed: integer
  iters: integer
  budget: integer
  timeout_ms: integer
  --- Root containing <name>/*.input; default testdata/fuzz.
  corpus_dir: string
  --- Root for captured failures; default the test step's $TMP/fuzz or o/fuzz.
  artifact_dir: string
  --- Replay these exact bytes instead of the corpus and generator.
  replay_input: string
end

--- Explicit outcomes: pass, failure, crash, timeout, error, skipped.
--- skipped is internal to a worker re-entering its sibling properties.
--- running is an unfinished capture and can never be a successful result.
local record Result
  status: string
  name: string
  seed: integer
  iteration: integer
  generated: integer
  corpus: integer
  draws: integer
  phase: string
  failure_kind: string
  message: string
  has_input: boolean
  input: string
  signal: integer
  --- reproduced, not_reproduced, unavailable, or not_attempted.
  reproduction: string
  saved_input: string
  saved_result: string
end

local record Types
  type Options = Options
  type Result = Result
end
local M: Types = {}
return M
