--- Benchmarks for the greet package, so `--make benchmark` has a target
--- that measures something rather than reporting a green skip.

-- Each Benchmark_* body is extracted and run as its OWN chunk, so a
-- require at file scope is not in scope inside one. They require what
-- they use themselves.
local function Benchmark_hi()
  local greet = require("greet")
  local _ = greet.hi("world")
end

-- Suppress unused warnings, the way examples do: the runner finds these
-- by name in the source, so nothing in the file calls them.
local _ = {Benchmark_hi}
