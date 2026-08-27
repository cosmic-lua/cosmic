return {
  ["block_reason"] = {
    ["3IP9ijhvSdH0h5uTjb4xOlgZKZ9"] = "discover skips a test_* definition whose body carries a function token in TYPE position (end_line_of loses the closer), so the generated tail omits that case and the test silently stops running; 17 definitions across 10 files tree-wide, including files in this batch's scope",
    ["3IU62YqO7uyYrJt53x6fmaE6dlJ"] = "_build/coldbuild_test.tl type-checks the tree with the pinned release's checker, which predates the D29 seam, so any runner-mode test file fails it with an uncalled-local warning until the pin names a release carrying #1446",
  },
  ["blocked_by"] = "3IU62YqO7uyYrJt53x6fmaE6dlJ 3IP9ijhvSdH0h5uTjb4xOlgZKZ9",
  ["id"] = "3IU6AgNNxVcDWuDwet2j1TW1wCb",
  ["parent"] = "3IOCdooEOElQSPH42nr5xOrAQVn",
  ["phase"] = "plan",
  ["title"] = "migrate to runner mode, batch 2/7: _cli, _make",
}
