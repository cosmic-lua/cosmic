--- The test harness's epoch, which every sandboxed verdict key holds
--- (`build.declared_key`'s `epoch` part) in place of the harness's own
--- code: what every worker loads (`build.test_worker`'s `loads`), the
--- sandbox's maker (`build.test`'s `harness_own`), and the code that
--- makes a key and looks a verdict up under one (`build.test` and its
--- `key_code`). An edit to that code moves no key by itself, so a
--- comment in build/test.tl runs no test again but those that import
--- it; `epoch` moves every key, and is bumped by hand for a change that
--- can alter a pass or a fail.
---
--- `acknowledged` is the digest of that code as it was when the choice
--- was last made (`build.test`'s `harness`, over each module's source and bytecode):
--- build/harness_epoch_test.tl fails when the tree's differs, printing
--- the digest to set it to, and asks whether to bump `epoch` too: yes
--- where the change can alter what a worker is given, how it is judged
--- or how a key is computed -- a sandbox's hold or bind tightened among
--- them, a fix for soundness that moves no other part of a key, so a
--- pass a test earned through the hole does not stand after it. Either
--- way the choice is in the diff, and
--- CI's merge queue runs every
--- test (`--all`) for a change that moves this file
--- (ci/cosmic_ci/orchestration.tl's `stands`), so one recorded wrongly
--- as harmless is caught before it lands.
local record harness_epoch
  epoch: integer
  acknowledged: string
end

harness_epoch.epoch = 1
harness_epoch.acknowledged = "c3f26c60f0044643efd04a3bd8a3201f6cec1a892924f783a9c2613f47d5dd47"

return harness_epoch
