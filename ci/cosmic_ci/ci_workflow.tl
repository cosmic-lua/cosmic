--- ci.yml (JSON5 with comments) as the tests that read it take it: the
--- parts of a job they look at, as records, so a test checks a field's
--- type by reading it and no more by a cast.
local Shape = require("cosmic.shape")

local record CiWorkflow
  --- One step of a job. Its `with` and a matrix entry may hold a value
  --- that is no string, so those are read as the test needs them.
  record Step
    id?: string
    run?: string
    ["if"]?: string
    env?: {string:string}
    with?: {string:any}
  end
  record Matrix
    name?: string
    include?: {{string:any}}
  end
  record Strategy
    matrix?: CiWorkflow.Matrix
  end
  record Job
    env?: {string:string}
    steps?: {CiWorkflow.Step}
    strategy?: CiWorkflow.Strategy
  end
  record Document
    jobs: {string:CiWorkflow.Job}
  end
end

local DOCUMENT <const> = Shape.record_of("CiWorkflow.Document")

--- The document `text` holds, which raises where it is no workflow of
--- the shape the tests read.
function CiWorkflow.parse(text: string): CiWorkflow.Document
  local document, trouble = DOCUMENT:decode_into(text, { json5 = true, hash_comments = true })
  assert(document ~= nil, trouble)
  return document
end

return CiWorkflow
