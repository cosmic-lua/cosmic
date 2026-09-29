--- The test harness's epoch, which every sandboxed verdict key holds
--- (`build.declared_key`'s `epoch` part) in place of the harness's own
--- code: what every worker loads (`build.test_worker`'s `loads`), the
--- sandbox's maker (`build.test`'s `harness_own`), and the code that
--- makes a key and looks a verdict up under one (`build.test` and its
--- `key_code`). An edit to that code moves no key by itself, so a
--- comment in build/test.tl runs no test again but those that import
--- it. `epoch` moves every key, and is bumped by hand for a change that
--- can alter a pass or a fail.
---
--- `acknowledged` holds a digest per module of that code as it was when
--- the choice was last made (`build.test`'s `harness`, over each
--- module's source and bytecode). It is one module to a line, sorted,
--- with a blank line between each two, so two changes to different
--- modules merge cleanly, even two that sort next to each other, and two
--- to the same module conflict on its line. build/harness_epoch_test.tl
--- fails when a module's digest differs from its entry, when a module has
--- no entry, and when an entry names no module of the harness. It prints
--- the lines to set, and asks whether to bump `epoch` too: yes where the
--- change can alter what a worker is given, how it is judged or how a key
--- is computed. A sandbox's hold or bind tightened counts, as a soundness
--- fix that moves no other part of a key: a pass a test earned through
--- the hole must not stand after it. Either way the choice is in the
--- diff, and CI's merge queue runs every test (`--all`) for a change that
--- moves this file (ci/cosmic_ci/orchestration.tl's `stands`), so one
--- recorded wrongly as harmless is caught before it lands.
---
--- The rule the harness keeps, which `library` and its test hold it to.
--- Its modules are:
---
--- * what every worker loads (`worker.loads`, which `worker.judge` holds
---   each worker to);
--- * the sandbox's maker (`harness_own`);
--- * build.test itself and cosmic.child, which applies a worker's
---   sandbox (`harness_alone`), each held alone;
--- * the closure of the key's roots (`key_roots`) over the requires each
---   makes by value, as its bytecode names them (`test.value_imports`).
---   A `local type` require is not followed, since Teal erases it and
---   what the imported type does at run time is compiled into the
---   importer's bytecode, which the digests hold.
---
--- A module of the harness reaches the host through the core's raw
--- bindings, which the runtime's identity keys, and through the
--- standard-library modules `library` names, each with its reason, and no
--- other `cosmic.*` module. What else of the tree the runner calls is its
--- plumbing -- the probe of whether to sandbox
--- (`build.test_sandbox_probe`), and what cosmic.child requires to start
--- a worker -- which must fail loudly, as a failure or a refusal, never
--- as a pass. What a module of the harness calls through a library table
--- a test can replace, it takes as a local when it loads.
local record harness_epoch
  epoch: integer
  acknowledged: {string:string}
  --- The standard-library modules the harness's modules may reach, each
  --- by why it must.
  library: {string:string}
end

harness_epoch.epoch = 3
harness_epoch.acknowledged = {

  ["build.artifact"] = "f1a807f869ab0a6f20755397dfe26f8a4e4b4b57cacd33a17ae6cadfb726cb7d",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_names"] = "df4ae0420c7c21aec1f5ee52d62d3f2052c8f1c680f8261dd9b98568bda1b746",

  ["build.caches"] = "0b02902719252609ab099e6ea3ed0b0dfebc76cc111ec535b3833d925cf56b6a",

  ["build.confine"] = "2389cf344d33ae0835dedd8cea138c4d82de0e5bb68d969607cd10228f976438",

  ["build.core_image"] = "34c93a6b28c550fb039fed57b17e399279b9b472f09650e825742c0b6a2a58aa",

  ["build.declared_key"] = "fef6b12e2831526967ed54894478938f8e9629c14692e58b09d583b5d2b61f5e",

  ["build.digest"] = "67bafa67ae11e35c36e9a2a0d35fcf0a9ace9a27ea40fe0194ae38dc132ccd67",

  ["build.filesystem_observations"] = "ca600b34e5959f900fd089ec298dda56bfb5cb08e8bc153cef8b2ccfe408b224",

  ["build.key_parts"] = "b051b4c075439242f2fd5ee1361b75a19abd894fddfa1b10ec06e441887c083f",

  ["build.launcher"] = "9dff6e6443e223fa5a99bb960d8046b47ea47bb506ffd08798771153715a2305",

  ["build.shared_verdicts"] = "8ecbc0fe94947133dc8ddb0bec2869bcbfe9bbdf3269fd21d455677436ed2178",

  ["build.test"] = "4587eaa059f38a9302f23e1a47776a2c4bb1697c00ffe2ca2beca829a7148b40",

  ["build.test_inputs"] = "b380668f9c8195a51131864e8bdbe6fc3a8c769324a8198db0720ffd47e288a5",

  ["build.test_sandbox"] = "300912379ba4ad007c2969ed8447b6ae61dd0536b4a6071e8569805795a4ca99",

  ["build.test_worker"] = "64325c2113c1e0a0ce4e29182a5d8b8769e7a55bf620d9f4f77f3855fdf58e45",

  ["build.this_program"] = "5d3b4cd43a514a2957d3bb6dae0827a3ca67245c473709cb644de5d61dc20a52",

  ["build.zig_caches"] = "a09afd64fec41a72a2b350879f9d8aefc59482dc6d8938564124b893e1840c07",

  ["cmd.cosmic.main"] = "7e1aeb6507bc43ed66bff90de92beb0dcc983087452924d87f08be72ddc9e7a8",

  ["cosmic.child"] = "ecd4c76c90a129eb07feb3c5ba868e4c44deab1eb2648df0e94e2ae2f39fa464",

  ["cosmic.coverage"] = "93d5838bf518d59450cb8fa7d6f11f8a2113c0c6692047d2d066fa54bdfcb0b4",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "e6becd6f47da455cc2717fa7bd71057a441cb41597fad74a4880fb5daa812913",

  ["cosmic.proc"] = "74575ab0114ec38c9b65838f3ce981f3ec66f1216b5abc77b4679a649f5dbbaa",

  ["cosmic.removed"] = "33abed453c4fc39fd8c80bcd388f84749b6b28f59047f24a97a94cd0d6d97442",

  ["cosmic.sqlite"] = "8f11202571d0a582c49deb134ac7513f3152be378f90a591051d69bb498fd0f6",

  ["cosmic.string"] = "579df77a2498f37f1867b377dd5609f64074028ef7d7b7e5919f86435f61d96a",

  ["cosmic.test"] = "4ac20e6f1c0198404353969c00ec4ba1efbe66f969f8f37fbd7f43983c595c18",

}

harness_epoch.library = {
  ["cosmic.child"] = "its `start` turns a worker's plan into the unveils, binds and " ..
    "offline spawn holds it to; held alone, what it requires is not walked",
  ["cosmic.coverage"] = "the worker starts and stops the coverage a test's lines are " ..
    "counted by, whose session a test that imports it shares",
  ["cosmic.env"] = "the worker's environment, which its key holds, is read and built " ..
    "through it",
  ["cosmic.fs"] = "places each read, bind and unveil (`within`, `relative`) and writes " ..
    "the worker's report",
  ["cosmic.proc"] = "names this program (`executable`), which a worker whose test does " ..
    "not declare `tool` is held from running",
  ["cosmic.removed"] = "what a test that reaches for a removed global is told, which " ..
    "the core loads in any worker",
  -- TODO: take cosmic.sqlite out of the harness, and this entry out of
  -- `library`, once the shared SQLite module of plan 4.3 lets
  -- build.declared_key's `program`, build.shared_verdicts and build.bind
  -- read and write through the raw binding.
  ["cosmic.sqlite"] = "the key's code digests the rows it reads of the store, and " ..
    "shared verdicts are stored and looked up under exact keys through it",
  ["cosmic.string"] = "the launcher's template, which a key holds, is split into lines " ..
    "through it (`build.launcher`)",
  ["cosmic.test"] = "a test's declaration (`Test.needs`), which the worker judges, and " ..
    "the runner's hook into it",
}

return harness_epoch
