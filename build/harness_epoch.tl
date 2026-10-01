--- The test harness's epoch, which every sandboxed verdict key holds
--- ([`build.declared_key`]'s `epoch` part) in place of the harness's own
--- code: what every worker loads ([`build.test_worker`]'s `loads`), the
--- sandbox's maker ([`build.test`]'s `harness_own`), and the code that
--- makes a key and looks a verdict up under one ([`build.test`] and its
--- `key_code`). An edit to that code moves no key by itself, so a
--- comment in build/test.tl runs no test again but those that import
--- it. `epoch` moves every key, and is bumped by hand for a change that
--- can alter a pass or a fail.
---
--- `epoch` is a count and a token of 8 random hex digits,
--- "N-xxxxxxxx": the token makes each bump its own value. Were it a
--- count alone, two branches that each bumped 7 to 8 would make the one
--- edit, which git merges cleanly, and the merged tree, holding both
--- changes, would stand on the verdicts either branch earned under 8
--- alone (the shared verdict cache is keyed without the tree's
--- location). Two tokens conflict on the line instead. `retired` holds
--- every token `epoch` held before, in the order they were retired
--- (the counts 1 to 7 for the epochs that had none), and the count is
--- one more than how many it holds: a bump appends the old token there
--- and draws a new one, so a bump of the count alone fails, and two
--- branches that bump from one value append the same line, which
--- merges, while their `epoch` lines conflict. On a conflict, keep
--- neither side: set `epoch` to the bare count and run
--- build/harness_epoch_test.tl, which fails and prints a fresh value.
--- That test holds `epoch` and `retired` to all this, and prints both
--- edits of a bump when the harness moves.
---
--- `acknowledged` holds a digest per module of that code as it was when
--- the choice was last made ([`build.test`]'s `harness`, over each
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
--- * what every worker loads ([`worker.loads`], which [`worker.judge`] holds
---   each worker to);
--- * the sandbox's maker (`harness_own`);
--- * build.test itself and cosmic.child, which applies a worker's
---   sandbox (`harness_alone`), each held alone;
--- * the closure of the key's roots (`key_roots`) over the requires each
---   makes by value, as its bytecode names them ([`test.value_imports`]).
---   A `local type` require is not followed, since Teal erases it and
---   what the imported type does at run time is compiled into the
---   importer's bytecode, which the digests hold.
---
--- A module of the harness reaches the host through the core's raw
--- bindings, which the runtime's identity keys, and through the
--- standard-library modules `library` names, each with its reason, and no
--- other `cosmic.*` module. What else of the tree the runner calls is its
--- plumbing -- the probe of whether to sandbox
--- ([`build.test_sandbox_probe`]), and what cosmic.child requires to start
--- a worker -- which must fail loudly, as a failure or a refusal, never
--- as a pass. What a module of the harness calls through a library table
--- a test can replace, it takes as a local when it loads.
local record harness_epoch
  epoch: string
  --- Every token `epoch` held before its current one, oldest first.
  retired: {string}
  acknowledged: {string:string}
  --- The standard-library modules the harness's modules may reach, each
  --- by why it must.
  library: {string:string}
end

harness_epoch.epoch = "9-757b1277" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "55c6260541c8f3be6caf3f77121aadb47636a8f26308e3b0b089e7b193522176",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_names"] = "935f423ffc3fa01e6dc82028a841458319195762357707325f71fcd1e2385afd",

  ["build.caches"] = "598a907beb9763ee08569df514f2437ddfeb6734b8a9f5d1a00c2e77ce510ae3",

  ["build.confine"] = "ec5426f0704b978b8f5adc7e633e072205e0224de2e694b6ca278a41e3915ae0",

  ["build.core_image"] = "4942e488c251af85703efc977c9e33260b199134d39316c3b9a5579dcaff7830",

  ["build.declared_key"] = "c6166fb0527d5fcfa0ccd502f42ad1525faa3b88d52e91ade1879fb8679e8693",

  ["build.digest"] = "dccca5b63f2992d4d23213450142bdd05eee403ebaf3a4e0acf7437da72558f0",

  ["build.key_parts"] = "b1e6657cd10ce608808b81bb3d77b919e96e8ca93303999a7a556466d1ec44d0",

  ["build.launcher"] = "1bddaa2b691f6aa90da3256d045fc69f38d12c935e981a231841d94c2157b224",

  ["build.plural"] = "52aa9695f4dffc58d017a83027ef65807b8d22b794b6d286a82ab70009250e69",

  ["build.shared_sqlite"] = "9750c85b5db5419e925d8a8af9552c60054872486a5e37ea762ee3c4862536d2",

  ["build.shared_verdicts"] = "ea3d41711f22f34b782afb89ae40abb12729f01f76614951e9e65c6aa700f67f",

  ["build.test"] = "c2ab362cdfc944084af8f03d15d0674be383cd37b176281f2d7fadb566425691",

  ["build.test_inputs"] = "c17fa9cc8ac35e4785118830e365e60d4916b706976049990f3827d7b3e90bbd",

  ["build.test_sandbox"] = "453f3828508b60b2acf0e20351c5e10990a8ffea899aebdb94f5756451a07f54",

  ["build.test_worker"] = "57249c719262d3016dc13b8ba53d35a3bc6c8798a029d9472108889ade765574",

  ["build.this_program"] = "8de7976beaec4a4367f0a4af8cd2162df5f587891cbad1b94ecc51a28de203eb",

  ["build.zig_caches"] = "d35906e02830ba49939d7d8c8ec2ac9ffdd1782285c1577751b318dc98d17eac",

  ["cmd.cosmic.main"] = "d00f469acf42d89c76c2e9ebabd40e73e20d00cb3a5ad6d9189716265fcdf9bf",

  ["cosmic.child"] = "f380a2800378c01c6288083eb3bba9628f981f5b729f92bf4eda3d3d88a6b961",

  ["cosmic.coverage"] = "0fd55d11c4562209364c73b81a1c02b7808d3022aae2895423385753ed6c7d59",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "7b39d76caacdca83ad29f57573056a3eb6f7d61077a35d240491d05f54b51be3",

  ["cosmic.proc"] = "489cf0b96c5294aee2aee1de5b3c884bc489bdfecd90b822c5b383ebf1d23cc7",

  ["cosmic.removed"] = "c8cf8276e37c26ce0fde2635db78b793ff5ccff6c754385b306676cf6d63a6a2",

  ["cosmic.sqlite"] = "82d676b467d4922f82441c9e753116850dbfafb2ebc20fa5b1a6b7029b0a97c0",

  ["cosmic.string"] = "579df77a2498f37f1867b377dd5609f64074028ef7d7b7e5919f86435f61d96a",

  ["cosmic.test"] = "577bc17543910d9c6abc7b0ce498c8a80646c712699a00622e3c448fe0f840bf",

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
  -- `library`, once build.shared_sqlite gives build.declared_key's
  -- `program`, build.shared_verdicts and build.bind what they read and
  -- write through the raw binding (cosmic.internal.sqlite), and they
  -- and it reach no cosmic.sqlite.
  ["cosmic.sqlite"] = "the key's code digests the rows it reads of the store, and " ..
    "shared verdicts are stored and looked up under exact keys through it",
  ["cosmic.string"] = "the launcher's template, which a key holds, is split into lines " ..
    "through it (`build.launcher`)",
  ["cosmic.test"] = "a test's declaration (`Test.needs`), which the worker judges, and " ..
    "the runner's hook into it",
}

harness_epoch.retired = {
  "1",
  "2",
  "3",
  "4",
  "5",
  "6",
  "7",
  "072f7458",
}

return harness_epoch
