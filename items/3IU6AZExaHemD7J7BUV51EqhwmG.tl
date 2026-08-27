return {
  ["block_reason"] = {
    ["3IP9ijhvSdH0h5uTjb4xOlgZKZ9"] = "discover skips a test_* definition whose body carries a function token in TYPE position (end_line_of loses the closer), so the generated tail omits that case and the test silently stops running; 17 definitions across 10 files tree-wide, including files in this batch's scope",
    ["3IU62YqO7uyYrJt53x6fmaE6dlJ"] = "_build/coldbuild_test.tl type-checks the tree with the pinned release's checker, which predates the D29 seam, so any runner-mode test file fails it with an uncalled-local warning until the pin names a release carrying #1446",
  },
  ["blocked_by"] = "3IU62YqO7uyYrJt53x6fmaE6dlJ 3IP9ijhvSdH0h5uTjb4xOlgZKZ9",
  ["builders"] = "e831e06e-2f80-53d1-84e9-8198069f90ed --session",
  ["claim"] = "--session",
  ["id"] = "3IU6AZExaHemD7J7BUV51EqhwmG",
  ["parent"] = "3IOCdooEOElQSPH42nr5xOrAQVn",
  ["phase"] = "do",
  ["title"] = "migrate to runner mode, batch 1/7: _build, _docs, _types, 3p, _fuzz, _eval, _perf, _tool",
}
