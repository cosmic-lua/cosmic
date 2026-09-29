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

harness_epoch.epoch = 2
harness_epoch.acknowledged = {

  ["build.analyzer"] = "bae201b05376598e0533493225c02aeea745620f5483dfe7a51d907420f7065a",

  ["build.artifact"] = "dfbd62c141aeb4056a79c168828a2c9d1b60feb79f2c6809bc46ba1b48538e92",

  ["build.ast"] = "7963f834f90d0fff826ac5d8ea5feee70bb277be5eb2e3ac353865902fb210ef",

  ["build.ast.match"] = "e3d9b20d358c685a676dd1386d9e5a3944d46fcaadabba66c7d818930081a3c7",

  ["build.ast.match_cast"] = "ba98216c97163460d15e9460aac838d04ebd908daada9ff661259fee0468257f",

  ["build.ast.node"] = "11077786c48ac5d592ce64cfc253cea1511b58883684ed9a9e1cbf974ef74c62",

  ["build.ast.requires"] = "89597622aeda4d8e1dc1f94666d9f03acad1d76a6a26d92dcb781cdce24cc106",

  ["build.ast.rewrite"] = "c03293a5ac5f20683959fef3f5c978e108c228b525a9e675df70af93544d165b",

  ["build.ast.walk"] = "33e53c4c1332f20b4034e36b7350b385d0b9d0681ce3344ee02c109d003faa1d",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_names"] = "df4ae0420c7c21aec1f5ee52d62d3f2052c8f1c680f8261dd9b98568bda1b746",

  ["build.caches"] = "0b02902719252609ab099e6ea3ed0b0dfebc76cc111ec535b3833d925cf56b6a",

  ["build.confine"] = "eb933cd6fded6fb3dbab3ac4b94fd5a33b63f4e01478bb5315ee5c3f51a2f9d3",

  ["build.core_image"] = "ea93af27983a200a82f9820f1964a52e8eacf04f4c29f438b7bacbbf2c38a684",

  ["build.declared_key"] = "4d145eda79974d5891d5fbd53de8add0aa899f680f7729491d7c24bffd42185e",

  ["build.filesystem_observations"] = "58d83c23cef5c822327c7f74790a2903f46f78831f0240cf36c14739a2c614e2",

  ["build.inputs"] = "c8d331965b9a38ab42180191f0348bebc853105cefbd51139c990328141005ec",

  ["build.key_parts"] = "eccb81a210564caeb7e168ee9f75bc3dbcc54e0954d8c76b61b009671f1e2d6a",

  ["build.launcher"] = "4b33d1b8f52a790a33ba1a1c13666a0d9f53bcb1ce4b165d49cb3dba1c0f5153",

  ["build.positions"] = "e138b1d40af4c67f13336ad5e157bdcebeac032819de16dd4c6d32871569c9a5",

  ["build.shared_verdicts"] = "8ecbc0fe94947133dc8ddb0bec2869bcbfe9bbdf3269fd21d455677436ed2178",

  ["build.test"] = "302993c0eb19f1c275fb105d7292dc6e2c64ab177887b7261ac8c2fb84002bf6",

  ["build.test_inputs"] = "b380668f9c8195a51131864e8bdbe6fc3a8c769324a8198db0720ffd47e288a5",

  ["build.test_sandbox"] = "1fb51b14f2ef32a5aa30675d79f80b41a8f68a871125ef75264930b9991de868",

  ["build.test_worker"] = "e9422bfb0f2db1f2ae8d9226945febd974cf6d3b0088d761cd9d517acd37d4f4",

  ["build.this_program"] = "5d3b4cd43a514a2957d3bb6dae0827a3ca67245c473709cb644de5d61dc20a52",

  ["build.zig_caches"] = "a09afd64fec41a72a2b350879f9d8aefc59482dc6d8938564124b893e1840c07",

  ["cmd.cosmic.main"] = "7e1aeb6507bc43ed66bff90de92beb0dcc983087452924d87f08be72ddc9e7a8",

  ["cosmic.child"] = "6e673e6f3be3cc9cf6d74223c4924271e57b4cfb5d34b4a95590dad08206dfb7",

  ["cosmic.codec"] = "a1f336105d70271fc51baa9e602cbdbe8dce38f336d027c962f5df3295ba20e6",

  ["cosmic.compress"] = "a82be84e133ee562fe8d5cf46cc543d67567f9e808c71ea1cf35fcd6a462df13",

  ["cosmic.coverage"] = "93d5838bf518d59450cb8fa7d6f11f8a2113c0c6692047d2d066fa54bdfcb0b4",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.errors"] = "7a1135e1dd69adf0e0a7320cf49053eae44d6c4f6e46f6edaaa1b09fbf0c7f50",

  ["cosmic.fs"] = "18a07c2fb44970619fee6312338b5e89f303bc0c3e0b8a5b16e8794421816505",

  ["cosmic.hash"] = "97850d228d8368d1c4de1342d124b72fbeacd0b2d57d7234f8922dda83a426ab",

  ["cosmic.proc"] = "74575ab0114ec38c9b65838f3ce981f3ec66f1216b5abc77b4679a649f5dbbaa",

  ["cosmic.removed"] = "33abed453c4fc39fd8c80bcd388f84749b6b28f59047f24a97a94cd0d6d97442",

  ["cosmic.sqlite"] = "56405fb541a52aa0c77136c018efc833aa775e016d8b899976e38b9b34b69166",

  ["cosmic.store"] = "8a1dbc071ec185961b3771dd60ea362a4b62c720f96991f1d048989c5b07491c",

  ["cosmic.stream"] = "d67c1d6621a1aea30d806f8e05e896f0319c0be775fe272d1c03acf26650418f",

  ["cosmic.string"] = "579df77a2498f37f1867b377dd5609f64074028ef7d7b7e5919f86435f61d96a",

  ["cosmic.test"] = "d07aad6e52ea38f457ddcd8af322ddb22e78f72f9f23a91d906f3fcea8aa6bdc",

  ["cosmic.time"] = "8c3bc15ddb5a5a92662051caf2bdcf8f44db0e465bb8e47d40b1d7abdcbe74ad",

}

return harness_epoch
