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
---   sandbox, and cosmic.sandbox and cosmic.sandbox.policy, which decide a
---   policy worker's grants (`harness_alone`), each held alone;
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

harness_epoch.epoch = "49-e102e8aa" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "f0ce2ba33bea96c13f1a40f6883c8a512b363ea0fe3996fb1cec4ad609d05899",

  ["build.assertions"] = "536da1af6ed52bf04f8f8803d77f83f44a9c43cb65f2572eca09c995fa87fe4d",

  ["build.bind"] = "e6e670add858a2a3b3fe668d61a1447b7ade175ca3c8de64ab040e091c3038a6",

  ["build.cache_formats"] = "c8ff0b082d587dde5b954b9966119e935ea1d2b052f9d9cdb3784a3fddc94ac5",

  ["build.cache_names"] = "f3ffd43d849dcd48fc9d781a0826d9c500484e41fc5c9cc0597a4b37cd650516",

  ["build.caches"] = "b39b55b004ea7b8584d1ffbe6dc64fc0f2f4f1c7906bd10bc22510278204d980",

  ["build.confine"] = "9f53e093dd7fcc0941c131561d343fa47da3dede1c843fc0578838197be52e80",

  ["build.core_image"] = "b3106284696a578a122a0c4e9b3138a4f337795944c670b908e729ed91b1e2c4",

  ["build.declared_key"] = "3e39f82296c12b23c5e0a3ac8d8cca42b66a3e168a3541966a119f2384c9e210",

  ["build.digest"] = "918687680d02c908dc1080f10a40dbab03941f70baae7605f3536e0f18e84d49",

  ["build.host_names"] = "420b04ddfb93cc60b6bbab3a1129b118f161bb92bbf0f5f7fbf1d6b918a05eca",

  ["build.host_requires"] = "51f598b4b418bd54e9b13aba52ca4e7fb83ff81514bff3a26fefdf7eab449787",

  ["build.key_parts"] = "2472f14aea015351fe3ab87a2be1bf53ba2eb7980189cdf0e210c9735a7ce8b4",

  ["build.launcher"] = "bc52c3884cb494ea6a2e0bb2812bef61e0c273a87485be51e15e0f38e9c0bf97",

  ["build.paths"] = "6b7deba6fcc62042a96683d7576c26789838825e650ce70621c305315c78f4cd",

  ["build.plural"] = "08dc094acbdc34d3bc0ed7d04238e33810e3ff573574b2e612e1202bde7f24c4",

  ["build.shared_sqlite"] = "5745750ce96c9251747ef491ce4270ea65a4ba12095fbf45538d394e5e8e8553",

  ["build.shared_verdicts"] = "8ebd1caf3241a119bed76eb61f3992b681453bfef5e3cb19f12cee99b2b8ba31",

  ["build.test"] = "b79b230d9cbcb20c1ab346c120bca8be760b9e0a113dca53d1b399df1d6b8523",

  ["build.test_inputs"] = "c4df041918cc0a05acae546709cdfd912b4b1e8cdb26b51d8e515abf7e58713c",

  ["build.test_policy"] = "597348dbe514ef0cee04cbfdcee0f3b3198d9a15a2bd4f51961b3fc1894de607",

  ["build.test_sandbox"] = "2455f9e5686ca8d45f15dad33c498103d70f94df8bde8ce235a6d253b58f8da1",

  ["build.test_worker"] = "cf260d35867d05c79a8fad331ccdb661c37bd96328b5d681cdee976298498172",

  ["build.this_program"] = "a8fd0caa3b712ad0b9e6b31f8db858f20273a3a0d1e83784bb507e24bb7feead",

  ["build.zig_caches"] = "ab1f618e4f1897e2afbe87026d1979e2a4cfaec1f736042aa3e73e9f1fe5f0fe",

  ["cmd.cosmic.main"] = "2d26957d2b15907fee48c1fc319df0413b348cfd6115522c5a8fe52aecbc2afc",

  ["cosmic.child"] = "c16a40e5b4e1f09bc87cf75fa7a0e22ac348ad6283bd28845ab3c69405a84cd1",

  ["cosmic.codec"] = "6541259b7dbf3789b1b57242d4af4c2e9eb0efa7c872305c328ae8e67e7e4883",

  ["cosmic.coverage"] = "3030dd441f3319242cc72e83bb909a5f560d222109555be02b15e518f3986be2",

  ["cosmic.env"] = "f46e76a3997fea1668f7abe80648275de12b77285c9a4aaaf428552c985b65d1",

  ["cosmic.fs"] = "fee40d6615b03d989a8c708625a21c76c0b81ff6daaf73014b4f6ea1a938755a",

  ["cosmic.hash"] = "c6b73b0d1b1aafdf5a122b5a8cffa74fd1ff0b39f7129ff48d1ef91b2769f83a",

  ["cosmic.proc"] = "a5e3f73f45f2df5f6104313300f479ec0b16a5325c3b05a95ca2393ae6397574",

  ["cosmic.project"] = "ff7ae4d2958b9a7d24d13c990b8e3e3f41f0574fa169a645298c21b246924843",

  ["cosmic.sandbox"] = "83a15b8f74f0300b061edad177ec06eb06ea4494334a88bae14602fed720c66b",

  ["cosmic.sandbox.policy"] = "062777703fa8bf520e872d8e1b39ed9da6cbe62089498e044055a08b46b59404",

  ["cosmic.sqlite"] = "70e62606a82d6381773966682bf48837b73a0ea26de44ad604636ad5c2ccc3a9",

  ["cosmic.string"] = "e1ca89bb3a9446c9d398d8be50425177b32981a9b1b40bdf8504661e7f388691",

  ["cosmic.test"] = "51ed8f4ac4390f3ac6b2accd9eeda2430f87f7404b0bbae06338b348afedc012",

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
    "the worker's report, copies a closure's files past the most paths a sandbox " ..
    "holds (`build.test_sandbox`'s `in_copies`), and probes the paths a module requires of the host " ..
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
    "is held to (`build.test_policy`'s `runs`), and `profile` names the system's paths a " ..
    "plan counts among them (`build.test_sandbox`'s `granted`); held alone, what it " ..
    "requires is not walked",
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
    "(`build.test`), sandbox paths (`build.test_sandbox`), the artifact's SQLite " ..
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
}

return harness_epoch
