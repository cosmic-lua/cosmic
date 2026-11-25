--- What [`Prompt.build`] and [`Prompt.where`] (cosmic/agent/prompt.tl) give their templates, `prompt_text.tmpl` and
--- `where_text.tmpl`:
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

  --- A tool a snippet calls, as the prompt names it.
  record CodeTool
    --- The name Host.use takes.
    name: string
    --- What it does, on one line.
    about: string
    --- The JSON schema of its input, as JSON text.
    input: string
  end

  --- What `prompt_text.tmpl` renders: each list is nil where it would be empty, so its section is left out.
  record Text
    --- The tools offered to the model.
    tools?: {Tools.Tool}
    --- The tools a snippet of run may call, by Host.use.
    code_tools?: {CodeTool}
    --- Whether a snippet of run may run programs (Host.bash).
    commands: boolean
    --- Whether run is offered.
    run: boolean
    --- The project's instructions.
    instructions?: {Instructions}
    --- The cosmic.* modules a snippet may require, a line each ([`Host.modules`]); nil where run is not offered.
    modules?: string
  end

  --- What `where_text.tmpl` renders: what follows the system prompt, past its cache mark, which differs from one
  --- session to the next.
  record Where
    --- The working directory.
    cwd: string
    --- The MCP servers a snippet may call; nil where there are none, so their section is left out.
    servers?: {Server}
  end
end

return PromptData
