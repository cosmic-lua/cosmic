return {
  ["block_reason"] = {["3IP9ijhvSdH0h5uTjb4xOlgZKZ9"] = "discover skips a test_* definition whose body carries a function token in TYPE position (end_line_of loses the closer), so the generated tail omits that case and the test silently stops running; 17 definitions across 10 files tree-wide, including files in this batch's scope", ["3IU62YqO7uyYrJt53x6fmaE6dlJ"] = "_build/coldbuild_test.tl type-checks the tree with the pinned release's checker, which predates the D29 seam, so any runner-mode test file fails it with an uncalled-local warning until the pin names a release carrying #1446", ["3IUJSV7eIcrpVIs1kmGBvCTQuSC"] = "cold-build rule, measured 2026-08-27 on 555873eb by the same mirror + coldbuild argv: the pinned 2026-08-27-cb39b65 checker loses cosmic/sqlite/advanced_test.tl:226,249 and cosmic/sqlite/close_test.tl:48,161 once migrated, refusing them as unused functions. The pin predates #1455 (2724a719); the tree's own checker passes all of them."},
  ["blocked_by"] = "3IU62YqO7uyYrJt53x6fmaE6dlJ 3IP9ijhvSdH0h5uTjb4xOlgZKZ9 3IUJSV7eIcrpVIs1kmGBvCTQuSC",
  ["builders"] = "ca143d92-7e34-569b-b008-1f69817ffff5",
  ["claim"] = "ca143d92-7e34-569b-b008-1f69817ffff5",
  ["id"] = "3IU6B7LDfVWJ8fv39uHuMjkdGGh",
  ["parent"] = "3IOCdooEOElQSPH42nr5xOrAQVn",
  ["title"] = "migrate to runner mode, batch 4/7: cosmic/{sqlite,quicksand,fetch,net,doc}",
}
