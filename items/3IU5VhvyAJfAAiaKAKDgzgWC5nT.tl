return {
  ["block_reason"] = {
    ["3IU667WI130hFvXaEsWVzVctHiP"] = "sources will require the patched checker; the pinned bootstrap (2026-08-27-6b88a0d) predates c78504bd, so cold build fails until the pin catches up",
    ["3IU66h3fUKQsXgE8RJNXvXRiWeJ"] = "pull-time gate failed: the pin (2026-08-27-6b88a0d) predates c78504bd, so these sources would fail the cold-build guard; opens on the next release + pin bump",
  },
  ["blocked_by"] = "3IU667WI130hFvXaEsWVzVctHiP 3IU66h3fUKQsXgE8RJNXvXRiWeJ",
  ["builders"] = "3f616956-66af-5d35-82b3-9ab54b187eb2",
  ["id"] = "3IU5VhvyAJfAAiaKAKDgzgWC5nT",
  ["parent"] = "3HyRcW05wBip6Wqcz145bUQBTyj",
  ["phase"] = "ready",
  ["title"] = "retire the guard-and-cast workarounds the landed narrow rules obsoleted",
}
