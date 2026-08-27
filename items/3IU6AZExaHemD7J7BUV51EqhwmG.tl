return {
  ["block_reason"] = {
    ["3IP9ijhvSdH0h5uTjb4xOlgZKZ9"] = "discover skips a test_* definition whose body carries a function token in TYPE position (end_line_of loses the closer), so the generated tail omits that case and the test silently stops running; 17 definitions across 10 files tree-wide, including files in this batch's scope",
    ["3IU62YqO7uyYrJt53x6fmaE6dlJ"] = "_build/coldbuild_test.tl type-checks the tree with the pinned release's checker, which predates the D29 seam, so any runner-mode test file fails it with an uncalled-local warning until the pin names a release carrying #1446",
    ["3IUJSV7eIcrpVIs1kmGBvCTQuSC"] = "the pinned cb39b65 checker's old discover misses _types/tlast_test.tl's second definition, so the migrated file fails _build/coldbuild_test.tl (unused function under generation 1) until the pin names a release carrying #1455",
    ["3IUKPAcMAg2uL3IB3wyI6CDMkam"] = "cold-build rule: bin/cosmic.pin names 2026-08-27-cb39b65, which predates #1455 (2724a719). Measured with coldbuild's own instrument over batch 1's 65 migrated files: o/bootstrap/cosmic --check types --include-dir . --include-dir o/_types/types_gen passes 64/65 and fails _types/tlast_test.tl:39 with 'unused function test_cache_thaws_on_fresh_tl'; the same argv under o/bin/cosmic passes 65/65. The batch cannot land until the pin carries the counter fix.",
  },
  ["blocked_by"] = "3IU62YqO7uyYrJt53x6fmaE6dlJ 3IP9ijhvSdH0h5uTjb4xOlgZKZ9 3IUJSV7eIcrpVIs1kmGBvCTQuSC 3IUKPAcMAg2uL3IB3wyI6CDMkam",
  ["builders"] = "e831e06e-2f80-53d1-84e9-8198069f90ed --session",
  ["id"] = "3IU6AZExaHemD7J7BUV51EqhwmG",
  ["parent"] = "3IOCdooEOElQSPH42nr5xOrAQVn",
  ["phase"] = "ready",
  ["title"] = "migrate to runner mode, batch 1/7: _build, _docs, _types, 3p, _fuzz, _eval, _perf, _tool",
}
