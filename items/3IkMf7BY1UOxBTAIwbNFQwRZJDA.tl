return {
  ["block_reason"] = {["3IkSSqvH4BLD8YdvdYwohk2Pemz"] = "cosmos pin bump cannot reach a green --make ci while bin/cosmic.pin stays fixed: 8 generation-reachable/cold-invocation files (fd.tl, fs/ops.tl, fs/file.tl, embed/init.tl, child/init.tl, proc/rusage.tl, time.tl, main_handlers.tl) fail one of the build's two compile passes under either old or new destructuring, confirmed by a second builder pass", ["3Ip8zrCbHnPiV5bRM49XvoxXNCM"] = "generation 1 runs the trust root's engine, and bin/cosmic.pin (2026-08-31-a5b36f4) predates the D43 seed pass (#1656): measured in 3IkSSqvH's Resolution, no cosmos pin bump touching a generator-closure binding cold-builds in either wrapper shape until the trust root carries 8758f80c"},
  ["blocked_by"] = "3IkSSqvH4BLD8YdvdYwohk2Pemz 3Ip8zrCbHnPiV5bRM49XvoxXNCM",
  ["builders"] = "wave21-1-pinbump",
  ["id"] = "3IkMf7BY1UOxBTAIwbNFQwRZJDA",
  ["parent"] = "3IQtewgN78SnlsiBLPgF1i3VNKE",
  ["repo"] = "cosmic-lua/cosmic",
  ["speccers"] = "wave21-1-pinbump 259ba306-c053-56fc-b9ad-784a9d4ed050",
  ["title"] = "cosmos pin bump: 2026.08.31-6dfa6728a to a release carrying the post-#304 exact contracts (#315, #321, #324, #328, #329, #331)",
}
