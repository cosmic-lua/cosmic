return {
  ["block_reason"] = {["3IP9ijhvSdH0h5uTjb4xOlgZKZ9"] = "discover skips a test_* definition whose body carries a function token in TYPE position (end_line_of loses the closer), so the generated tail omits that case and the test silently stops running; 17 definitions across 10 files tree-wide, including files in this batch's scope", ["3IU62YqO7uyYrJt53x6fmaE6dlJ"] = "_build/coldbuild_test.tl type-checks the tree with the pinned release's checker, which predates the D29 seam, so any runner-mode test file fails it with an uncalled-local warning until the pin names a release carrying #1446", ["3IUJSV7eIcrpVIs1kmGBvCTQuSC"] = "cold-build rule, measured 2026-08-27 on 555873eb by the same mirror + coldbuild argv: the pinned 2026-08-27-cb39b65 checker loses cosmic/_teal_ast_test.tl:23 (test_artifact_cache_thaws) and cosmic/fd_read_test.tl:99 (test_sync_moved_to_fs) once migrated, refusing them as unused functions. The pin predates #1455 (2724a719); the tree's own checker passes all of them."},
  ["blocked_by"] = "3IU62YqO7uyYrJt53x6fmaE6dlJ 3IP9ijhvSdH0h5uTjb4xOlgZKZ9 3IUJSV7eIcrpVIs1kmGBvCTQuSC",
  ["builders"] = "wk5-a2-ca143d92-7e34-569b-b008-1f69817ffff5",
  ["claim"] = "wk5-a2-ca143d92-7e34-569b-b008-1f69817ffff5",
  ["id"] = "3IU6BPFgDZ6TepaxWJQ4h1AtssL",
  ["parent"] = "3IOCdooEOElQSPH42nr5xOrAQVn",
  ["pr"] = 1560,
  ["title"] = "migrate to runner mode, batch 5/7: cosmic/*_test.tl, _literal_format through hash",
  ["verdict"] = "accept",
  ["verdict_head"] = "70733d711acf61e5ea2f653afa506d629aec62a1",
  ["verdict_spec"] = "5f4ff83660fe8ca04a1ba1d91f0fe8c76056d5a08b2c7ddbf6f791adf1ff83f4",
}
