return {
  ["block_reason"] = {
    ["3ISnTFGe6kVmi3Piua0O555asQv"] = "the split cannot cold-build until a release and pin bump carry the directory-aware mechanism this item lands — proven by run 33033225229, where the pinned binary applied no patches over the split layout",
    ["3ITpcO2134fMQLkvKbEqg6ScM0O"] = "the split's pull-time gate is closed: the pin (2026-08-27-afad5b5) predates the mechanism merge 6b88a0db, so a cold build's generation 1 still cannot read the directory — verified by ancestry check 2026-08-27",
  },
  ["blocked_by"] = "3ISnTFGe6kVmi3Piua0O555asQv 3ITpcO2134fMQLkvKbEqg6ScM0O",
  ["builders"] = "0e714d6a-0cbe-5595-8ef6-73346e2f4d81",
  ["claim"] = "0e714d6a-0cbe-5595-8ef6-73346e2f4d81",
  ["id"] = "3ITo9InvDKnofScNuZYfUluM4o8",
  ["parent"] = "3ISJI4Lgn9UobC9gFoEk04B1HON",
  ["phase"] = "do",
  ["title"] = "split tl_patch.tl into tl_patch/ once the pinned mechanism reads directories (stage 2 of 3ISnTFGe)",
}
