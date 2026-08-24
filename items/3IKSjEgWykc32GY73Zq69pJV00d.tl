return {
  ["block_reason"] = {
    ["3IKg4hsFiuy1QXFYZBwPmvvNq4w"] = "the C parser copies the Teal reader's contract byte for byte, and that contract mis-decodes \\ddd as octal today; freezing it in C either bakes in the bug or makes the sibling differential harness report the Teal side's fault as a disagreement",
  },
  ["blocked_by"] = "3IKg4hsFiuy1QXFYZBwPmvvNq4w",
  ["builders"] = "931e78b5-bbf4-5886-9bf0-76f62cce36c7 881222fd-9a27-5a97-939d-2ff71f1bb67b",
  ["claim"] = "881222fd-9a27-5a97-939d-2ff71f1bb67b",
  ["id"] = "3IKSjEgWykc32GY73Zq69pJV00d",
  ["parent"] = "3IK8E4XFNSEMc6fXtc6qbUxiLVO",
  ["pr"] = 274,
  ["repo"] = "whilp/cosmopolitan",
  ["resolution"] = "completed",
  ["title"] = "cosmo.DecodeLua: the C literal parser in tool/net, beside ljson.c",
  ["verdict"] = "accept",
  ["verdict_head"] = "c9eb3e1a086efacd0b55a1d9b63d3b1e822e13a7",
}
