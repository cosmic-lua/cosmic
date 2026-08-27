return {
  ["block_reason"] = {
    ["3ISnTFGe6kVmi3Piua0O555asQv"] = "the entry pair has nowhere to go: 3p/tl/tl_patch.tl is 499/500 lines and _make/patch.tl resolves one patch file per pin, so this slice's Change cannot name its target until that is settled",
    ["3ITo9InvDKnofScNuZYfUluM4o8"] = "its two-entry patch pair can only land in 3p/tl/tl_patch/narrow.tl: the single file has 1 line of headroom, so the entries wait on the split (stage 2), not just the mechanism",
  },
  ["blocked_by"] = "3ISnTFGe6kVmi3Piua0O555asQv 3ITo9InvDKnofScNuZYfUluM4o8",
  ["builders"] = "0177c77f-81b5-5fbc-9731-86abcfb395ca",
  ["claim"] = "0177c77f-81b5-5fbc-9731-86abcfb395ca",
  ["id"] = "3ISSFrCOHAKPtslNGCLS5gqBEk8",
  ["parent"] = "3ISJI4Lgn9UobC9gFoEk04B1HON",
  ["phase"] = "land",
  ["pr"] = 1439,
  ["title"] = "tl patch: is-dispatch over metatable<T> against table-kinded targets — sketch validated",
  ["verdict"] = "accept",
  ["verdict_head"] = "d743c9bb49fb00d3cfbedf7f76561988705fcffd",
}
