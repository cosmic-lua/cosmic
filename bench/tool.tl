--- Run-time microbenchmarks of cosmic's own tooling: `bin/cosmic bench/tool.tl [name...]`, run in a checkout.
--- Each case starts the binary that runs this script as a child on a warm cache and times it to its exit: `fix
--- --check` of one file, `test` of one small module, and the checker over a file that was just edited. A case
--- takes seconds, so a batch is one run; use `--rounds` to take more. With `--against <old-binary>` each side runs
--- in its own cache, so a case measures the tool's own cost. Each case is one line on [`bench.harness`]. It
--- measures; it gates nothing, and no test reads its numbers.
local Bench = require("bench.harness")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Proc = require("cosmic.proc")

local bench = Bench.new("tool")
local case = bench.case

local exe = Proc.executable()!

--- A case that runs `exe` with `words` in the working directory, once an operation, after one warming run.
local function tool(name: string, words: {string})
  local argv: mut {string} = { exe }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local function run()
    local result = assert(Child.run(argv, { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(600) }))
    assert(result.code == 0, name .. " exited " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  end
  case(name, function(n: integer)
    for _ = 1, n do run() end
  end, { setup = run })
end

tool("fix --check one file", { "fix", "--check", "cosmic/codec.tl" })
tool("test one module", { "test", "cosmic/codec_test.tl" })
tool("check-types one test", { "test", "--check-types", "cosmic/codec_test.tl" })

return function(argv: {string}): integer return bench.main(argv) end
