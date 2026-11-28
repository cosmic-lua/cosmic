--- The names a test module's runner calls: a top-level `local function` of a `*_test.tl` file whose name starts
--- with one of [`TestNames.prefixes`] is found by its name alone, with no registration. `test_*` is a test, and
--- `bench_*` a bench, which a plain `cosmic test` runs once and `cosmic test --bench` times
--- (doc/decisions/0002-one-companion-one-runner.md).
local record TestNames
  --- What a called function's name starts with.
  prefixes: {string}
end

TestNames.prefixes = { "test_", "bench_" }

--- Whether a top-level `local function` named `name` is one the runner calls.
function TestNames.called(name: string): boolean
  for _, prefix in ipairs(TestNames.prefixes) do
    if name:sub(1, #prefix) == prefix then return true end
  end
  return false
end

--- Whether the function named `name` is a bench, which the runner hands a [`Bench.B`] rather than a directory.
function TestNames.is_bench(name: string): boolean
  return name:sub(1, 6) == "bench_"
end

return TestNames
