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

harness_epoch.epoch = "11-e0bd3a21" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "ab180fe0e9efe92df1cce055664fd33436a535b1db782b53c2dc9fa57039fdea",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_names"] = "935f423ffc3fa01e6dc82028a841458319195762357707325f71fcd1e2385afd",

  ["build.caches"] = "598a907beb9763ee08569df514f2437ddfeb6734b8a9f5d1a00c2e77ce510ae3",

  ["build.confine"] = "ec5426f0704b978b8f5adc7e633e072205e0224de2e694b6ca278a41e3915ae0",

  ["build.core_image"] = "4942e488c251af85703efc977c9e33260b199134d39316c3b9a5579dcaff7830",

  ["build.declared_key"] = "dd059c24a6198a61e915e825cce43139643401e0fbb2610a6e18a64f657be770",

  ["build.digest"] = "dccca5b63f2992d4d23213450142bdd05eee403ebaf3a4e0acf7437da72558f0",

  ["build.key_parts"] = "b1e6657cd10ce608808b81bb3d77b919e96e8ca93303999a7a556466d1ec44d0",

  ["build.launcher"] = "1bddaa2b691f6aa90da3256d045fc69f38d12c935e981a231841d94c2157b224",

  ["build.plural"] = "08b0e817376c03fe90737c8bb26d6ae1400dadd9d61b23d00c1b0f1051ad8771",

  ["build.shared_sqlite"] = "996930ade3ff42383e1634e7897910298ddeec11586c63ecd5136a378ebaa2b0",

  ["build.shared_verdicts"] = "ea3d41711f22f34b782afb89ae40abb12729f01f76614951e9e65c6aa700f67f",

  ["build.test"] = "678c780f84dcd498339edb2b9d7a27383fc4cdfd474ff1e18e217958d670234d",

  ["build.test_inputs"] = "b3027734e4e45cf19d64a6aa4f5c73da9d3e6963543beebfa27b7fac2b756de5",

  ["build.test_sandbox"] = "e830d7ba5c4ee63cf4e611c671875fc7741e92532d6c93d5adf7cf2b7d48ca9f",

  ["build.test_worker"] = "a2c184d0cb41e691aaec7b89edf5c830d739ef8d4c92bdfe5c707e3e3dc74c00",

  ["build.this_program"] = "0cc5168af57d57876e8f40f5e36219bbbcf9666f09ce0d78d306cc4840f50703",

  ["build.zig_caches"] = "d35906e02830ba49939d7d8c8ec2ac9ffdd1782285c1577751b318dc98d17eac",

  ["cmd.cosmic.main"] = "d00f469acf42d89c76c2e9ebabd40e73e20d00cb3a5ad6d9189716265fcdf9bf",

  ["cosmic.child"] = "cd052ecc519e4164febd39708a59349e6fefb09c5313c5c7f207f6d5b043bd71",

  ["cosmic.coverage"] = "42b4376d57c969edc7894363b20410fcc1d1cacda4f042a8fe3f4d05e91d6e84",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "7b39d76caacdca83ad29f57573056a3eb6f7d61077a35d240491d05f54b51be3",

  ["cosmic.proc"] = "489cf0b96c5294aee2aee1de5b3c884bc489bdfecd90b822c5b383ebf1d23cc7",

  ["cosmic.sqlite"] = "564ba342d5a754c2d506295754ff08f8319744006d3ffc9b3b27016750d5ffcf",

  ["cosmic.string"] = "7f7dfc84c61efeb1c11838e30de81a1e50e4014533d80c8409a31db05ce68c1c",

  ["cosmic.test"] = "fdbcb69647b9756c2cefa2e54fde6ca74695ba37dfc9e4868cfc12b2bb3119d2",

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
  -- TODO: take cosmic.sqlite out of the harness, and this entry out of
  -- `library`, once build.shared_sqlite gives build.declared_key's
  -- `program`, build.shared_verdicts and build.bind what they read and
  -- write through the raw binding (cosmic.internal.sqlite), and they
  -- and it reach no cosmic.sqlite.
  ["cosmic.sqlite"] = "the key's code digests the rows it reads of the store, and " ..
    "shared verdicts are stored and looked up under exact keys through it",
  ["cosmic.string"] = "text a key or verdict holds is split, tested or counted through " ..
    "it: the launcher's template (`build.launcher`), the runtime identity " ..
    "(`build.test`), sandbox paths (`build.test_sandbox`), the artifact's SQLite " ..
    "header (`build.artifact`), cache set-aside names (`build.shared_sqlite`) and " ..
    "plurals (`build.plural`)",
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
  "757b1277",
  "06977640",
}

return harness_epoch
