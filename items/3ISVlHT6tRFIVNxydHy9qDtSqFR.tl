return {
  ["block_reason"] = {
    ["3ISWHWQTq31NBoVzqQ3tH8G6aqQ"] = "no eligible release can publish while the compare step crashes",
    ["3ISlWFiS7svcOfni0vzn6iFo8a9"] = "the other half of the same red lane: codec_base64_roundtrip_64k is a REAL +7.8% regression per 3ISWHyP7's A/B, so fixing the gate's noise handling alone still leaves the release refused on this scenario. A green organic release needs both.",
    ["3ISlY5Xlyt9hRhDUY0wlOyVgYNo"] = "no release has published since 2026-08-23-d71d7f1: release.yml's perf gate has failed the daily run on 2026-08-24 (32699814015), 2026-08-25 (32818853162) and 2026-08-26 (32940138465), so there is no post-2026-08-26 artifact for bin/cosmic.pin to point at. 3ISWHyP7's evidence exonerated json_decode_large as machine variance, which is this item's gate hole; until the gate stops flagging it the lane stays red.",
    ["3ITHROpYatfTyy9DH2AHFHO8G7X"] = "No eligible release can exist while the release lane is red. Latest release is 2026-08-23-d71d7f1; every scheduled run since (32699814015, 32818853162, 32940138465) failed at the 'compare against the previous release' step, and 3ISlWFiS confirmed that failure is the real codec_base64_roundtrip_64k +8.35% regression, correctly gating. This slice's Change (1) says a red lane is its own item to block on, and that item is 3ITHROpY. Unblocks when the regression is bisected and fixed so a release publishes carrying 1ca3f7ff.",
    ["3ITOUv0wv6OVH7bkh0RmgzmoDcl"] = "No cosmic release can publish while release.yml's 'compare against the previous release' step fails on codec_base64_roundtrip_64k: scheduled runs 32699814015 (08-24), 32818853162 (08-25) and 32940138465 (08-26) all failed at that step with the 'release' job skipped, so the latest release is still 2026-08-23-d71d7f1 — which predates 1ca3f7ff and is therefore not an eligible pin target. 3ITOUv0w names the commit that moved the scenario; the fix it leads to is what re-greens the lane. The only other route to an eligible release is a workflow_dispatch carrying perf_gate: false, which publishes outward and is a human's call.",
  },
  ["blocked_by"] = "3ISWHWQTq31NBoVzqQ3tH8G6aqQ 3ISlY5Xlyt9hRhDUY0wlOyVgYNo 3ISlWFiS7svcOfni0vzn6iFo8a9 3ITHROpYatfTyy9DH2AHFHO8G7X 3ITOUv0wv6OVH7bkh0RmgzmoDcl",
  ["builders"] = "d0c48f36-d8a8-5b7a-866d-d5c87d1c0467 7b2d5794-d8f2-5252-98a4-78fd6c9236e6",
  ["claim"] = "7b2d5794-d8f2-5252-98a4-78fd6c9236e6",
  ["id"] = "3ISVlHT6tRFIVNxydHy9qDtSqFR",
  ["parent"] = "3ISJI4Lgn9UobC9gFoEk04B1HON",
  ["phase"] = "check",
  ["pr"] = 1421,
  ["title"] = "pin bump: bin/cosmic.pin to the first release carrying narrow-pack-n (post-2026-08-26)",
}
