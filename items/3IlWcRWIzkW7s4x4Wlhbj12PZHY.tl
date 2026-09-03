return {
  ["block_reason"] = {["3ImmKYCJNNxTS9eAISxrHCW59sk"] = "reject verdict on PR #1643 found a real unsoundness: retyping these iterators non-nilable makes their terminating direct-call read (FileIter's subtree errors, stream/Body's read-failure message) silently dishonest and uncaught by the checker; the item's spec needs a decision on direction (retype anyway with per-site casts / keep string|nil / a narrow-only for-in mechanism) before it is pullable again"},
  ["blocked_by"] = "3ImmKYCJNNxTS9eAISxrHCW59sk",
  ["builders"] = "builder-bj12_PZHY-orch9 7019a67a-89f8-5ed7-bd1c-6d260093b01b",
  ["claim"] = "7019a67a-89f8-5ed7-bd1c-6d260093b01b",
  ["id"] = "3IlWcRWIzkW7s4x4Wlhbj12PZHY",
  ["parent"] = "3IPXQ1Zw1xfRYx4dV1zwASNhQ3N",
  ["speccers"] = "7019a67a-89f8-5ed7-bd1c-6d260093b01b",
  ["title"] = "library iterators declare their terminating nil in the first return, so for-in bodies see string | nil: FileIter, LineIter, Body.lines (7 census rows)",
}
