return {
  ["block_reason"] = {
    ["3IKSi0JNJkjQaHoJKn6UGk8IjYo"] = "the differential property extends the fuzz slice's harness, which does not exist yet",
    ["3IKSjEgWykc32GY73Zq69pJV00d"] = "nothing to adopt until the C parser lands and ships in a cosmos release",
    ["3IKgKs34ktEveeMUkymg4g6PRFC"] = "both edit _fuzz/literal_fuzz_test.tl: 3IKgKs34 (PR #1361, in check) removes the byte-27 domain bound and its two constants, and this slice adds a differential property to the same file — landing order, so the differential lands on the file the byte-27 fix left behind rather than conflicting with it",
  },
  ["blocked_by"] = "3IKSjEgWykc32GY73Zq69pJV00d 3IKSi0JNJkjQaHoJKn6UGk8IjYo 3IKgKs34ktEveeMUkymg4g6PRFC",
  ["id"] = "3IKSjS8NuSGgr3LjGED24NXRq9G",
  ["parent"] = "3IK8E4XFNSEMc6fXtc6qbUxiLVO",
  ["phase"] = "ready",
  ["title"] = "adopt the C literal parser behind cosmic.literal.parse, differentially fuzzed against the Teal reader",
}
