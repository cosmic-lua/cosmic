return {
  ["block_reason"] = {
    ["3IUBNQZZ8UHrBZD8Tgb7BgEx2zD"] = "3IUBNQZZ adds format_identity, widens format to format(deltas, base?, cur?), and converts the five compare.format( call sites so both pt.Results reach the formatter; without that plumbing this item cannot print a header line at all, and cutting both in parallel puts two branches over the same header region and the same _perf/skew_test.tl wall (3IVF3HbV)",
  },
  ["blocked_by"] = "3IUBNQZZ8UHrBZD8Tgb7BgEx2zD",
  ["builders"] = "05f7c552-0c90-51cb-99b3-e018759c6ed5/3IVEEDO8",
  ["claim"] = "05f7c552-0c90-51cb-99b3-e018759c6ed5/3IVEEDO8",
  ["id"] = "3IVEEDO80RzHR8bX26QyXPe8H59",
  ["parent"] = "3HyRcd9FVIczIYW5swnw2IXbnGA",
  ["pr"] = 1493,
  ["resolution"] = "completed",
  ["title"] = "perf report says which binary but not which session: meta.timestamp is written, dropped by RESULTS_SPEC, and never printed",
  ["verdict"] = "accept",
  ["verdict_head"] = "27b8d09187aed4aacd0d0cae2b2f31b0f87a08cc",
}
