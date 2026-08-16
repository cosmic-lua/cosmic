-- The eval suite manifest: exactly seven tasks, read as data by
-- cosmic.literal and never executed (the same *_pin.tl property).
--
-- `cosmic.literal`'s grammar has no array syntax (see
-- cosmic/_literal_format.tl), so a list is a string-keyed table with
-- numeric-string keys ("1".."7") standing in for order, and a task's
-- surfaces/metrics are comma-joined strings rather than nested lists.
-- `_eval/stage.tl`'s manifest loader is the one place that unpacks
-- both conventions back into `eval_types.Manifest`.
--
-- ids, metrics, and status are pinned verbatim from the accepted
-- #1135 §3 and frozen: changing any of them is a version bump.
-- surfaces are descriptive and tunable in review without one.
return {
  version = 1,
  tasks = {
    ["1"] = {
      id = "json-cli",
      brief = "_eval/tasks/json-cli.md",
      surfaces = "flags,fs,json",
      metrics = "S,C,Y,G4",
      status = "proven",
    },
    ["2"] = {
      id = "module-tests",
      brief = "_eval/tasks/module-tests.md",
      surfaces = "string,testing,flags",
      metrics = "C,Y,G4",
      status = "proven",
    },
    ["3"] = {
      id = "sqlite-indexer",
      brief = "_eval/tasks/sqlite-indexer.md",
      surfaces = "fs,sqlite,hash",
      metrics = "S,C,Y",
      status = "proven",
    },
    ["4"] = {
      id = "child-tcp",
      brief = "_eval/tasks/child-tcp.md",
      surfaces = "child,net",
      metrics = "S,C,Y",
      status = "proven",
    },
    ["5"] = {
      id = "text-report",
      brief = "_eval/tasks/text-report.md",
      surfaces = "fs,string,time",
      metrics = "S,C,Y",
      status = "new",
    },
    ["6"] = {
      id = "multi-module-build",
      brief = "_eval/tasks/multi-module-build.md",
      surfaces = "fs,string,flags",
      metrics = "C,Y,G4",
      status = "new",
    },
    ["7"] = {
      id = "contained-task",
      brief = "_eval/tasks/contained-task.md",
      surfaces = "sandbox,fs",
      metrics = "Y,G2",
      status = "new",
    },
  },
}
