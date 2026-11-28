--- The old cosmic of build/test_bench_tool_test.tl's `--against` tests, built by [`cosmic.fake`]: as
--- `test --bench --json ...` it prints one bench's object, a second an operation, so the new side is always faster.

local Steps = require("cosmic.fake.steps")

local cases: {string:function({string}): integer} = {
  test = function(_: {string}): integer
    return Steps.print('{"name":"tally_test.tl:bench_sum","best":1000000000,"median":1000000000,"n":1,' ..
        '"rounds":3,"unit":"ns/op","samples":[1000000000]}') or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("test against fake", cases, argv)
end

return main
