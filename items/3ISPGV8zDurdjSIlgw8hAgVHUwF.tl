return {
  ["block_reason"] = {
    ["3ISKgfS6iOzNi1JT0crQacsvxFb"] = "the cast can only come out under a pinned checker that knows PackTable<any>: the patch must land, ship in a release, and become bin/cosmic.pin first — until then the cold build fails generation 1",
    ["3ISVlHT6tRFIVNxydHy9qDtSqFR"] = "the cast retire needs the pinned checker to know PackTable<any>; the pin moves only after the first post-2026-08-26 release ships narrow-pack-n",
  },
  ["blocked_by"] = "3ISKgfS6iOzNi1JT0crQacsvxFb 3ISVlHT6tRFIVNxydHy9qDtSqFR",
  ["builders"] = "7b2d5794-d8f2-5252-98a4-78fd6c9236e6",
  ["claim"] = "7b2d5794-d8f2-5252-98a4-78fd6c9236e6",
  ["id"] = "3ISPGV8zDurdjSIlgw8hAgVHUwF",
  ["parent"] = "3ISJI4Lgn9UobC9gFoEk04B1HON",
  ["phase"] = "check",
  ["pr"] = 1423,
  ["title"] = "coverage: retire the pack-n cast once the pinned checker carries narrow-pack-n",
}
