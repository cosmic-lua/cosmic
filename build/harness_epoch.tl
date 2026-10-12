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

harness_epoch.epoch = "45-0b25a594" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "4405196f6511a21a7493aa3d1ee196c6318d3ceec2e0202800494c46b9502745",

  ["build.assertions"] = "a4385b7259b97e88c39510bf5147094c13225a5f79d36e8bf47945d65b4d3dcc",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_formats"] = "04816288313d1bb762dd91c4438460540653e2dcdf88759460cb36f22214e207",

  ["build.cache_names"] = "fb7a65fca2992e00d7b28fce3a8a9ae0e7027fb19b67fbe5eb9d234bf3aa9204",

  ["build.caches"] = "cf7287d6ba2af1cc8e299e9ced24863c444f58a12281181663e115058ac7b6aa",

  ["build.confine"] = "0bd545e460620886588c4f98d0ecc4c71d61215e555456d28f35f147e22ddf98",

  ["build.core_image"] = "dfc18e0e6316237ab9fb11a957df68d6217e42cffc6f2f3a767018c5313700ac",

  ["build.declared_key"] = "ec761890d092b1f7940689f96656183669ae8989828e5e14246d3368795e1a53",

  ["build.digest"] = "dccca5b63f2992d4d23213450142bdd05eee403ebaf3a4e0acf7437da72558f0",

  ["build.host_names"] = "710cff9499675bfc7c89aa7966d0a692ede499e85de2493d602444748529e64e",

  ["build.host_requires"] = "fb9f46f88cb2a16c874bf166ed9ba9b46f3e0a91e9e72a18c9ea190408c6f00b",

  ["build.key_parts"] = "ec094aee1c9558c44690eba0429337ec3048f1506be1bc3aa5672923b35ec978",

  ["build.launcher"] = "1bddaa2b691f6aa90da3256d045fc69f38d12c935e981a231841d94c2157b224",

  ["build.paths"] = "02232811d7a8e2b9e709f3a28371a51a41a48ac7de041e7caef77dd8b3b0e763",

  ["build.plural"] = "08b0e817376c03fe90737c8bb26d6ae1400dadd9d61b23d00c1b0f1051ad8771",

  ["build.shared_sqlite"] = "788981d831e67bb29bdf3e91e685e06904288d211d44fb671b8ece4c0ae00f77",

  ["build.shared_verdicts"] = "8bcb5739980af35bed92f19a435b1176c57bc42c8f6b37de09888e4f0d656b43",

  ["build.test"] = "39f9fd8f732d6f5cd28a2e594f9041322ab3ca47638e556b5f394427afa7e6ec",

  ["build.test_inputs"] = "2e68e3db31c59cfe46abed761915ca59bad14d716f17e1084c7bcee5bdad9103",

  ["build.test_policy"] = "dd962f8bd3dd7df8e2fb2009ce58908b4625471a257fd12875da0a51a265ed95",

  ["build.test_sandbox"] = "93b2ea055ba9bc3e19df81df64707459c8c9b5119273dd2f965a2fc48384f714",

  ["build.test_worker"] = "fe4a27a90c297fc3031d6e2bd991d3f8b470beee27685cc570298822c734d72c",

  ["build.this_program"] = "2a4156f49f5f2a7e997efc3d3ac8cdbeca9eb265aec7a8e591057a06b17d9d4d",

  ["build.zig_caches"] = "9f82e40f15829ffc5ca68c6b6da7a7a2dc7576e3ad5e8e041f559948abcf9f70",

  ["cmd.cosmic.main"] = "d00f469acf42d89c76c2e9ebabd40e73e20d00cb3a5ad6d9189716265fcdf9bf",

  ["cosmic.child"] = "af80c99b910fbefa3664922a099eb8fe9b43ce2e56ddc48f43d3e7564b843358",

  ["cosmic.codec"] = "2ae129ad495661877283eabf153c5056250d8bd791235397fcaa45b4c8ca5f87",

  ["cosmic.coverage"] = "079fe202231c4ae3ee642e27f6703a37850132c28c2a6d1daf50c7eb1669ac9a",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "c1f8de00010dcda4d39594f4449805218abce85f3df05f496ed87ce91e2cea90",

  ["cosmic.hash"] = "6bde9d7c791ae0ea7e8911760e146d07cadcff06223377ce6b4375128e144d0f",

  ["cosmic.proc"] = "1ff76631895d02ba131ae0a3475827dd3670fbc155bb95f85f149a0514222ee6",

  ["cosmic.project"] = "ac898dd16fd051e08c47be1dea7b86c8ea4159517e6fde765162a9f7d6678364",

  ["cosmic.sandbox"] = "aa0a16b5285a9934bf4f05914ed847c9c4e34210d24a0dd6e84e9ca0d3fb5bf4",

  ["cosmic.sandbox.policy"] = "2bf57101aceabcedd04c657d03419581a4a246bcf2dd396309199fe45b8094ca",

  ["cosmic.sqlite"] = "8a7d01a9edeaf86e7386c70e8111fbf8b57ecf54c5ff83bdf6a48da921f520d8",

  ["cosmic.string"] = "bf0e5e828de84f23aa818887e0280a3ebc844c9ca5e384c33227cb42715b8655",

  ["cosmic.test"] = "7e364de1da328bff737f0e19b648784a82fe8af68b20a84649cc7fb0770e69ce",

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
}

return harness_epoch
