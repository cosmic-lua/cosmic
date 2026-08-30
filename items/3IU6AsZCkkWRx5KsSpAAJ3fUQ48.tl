return {
  ["block_reason"] = {["3IP9ijhvSdH0h5uTjb4xOlgZKZ9"] = "discover skips a test_* definition whose body carries a function token in TYPE position (end_line_of loses the closer), so the generated tail omits that case and the test silently stops running; 17 definitions across 10 files tree-wide, including files in this batch's scope", ["3IU62YqO7uyYrJt53x6fmaE6dlJ"] = "_build/coldbuild_test.tl type-checks the tree with the pinned release's checker, which predates the D29 seam, so any runner-mode test file fails it with an uncalled-local warning until the pin names a release carrying #1446", ["3IUJSV7eIcrpVIs1kmGBvCTQuSC"] = "cold-build rule, measured 2026-08-27 on 555873eb: with every *_test.tl outside testdata/ migrated into a scratch mirror, coldbuild's own argv (COSMIC_COVERAGE=0 o/bootstrap/cosmic --check types --include-dir . --include-dir o/_types/types_gen <files>) under the pinned 2026-08-27-cb39b65 loses cosmic/fs/find_close_test.tl:69 (test_find_iter_to_be_closed_scope) and cosmic/sandbox/init_test.tl:46,105 — the pin predates #1455 (2724a719), so generation 1 refuses them as unused functions. The tree's own checker passes all of them."},
  ["blocked_by"] = "3IU62YqO7uyYrJt53x6fmaE6dlJ 3IP9ijhvSdH0h5uTjb4xOlgZKZ9 3IUJSV7eIcrpVIs1kmGBvCTQuSC",
  ["builders"] = "wave18-a-1788060000 wave18-a2-1788064500",
  ["id"] = "3IU6AsZCkkWRx5KsSpAAJ3fUQ48",
  ["parent"] = "3IOCdooEOElQSPH42nr5xOrAQVn",
  ["pr"] = 1558,
  ["resolution"] = "completed",
  ["speccers"] = "orchestrator-w18 wave18-a2-1788064500",
  ["title"] = "migrate to runner mode, batch 3/7: cosmic/{fs,child,format,flags,coverage,sandbox}",
  ["verdict"] = "accept",
  ["verdict_head"] = "ed329053dbcb7fbb6ca2e9303b0b7fa3fa3381c2",
  ["verdict_spec"] = "f03d851a80c93e892e43dfd29e0fec3f9f1de56d61a554e09afb37d64a8e827c",
}
