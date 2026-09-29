--- The test harness's epoch, which every sandboxed verdict key holds
--- (`build.declared_key`'s `epoch` part) in place of the harness's own
--- code: what every worker loads (`build.test_worker`'s `loads`), the
--- sandbox's maker (`build.test`'s `harness_own`), and the code that
--- makes a key and looks a verdict up under one (`build.test` and its
--- `key_code`). An edit to that code moves no key by itself, so a
--- comment in build/test.tl runs no test again but those that import
--- it; `epoch` moves every key, and is bumped by hand for a change that
--- can alter a pass or a fail.
---
--- `acknowledged` holds a digest per module of that code as it was when
--- the choice was last made (`build.test`'s `harness`, over each
--- module's source and bytecode), one module to a line, sorted, with a
--- blank line between each two, so two changes to different modules of
--- the harness merge cleanly, even two that sort next to each other,
--- and two to the same one conflict on its line. build/harness_epoch_test.tl fails
--- when a module's digest differs from its entry, when a module has no
--- entry, and when an entry names no module of the harness, printing
--- the lines to set, and asks whether to bump `epoch` too: yes
--- where the change can alter what a worker is given, how it is judged
--- or how a key is computed -- a sandbox's hold or bind tightened among
--- them, a fix for soundness that moves no other part of a key, so a
--- pass a test earned through the hole does not stand after it. Either
--- way the choice is in the diff, and
--- CI's merge queue runs every
--- test (`--all`) for a change that moves this file
--- (ci/cosmic_ci/orchestration.tl's `stands`), so one recorded wrongly
--- as harmless is caught before it lands.
local record harness_epoch
  epoch: integer
  acknowledged: {string:string}
end

harness_epoch.epoch = 1
harness_epoch.acknowledged = {

  ["build.analyzer"] = "6e7631f89ee3a61463b146a8ebcc5b7ed2b9938a09491001f85c1c5a6c04e7c4",

  ["build.artifact"] = "dfbd62c141aeb4056a79c168828a2c9d1b60feb79f2c6809bc46ba1b48538e92",

  ["build.ast"] = "7963f834f90d0fff826ac5d8ea5feee70bb277be5eb2e3ac353865902fb210ef",

  ["build.ast.match"] = "e3d9b20d358c685a676dd1386d9e5a3944d46fcaadabba66c7d818930081a3c7",

  ["build.ast.match_cast"] = "ba98216c97163460d15e9460aac838d04ebd908daada9ff661259fee0468257f",

  ["build.ast.node"] = "bf06ee19c5f3481b1ced672f136f1823001b3fef64d10c9dbb30da3078dca707",

  ["build.ast.requires"] = "89597622aeda4d8e1dc1f94666d9f03acad1d76a6a26d92dcb781cdce24cc106",

  ["build.ast.rewrite"] = "c03293a5ac5f20683959fef3f5c978e108c228b525a9e675df70af93544d165b",

  ["build.ast.walk"] = "33e53c4c1332f20b4034e36b7350b385d0b9d0681ce3344ee02c109d003faa1d",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_names"] = "df4ae0420c7c21aec1f5ee52d62d3f2052c8f1c680f8261dd9b98568bda1b746",

  ["build.caches"] = "0bf2b640e393027df521ebccf00150acd945eee0c19eda176ce3d27a08bb8abb",

  ["build.confine"] = "b4af3b71b3339713b53a80ae1fce80f2fa9b3842d9105eef49ba5b7c1e345a99",

  ["build.core_image"] = "ea93af27983a200a82f9820f1964a52e8eacf04f4c29f438b7bacbbf2c38a684",

  ["build.declared_key"] = "961bcd11c205202bdacea48b5885b23f109a859d21afab5bd4f3bdaf8c1a1b09",

  ["build.filesystem_observations"] = "0263f675eb3e479c94d953b4e7935953741acf16d7044a3362ef95d87b176c77",

  ["build.inputs"] = "c8d331965b9a38ab42180191f0348bebc853105cefbd51139c990328141005ec",

  ["build.launcher"] = "4b33d1b8f52a790a33ba1a1c13666a0d9f53bcb1ce4b165d49cb3dba1c0f5153",

  ["build.positions"] = "e138b1d40af4c67f13336ad5e157bdcebeac032819de16dd4c6d32871569c9a5",

  ["build.shared_verdicts"] = "8ecbc0fe94947133dc8ddb0bec2869bcbfe9bbdf3269fd21d455677436ed2178",

  ["build.test"] = "0371c9370f1f874fb487657e7fc2309e763151df8b7baccbe897b4051b601e54",

  ["build.test_inputs"] = "07b08821cfd34e6b688ea2cd817e874aa208c072842aa86a04ae0102fad5ca05",

  ["build.test_sandbox"] = "53bbd6d956be19d5d5449d091b4703faae5f948e627101895e9680b4590dfeea",

  ["build.test_worker"] = "7ecf56880082c9e014e3fd4480a14e908b28f4188b16f150008fad4a023b72bf",

  ["build.this_program"] = "f9fef9f8bc7fef4792d5aa6797a4c3e03b3285b919416dfa32996a29016bb0dc",

  ["build.verdict"] = "19023aead8ad821bc322be4833cb41fc421cca1d3e79cdd64bbd4416c5589827",

  ["build.zig_caches"] = "a09afd64fec41a72a2b350879f9d8aefc59482dc6d8938564124b893e1840c07",

  ["cmd.cosmic.main"] = "c00a8f33fb56e289546497cffddf3a34a140578b1e66874baccf0867df094734",

  ["cosmic.child"] = "6e673e6f3be3cc9cf6d74223c4924271e57b4cfb5d34b4a95590dad08206dfb7",

  ["cosmic.codec"] = "fd69c09044669725c5ae853bd192d32a4fe32426b20e6028426a4ee04ded1797",

  ["cosmic.compress"] = "a82be84e133ee562fe8d5cf46cc543d67567f9e808c71ea1cf35fcd6a462df13",

  ["cosmic.coverage"] = "93d5838bf518d59450cb8fa7d6f11f8a2113c0c6692047d2d066fa54bdfcb0b4",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.errors"] = "7a1135e1dd69adf0e0a7320cf49053eae44d6c4f6e46f6edaaa1b09fbf0c7f50",

  ["cosmic.fs"] = "18a07c2fb44970619fee6312338b5e89f303bc0c3e0b8a5b16e8794421816505",

  ["cosmic.hash"] = "fabf524e6ceda899471bd79d3bdf587824779ca1993ff3fac9cd26a1265acc8a",

  ["cosmic.log"] = "27a8c97a6f079136468269a85e5123dcd0b114ca6fc39fc159c801d441fee996",

  ["cosmic.proc"] = "74575ab0114ec38c9b65838f3ce981f3ec66f1216b5abc77b4679a649f5dbbaa",

  ["cosmic.removed"] = "33abed453c4fc39fd8c80bcd388f84749b6b28f59047f24a97a94cd0d6d97442",

  ["cosmic.sqlite"] = "efe0d870c58fd37c77c3f94399825e740d224bf344fab8da9d8bea4d66f1e28c",

  ["cosmic.store"] = "8a1dbc071ec185961b3771dd60ea362a4b62c720f96991f1d048989c5b07491c",

  ["cosmic.stream"] = "f096a19e655719573d27b6a24ceea4677a92099fdf1fc38ad2a5e9d9245e931b",

  ["cosmic.string"] = "579df77a2498f37f1867b377dd5609f64074028ef7d7b7e5919f86435f61d96a",

  ["cosmic.test"] = "cbf2ddedccf2e18689dc3ddef0873993c8c5ec1d5bb2c3d6b03e2993402bfd78",

  ["cosmic.time"] = "a5071b9f5b61979e3137751dc9891290ee66ce0ee447598f689b004568c40576",

}

return harness_epoch
