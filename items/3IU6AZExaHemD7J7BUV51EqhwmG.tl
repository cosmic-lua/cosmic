return {
  ["block_reason"] = {
    ["3IP9ijhvSdH0h5uTjb4xOlgZKZ9"] = "discover skips a test_* definition whose body carries a function token in TYPE position (end_line_of loses the closer), so the generated tail omits that case and the test silently stops running; 17 definitions across 10 files tree-wide, including files in this batch's scope",
    ["3IU62YqO7uyYrJt53x6fmaE6dlJ"] = "_build/coldbuild_test.tl type-checks the tree with the pinned release's checker, which predates the D29 seam, so any runner-mode test file fails it with an uncalled-local warning until the pin names a release carrying #1446",
    ["3IUJSV7eIcrpVIs1kmGBvCTQuSC"] = "the pinned cb39b65 checker's old discover misses _types/tlast_test.tl's second definition, so the migrated file fails _build/coldbuild_test.tl (unused function under generation 1) until the pin names a release carrying #1455",
  },
  ["blocked_by"] = "3IU62YqO7uyYrJt53x6fmaE6dlJ 3IP9ijhvSdH0h5uTjb4xOlgZKZ9 3IUJSV7eIcrpVIs1kmGBvCTQuSC",
  ["builders"] = "e831e06e-2f80-53d1-84e9-8198069f90ed --session 0b13d2b4-bb26-5bc1-8635-407acd85452c 05f7c552-0c90-51cb-99b3-e018759c6ed5",
  ["claim"] = "05f7c552-0c90-51cb-99b3-e018759c6ed5",
  ["id"] = "3IU6AZExaHemD7J7BUV51EqhwmG",
  ["parent"] = "3IOCdooEOElQSPH42nr5xOrAQVn",
  ["pr"] = 1458,
  ["resolution"] = "completed",
  ["title"] = "migrate to runner mode, batch 1/7: _build, _docs, _types, 3p, _fuzz, _eval, _perf, _tool",
  ["verdict"] = "accept",
}
