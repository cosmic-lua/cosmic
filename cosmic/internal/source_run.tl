--- The file a source run (`cosmic <file.tl>`) runs, which build/dispatch.tl's `run` sets before it loads the file and
--- [`Proc.relaunch`] answers as its `script`, and the module it is, by which [`cosmic.web.assets`] knows the program a
--- `cmd/<name>/main.tl` run from its source is. It is kept here, not in cosmic.proc's record, so the tool's write stays
--- out of the public module's surface.
local record source_run
  --- The file's absolute path; nil in any other run: a built program, a test, `-e` or `--standalone`.
  mut script?: string
  --- The module the file is, by its path from the tree's root (`cmd.spam.main` for `cmd/spam/main.tl`); nil where
  --- `script` is.
  mut main?: string
end

local state: source_run = {}

return state
