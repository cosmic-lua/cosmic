--- What [`Prompt.build`] (cosmic/agent/prompt.tl) gives its template, `prompt_text.tmpl`:
--- the record it renders, apart so that the template's import of it is no
--- cycle.

local Tools = require("cosmic.agent.tools")

local record PromptData
  --- A file of project instructions as the prompt names it.
  record Instructions
    --- Its path, relative to the working directory.
    path: string
    --- What it holds.
    content: string
  end

  --- An MCP server as the prompt names it.
  record Server
    --- The name a snippet requires it by, as `mcp.<name>`.
    name: string
    --- What it is for, on one line; nil where the server says nothing.
    about?: string
  end

  --- What `prompt_text.tmpl` renders: each list is nil where it would be empty, so its section is left out.
  record Text
    --- The tools offered to the model.
    tools?: {Tools.Tool}
    --- The tools a snippet of run may call, by Host.use.
    code_tools?: {Tools.Tool}
    --- Whether bash is offered.
    bash: boolean
    --- Whether run is offered.
    run: boolean
    --- The project's instructions.
    instructions?: {Instructions}
    --- The MCP servers a snippet may call.
    servers?: {Server}
  end
end

return PromptData
