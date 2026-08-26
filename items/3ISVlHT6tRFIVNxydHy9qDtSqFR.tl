return {
  ["block_reason"] = {
    ["3ISWHWQTq31NBoVzqQ3tH8G6aqQ"] = "no eligible release can publish while the compare step crashes",
    ["3ISlY5Xlyt9hRhDUY0wlOyVgYNo"] = "no release has published since 2026-08-23-d71d7f1: release.yml's perf gate has failed the daily run on 2026-08-24 (32699814015), 2026-08-25 (32818853162) and 2026-08-26 (32940138465), so there is no post-2026-08-26 artifact for bin/cosmic.pin to point at. 3ISWHyP7's evidence exonerated json_decode_large as machine variance, which is this item's gate hole; until the gate stops flagging it the lane stays red.",
  },
  ["blocked_by"] = "3ISWHWQTq31NBoVzqQ3tH8G6aqQ 3ISlY5Xlyt9hRhDUY0wlOyVgYNo",
  ["id"] = "3ISVlHT6tRFIVNxydHy9qDtSqFR",
  ["parent"] = "3ISJI4Lgn9UobC9gFoEk04B1HON",
  ["phase"] = "ready",
  ["title"] = "pin bump: bin/cosmic.pin to the first release carrying narrow-pack-n (post-2026-08-26)",
}
