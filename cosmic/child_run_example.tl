--- Worked example for [`Child.run`], shown by `cosmic docs` under the
--- symbol it demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Child = require("cosmic.child")
local Test = require("cosmic.test")

--- The host program the example runs, `/bin/sh`, which the sandboxed
--- worker sees only when the module declares `system`.
Test.needs{ system = true }

local Example = {}

--- A host program run to completion, its output collected: a failing
--- exit is a `Result` with `ok` false and the status in `code`, not an
--- error. `argv[1]` is a path, as given: [`Proc.find`] finds a program by
--- name.
function Example.run()
  local result = assert(Child.run(
    { "/bin/sh", "-c", "echo out; echo warning >&2; exit 3" },
    { stdout = "capture", stderr = "capture" }))
  print(result.stdout, result.stderr, result.code)
  assert(result.stdout == "out\n", result.stdout)
  assert(result.stderr == "warning\n", result.stderr)
  assert(result.code == 3 and not result.ok and not result.timed_out)
end

return Example
