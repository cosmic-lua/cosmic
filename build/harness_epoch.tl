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

harness_epoch.epoch = "53-0e837ee8" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "6bcacc0e4e216df503ef7866f63bfe517e804ab88cfed06e76c2bea9bd67946c",

  ["build.assertions"] = "536da1af6ed52bf04f8f8803d77f83f44a9c43cb65f2572eca09c995fa87fe4d",

  ["build.bind"] = "e6e670add858a2a3b3fe668d61a1447b7ade175ca3c8de64ab040e091c3038a6",

  ["build.cache_formats"] = "0f32a7868d0e9b00d1170380e8ca7ba93d449b66cebf9b3a182c8218a993b122",

  ["build.cache_names"] = "1bdd81c33602e85362226a8bb0b529720d89c747376961f8d0aab99158c9e772",

  ["build.caches"] = "969bfed82c44d6623119afcedbecd265a1bbbd43805e43dc1c96462dfeee98d8",

  ["build.confine"] = "2b711ac00186f5caed7ae1920eed0ce9a14ac17b50a53707c84b4f083f686799",

  ["build.core_image"] = "18daf88c3c58f62a222472eaa52b99218cd1e5b7ccafde6a0beded46c8f3382b",

  ["build.declared_key"] = "96292625c08a260df641f76860b362eaa7a77fef1d595b1ba2fcf7961dc31a53",

  ["build.digest"] = "63588bce17aabb935b044ae8a4af8cea78d1dca19822a36e72efe62d4a877355",

  ["build.host_names"] = "2312dc872d652e92fad4dcd73cffa31ed1ad179d5e5cb960a06df33ba562eb73",

  ["build.host_requires"] = "3feee5ee2450c6bad2bdd380cb14c169173ee8076e9b4ac7afd3fac8cf2e0e3e",

  ["build.key_parts"] = "ec597f813d1bc7c595f21e587900c90c6be0f9d9402566beb076719069996e8b",

  ["build.launcher"] = "ea8495db991837f0b3411e99305d62b319c96071089897b555516062f6c05579",

  ["build.paths"] = "911ce247a4e165f0e0be03486c0b4c74fc02676d2d18363eeebbdb01af6286b4",

  ["build.plural"] = "08dc094acbdc34d3bc0ed7d04238e33810e3ff573574b2e612e1202bde7f24c4",

  ["build.shared_sqlite"] = "3af88d37269e2836b4cd960373cc187a8cf919101f0534328aa8341eb25c69e6",

  ["build.shared_verdicts"] = "8d1755865073aabf737be7f5c9aafe036b97a38a06139447118a44a2ddeb1fd9",

  ["build.test_inputs"] = "a1c8aa5a8905d712f576c843749adf8a4ce16702c7e377c56c77864ec36c1c37",

  ["build.test_key"] = "9ac6c2c0722b98b0ff3cac1b60df030d79fb0cca53a7d3b9e1f5223e9beb8fff",

  ["build.test_policy"] = "6f9e3fabca11585b186a5cad1b41a9eaf068b43c28f5ad56bee77a680dc6ad01",

  ["build.test_sandbox"] = "e1339de6c480185265165dcf809188758b4d96012c15d75731adff2aaabed4f7",

  ["build.test_worker"] = "0e412717c6a27d88ef24e4dcd0662c3043d95070687a43f6d922e476a2e17a96",

  ["build.this_program"] = "fda119e6dda378526fc10aa2d080860ac1a4a85a84bead050144b07e6ba07d5e",

  ["build.zig_caches"] = "3dd89e9f3b612891419f3178cfb211d59ff80da1e42515f77e33b4a9366f2853",

  ["cmd.cosmic.main"] = "4199a34c391ac393c2cff8404cced9e3e593309f7ec58fb1af37f26e3fead347",

  ["cosmic.child"] = "00132fd7d4d1e42c4087c4907ff04cf5e6ccd98302a8efc4e312dcc370050902",

  ["cosmic.codec"] = "52572ec5f66817018bb20d585ebc0e5ea2ed14b2d15af6eaeb61a8dc13e5624b",

  ["cosmic.coverage"] = "1fd90d399ac245486c914ca72e37ff638957ca46403aba64acbbd1af77017942",

  ["cosmic.env"] = "4fab933c9a5f8103144f6b2283e368c140878ce80bcb8162866aa9ca2004927d",

  ["cosmic.fs"] = "155cd26d7bb31b6cc3431f49cf816b0bb78dd87e9fe61fc65cfdbd14938de70f",

  ["cosmic.hash"] = "965927db84637153d43cb09283970fd875a1164afde8ec862fd48965991f8d79",

  ["cosmic.proc"] = "c6b7da95cc5de8810585859b6751498cb0e5403857395b4e6836937e2564acf4",

  ["cosmic.project"] = "7109f1a1bfb3400ba57174beca48225a345b8388ea0766a1eab33929545fb8ec",

  ["cosmic.sandbox"] = "a05185b626ff560626242e02ccc05842c202295e84ed05803f661ee690b3ff40",

  ["cosmic.sandbox.policy"] = "e49d7a8711ba86b30ccd2d1f541a276c7668fc2bead052fa7a44d4503d17e267",

  ["cosmic.sqlite"] = "acaf8e4c6d9c978bca8291420b8d192f5cec8665fa94a09ce5a12ee283cebdaa",

  ["cosmic.string"] = "00360e77fa2fb890be0cb2f3a2388975a45dff636aae22cfc9c28b04d84eb2a9",

  ["cosmic.test"] = "cfc0d8ed2c8a9c3adcb0c281f764a6900ff978328557b218bc606fd8b4ff319b",

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
}

return harness_epoch
