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
  epoch: string
  --- Every token `epoch` held before its current one, oldest first.
  retired: {string}
  acknowledged: {string:string}
  --- The standard-library modules the harness's modules may reach, each
  --- by why it must.
  library: {string:string}
end

harness_epoch.epoch = "60-4a96df9f" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "38a8cfff7234e89aac9fdcdacbdc2148b35a282d73f0ff59952aa360d9d74033",

  ["build.assertions"] = "493581fd2868cf0ec99a12baaf108fb28c9106398d2df35a8e5d3d925ad6bfd3",

  ["build.bind"] = "e6e670add858a2a3b3fe668d61a1447b7ade175ca3c8de64ab040e091c3038a6",

  ["build.cache_formats"] = "0f32a7868d0e9b00d1170380e8ca7ba93d449b66cebf9b3a182c8218a993b122",

  ["build.cache_names"] = "1bdd81c33602e85362226a8bb0b529720d89c747376961f8d0aab99158c9e772",

  ["build.caches"] = "8202d64fe1e7ebad1a89e753305a82913c60ae5a0ccffad54a4a8f8e46649db7",

  ["build.confine"] = "4ada3faec7b320e887486f86fea16ed8aefc92f5b2a7b27b5dd783f9fa579a11",

  ["build.core_image"] = "18daf88c3c58f62a222472eaa52b99218cd1e5b7ccafde6a0beded46c8f3382b",

  ["build.declared_key"] = "2003b297475205fa31fa12cd7bb78193c73d52b15f18969e6fa8d47b9e490569",

  ["build.digest"] = "9437ad0c656ef9ad0c8396b0370e6d3727682b5cb43d9dea4ded4f4f14896170",

  ["build.host_names"] = "be77323ab570346a02b67f7b8122cf30503dcb0642adb23f1f1c3d9b6da61547",

  ["build.host_requires"] = "9356c9adfc65e4cf1415b145a63d27be272b6cd8aa050e952ad1bfd7d0af3028",

  ["build.key_parts"] = "8d6552f9b67824ad5158996a1806062870f2e0a7f8eac6d42f27b3fa26337fc2",

  ["build.launcher"] = "f63b34f9b3b26b36a59c5c7cef59230fc3d9abe428a6c911a9623c53c8c8a9cd",

  ["build.load_module"] = "a54bd951a24ee621ba85cda899b57226f1203ebc7ff8e710fad39459d5ba6e63",

  ["build.paths"] = "911ce247a4e165f0e0be03486c0b4c74fc02676d2d18363eeebbdb01af6286b4",

  ["build.plural"] = "08dc094acbdc34d3bc0ed7d04238e33810e3ff573574b2e612e1202bde7f24c4",

  ["build.shared_sqlite"] = "a1f438f3ab7ff5eb92e8db6235d80bd75b6dc8db51833f27aa78cc6965daca90",

  ["build.shared_verdicts"] = "4c24d7d643a460ca52731f5549be2e0f567576f5ea6e0c2b3382a7e6ef223f10",

  ["build.test_inputs"] = "3e1795794c1f76e4fc42314b7ed0ac1f455848397e86c01005de697d21e45581",

  ["build.test_key"] = "946f70444b29ece2bade7a7f9d7aa69440a014e5e75e62c1e832915eeaff13fe",

  ["build.test_policy"] = "b1eda91fc78d4da9c2216a5a78b3394c64e7bcf51cacb3d4469bc053ade829ea",

  ["build.test_sandbox"] = "e5980389fa52539475b918e58e3d34d133e7f20b97430ec7e16c2d8a52fd6a2d",

  ["build.test_worker"] = "ac1b7e08f7e1a8c3ec8c38ed1381971a8bf643c44f64feda5f01990cf8c24588",

  ["build.this_program"] = "345b0565401a0f96cd0dcc4165281806148315424265bca17841eaf72d32fd42",

  ["build.zig_caches"] = "3dd89e9f3b612891419f3178cfb211d59ff80da1e42515f77e33b4a9366f2853",

  ["cmd.cosmic.main"] = "4199a34c391ac393c2cff8404cced9e3e593309f7ec58fb1af37f26e3fead347",

  ["cosmic.child"] = "e8827ff6e5d49dbb2f18b5a015febdbb58ea9ebaafe7465fb17d28e552b99b8e",

  ["cosmic.codec"] = "5e783e4f60065fa4f114225120aaf286c3d07987b4df98ade9e39e93c5bd24f5",

  ["cosmic.coverage"] = "606cfe646be07026cd761d392d21d2ca9000a074c061b6c325bf2b67a8039770",

  ["cosmic.env"] = "00c375e0905b4c0589a2f40f9760f5dd85e931fb56413d83c0d7da07192c83c6",

  ["cosmic.fs"] = "8181e65f1fe838a9b20dcf4bd6ace61e7be9c422a7f043345a8957bad62bbd21",

  ["cosmic.hash"] = "32dfb2b98f9d8fb0ab5eaee33c7e3b629de3da535e46bb9b729a4fc81714ed0d",

  ["cosmic.proc"] = "8f841564877b8a1fe98ff67ea49b9655e22661c2e63c32b05823f12b70e3e218",

  ["cosmic.project"] = "0b9e174a20d130f3bacf1e7e44eac912a5dac86238b58f83408eb43f3eff1986",

  ["cosmic.sandbox"] = "95644257ea639ea879dbb6a42d10a7eb500d033e1198d055af959fe3b8bf9630",

  ["cosmic.sandbox.policy"] = "ce2cbf3101cfe8a57d0d946b3c1fe2b5bdb8626b0fa39f45b9bdcf46b9146c65",

  ["cosmic.sqlite"] = "1c571fba7ea7bafbaa1cb7bb91253c8419f74a9c12922b8a66c8c27183a9d97e",

  ["cosmic.string"] = "4696ea716c4b8f796923350161765a4fdc0313355d68c327902536123cf603a5",

  ["cosmic.test"] = "2f3ad39a3577a9bea280c8b7578966002607d3738e76e1cb8dc045a1ad8c046f",

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
}

return harness_epoch
