return {
  ["block_reason"] = {
    ["3IHHJcVrVbkZzSkWafkdmaEPhLm"] = "step 1 edits zipos.internal.h and every A/B in Acceptance is an incremental C build; a stale-header rebuild would measure the wrong binary",
  },
  ["blocked_by"] = "3IHHJcVrVbkZzSkWafkdmaEPhLm",
  ["builders"] = "claude-sched-2026-08-24T0238",
  ["claim"] = "claude-sched-2026-08-24T0238",
  ["enable"] = "none: spec asserted TEST(zipos,test) is the concurrent pop/push stress, an unmeasured tree-fact; hyperion.txt is deflated (Defl:N), so no gate exercises the recycle array concurrently. Fix in this spec: require a stored member opened across threads, with the unzip -v measurement backing the claim.",
  ["id"] = "3ILE1xUd8R7DGmoKST8FuaWAz0K",
  ["parent"] = "3IK8GFHjEDon4Ni4GNkwzCtGI0o",
  ["phase"] = "do",
  ["pr"] = 271,
  ["repo"] = "whilp/cosmopolitan",
  ["title"] = "zipos: recycle the fixed-size stored-member handle through a 4-slot lock-free array",
  ["verdict"] = "request changes",
  ["verdict_head"] = "d74bd7db693511c6260278a289eb7516a0a36427",
}
