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

harness_epoch.epoch = "47-01fb9c1b" -- on a conflict keep neither side: set it to the bare count and run build/harness_epoch_test.tl, which prints a fresh value
harness_epoch.acknowledged = {

  ["build.artifact"] = "4405196f6511a21a7493aa3d1ee196c6318d3ceec2e0202800494c46b9502745",

  ["build.assertions"] = "9acb2c37d7991bc296e6b11c778cb770f16af73ed46e9ba35c6fbbc1a1082990",

  ["build.bind"] = "9fee5bf681f9fcb8a2e2e88ba7982b1d3546b5c438ddd598e5de1c27e12c80ec",

  ["build.cache_formats"] = "04816288313d1bb762dd91c4438460540653e2dcdf88759460cb36f22214e207",

  ["build.cache_names"] = "fb7a65fca2992e00d7b28fce3a8a9ae0e7027fb19b67fbe5eb9d234bf3aa9204",

  ["build.caches"] = "cf7287d6ba2af1cc8e299e9ced24863c444f58a12281181663e115058ac7b6aa",

  ["build.confine"] = "02b24cb79fd44d96a48fd5295e1e732a475567af3f4f7a6178e44965a18a5ac1",

  ["build.core_image"] = "dfc18e0e6316237ab9fb11a957df68d6217e42cffc6f2f3a767018c5313700ac",

  ["build.declared_key"] = "c05a627669361d1002157f9410412b7b17878d6da870fff9126d91296daf58fd",

  ["build.digest"] = "dccca5b63f2992d4d23213450142bdd05eee403ebaf3a4e0acf7437da72558f0",

  ["build.host_names"] = "710cff9499675bfc7c89aa7966d0a692ede499e85de2493d602444748529e64e",

  ["build.host_requires"] = "fb9f46f88cb2a16c874bf166ed9ba9b46f3e0a91e9e72a18c9ea190408c6f00b",

  ["build.key_parts"] = "ec094aee1c9558c44690eba0429337ec3048f1506be1bc3aa5672923b35ec978",

  ["build.launcher"] = "1bddaa2b691f6aa90da3256d045fc69f38d12c935e981a231841d94c2157b224",

  ["build.paths"] = "02232811d7a8e2b9e709f3a28371a51a41a48ac7de041e7caef77dd8b3b0e763",

  ["build.plural"] = "08b0e817376c03fe90737c8bb26d6ae1400dadd9d61b23d00c1b0f1051ad8771",

  ["build.shared_sqlite"] = "2ed2bdebb27a9e181708c02e84707853f1ada4a5dc2d8de4197f7315b5bfd4c7",

  ["build.shared_verdicts"] = "8b17d8fcbfeafafaa1159580fae06cd60ccef4e2bde5ba2a7b0f5e132ce831c1",

  ["build.test"] = "7a7bf78c56e16f5226c477b6ab3347493ea86eb8ebddb195882214cb294d2e38",

  ["build.test_inputs"] = "aac22745c999f6c5ce55647c1c5aeb599e00fa2477bc18766f78e2211c28f5b3",

  ["build.test_policy"] = "dd962f8bd3dd7df8e2fb2009ce58908b4625471a257fd12875da0a51a265ed95",

  ["build.test_sandbox"] = "93b2ea055ba9bc3e19df81df64707459c8c9b5119273dd2f965a2fc48384f714",

  ["build.test_worker"] = "5064a071c208158e6239a1b8d9e5adbd103e2d885932626365880f68484fc10e",

  ["build.this_program"] = "2abacf4586a64e2b333c431a98d16d111f0dcf67af15f34f7781d3481b35b048",

  ["build.zig_caches"] = "9f82e40f15829ffc5ca68c6b6da7a7a2dc7576e3ad5e8e041f559948abcf9f70",

  ["cmd.cosmic.main"] = "d00f469acf42d89c76c2e9ebabd40e73e20d00cb3a5ad6d9189716265fcdf9bf",

  ["cosmic.child"] = "967ec61574d5d723174d9ad374a9903c52c33c25135553dfa1ebffa44fd33f64",

  ["cosmic.codec"] = "2ae129ad495661877283eabf153c5056250d8bd791235397fcaa45b4c8ca5f87",

  ["cosmic.coverage"] = "bce5162e40c5e901b8c6438bd984ce0101a64244c586f8d6edc400461400175c",

  ["cosmic.env"] = "9ae16736e69ff2305de1aff7db0f15db90993e1e61ef786d7bf6f33528ef0057",

  ["cosmic.fs"] = "c1f8de00010dcda4d39594f4449805218abce85f3df05f496ed87ce91e2cea90",

  ["cosmic.hash"] = "6bde9d7c791ae0ea7e8911760e146d07cadcff06223377ce6b4375128e144d0f",

  ["cosmic.proc"] = "868938b76e8155ce997a702da70896009e2b8cc588b716ca49711aae3e4eac85",

  ["cosmic.project"] = "ac898dd16fd051e08c47be1dea7b86c8ea4159517e6fde765162a9f7d6678364",

  ["cosmic.sandbox"] = "47a08ecef66f739ee1e3536c90398f6ba1703630108447d6ec9f40afb31944df",

  ["cosmic.sandbox.policy"] = "325834a09f889e5d7ea7ea3f6bdf578be960fe7ef852e4896be43472b5b20308",

  ["cosmic.sqlite"] = "1a547144be43ebd753c31ac3a1fa9447390265b22523c7f5c67fe768c3766442",

  ["cosmic.string"] = "bf0e5e828de84f23aa818887e0280a3ebc844c9ca5e384c33227cb42715b8655",

  ["cosmic.test"] = "6bca8b40bb796e09774a4e9fc64741fee7ca92355eba798db1b419b4510e6b63",

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
  "0b25a594",
  "c2cc59fa",
}

return harness_epoch
