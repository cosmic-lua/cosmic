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

harness_epoch.epoch = "35-3ef16d5d" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "4405196f6511a21a7493aa3d1ee196c6318d3ceec2e0202800494c46b9502745",

  ["build.assertions"] = "9a37be1602aa1540dd0248a267964b00c667843089d44bfb3f1828f324a739ce",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_formats"] = "4ae5e6d24acc9388d72472a50da0146c5a026ec089796491001380175c195a40",

  ["build.cache_names"] = "d576babcccc2b3e8875bdae9066f2c53835e0a87374438ae98a86a8064214542",

  ["build.caches"] = "57bac59a121d7520f3d30b9052a6f6c5d67a51e8785c5a75d021760317fb9312",

  ["build.confine"] = "d832c729d13f4f4adf0d3cf983541826f6aa18340b924ed74213cef22fd7adfb",

  ["build.core_image"] = "dfc18e0e6316237ab9fb11a957df68d6217e42cffc6f2f3a767018c5313700ac",

  ["build.declared_key"] = "b870bb92d830c56274e85c5ef1add9ddf658adf456f63e8691540527ea25fca2",

  ["build.digest"] = "dccca5b63f2992d4d23213450142bdd05eee403ebaf3a4e0acf7437da72558f0",

  ["build.host_names"] = "aad7658fe3e84c19552b4f69151271d49d94e1fc924a016b450536ce2a2da1a6",

  ["build.host_requires"] = "8c17d5873cecb2318f579a3b0bf9ce3f18a3901f8f674956ac9321e823fdbae9",

  ["build.key_parts"] = "943e73eeff585ef486ed03cc22ba7143a92a715b58675d990a0051d8ed165b90",

  ["build.launcher"] = "1bddaa2b691f6aa90da3256d045fc69f38d12c935e981a231841d94c2157b224",

  ["build.plural"] = "08b0e817376c03fe90737c8bb26d6ae1400dadd9d61b23d00c1b0f1051ad8771",

  ["build.shared_sqlite"] = "788981d831e67bb29bdf3e91e685e06904288d211d44fb671b8ece4c0ae00f77",

  ["build.shared_verdicts"] = "516c08e34d1fc392de5363af92b6d669344fc3c8b504c469ae3771a424d0db6b",

  ["build.test"] = "9cae197443a101ae06514d8e4f3af4b1065aca8c6cf41be417d77d3c58b3e8d3",

  ["build.test_inputs"] = "ec023eee681364d5fb8e1ac9937d039c8320125cf60cb14ef55bc3c51a017b51",

  ["build.test_policy"] = "f4d98a90f54c4ba29b6ce6d50c0cf08a5efc02e225dbd2382af84dee78da8557",

  ["build.test_sandbox"] = "8b6770324a64caa08e574d7c72ce4a6e4af9f9ed803e947de07acc61f68484bd",

  ["build.test_worker"] = "ef7f9270be6e9c66b8f4dd933db78d7555e643a8fe86c8f27c02410e68837163",

  ["build.this_program"] = "7c92f68645762de7b5d774d8f0e0ae3494a9eb74b9a040e8a9c17b7ef2628a97",

  ["build.zig_caches"] = "472c399b1bbbc6f9b58a2edd4fa6fabcddbea9140cac683b58acec608ff3c78c",

  ["cmd.cosmic.main"] = "d00f469acf42d89c76c2e9ebabd40e73e20d00cb3a5ad6d9189716265fcdf9bf",

  ["cosmic.child"] = "9f17eb25506ca0e5d5fd3929130b60a4bc53714ee20e611a4f499e89a38d7fa7",

  ["cosmic.coverage"] = "079fe202231c4ae3ee642e27f6703a37850132c28c2a6d1daf50c7eb1669ac9a",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "befc25dee33fd54963b4a28dfe6a825724c37ed9f0f26a29b8908b1a72f628ed",

  ["cosmic.proc"] = "1f2f124e7478daaf5955a2043d03a379d8dbc657ffe938ac71d221376f677bcf",

  ["cosmic.sandbox"] = "e658801f7a54a6cacdec864a8040a8b3e058cc580bf20bb79e5777f6fa900a5c",

  ["cosmic.sqlite"] = "ac3fd16dd89251feaee572e4e4b1d29257037afeca3b5c9b141557f2ce732390",

  ["cosmic.string"] = "bf0e5e828de84f23aa818887e0280a3ebc844c9ca5e384c33227cb42715b8655",

  ["cosmic.test"] = "ef32574fdad8aa2854757326d596f98901c439f1ec87b777360f3940fb69c940",

}

harness_epoch.library = {
  ["cosmic.child"] = "its `start` turns a worker's plan into the unveils, binds and " ..
    "offline spawn holds it to; held alone, what it requires is not walked",
  ["cosmic.coverage"] = "the worker starts and stops the coverage a test's lines are " ..
    "counted by, whose session a test that imports it shares",
  ["cosmic.env"] = "the worker's environment, which its key holds, is read and built " ..
    "through it",
  ["cosmic.fs"] = "places each read, bind and unveil (`within`, `relative`), writes " ..
    "the worker's report, and probes the paths a module requires of the host " ..
    "(`build.host_requires`: `exists`, `is_dir`, `absolute`)",
  ["cosmic.proc"] = "names this program (`executable`), which a worker whose test does " ..
    "not declare `tool` is held from running; and finds a program a module requires " ..
    "of the host (`find`) and whether a portable artifact can start again " ..
    "(`relaunch`) for `build.host_requires`",
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
}

return harness_epoch
