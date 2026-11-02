--- The test harness's epoch, which every sandboxed verdict key holds
--- ([`build.declared_key`]'s `epoch` part) in place of the harness's own
--- code: what every worker loads ([`build.test_worker`]'s `loads`), the
--- sandbox's maker ([`build.test_key`]'s `harness_own`), and the code that
--- makes a key and looks a verdict up under one ([`build.test_key`] and its
--- `key_code`). An edit to that code moves no key by itself, so a
--- comment in build/test_key.tl runs no test again but those that import
--- it. `epoch` moves every key, and is bumped by hand for a change that
--- can alter a pass or a fail. The runner around it, [`build.test`], is no
--- module of the harness: it schedules the workers and keeps the history,
--- the coverage and the summary, makes no key, and an edit to it moves
--- no digest here.
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
--- the choice was last made ([`build.test_key`]'s `harness`, over each
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
--- * build.test_key itself, cosmic.child, which applies a worker's
---   sandbox, and cosmic.sandbox and cosmic.sandbox.policy, which decide a
---   policy worker's grants (`harness_alone`), each held alone;
--- * the closure of the key's roots (`key_roots`) over the requires each
---   makes by value, as its bytecode names them ([`test_key.value_imports`]).
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
  mut epoch: string
  --- Every token `epoch` held before its current one, oldest first.
  mut retired: {string}
  mut acknowledged: {string:string}
  --- The standard-library modules the harness's modules may reach, each
  --- by why it must.
  mut library: {string:string}
end

harness_epoch.epoch = "68-e680128b" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "a7cd28a1e980b748cfeb35ba4dd544c897f52d38700917174cecec0f77e82a7a",

  ["build.assertions"] = "410e45284b2737215f24ae88cf827d93d66b512403abb23ff213262ec6dd341f",

  ["build.bind"] = "e6e670add858a2a3b3fe668d61a1447b7ade175ca3c8de64ab040e091c3038a6",

  ["build.cache_formats"] = "2cd4a0d62a935567d66baae50dfb26d16a03c028c32eae2d08087d607f40178a",

  ["build.cache_names"] = "b9f26afc65a580578f0e426537798b7ac4717ede50b93762a366d69cafe4c9c5",

  ["build.caches"] = "8202d64fe1e7ebad1a89e753305a82913c60ae5a0ccffad54a4a8f8e46649db7",

  ["build.confine"] = "da59bdd0ed599feac062f10ef912a7963e019475b2da9c79d0794459c4744d22",

  ["build.core_image"] = "18daf88c3c58f62a222472eaa52b99218cd1e5b7ccafde6a0beded46c8f3382b",

  ["build.declared_key"] = "29407b9c751a63ec7b9242a8add8520a96133f0f2008773dd17901c3c803ac0f",

  ["build.digest"] = "9437ad0c656ef9ad0c8396b0370e6d3727682b5cb43d9dea4ded4f4f14896170",

  ["build.host_names"] = "eaf74cf62096708d785929c3d825e996b2f462785ebb1cc23a78968201575d4a",

  ["build.host_requires"] = "4c82ce0592aae3852c6b05ca1fb7d894f356db79d777a89d36766f04cdb788a8",

  ["build.key_parts"] = "acaafac3a19ed27d9fcdcc4d55f59d75eb1bca9aa1ab5fdbe5ae511975fb7559",

  ["build.launcher"] = "ef6479d3f260455c3f234bb91ccfd3b692dd29964391b3459fe865506f914489",

  ["build.load_module"] = "a54bd951a24ee621ba85cda899b57226f1203ebc7ff8e710fad39459d5ba6e63",

  ["build.paths"] = "425b1a9019afbf100e4bb6fe73ab999020829705a275c2a1604908938eef85be",

  ["build.plural"] = "08dc094acbdc34d3bc0ed7d04238e33810e3ff573574b2e612e1202bde7f24c4",

  ["build.shared_sqlite"] = "a1f438f3ab7ff5eb92e8db6235d80bd75b6dc8db51833f27aa78cc6965daca90",

  ["build.shared_verdicts"] = "8e284e5037581b928c10bf291f7dbaf8001623716138300369e261e88bb35b3b",

  ["build.test_inputs"] = "a97a6a6c70a397a0b641aa2ecedac3cf88dba21044380dee8e8ed39804e75f82",

  ["build.test_key"] = "18ddb2cd019df8b09ea1a33fb73f59ce81d2ae7c2ca4371e8bbae6024dc44889",

  ["build.test_policy"] = "b1eda91fc78d4da9c2216a5a78b3394c64e7bcf51cacb3d4469bc053ade829ea",

  ["build.test_sandbox"] = "0f483ad2a3ad9d4774866de8f2d6bdf834e8bd2b2d3b52c5a0133a833a6ebcfb",

  ["build.test_worker"] = "1e04b5ec9aaa5b45241322ff85dae247809f561576d9f15d8f5b37f69430d9bf",

  ["build.this_program"] = "bb2c0f8a8f6c1e4ae9ec00c8de712705416150c4aeb8c3a402625071939a69f2",

  ["build.zig_caches"] = "3dd89e9f3b612891419f3178cfb211d59ff80da1e42515f77e33b4a9366f2853",

  ["cmd.cosmic.main"] = "4199a34c391ac393c2cff8404cced9e3e593309f7ec58fb1af37f26e3fead347",

  ["cosmic.child"] = "398d21f3f73d3030a4f508b5ea3d83631b282de4f4144902292958a58ac59ecc",

  ["cosmic.codec"] = "5e783e4f60065fa4f114225120aaf286c3d07987b4df98ade9e39e93c5bd24f5",

  ["cosmic.coverage"] = "606cfe646be07026cd761d392d21d2ca9000a074c061b6c325bf2b67a8039770",

  ["cosmic.env"] = "b198b867296cbb43addd4f19f5bea6f347ec2fb1e0de083400d9ed65aa065d81",

  ["cosmic.fs"] = "d47e88f534b9e101579ea84e95a273795c3aeb0d013c4b300c17a46f685b79eb",

  ["cosmic.hash"] = "32dfb2b98f9d8fb0ab5eaee33c7e3b629de3da535e46bb9b729a4fc81714ed0d",

  ["cosmic.proc"] = "277980fe5e57f7abe4abdcaad233381e7228b5bee3ac3daa41d98c4a2b7d3a82",

  ["cosmic.project"] = "42d53afc698ecff44995a56ae3c68521484a595bbb8aee3223c6824c9dcc3002",

  ["cosmic.sandbox"] = "95644257ea639ea879dbb6a42d10a7eb500d033e1198d055af959fe3b8bf9630",

  ["cosmic.sandbox.policy"] = "ce2cbf3101cfe8a57d0d946b3c1fe2b5bdb8626b0fa39f45b9bdcf46b9146c65",

  ["cosmic.sqlite"] = "e5e70f0c6dd0be5a7fcf31c731e4e305584c799aa4f00bffa5a469383a4a9467",

  ["cosmic.string"] = "4696ea716c4b8f796923350161765a4fdc0313355d68c327902536123cf603a5",

  ["cosmic.test"] = "d42c7799c5e129d6538a4e112d05738e057096795444d33fad147a6a0fd75f9d",

}

harness_epoch.library = {
  ["cosmic.child"] = "its `start` turns a worker's plan into the unveils, binds and " ..
    "offline spawn holds it to; held alone, what it requires is not walked",
  ["cosmic.codec"] = "cosmic.hash's hex encoding of the digest `build.paths` names a " ..
    "project's build directory by",
  ["cosmic.coverage"] = "the worker starts and stops the coverage a test's lines are " ..
    "counted by, whose session a test that imports it shares",
  ["cosmic.env"] = "the worker's environment, which its key holds, is read and built " ..
    "through it",
  ["cosmic.fs"] = "places each read, bind and unveil (`within`, `relative`), writes " ..
    "the worker's report, and probes the paths a module requires of the host " ..
    "(`build.host_requires`: `exists`, `is_dir`, `absolute`)",
  ["cosmic.hash"] = "`build.paths` names a project's build directory by the SHA-256 of " ..
    "its root (`hex_sha256`), where the worker finds its tree's and builds its own",
  ["cosmic.proc"] = "names this program (`executable`), which a worker whose test does " ..
    "not declare `tool` is held from running; and finds a program a module requires " ..
    "of the host (`find`) and whether a portable artifact can start again " ..
    "(`relaunch`) for `build.host_requires`",
  ["cosmic.project"] = "`build.paths` asks its `directory` where a project's build " ..
    "directory is, where the worker finds its tree's and builds its own",
  ["cosmic.sandbox"] = "`merge` resolves a policy's profiles into the grants a worker " ..
    "is held to (`build.test_policy`'s `runs`); held alone, what it requires is not walked",
  ["cosmic.sandbox.policy"] = "the policy layer cosmic.sandbox answers under its own " ..
    "name: its `merge` and the profiles it joins decide the grants a worker is held to " ..
    "(`build.test_policy`'s `runs`); held alone, what it requires is not walked",
  -- TODO: take cosmic.sqlite out of the harness, and this entry out of
  -- `library`, once build.shared_sqlite gives build.declared_key's
  -- `program`, build.shared_verdicts and build.bind what they read and
  -- write through the raw binding (cosmic.internal.sqlite), and they
  -- and it reach no cosmic.sqlite.
  ["cosmic.sqlite"] = "the key's code digests the rows it reads of the store, and " ..
    "shared verdicts are stored and looked up under exact keys through it",
  ["cosmic.string"] = "text a key or verdict holds is split, tested or counted through " ..
    "it: the launcher's template (`build.launcher`), the runtime identity " ..
    "(`build.test_key`), sandbox paths (`build.test_sandbox`), the artifact's SQLite " ..
    "header (`build.artifact`) and " ..
    "plurals (`build.plural`)",
  ["cosmic.test"] = "a test's declaration (`Test.policy`), which the worker judges, and " ..
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
  "3da8eb88",
  "d2c79229",
  "312f48e5",
  "74e91a61",
  "5f20bcaf",
  "8a7a1acd",
  "6d092906",
  "edbfc9d7",
  "72d5649f",
  "3074f3dd",
  "385455a5",
  "a2e20ebb",
  "8d6d32ab",
  "3ef16d5d",
  "f1098f05",
  "65e16d68",
  "3ce9b8e0",
  "c7eacb64",
  "aabf64e1",
  "9ee7da50",
  "2ae6c1bc",
  "70386030",
  "f3062d3a",
  "0b25a594",
  "c2cc59fa",
  "01fb9c1b",
  "7517cd3f",
  "e102e8aa",
  "a6665ec1",
  "fddb0e02",
  "f29a420b",
  "1c38ce00",
  "dbae9496",
  "4523ed60",
  "70cb7bca",
  "69753f80",
  "692cdf96",
  "c5141a87",
  "4a96df9f",
  "b5aed75f",
  "46f7c58b",
  "2eb7fbc7",
  "0d97379f",
  "2e847ae8",
  "3cf04e65",
  "130cdab9",
}

return harness_epoch
