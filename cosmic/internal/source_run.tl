--- The file a source run (`cosmic <file.tl>`) runs, which build/dispatch.tl's `run` sets before it loads the file and
--- [`Proc.relaunch`] answers as its `script`. It is kept here, not in cosmic.proc's record, so the tool's write stays
--- out of the public module's surface.
local record source_run
  --- The file's absolute path; nil in any other run: a built program, a test, `-e` or `--standalone`.
  mut script?: string
end

local state: source_run = {}

return state
