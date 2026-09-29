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

  ["build.artifact"] = "9144fb3a0cbaead8ab175937bf1d56d197034a31307d15b28e9a212c48196ed9",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_names"] = "965d44064c9a853518b47596b22ba7a159d50d101ab80ddbb42fbc7700daa338",

  ["build.caches"] = "8beec2912c9583fe4d30987adc85c146c718272a9407ae6ac6ce38ec3b74306c",

  ["build.confine"] = "0077e484861eb312926fd05e081b42d80a1421786d64b8f005f0fb58d3f1afde",

  ["build.core_image"] = "bd5b49295b707e7d6e36087401d0779d6b06c09286fc730706f994658ba7bf3f",

  ["build.declared_key"] = "0b4df3c2535d7b4c03b8fafc7ade593aa6faddd2530fa54a1b1f44eccbe38796",

  ["build.digest"] = "67bafa67ae11e35c36e9a2a0d35fcf0a9ace9a27ea40fe0194ae38dc132ccd67",

  ["build.filesystem_observations"] = "ca600b34e5959f900fd089ec298dda56bfb5cb08e8bc153cef8b2ccfe408b224",

  ["build.key_parts"] = "b051b4c075439242f2fd5ee1361b75a19abd894fddfa1b10ec06e441887c083f",

  ["build.launcher"] = "9dff6e6443e223fa5a99bb960d8046b47ea47bb506ffd08798771153715a2305",

  ["build.shared_verdicts"] = "3613a510291086c72ff2bdc815c56023a29de6c9b034d2cc1809488e3903a25f",

  ["build.test"] = "012e2f883ef36a9b336983d08f909d538adc32d45332316ad8319d0eced162b8",

  ["build.test_inputs"] = "309b687417091781ed335c2b7378163882bf0803574fa2954f4a5b9f48cf2cc8",

  ["build.test_sandbox"] = "64b5f000857d2f3ebf9cc66ce24f2555145314fa26f89a295c33e8c715a96e6c",

  ["build.test_worker"] = "b067d58a4f23e2e45dd778dca9df265b01ae9dbf32c9d756e9b39211465939a9",

  ["build.this_program"] = "543c40bf6abd96f03c599f91a873433d13a533ef19a6d6fca30085dc8b7c2265",

  ["build.zig_caches"] = "6fb33bb6dddd3bc15b50c6fe3435d1789240041e2401a0436f19cc5b9c878015",

  ["cmd.cosmic.main"] = "7e1aeb6507bc43ed66bff90de92beb0dcc983087452924d87f08be72ddc9e7a8",

  ["cosmic.child"] = "845d1775637abbdd8ccf3759e5b41e3996df56ca72b4022684f1093edab2f570",

  ["cosmic.coverage"] = "f8ac6e5ad6dc4eb2207c546b69ce80725d51d69c7587bfc895c6f23cbbdc9ebd",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "7713fba2b88c8505882d9580e48b67fa035bcba13644d872a5a18f786709c3d6",

  ["cosmic.proc"] = "9ec379c6f2fee07c94b5d8a9381f84bdba8824b78eaca129b2c6284e8f8dc3c5",

  ["cosmic.removed"] = "561c454617e4c48515e32e585f62b152c400c1bc0ea0224cab22a75381db5ed0",

  ["cosmic.sqlite"] = "8deac467a3fb2a2e1585754a70597ce5cb8507a15f8f089f7e08d900d02d1762",

  ["cosmic.string"] = "579df77a2498f37f1867b377dd5609f64074028ef7d7b7e5919f86435f61d96a",

  ["cosmic.test"] = "747f225653f808f4d26b70838dc45ce4193af2be08dcad34ca338dd44df44b17",

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
