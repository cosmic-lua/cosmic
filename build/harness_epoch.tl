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
--- * build.test itself, cosmic.child, which applies a worker's
---   sandbox, and cosmic.sandbox, which decides a policy worker's grants
---   (`harness_alone`), each held alone;
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

harness_epoch.epoch = "22-3da8eb88" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "4405196f6511a21a7493aa3d1ee196c6318d3ceec2e0202800494c46b9502745",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_formats"] = "4ae5e6d24acc9388d72472a50da0146c5a026ec089796491001380175c195a40",

  ["build.cache_names"] = "d576babcccc2b3e8875bdae9066f2c53835e0a87374438ae98a86a8064214542",

  ["build.caches"] = "57bac59a121d7520f3d30b9052a6f6c5d67a51e8785c5a75d021760317fb9312",

  ["build.closure_artifact"] = "9b1cb928388ed598043b0743d5311a748d1159b2190ae03d7f190bbaeca25d39",

  ["build.confine"] = "a7da705d8f97b7d160646bb6fa522695225748602649fb4ca0cc16dfc7fe1a36",

  ["build.core_image"] = "dfc18e0e6316237ab9fb11a957df68d6217e42cffc6f2f3a767018c5313700ac",

  ["build.declared_key"] = "2c493574f2bb0dbbbef3279304217fb4b96c9bf6a92ee8eda14b3ee8ca050431",

  ["build.digest"] = "dccca5b63f2992d4d23213450142bdd05eee403ebaf3a4e0acf7437da72558f0",

  ["build.key_parts"] = "5d7e7852a5938ed34cdd452d5536608fea8c259faee423ea01bda47efb8adadf",

  ["build.launcher"] = "1bddaa2b691f6aa90da3256d045fc69f38d12c935e981a231841d94c2157b224",

  ["build.plural"] = "08b0e817376c03fe90737c8bb26d6ae1400dadd9d61b23d00c1b0f1051ad8771",

  ["build.shared_sqlite"] = "788981d831e67bb29bdf3e91e685e06904288d211d44fb671b8ece4c0ae00f77",

  ["build.shared_verdicts"] = "516c08e34d1fc392de5363af92b6d669344fc3c8b504c469ae3771a424d0db6b",

  ["build.test"] = "c93c714739425e7d20c3fecdac8969bcc6c0f1b07e0fc42362dbbeb6d70c53fe",

  ["build.test_inputs"] = "1d386a687529da4207a684dc7d231bdf7d89e38effce9048ea71ea5728cbe0bf",

  ["build.test_policy"] = "44ba4848ef58bb6ae0d4525a407b51e47da27c2b992961224c901957b3a716e6",

  ["build.test_sandbox"] = "05694570dd593cd528f32fc319331a2d51e29653b71e8c55ad62f1feb980d748",

  ["build.test_worker"] = "bb31365aa690a48f616b91abb91e97be909c3bde4b466dabf5f29f20c1d92a34",

  ["build.this_program"] = "975740a93eb1e88680fe402a0bf6e5e52d1acad579dbdfedd0be27d10ae02980",

  ["build.zig_caches"] = "472c399b1bbbc6f9b58a2edd4fa6fabcddbea9140cac683b58acec608ff3c78c",

  ["cmd.cosmic.main"] = "d00f469acf42d89c76c2e9ebabd40e73e20d00cb3a5ad6d9189716265fcdf9bf",

  ["cosmic.child"] = "dcdd2affc68d3637763ebf1bdc36e0c5a85a01cdbe90ef7e23758375120c6394",

  ["cosmic.coverage"] = "079fe202231c4ae3ee642e27f6703a37850132c28c2a6d1daf50c7eb1669ac9a",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "befc25dee33fd54963b4a28dfe6a825724c37ed9f0f26a29b8908b1a72f628ed",

  ["cosmic.proc"] = "bbafb94bfa1671115f839c6fe57c921893d31d0e5baa1c4b1692e802b9c06212",

  ["cosmic.sandbox"] = "1ad6efaf103f483eaa89388ef75f7ed99d3595eab22994f5d55a0ce180de87d3",

  ["cosmic.sqlite"] = "ac3fd16dd89251feaee572e4e4b1d29257037afeca3b5c9b141557f2ce732390",

  ["cosmic.string"] = "bf0e5e828de84f23aa818887e0280a3ebc844c9ca5e384c33227cb42715b8655",

  ["cosmic.test"] = "a0072e3b09edf24d66f561157c464601bef9d2b4ac42bb7e385cc9e8c06e855e",

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
  ["cosmic.sandbox"] = "`merge` resolves a policy's profiles into the grants a worker " ..
    "is held to (`build.test_policy`'s `runs`); held alone, what it requires is not walked",
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
    "header (`build.artifact`) and " ..
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
  "e0bd3a21",
  "3b24cc73",
  "8cd21a8a",
  "09244ac2",
  "e83f51b3",
  "a2b093aa",
  "3c746d0f",
  "97867c56",
  "31549737",
  "c81fe20a",
  "b6ac3eca",
}

return harness_epoch
