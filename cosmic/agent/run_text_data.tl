--- What the description of the `run` tool (cosmic/agent/tools.tl) gives its
--- template, `run_text.tmpl`: the record it renders, apart so that the
--- template's import of it is no cycle.

local record RunTextData
  --- What `run_text.tmpl` renders.
  record Text
    --- How many KB of a program's output are shown at its start and at its end.
    kb: integer
  end
end

return RunTextData
