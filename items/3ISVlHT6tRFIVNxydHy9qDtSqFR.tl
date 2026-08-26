return {
  ["block_reason"] = {
    ["3ISWHWQTq31NBoVzqQ3tH8G6aqQ"] = "no eligible release can publish while the compare step crashes",
    ["3ISlWFiS7svcOfni0vzn6iFo8a9"] = "the other half of the same red lane: codec_base64_roundtrip_64k is a REAL +7.8% regression per 3ISWHyP7's A/B, so fixing the gate's noise handling alone still leaves the release refused on this scenario. A green organic release needs both.",
    ["3ISlY5Xlyt9hRhDUY0wlOyVgYNo"] = "no release has published since 2026-08-23-d71d7f1: release.yml's perf gate has failed the daily run on 2026-08-24 (32699814015), 2026-08-25 (32818853162) and 2026-08-26 (32940138465), so there is no post-2026-08-26 artifact for bin/cosmic.pin to point at. 3ISWHyP7's evidence exonerated json_decode_large as machine variance, which is this item's gate hole; until the gate stops flagging it the lane stays red.",
  },
  ["blocked_by"] = "3ISWHWQTq31NBoVzqQ3tH8G6aqQ 3ISlY5Xlyt9hRhDUY0wlOyVgYNo 3ISlWFiS7svcOfni0vzn6iFo8a9",
  ["id"] = "3ISVlHT6tRFIVNxydHy9qDtSqFR",
  ["parent"] = "3ISJI4Lgn9UobC9gFoEk04B1HON",
  ["phase"] = "ready",
  ["title"] = "pin bump: bin/cosmic.pin to the first release carrying narrow-pack-n (post-2026-08-26)",
}
