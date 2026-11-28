--- The loop of `cosmic agent`, as pi's agent loop: send the conversation to
--- the Messages API, show what the model says, run each tool it calls
--- and send back the results, until it ends its turn. The conversation
--- is a session's, so a chat goes on from one prompt to the next.
---
--- Each message, and each tool's output, is kept before it is shown,
--- so a run that ends in the middle of a turn loses nothing it showed:
--- [`Agent.Session.resume`] takes the turn up again where it was left.
---
---     local sign = assert(Auth.from(Env.get, "https://api.anthropic.com"))
---     local agent = Agent.new({ sign = sign, cwd = cwd, model = Agent.MODELS.sonnet })
---     agent.on = Show.text(print, print)
---     local ok, why = agent:prompt("what is in this directory?")
---     agent:close()
---
--- An agent is a value with fields: what [`Agent.new`] gives each is a
--- default to read and to change between prompts (the model, the effort,
--- the tools, the system prompt, the sandbox), and `on`, `steering` and `stopping`
--- are how a program of its own hears the agent and steers it
--- ([`Agent.Event`], [`cosmic.agent.show`]).
---
--- `before` and `after` are the agent's own policy over each tool call
--- the model makes, and each call a snippet of run makes of the agent
--- (history, store, mcp, use): `before` may block a call, with a reason the model
--- reads (or the snippet, raised), and `after` may change a result
--- before it is kept or read
--- ([`Agent.Before`], [`Agent.After`], [`cosmic.agent.check`]). They are
--- one layer, over what a call means to do: the sandbox holds what the
--- code that runs can do, and what a snippet does with no call of the
--- agent (its Host helpers, fetch through the relay) only the sandbox
--- sees.
---
---     agent.before = Check.all({ Check.only({ "run", "history" }), Check.budget({ run = 20 }) })
---
--- How the agent works, which is how pi works:
---
--- 1. the prompt joins the conversation, as the user's
--- 2. the conversation, the system prompt and the tools go to the
---    Messages API, cached as one prefix; the reply is streamed, and
---    put back together whole
--- 3. the reply is kept, then the model's text is printed, and each
---    tool it calls is run
--- 4. the results go back as the next user message, and it goes to 2
--- 5. when the model ends its turn, the prompt is done
---
--- The model's replies are kept as they came, thinking included, so
--- the next request continues them. There is no limit on turns, no
--- approval of tool calls.
---
--- A conversation has no length limit either: past 150k tokens of
--- input, the server sums up what came before into a compaction block
--- at the head of its reply (server-side compaction). cosmic agent keeps
--- and sends the whole conversation still, and the server reads it
--- from the last compaction block on, so a request after one costs
--- what the summary and the turns since cost. What the summary leaves
--- out is still in sessions.db, where Host.history in run finds it.
---
--- Each request asks the API (beta headers): to fall back to another
--- model where one refuses (server-side-fallback-2026-07-01); to say
--- why the cache missed, against the reply before
--- (cache-diagnosis-2026-04-07: requests.cache_miss); and to compact
--- (compact-2026-01-12). A credential may add its own (oauth).
---
--- Each message, and each tool's whole output, is kept in sessions.db
--- before it is shown (`cosmic docs cosmic.agent.sessions`). So a run that ends in
--- the middle of a turn loses nothing it showed, and `cosmic agent resume`
--- (or ask or chat, which go on with the newest session) takes the turn up where it was:
--- each tool call that ended gets its kept output as its result, one
--- that never ended gets a result of interrupted, not run again, and the
--- request the run was in is sent again. A turn is started again at
--- most 5 times; after that, a new prompt goes on.
---
--- Ctrl-C stops the turn: the tool running is ended, the rest are
--- given a result of stopped, and the turn is kept as stopped, not to be
--- resumed; SIGTERM ends the agent once the turn is kept. A turn the
--- model ended, refused or ran out of tokens is not resumed either.
--- In chat at a terminal, a line typed while the model works
--- steers it: it goes to the model after the tool call running, and
--- the calls after it are skipped. /later <prompt> waits for the turn
--- to end, as a prompt of its own.

local AgentMcp = require("cosmic.agent.mcp")
local Auth = require("cosmic.agent.auth")
local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Worker = require("cosmic.agent.worker")
local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local Sessions = require("cosmic.agent.sessions")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local Streamed = require("cosmic.agent.stream")
local Prompt = require("cosmic.agent.prompt")
local Tools = require("cosmic.agent.tools")

local record Agent
  --- An open reply: its status and headers, and its body read a piece at a time.
  record Reply
    --- The HTTP status.
    status: integer
    --- The reply's headers, by lowercase name.
    headers: {string: string}
    --- The next bytes of the body: nil and "" at its end, nil and why where it failed.
    read: function(): string?, string
    --- Ends the reply, its connection given back.
    close: function()
  end

  --- Opens one request: Http.open's work, so a test can stand in.
  type Send = function(url: string, opts: Http.OpenOptions): Reply?, string

  --- The most one turn ([`Agent.Session.prompt`], or `resume`) may
  --- spend: each field nil for no limit. The first limit reached ends the
  --- turn for good, the tool calls of its last reply given results of
  --- stopped, with why ([`Agent.BUDGET_SPENT`]). Tokens, cost and turns
  --- are counted when each request comes back, so the request that
  --- reaches a limit is the last; the time is counted from the turn's
  --- start, and a tool that runs past it is stopped as the user stops one. A turn resumed
  --- ([`Agent.Session.resume`]) counts from nothing again. The model
  --- reads the limits beside the turn's prompt. Once a limit is mostly
  --- spent (a quarter left, or one request), a note with the tool results
  --- tells it to finish.
  record Budget
    --- Tokens new to each request of the turn: input, cache writes and
    --- output. Cache reads are left out: each counts the whole prefix
    --- again, which `cost` weighs at its price.
    tokens?: integer
    --- USD, at [`Agent.cost`]'s prices; a model with no price counts nothing.
    cost?: number
    --- Requests: the model's turns.
    turns?: integer
    --- Seconds of wall clock.
    seconds?: number
  end

  --- What [`Agent.new`] makes an agent with. Each field but `sign` and
  --- `cwd` has a default, and each is a field of the agent after.
  record Options
    --- What signs each request (cosmic.agent.auth).
    sign: Auth.Sign
    --- Where the tools run from.
    cwd: string
    --- The model, as the API names it; the latest Opus ([`Agent.MODELS`]) by default.
    model?: string
    --- How hard it thinks: low, medium, high, xhigh or max; the model's ([`Agent.effort`]) by default.
    effort?: string
    --- The API's root; https://api.anthropic.com by default.
    base_url?: string
    --- The tools the model is offered (cosmic.agent.tools); [`Tools.all`]'s, run alone, by default.
    tools?: {Tools.Tool}
    --- The system prompt; [`Prompt.build`]'s for `cwd` and `tools` by default.
    system?: string
    --- What the system prompt is followed by, in a block past its cache mark; [`Prompt.where`]'s for `cwd` and
    --- the servers of `mcp` by default, "" for nothing. The working directory and the servers are here, not in
    --- `system`, so `system` is the same in each directory and for each set of servers, and read from the cache
    --- that a session elsewhere wrote.
    where?: string
    --- What opens a request; Http.open by default.
    send?: Send
    --- The layers the tools are held to (cosmic.agent.policy), each held stacked: only what every layer lets
    --- them do ([`Sandbox.intersect`]); nil or {} for nothing.
    sandbox?: {Sandbox.Policy}
    --- Whether a snippet may run programs (Host.bash; [`Worker.Options`] `commands`); false by default, so none runs
    --- where the sandbox holds it: on Linux, under a policy. With no sandbox, or on macOS, a snippet may still run one.
    commands?: boolean
    --- What a snippet may load code from ([`Worker.Options`] `modules`): nil is the standard library and the working
    --- directory's tree ([`Worker.MODULES`]), {} none.
    modules?: {string}
    --- The worker the run tool sends its snippets to (cosmic.agent.worker); nil for none.
    worker?: Worker.Set
    --- The MCP servers a snippet may call (cosmic.agent.mcp); nil for none.
    mcp?: AgentMcp.Set
    --- The build of cosmic, kept with each request.
    build?: string
    --- The conversation so far, each message as the API takes it; none by default.
    messages?: {Json.Value}
    --- The database the session is kept in (cosmic.agent.sessions); nil for one kept nowhere.
    db?: Sqlite.Handle
    --- The session's id in `db`.
    id?: integer
    --- How often its last turn was started again, as kept; 0 by default.
    restarts?: integer
    --- Whether its last turn ended for good, as kept; false by default, so a conversation that ends with the user's word is unfinished.
    ended?: boolean
    --- The most each turn may spend; nil for no limit.
    budget?: Budget
  end

  --- The kind of a [`Agent.TextEvent`].
  enum TextKind "text" end
  --- The kind of a [`Agent.ToolEvent`].
  enum ToolKind "tool" end
  --- The kind of a [`Agent.ResultEvent`].
  enum ResultKind "result" end
  --- The kind of a [`Agent.MessageEvent`].
  enum MessageKind "message" end
  --- The kind of a [`Agent.RequestEvent`].
  enum RequestKind "request" end

  --- The model said `text`.
  record TextEvent
    --- "text".
    kind: TextKind
    --- What it said.
    text: string
    --- True where the message that holds it also calls a tool: words on
    --- the way, not the turn's answer.
    calls?: boolean
  end

  --- The model called the tool `name` with `input`.
  record ToolEvent
    --- "tool".
    kind: ToolKind
    --- The tool's name.
    name: string
    --- What the model gave it.
    input: Tools.Object
  end

  --- The tool `name` gave `result`.
  record ResultEvent
    --- "result".
    kind: ResultKind
    --- The tool's name.
    name: string
    --- What it gave.
    result: Tools.Result
  end

  --- `message` was added to the conversation.
  record MessageEvent
    --- "message".
    kind: MessageKind
    --- The message, as the API takes it.
    message: Json.Value
  end

  --- A request to the API ended, as it was kept: its tokens, cost and time.
  record RequestEvent
    --- "request".
    kind: RequestKind
    --- The request.
    request: Sessions.Request
  end

  --- Who made a [`Agent.Call`]: the model, or a snippet's code, through
  --- its host: history, store, mcp, or a tool by [`Host.use`], each asked
  --- as a call of its own.
  enum Caller "model" "code" end

  --- The kind of a [`Agent.BlockedEvent`].
  enum BlockedKind "blocked" end

  --- The agent's `before` blocked a call `name`, for `reason`: a tool
  --- call of the model, which reads the reason as its result, or a
  --- snippet's call of the agent, which raises it in the snippet.
  record BlockedEvent
    --- "blocked".
    kind: BlockedKind
    --- The call's name ([`Agent.Call`]'s).
    name: string
    --- Who made it.
    caller: Caller
    --- What it was given.
    input: Tools.Object
    --- Why: what `before` said, or what it raised.
    reason: string
  end

  --- A call, as `before` and `after` see it: a tool call of the model,
  --- or a snippet's call of the agent.
  record Call
    --- The tool's name (a snippet's [`Host.use`] too), or the snippet's
    --- call's: history, store.get, store.put, mcp.servers, mcp.tools or
    --- mcp.call.
    name: string
    --- What it was given, as the tool gets it: read it, and change none of it.
    input: Tools.Object
    --- Who made it.
    caller: Caller
    --- The agent's working directory.
    cwd: string
    --- The session's id where it is kept; nil where it is not.
    id?: integer
    --- The paths it touches, as the tool says ([`Tools.Tool`]'s `paths`);
    --- none for a tool that says none, which may touch any (run).
    paths: {Tools.Touch}
    --- Whether the user stopped the turn.
    stopped: function(): boolean
  end

  --- What runs before each tool call the model makes, and each call a
  --- snippet makes of the agent: nil lets it run, a string blocks it,
  --- and the model reads that string as the reason. A hook that raises
  --- blocks the call, with the error as the reason, so a bug fails
  --- closed; so does a tool's `paths` that raises. A call of a tool the
  --- agent does not offer is not asked: it gets a result of not found.
  --- cosmic.agent.check makes the common ones.
  ---
  --- A snippet's call has `caller` "code", its name the call's, its
  --- input the arguments the snippet sent, unchecked, and no paths
  --- ([`Tools.Context`] `guard` lists them); one of [`Host.use`] has the
  --- tool's name, input and paths, as the model's call would. A blocked
  --- one raises "host: <name>: Blocked: <reason>" in the snippet, which
  --- the model reads only as the snippet passes it on. Such calls may
  --- come at once, from a snippet's tasks, and while its time runs.
  type Before = function(call: Call): string?

  --- What runs after each call that ran, before its result is kept and
  --- the model reads it, or a snippet reads it (where nothing is kept):
  --- nil keeps the result, a result takes its place
  --- (to redact a secret, or cut it short). What is kept is `raw` where
  --- it is set, else `text`: redact both, or give a result with no `raw`.
  --- A snippet's call gives its result as JSON text, escaped as JSON is,
  --- or its failure as an error result; the text it is given back is
  --- read as JSON where it is JSON. A hook that raises makes the result
  --- an error that says so.
  type After = function(call: Call, result: Tools.Result): Tools.Result?

  --- What an agent tells its `on` as it goes, each after what it tells
  --- of is kept: `kind` tells them apart.
  ---
  ---     agent.on = function(e: Agent.Event)
  ---       if e.kind == "text" then print(e.text) elseif e.kind == "tool" then print("> " .. e.name) end
  ---     end
  type Event = TextEvent | ToolEvent | ResultEvent | BlockedEvent | MessageEvent | RequestEvent

  --- What a model costs, in USD a million tokens: a cache read, and
  --- input and output. A cache write is 1.25 times input for five
  --- minutes, 2 times for an hour.
  record Price
    --- USD a million input tokens.
    input: number
    --- USD a million output tokens.
    output: number
    --- USD a million tokens read from the cache.
    cache_read: number
  end

  --- An agent: one conversation, how it calls the API, and how it is
  --- heard. What [`Agent.new`] gave `model`, `effort`, `sign`,
  --- `base_url`, `tools`, `system`, `send`, `sandbox`, `commands`, `worker`, `mcp` and
  --- `build` is a default: change it between prompts. `on`, `steering`
  --- and `stopping` are the caller's to set. The rest is the agent's
  --- state, kept as it goes: read it, but leave it to the agent.
  interface Session
    --- The model, as the API names it.
    mut model: string
    --- How hard it thinks: low, medium, high, xhigh or max.
    mut effort: string
    --- What signs each request (cosmic.agent.auth).
    mut sign: Auth.Sign
    --- The API's root; https://api.anthropic.com where nil.
    mut base_url?: string
    --- The tools the model is offered, read at each request: a call to
    --- one not here gets a result of not found. The system prompt is not
    --- built again when they change: set `system` to
    --- `Prompt.build(cwd, Prompt.contexts(cwd), { tools = tools })` too.
    mut tools: {Tools.Tool}
    --- The system prompt, sent as a block with a cache mark of its own.
    mut system: string
    --- What follows the system prompt, past its cache mark: the working directory and the MCP servers; "" for nothing.
    mut where: string
    --- Where the tools run from.
    cwd: string
    --- What opens a request; Http.open where nil.
    mut send?: Send
    --- The layers the tools are held to (cosmic.agent.policy), stacked as [`Sandbox.intersect`] joins them at
    --- each call; nil or {} for nothing. A call is blocked when they do not join.
    mut sandbox?: {Sandbox.Policy}
    --- Whether a snippet may run programs (Host.bash): a worker started without them is started again with them. The
    --- system prompt says whether programs run, so one changed here is told the model only by a new `system`
    --- ([`Prompt.build`] with the same `commands`).
    mut commands: boolean
    --- What a snippet may load code from ([`Agent.Options`] `modules`).
    mut modules?: {string}
    --- The worker the run tool sends its snippets to (cosmic.agent.worker); nil for none.
    mut worker?: Worker.Set
    --- The MCP servers a snippet may call (cosmic.agent.mcp); nil for none.
    mut mcp?: AgentMcp.Set
    --- The build of cosmic, kept with each request.
    mut build?: string
    --- Hears each [`Agent.Event`]; nil for none. An error it raises does not
    --- end the turn: the event is lost, and the first error is `on_failed`.
    mut on?: function(event: Event)
    --- Asked before each call ([`Agent.Before`]); nil lets each run.
    mut before?: Before
    --- Asked after each call that ran ([`Agent.After`]); nil keeps each result.
    mut after?: After
    --- The first error `on` raised; nil where it raised none. Set it to
    --- nil to hear of the next.
    mut on_failed?: string
    --- What the user sent while the model worked: given to the model
    --- after the tool call that runs, and the calls after it skipped.
    mut steering?: function(): {string}
    --- Whether the user stops the turn: asked between steps, and while a
    --- tool waits. The caller sets it; the agent sets `stopped` after.
    mut stopping?: function(): boolean
    --- The conversation, each message as the API takes it.
    messages: mut {Json.Value}
    --- The database it is kept in (cosmic.agent.sessions);
    --- nil for a session kept nowhere.
    mut db?: Sqlite.Handle
    --- Its id in `db`.
    mut id?: integer
    --- How often its last turn was started again (`resume`).
    mut restarts: integer
    --- Whether its last turn ended for good: not to be resumed.
    mut ended: boolean
    --- Whether the user stopped the last turn this run ran (`stopping`
    --- said so): the agent sets it.
    mut stopped: boolean
    --- Whether the last turn this run ran ended as its budget was spent
    --- ([`Agent.BUDGET_SPENT`]): the agent sets it.
    mut spent: boolean
    --- The id of the last reply, which the next request names for its
    --- cache diagnosis; nil until one came, or was read from where it is
    --- kept; "" where the API refused the one named, so none is named.
    mut last_reply?: string
    --- When the last request was sent ([`Clock.now_ns`]), one of `warm`'s
    --- too, where it came back whole and did not compact: the cache keeps
    --- what it read or wrote 5 minutes from then. Nil where none was, or
    --- the last failed or compacted, as `warm` would only repeat it.
    mut sent_ns?: integer
    --- The most each turn may spend ([`Agent.Budget`]); nil for no limit.
    mut budget?: Budget

    --- Adds `text` as the user's, and runs the loop until the model ends
    --- its turn: true, or false and why. Why is the API's trouble, the
    --- model's refusal, or that the user stopped it; the conversation
    --- keeps what was said before it. A blank prompt is refused, as the
    --- API refuses it.
    prompt: function(Session, text: string): boolean, string
    --- Takes the unfinished turn up again, as `prompt` runs one: a
    --- request the run ended in the middle of is sent again. At most 5
    --- times a turn: false and why after that, or where no turn is
    --- unfinished.
    resume: function(Session): boolean, string
    --- Whether the last turn is unfinished: it did not end (the model
    --- ended it, refused, ran out, or the user stopped it), and the
    --- user's (a prompt or tool results) is the last word.
    unfinished: function(Session): boolean
    --- Gives each tool call of the last message a result, where that
    --- message is the model's and its calls have none (a run ended in the
    --- middle of its calls), so the API takes the conversation again. A
    --- call whose output was kept gets that output. One that never ended
    --- gets interrupted, and is not run again.
    settle: function(Session): boolean, string
    --- Sends the conversation as the last request sent it, to the user's
    --- last word, asking for no reply: the cache keeps it 5 minutes more,
    --- for 0.05x of its input price, where writing it again costs 1.25x.
    --- Call it while the user is idle, before 5 minutes pass from
    --- `sent_ns`: true, or false and why. Nothing is sent, and true
    --- comes back, where `sent_ns` is nil.
    warm: function(Session): boolean, string
    --- Ends the worker and the MCP servers. The database is the caller's to
    --- close. Safe to call more than once; the agent is not to be
    --- prompted after.
    close: function(Session)
  end

  --- The models to choose from: the latest Opus, Sonnet and Haiku.
  record Models
    --- The latest Opus.
    opus: string
    --- The latest Sonnet.
    sonnet: string
    --- The latest Haiku: the cheapest, for many short runs such as evals.
    haiku: string
  end
  --- The models `--model` names, the latest of each.
  MODELS: Models
  --- The model, unless one is named.
  MODEL: string
  --- The effort, unless one is named, of a model [`Agent.effort`] names none for.
  EFFORT: string
  --- The effort of `model`, as the API names it, unless one is named: low for Haiku, which at medium spent a
  --- quarter more on the same evals and passed no more of them; [`Agent.EFFORT`] for the rest.
  effort: function(model: string): string
  --- What a turn that spent its budget ends with, before a colon and
  --- the limit it reached.
  BUDGET_SPENT: string
end

Agent.MODELS = { opus = "claude-opus-5-5", sonnet = "claude-sonnet-5-5", haiku = "claude-haiku-5-5" }
Agent.MODEL = "opus"
Agent.EFFORT = "medium"
-- Haiku 5.5, eval/agent with run only, 12 tasks x3 in two rounds (2026-11-25): medium $0.0013-0.0014 a run, low
-- $0.0010-0.0011, every run passed at both.
local EFFORTS <const>: {string: string} = { ["claude-haiku-5-5"] = "low" }
--- The effort of `model` unless one is named: low for Haiku, [`Agent.EFFORT`] for the rest.
function Agent.effort(model: string): string return EFFORTS[model] or Agent.EFFORT end
Agent.BUDGET_SPENT = "the turn's budget is spent"
--- How often a turn is started again before resume gives up on it.
local RESTARTS <const> = 5
--- Why a turn ended, where the user stopped it.
local STOPPED <const> = "stopped by the user"
-- The list prices, 2026-11 (`cosmic docs cosmic.agent.sessions` says how a request's cost is kept),
-- with the models `fallbacks = "default"` can serve in their place: Opus 5
-- and Opus 4.8 for Opus 5.5, Sonnet 5 for Sonnet 5.5.
--- The prices, by the model as the API names it.
local PRICES <const>: {string: Agent.Price} = {
  ["claude-opus-5-5"] = { input = 4, output = 20, cache_read = 0.2 },
  ["claude-sonnet-5-5"] = { input = 2, output = 10, cache_read = 0.1 },
  ["claude-opus-5"] = { input = 5, output = 25, cache_read = 0.5 },
  ["claude-opus-4-8"] = { input = 5, output = 25, cache_read = 0.5 },
  ["claude-sonnet-5"] = { input = 2, output = 10, cache_read = 0.2 },
  ["claude-haiku-5-5"] = { input = 0.1, output = 0.5, cache_read = 0.01 },
}

local VERSION <const> = "2026-10-21"
local MAX_TOKENS <const> = 32000

--- What an error says, where even its tostring raises.
local function told(err: any): string
  local ran, text = pcall(tostring, err)
  if ran then return text end
  return "an error that cannot be shown"
end

--- Tells `s`'s `on` of `event`, where it has one; an error it raises is
--- kept as `on_failed`, the first only, and the agent goes on.
local function tell(s: Agent.Session, event: Agent.Event)
  local on = s.on
  if on == nil then return end
  local ran, err = pcall(on, event)
  if not ran and s.on_failed == nil then s.on_failed = told(err) end
end

--- What `layers` hold stacked ([`Sandbox.intersect`]), and "": nil for no sandbox where `layers` is nil; nil and why
--- for no layer, or layers that do not join.
local function joined(layers?: {Sandbox.Policy}): Sandbox.Policy?, string
  if layers == nil then return nil, "" end
  if #layers == 0 then return nil, "the sandbox has no layer: give nil for none" end
  if #layers == 1 then return layers[1], "" end
  local policy, why = Sandbox.intersect(table.unpack(layers))
  if policy == nil then return nil, "the sandbox's layers do not join: " .. tostring(why) end
  return policy, ""
end

--- [`joined`] of `s.sandbox`, kept while its layers are the same: the worker runs on under the policy it was
--- started with, and starts again under another.
local record Joined
  from: {Sandbox.Policy}
  policy?: Sandbox.Policy
end
local JOINED: mut {Agent.Session: Joined} = setmetatable({}, { __mode = "k" })

local function held_policy(s: Agent.Session): Sandbox.Policy?, string
  local layers = s.sandbox
  local kept = JOINED[s]
  if layers ~= nil and kept ~= nil and #kept.from == #layers then
    local same = true
    for i, layer in ipairs(layers) do
      if kept.from[i] ~= layer then same = false end
    end
    if same then return kept.policy, "" end
  end
  local policy, why = joined(layers)
  if policy == nil and why ~= "" then return nil, why end
  local copy: mut {Sandbox.Policy} = {}
  for _, layer in ipairs(layers or {}) do copy[#copy + 1] = layer end
  if layers ~= nil then JOINED[s] = { from = copy, policy = policy } else JOINED[s] = nil end
  return policy, ""
end

--- The paths a call by code of `name` with `input` touches: its tool's, where it is one code may call
--- ([`Tools.for_code`]) and says; none for a host call of the agent (history, store, mcp). Nil and why where they fail.
local function code_paths(s: Agent.Session, name: string, input: Tools.Object): {Tools.Touch}?, string
  local t = Tools.find(s.tools, name)
  local paths = if t ~= nil and Tools.for_code(t) then t.paths else nil end
  if paths == nil then return {}, "" end
  local ran, found = pcall(paths, input, s.cwd)
  if not ran then return nil, "the tool's paths failed: " .. tostring(found) end
  return found, ""
end

--- What `before` of `s` says of `call`: nil to run it, or why not.
local function blocked(s: Agent.Session, call: Agent.Call): string?
  local before = s.before
  if before == nil then return nil end
  local ran, reason = pcall(before, call)
  if not ran then return "the agent's before hook failed: " .. told(reason) end
  if reason == nil then return nil end
  return told(reason)
end

--- `result` of `call`, as `after` of `s` makes it.
local function afterward(s: Agent.Session, call: Agent.Call, result: Tools.Result): Tools.Result
  local after = s.after
  if after == nil then return result end
  local ran, made = pcall(after, call, result)
  if not ran then
    return { text = "The agent's after hook failed: " .. told(made), is_error = true, changes = result.changes }
  end
  -- What the snippet changed is shown whatever the hook made of what the model reads, and the answer it gave ends the
  -- turn where the hook left the result one that ran.
  if made ~= nil and made.changes == nil then made.changes = result.changes end
  if made ~= nil and made.answer == nil and not made.is_error then made.answer = result.answer end
  return made or result
end

--- Adds `message` to `s`, and keeps it where `s` is kept: false and
--- why, and `s` as it was, where it cannot be kept.
local function add(s: Agent.Session, message: Json.Value): boolean, string
  local db, id = s.db, s.id
  if db ~= nil and id ~= nil then
    local kept, why = Sessions.add(db, id, message, s.model)
    if not kept then return false, why end
  end
  local messages = s.messages
  messages[#messages + 1] = message
  tell(s, { kind = "message", message = message })
  return true, ""
end

--- Keeps the state of `s`'s last turn: how often it was started again,
--- and whether it ended for good.
local function mark(s: Agent.Session, restarts: integer, ended: boolean): boolean, string
  local db, id = s.db, s.id
  if db ~= nil and id ~= nil then
    local kept, why = Sessions.mark(db, id, restarts, ended)
    if not kept then return false, why end
  end
  s.restarts, s.ended = restarts, ended
  return true, ""
end

--- The tool results for the tool calls of `s`'s last message,
--- where it is the model's and they went without results (a run ended in
--- the middle of its calls): so the API takes the conversation again.
--- A call whose output was kept gets it as its result; one that never
--- ended gets a result of interrupted, not run again.
local function settle(s: Agent.Session): boolean, string
  local last, _ = Json.to_object(s.messages[#s.messages])
  if last == nil or last["role"] ~= "assistant" then return true, "" end
  local content, _ = Json.to_array(last["content"])
  local results: mut {Json.Value} = {}
  for _, item in ipairs(content or {}) do
    local block, _ = Json.to_object(item)
    local id = block and block["id"]
    if block ~= nil and block["type"] == "tool_use" and id is string then
      local db, session = s.db, s.id
      local kept: Sessions.Answer? = nil
      if db ~= nil and session ~= nil then
        local found, why = Sessions.answer(db, session, id)
        if found == nil and why ~= "" then return false, why end
        kept = found
      end
      results[#results + 1] = if kept ~= nil then
        { type = "tool_result", tool_use_id = id, content = kept.text, is_error = kept.is_error }
        else
        { type = "tool_result", tool_use_id = id, content = "Interrupted: the call never ended.", is_error = true }
        end
    end
  end
  if #results == 0 then return true, "" end
  return add(s, { role = "user", content = Json.array(results) })
end

--- Keeps `result` of the call `call` of `tool` with `input` where `s`
--- is kept: the result as the model reads it, or nil and why.
local function record(s: Agent.Session, call: string, tool: string, input: Tools.Object,
                      result: Tools.Result): string?, string
  local db, id = s.db, s.id
  if db == nil or id == nil then return result.text, "" end
  local given, _ = Json.encode(input)
  local output, why = Sessions.output(db, id, { tool = tool, input = given or "{}", text = result.raw or result.text,
    is_error = result.is_error, call = call })
  if output == nil then return nil, why end
  if result.raw == nil then return result.text, "" end
  local run = Tools.find(s.tools, "run")
  if run == nil or not Tools.for_model(run) then return result.text, "" end
  -- The way to the whole comes first: a model that reads only the top fetches it again where it was served once.
  local shown = "[The whole output is kept as output " .. tostring(output) .. ": read it in run with Host.output(" ..
    tostring(output) .. ").]\n" .. result.text
  local kept, shown_why = Sessions.shown(db, output, shown)
  if not kept then return nil, shown_why end
  return shown, ""
end

--- The body of the next request of `s`.
local function request_body(s: Agent.Session): Json.Value
  local body: mut {string: Json.Value} = {
    model = s.model,
    max_tokens = MAX_TOKENS,
    tools = Tools.definitions(s.tools, s.commands),
    messages = Json.array(s.messages),
    stream = true,
    thinking = { type = "adaptive" },
    output_config = { effort = s.effort },
    cache_control = { type = "ephemeral" },
    -- Each model falls back to another on the server where it refuses
    -- and the server has one for it.
    fallbacks = "default",
    -- Past 150k tokens of input, the server sums up what came before (a
    -- compaction block), and later requests are read from there on.
    context_management = { edits = Json.array({ { type = "compact_20260112" } }) },
  }
  -- The system prompt has a cache mark of its own, as the tools have:
  -- both are read by each session whose project has the same
  -- instructions, whatever its directory and messages. The working
  -- directory comes after the mark. The API takes no empty block.
  local system: mut {Json.Value} = {}
  if s.system ~= "" then
    system[#system + 1] = { type = "text", text = s.system, cache_control = { type = "ephemeral" } }
  end
  if s.where ~= "" then system[#system + 1] = { type = "text", text = s.where } end
  if #system > 0 then body["system"] = Json.array(system) end
  -- The reply says why the cache missed, against the last reply; naming
  -- none still asks, so that the API keeps this one to name next.
  local last = s.last_reply
  body["diagnostics"] = { previous_message_id = if last ~= nil and last ~= "" then last else Json.null end }
  return body
end

local BETAS <const> = "server-side-fallback-2026-07-01,cache-diagnosis-2026-04-07,compact-2026-01-12"

local function headers(s: Agent.Session): {string: string}?, string
  local signed, why = s.sign()
  if signed == nil then return nil, why end
  local h: mut {string: string} = { ["content-type"] = "application/json", ["anthropic-version"] = VERSION }
  for k, v in pairs(signed) do h[k] = v end
  local more = signed["anthropic-beta"]
  h["anthropic-beta"] = if more ~= nil then BETAS .. "," .. more else BETAS end
  return h, ""
end

--- What `usage` costs on `model`, in USD: nil for a model with no price.
function Agent.cost(model: string, usage: {string: Json.Value}): number?
  local p = PRICES[model]
  if p == nil then return nil end
  local function n(v?: Json.Value): number return if v is number then v else 0 end end
  local input, output, read = n(usage["input_tokens"]), n(usage["output_tokens"]), n(usage["cache_read_input_tokens"])
  local five, hour = n(usage["cache_creation_input_tokens"]), 0.0
  local split, _ = Json.to_object(usage["cache_creation"])
  if split ~= nil then
    five, hour = n(split["ephemeral_5m_input_tokens"]), n(split["ephemeral_1h_input_tokens"])
  end
  return (input * p.input + output * p.output + read * p.cache_read + five * 1.25 * p.input + hour * 2 * p.input) / 1e6
end

--- What a reply's `usage` costs, in USD, where `model` sent it:
--- after a fallback, each attempt of `usage.iterations` at its own
--- model's price, the declined ones too (an upper bound: some declines
--- before any output are not billed). Nil where an attempt's model has
--- no price.
function Agent.billed(model: string, usage: {string: Json.Value}): number?
  local attempts, _ = Json.to_array(usage["iterations"])
  if attempts == nil or #attempts == 0 then return Agent.cost(model, usage) end
  local total = 0.0
  for _, a in ipairs(attempts) do
    local attempt, _ = Json.to_object(a)
    if attempt == nil then return nil end
    local named = attempt["model"]
    -- The attempt that replied is the top-level usage, whose split of
    -- cache writes (5m, 1h) an attempt may not carry.
    local priced: mut {string: Json.Value} = {}
    for k, v in pairs(attempt) do priced[k] = v end
    local split = usage["cache_creation"]
    if attempt["type"] == "fallback_message" and attempt["cache_creation"] == nil and split ~= nil then
      priced["cache_creation"] = split
    end
    local cost = Agent.cost(if named is string then named else model end, priced)
    if cost == nil then return nil end
    total = total + cost
  end
  return total
end

--- The headers that hold a credential, by name; and any named as a
--- key, a token or a secret is held one too.
local CREDENTIALS <const>: {string: boolean} = { authorization = true, ["proxy-authorization"] = true,
  ["x-api-key"] = true, cookie = true, ["set-cookie"] = true }

--- Headers, as JSON, less any that may hold a credential.
local function kept_headers(h: {string: string}): string
  local out: mut {string: Json.Value} = {}
  for k, v in pairs(h) do
    local name = k:lower()
    local secret = CREDENTIALS[name] == true or name:match("[-_]key$") ~= nil or name:match("[-_]token$") ~= nil or
      name:find("secret", 1, true) ~= nil
    if not secret then out[k] = v end
  end
  local text, _ = Json.encode(out)
  return text or "{}"
end

local function count_of(v?: Json.Value): integer?
  if v is integer then return v end
  if v is number then return math.tointeger(v) end
  return nil
end

--- Opens a request with Http.open.
local function open(url: string, opts: Http.OpenOptions): Agent.Reply?, string
  local res, why = Http.open(url, opts)
  if res == nil then return nil, tostring(why) end
  return {
    status = res.status, headers = res.headers,
    read = function(): string?, string
      local piece, failed = res:read()
      if piece == nil then return nil, tostring(failed) end
      if piece == false then return nil, "" end
      return piece, ""
    end,
    close = function() local _, _ = res:close() end,
  }, ""
end

--- Fills in `r` with what `reply` says it used, and what that cost.
local function counted(s: Agent.Session, r: Sessions.Request, reply: {string: Json.Value})
  local usage, _ = Json.to_object(reply["usage"])
  if usage == nil then return end
  r.input_tokens = count_of(usage["input_tokens"]) or 0
  r.output_tokens = count_of(usage["output_tokens"]) or 0
  r.cache_read = count_of(usage["cache_read_input_tokens"]) or 0
  local write = count_of(usage["cache_creation_input_tokens"]) or 0
  r.cache_write_5m, r.cache_write_1h = write, 0
  local split, _ = Json.to_object(usage["cache_creation"])
  if split ~= nil then
    r.cache_write_5m = count_of(split["ephemeral_5m_input_tokens"]) or 0
    r.cache_write_1h = count_of(split["ephemeral_1h_input_tokens"]) or 0
  end
  r.cost = Agent.billed(r.served or s.model, usage)
end

--- A request of `s`'s, as it is to be kept: what `call` fills in.
local function request_of(s: Agent.Session): Sessions.Request
  return { started = Clock.now_ns() // Clock.ms(1), ms = 0, model = s.model, effort = s.effort,
    max_tokens = MAX_TOKENS, betas = BETAS, system = s.system, status = 0, headers = "{}", shape = "{}",
    build = s.build }
end

--- Whether `reply` begins anew from a compaction block: a request after
--- it reads from there on, not what came before.
local function compacted(reply: {string: Json.Value}): boolean
  local content, _ = Json.to_array(reply["content"])
  for _, block in ipairs(content or {}) do
    local b, _ = Json.to_object(block)
    if b ~= nil and b["type"] == "compaction" then return true end
  end
  return false
end

--- Sends `s`'s conversation once, as `r`, which it fills in with what
--- came back: the reply, or nil and why. With `warming`, the first
--- `warming` messages alone, asking for no reply, unstreamed: a warm
--- request, whose reply the next request does not name.
local function call(s: Agent.Session, r: Sessions.Request, warming?: integer): {string: Json.Value}?, string
  local started = Clock.now_ns()
  -- Kept warm only from a request that came back whole and did not compact.
  s.sent_ns = nil
  local function failed(why: string): {string: Json.Value}?, string
    r.error, r.ms = why, (Clock.now_ns() - started) // Clock.ms(1)
    return nil, why
  end
  local db, id = s.db, s.id
  if s.last_reply == nil and db ~= nil and id ~= nil then
    s.last_reply = Sessions.last_reply(db, id)
  end
  local body = request_body(s)
  if warming ~= nil then
    local whole, _ = Json.to_object(body)
    local warm: mut {string: Json.Value} = {}
    for k, v in pairs(whole or {}) do warm[k] = v end
    local sent: mut {Json.Value} = {}
    for i, m in ipairs(s.messages) do
      if i > warming then break end
      sent[#sent + 1] = m
    end
    -- No tokens asked for, which the API takes only unstreamed: it reads
    -- the prefix (from the cache) and replies with no output.
    warm["messages"], warm["max_tokens"], warm["stream"] = Json.array(sent), 0, false
    body = warm
    r.max_tokens = 0
  end
  local text, why = Json.encode(body)
  if text == nil then return failed(tostring(why)) end
  -- The body less what is kept elsewhere: the messages, the system
  -- prompt, and the diagnostics, which name the reply before (its row's).
  local whole, _ = Json.to_object(body)
  local rest: mut {string: Json.Value} = {}
  for k, v in pairs(whole or {}) do
    if k ~= "messages" and k ~= "system" and k ~= "diagnostics" then rest[k] = v end
  end
  local shape, _ = Json.encode(rest)
  r.shape = shape or "{}"
  local send: Agent.Send = s.send or open
  local url = (s.base_url or "https://api.anthropic.com") .. "/v1/messages"
  local signed, sign_why = headers(s)
  if signed == nil then return failed(sign_why) end
  r.betas = signed["anthropic-beta"] or BETAS
  r.request_headers = kept_headers(signed)
  local got, send_why = send(url, { method = "POST", headers = signed, body = text,
    -- A stream may run long; one that stalls (no byte in two minutes,
    -- pings included) is ended.
    timeout_ns = Http.FOREVER, low_speed_bytes = 1, low_speed_ns = Clock.minutes(2),
    connect_timeout_ns = Clock.seconds(30),
    retry = { attempts = 4, statuses = { 429, 500, 502, 503, 504, 529 } } })
  if got == nil then return failed(send_why) end
  r.status, r.headers, r.request_id = got.status, kept_headers(got.headers), got.headers["request-id"]
  if got.status ~= 200 then
    local parts: mut {string} = {}
    while true do
      local chunk, _ = got.read()
      if chunk == nil then break end
      parts[#parts + 1] = chunk
    end
    got.close()
    local said = table.concat(parts)
    -- An id the API will not diagnose against (another model's, or one
    -- gone) is no reason to fail: the request goes again naming none.
    local named = s.last_reply
    if got.status == 400 and named ~= nil and named ~= "" and
        (said:find("previous_message_id", 1, true) ~= nil or said:find("diagnostics", 1, true) ~= nil) then
      s.last_reply = ""
      return call(s, r, warming)
    end
    r.reply = said
    return failed("HTTP " .. tostring(got.status) .. ": " .. said)
  end
  if warming ~= nil then
    local parts: mut {string} = {}
    while true do
      local chunk, _ = got.read()
      if chunk == nil then break end
      parts[#parts + 1] = chunk
    end
    got.close()
    local said = table.concat(parts)
    r.reply = said
    local reply, bad = Json.decode_object(said)
    if reply == nil then return failed("the reply is not a JSON object: " .. tostring(bad)) end
    r.ms = (Clock.now_ns() - started) // Clock.ms(1)
    local served, stop = reply["model"], reply["stop_reason"]
    r.served = if served is string then served else nil end
    r.stop_reason = if stop is string then stop else nil end
    counted(s, r, reply)
    s.sent_ns = started
    return reply, ""
  end
  -- What came, kept as it came where it cannot be put back together.
  local raw: mut {string} = {}
  local function read(): string?, string
    local chunk, read_why = got.read()
    if chunk == nil then return nil, read_why end
    raw[#raw + 1] = chunk
    return chunk, ""
  end
  local reply, stream_why = Streamed.message(read, function()
    if r.first_ms == nil then r.first_ms = (Clock.now_ns() - started) // Clock.ms(1) end
  end)
  got.close()
  if reply == nil then
    r.reply = table.concat(raw)
    return failed(stream_why)
  end
  local assembled, _ = Json.encode(reply)
  r.reply = assembled
  local reply_id = reply["id"]
  if reply_id is string then s.last_reply = reply_id end
  r.ms = (Clock.now_ns() - started) // Clock.ms(1)
  local served, stop = reply["model"], reply["stop_reason"]
  r.served = if served is string then served else nil end
  r.stop_reason = if stop is string then stop else nil end
  counted(s, r, reply)
  if not compacted(reply) then s.sent_ns = started end
  return reply, ""
end

--- Keeps request `r` where `s` is kept, then tells `s.on` of it.
local function keep_request(s: Agent.Session, r: Sessions.Request): boolean, string
  local db, id = s.db, s.id
  if db ~= nil and id ~= nil then
    local kept, why = Sessions.request(db, id, r)
    if kept == nil then return false, why end
  end
  tell(s, { kind = "request", request = r })
  return true, ""
end

--- Sends `s`'s conversation as its last request sent it, asking for no
--- reply, and keeps that request: true, or false and why.
local function warm(s: Agent.Session): boolean, string
  if s.sent_ns == nil then return true, "" end
  -- The last request ended at the user's last word: the API takes no
  -- conversation that ends in the model's.
  local last = #s.messages
  while last > 0 do
    local m, _ = Json.to_object(s.messages[last])
    if m ~= nil and m["role"] == "user" then break end
    last = last - 1
  end
  if last == 0 then return true, "" end
  local r = request_of(s)
  local reply, why = call(s, r, last)
  local kept, keep_why = keep_request(s, r)
  if reply == nil then return false, why end
  if not kept then return false, keep_why end
  return true, ""
end

--- Whether the user stopped the turn, by `s.stopping`.
local function stopped(s: Agent.Session): boolean
  local asked = s.stopping
  return asked ~= nil and asked()
end

--- What the user sent meanwhile, by `s.steering`, less blank lines: none
--- where nothing asks.
local function steering(s: Agent.Session): {string}
  local asked = s.steering
  if asked == nil then return {} end
  local out: mut {string} = {}
  for _, t in ipairs(asked()) do
    if not t:match("^%s*$") then out[#out + 1] = t end
  end
  return out
end

--- Ends the turn for good, so it is not resumed: `ok` and `why`.
local function finish(s: Agent.Session, ok: boolean, why: string): boolean, string
  local _, _ = mark(s, s.restarts, true)
  if not ok then return false, why end
  return true, ""
end

--- Ends the turn as the user stopped it.
local function stop(s: Agent.Session): boolean, string
  s.stopped = true
  return finish(s, false, STOPPED)
end

--- What a turn spent so far, against [`Agent.Budget`].
local record Spent
  mut tokens: integer
  mut cost: number
  mut turns: integer
  started: integer
end

--- Adds request `r` to `spent`.
local function spend(spent: Spent, r: Sessions.Request)
  spent.turns = spent.turns + 1
  -- What is new to each request: a cache read counts the whole prefix
  -- again each time, which the cost weighs at its price.
  spent.tokens = spent.tokens + (r.input_tokens or 0) + (r.output_tokens or 0) + (r.cache_write_5m or 0) +
    (r.cache_write_1h or 0)
  spent.cost = spent.cost + (r.cost or 0)
end

--- Why `s`'s turn may go no further, having spent `spent`: nil where
--- each limit of its budget is still ahead.
local function spent_why(s: Agent.Session, spent: Spent): string?
  local b = s.budget
  if b == nil then return nil end
  local limit = b.tokens
  if limit ~= nil and spent.tokens >= limit then
    return Agent.BUDGET_SPENT .. ": " .. String.counted(spent.tokens, "token") .. ", of " .. tostring(limit)
  end
  local most = b.cost
  if most ~= nil and spent.cost >= most then
    return Agent.BUDGET_SPENT .. ": " .. string.format("$%.4f, of $%.4f", spent.cost, most)
  end
  local turns = b.turns
  if turns ~= nil and spent.turns >= turns then
    return Agent.BUDGET_SPENT .. ": " .. String.counted(spent.turns, "request") .. ", of " .. tostring(turns)
  end
  local seconds = b.seconds
  local took = (Clock.monotonic_ns() - spent.started) / 1e9
  if seconds ~= nil and took >= seconds then
    return Agent.BUDGET_SPENT .. ": " .. string.format("%.1f s, of %g s", took, seconds)
  end
  return nil
end

--- `usd` as the budget notes show it: cents, or tenths of a cent below a dime.
local function dollars(usd: number): string
  return string.format(if usd ~= 0 and usd < 0.1 then "$%.4f" else "$%.2f" end, usd)
end

--- The limits of budget `b`, each with what `spent` used of it where given: "2 of 6 requests, $0.04 of $0.25".
local function budget_text(b: Agent.Budget, spent?: Spent): string
  local parts: mut {string} = {}
  local function put(used: string?, most: string)
    parts[#parts + 1] = if used ~= nil then used .. " of " .. most else most end
  end
  local tokens, cost, turns, seconds = b.tokens, b.cost, b.turns, b.seconds
  if turns ~= nil then
    put(if spent ~= nil then tostring(spent.turns) else nil end, String.counted(turns, "request"))
  end
  if tokens ~= nil then
    put(if spent ~= nil then tostring(spent.tokens) else nil end, String.counted(tokens, "token"))
  end
  if cost ~= nil then
    put(if spent ~= nil then dollars(spent.cost) else nil end, dollars(cost))
  end
  if seconds ~= nil then
    local took = if spent ~= nil then string.format("%.0f s", (Clock.monotonic_ns() - spent.started) / 1e9) else nil end
    put(took, string.format("%g s", seconds))
  end
  return table.concat(parts, ", ")
end

--- What the model reads at the start of a turn with budget `b`, so it plans to finish within it.
local function budget_note(b: Agent.Budget): string
  return "This turn's budget: " .. budget_text(b) .. ". The turn ends when the first of these is spent, " ..
    "so plan to finish within it."
end

--- What the model reads with its tool results once `s`'s turn has spent most of a limit (the next request may be
--- the last), else nil.
local function nearly_spent(s: Agent.Session, spent: Spent): string?
  local b = s.budget
  if b == nil then return nil end
  local near = false
  local function over(used: number, most?: number)
    if most ~= nil and used >= 0.75 * most then near = true end
  end
  local turns = b.turns
  if turns ~= nil and spent.turns + 1 >= turns then near = true end
  over(spent.tokens, b.tokens)
  over(spent.cost, b.cost)
  over((Clock.monotonic_ns() - spent.started) / 1e9, b.seconds)
  if not near then return nil end
  return "Budget: spent " .. budget_text(b, spent) .. ". The next reply may be the last: finish now with what " ..
    "you have."
end

--- Runs the loop from where `s` is, until the model ends its turn, or
--- its budget is spent.
local function loop(s: Agent.Session): boolean, string
  local spent: Spent = { tokens = 0, cost = 0.0, turns = 0, started = Clock.monotonic_ns() }
  local budget = s.budget
  local most_seconds = if budget ~= nil then budget.seconds else nil end
  local deadline = if most_seconds ~= nil then spent.started + math.floor(most_seconds * 1e9) else nil end
  while true do
    if stopped(s) then return stop(s) end
    local over = spent_why(s, spent)
    if over ~= nil then
      s.spent = true
      return finish(s, false, over)
    end
    local request = request_of(s)
    local reply, why = call(s, request)
    spend(spent, request)
    if reply == nil then
      local _, _ = keep_request(s, request)
      if stopped(s) then return stop(s) end
      return false, why
    end
    local content, _ = Json.to_array(reply["content"])
    local said = Json.array(content or {})
    -- An empty reply is no turn: the API takes no empty assistant message back.
    if #said > 0 then
      local added, add_why = add(s, { role = "assistant", content = said })
      if not added then
        local _, _ = keep_request(s, request)
        return false, add_why
      end
      request.seq = #s.messages
    end
    -- What a request used is worth keeping, but not worth the turn: the turn goes on without it.
    local _, _ = keep_request(s, request)
    local results: mut {Json.Value} = {}
    local sent: mut {string} = {}
    local halted, failed = false, ""
    -- Why the budget halted the turn, where it did rather than the user.
    local spent_reason: string? = nil
    local calls = false
    -- What a snippet gave by Host.reply: the turn ends with it as the model's reply.
    local reply_given: string? = nil
    for _, item in ipairs(content or {}) do
      local block, _ = Json.to_object(item)
      if block ~= nil and block["type"] == "tool_use" then calls = true end
    end
    for _, item in ipairs(content or {}) do
      local block, _ = Json.to_object(item)
      local kind = block and block["type"]
      local said_text = block and block["text"]
      local name = block and block["name"]
      if kind == "text" and said_text is string then
        tell(s, { kind = "text", text = said_text, calls = calls })
      elseif block ~= nil and kind == "tool_use" then
        local id = block["id"]
        local call_id = if id is string then id else "" end
        if not halted and failed == "" then
          if stopped(s) then
            halted = true
          else
            spent_reason = spent_why(s, spent)
            halted = spent_reason ~= nil
          end
        end
        if #sent == 0 and not halted and failed == "" then
          for _, t in ipairs(steering(s)) do sent[#sent + 1] = t end
        end
        if halted or failed ~= "" or #sent > 0 or reply_given ~= nil then
          -- Given results all the same: the API takes no tool call left without its result.
          local why_not = if halted and spent_reason ~= nil then "Stopped: " .. spent_reason .. "."
            elseif halted then "Stopped: the user stopped the turn." elseif failed ~= "" then
            "Not run: the agent could not keep what came before." elseif #sent > 0 then
            "Skipped: the user sent a message instead." else "Skipped: a snippet before it gave the answer." end
          results[#results + 1] = { type = "tool_result", tool_use_id = call_id, content = why_not, is_error = true }
        else
          local called = if name is string then name else "?" end
          local input, _ = Json.to_object(block["input"])
          local given = input or {}
          tell(s, { kind = "tool", name = called, input = given })
          -- A tool that runs past the turn's time is stopped as the user stops one.
          local asking = function(): boolean return stopped(s) or spent_why(s, spent) ~= nil end
          -- A tool for code alone is not the model's to call: it is not offered, so it is not found.
          local listed = Tools.find(s.tools, called)
          local tool = if listed ~= nil and Tools.for_model(listed) then listed else nil end
          local paths = tool and tool.paths
          local touched: {Tools.Touch} = {}
          local reason: string? = nil
          if paths ~= nil and (s.before ~= nil or s.after ~= nil) then
            local ran, found = pcall(paths, given, s.cwd)
            if ran then touched = found else reason = "the tool's paths failed: " .. told(found) end
          end
          local asked_call: Agent.Call = { name = called, input = given, caller = "model", cwd = s.cwd, id = s.id,
            paths = touched, stopped = asking }
          local result: Tools.Result
          local policy, unjoined = held_policy(s)
          if reason == nil and unjoined ~= "" then reason = unjoined end
          if reason == nil and tool ~= nil then reason = blocked(s, asked_call) end
          if reason ~= nil then
            result = { text = "Blocked: " .. reason, is_error = true }
            tell(s, { kind = "blocked", name = called, caller = "model", input = given, reason = reason })
          else
            local context: Tools.Context = { cwd = s.cwd, db = s.db, session = s.id,
              policy = policy, worker = s.worker,
              mcp = s.mcp, stopped = asking, deadline_ns = deadline, tools = s.tools,
              commands = s.commands, modules = s.modules,
              guard = if s.before == nil then nil else function(host: string, args: Tools.Object): string?
                local touches, touches_why = code_paths(s, host, args)
                local by_code: Agent.Call = { name = host, input = args, caller = "code", cwd = s.cwd, id = s.id,
                  paths = touches or {}, stopped = asking }
                local why_not = if touches == nil then touches_why else blocked(s, by_code) end
                if why_not ~= nil then
                  tell(s, { kind = "blocked", name = host, caller = "code", input = args, reason = why_not })
                end
                return why_not
              end end,
              amend = if s.after == nil then nil else function(host: string, args: Tools.Object,
                                                               answered: Tools.Result): Tools.Result
                local touches, _ = code_paths(s, host, args)
                local by_code: Agent.Call = { name = host, input = args, caller = "code", cwd = s.cwd, id = s.id,
                  paths = touches or {}, stopped = asking }
                return afterward(s, by_code, answered)
              end end }
            result = if tool ~= nil then Tools.dispatch(s.tools, called, given, context) else
              { text = Tools.unknown(s.tools, called), is_error = true } end
            if tool ~= nil then result = afterward(s, asked_call, result) end
          end
          if result.answer ~= nil then reply_given = result.answer end
          local shown, record_why = record(s, call_id, called, given, result)
          if shown == nil then failed = record_why end
          tell(s, { kind = "result", name = called, result = result })
          results[#results + 1] = { type = "tool_result", tool_use_id = call_id, content = shown or result.text,
            is_error = result.is_error }
        end
      end
    end
    if #results > 0 and not halted and failed == "" then
      for _, t in ipairs(steering(s)) do sent[#sent + 1] = t end
    end
    for _, t in ipairs(sent) do results[#results + 1] = { type = "text", text = t } end
    -- None where the budget is spent already: the turn ends next, and a later prompt would read it stale.
    local near = if #results > 0 and not halted and spent_why(s, spent) == nil then nearly_spent(s, spent) else nil end
    if near ~= nil then results[#results + 1] = { type = "text", text = near } end
    -- Each tool call gets its result before any stop, so the session stays one the API takes.
    if #results > 0 then
      local answers: Json.Value = { role = "user", content = Json.array(results) }
      local added, add_why = add(s, answers)
      if not added then
        -- Held here all the same, so this conversation stays one the API takes.
        s.messages[#s.messages + 1] = answers
        return false, add_why
      end
    end
    if failed ~= "" then return false, failed end
    if halted and spent_reason ~= nil then
      s.spent = true
      return finish(s, false, spent_reason)
    end
    if halted then return stop(s) end
    -- A snippet gave the answer (Host.reply): it is the reply, kept as the model's, and no request asks for one. Not
    -- where the user wrote meanwhile: the model reads that next.
    if reply_given ~= nil and #sent == 0 then
      local added, add_why = add(s, { role = "assistant", content = Json.array({ { type = "text", text = reply_given } }) })
      if not added then return false, add_why end
      tell(s, { kind = "text", text = reply_given, calls = false })
      return finish(s, true, "")
    end
    local stop_reason = reply["stop_reason"]
    if stop_reason == "refusal" then return finish(s, false, "the model refused") end
    if stop_reason == "max_tokens" then return finish(s, false, "the reply ran past max_tokens") end
    if #results == 0 then
      if stopped(s) then return stop(s) end
      -- What the user sent while the model wrote is the next of the turn.
      local more = steering(s)
      if #more == 0 then return finish(s, true, "") end
      local added, add_why = add(s, { role = "user", content = table.concat(more, "\n\n") })
      if not added then return false, add_why end
    end
  end
end

--- Adds `text` to `s` as the user's, and runs the loop until the model ends its turn.
local function prompt(s: Agent.Session, text: string): boolean, string
  if text:match("^%s*$") then return false, "the prompt is blank" end
  s.stopped, s.spent = false, false
  local marked, mark_why = mark(s, 0, false)
  if not marked then return false, mark_why end
  local budget = s.budget
  -- The budget goes in the turn's message, not the system prompt, so the cache holds whatever the budget.
  local content: Json.Value = if budget == nil then text else
    Json.array({ { type = "text", text = text }, { type = "text", text = budget_note(budget) } }) end
  local kept, keep_why = add(s, { role = "user", content = content })
  if not kept then return false, keep_why end
  return loop(s)
end

--- Whether `s`'s last turn is unfinished.
local function unfinished(s: Agent.Session): boolean
  local last, _ = Json.to_object(s.messages[#s.messages])
  return last ~= nil and last["role"] == "user" and not s.ended
end

--- Takes `s`'s unfinished turn up again, at most `RESTARTS` times a turn.
local function resume(s: Agent.Session): boolean, string
  if not unfinished(s) then return false, "no unfinished turn" end
  if s.restarts >= RESTARTS then
    return false, "the turn was started again " .. String.counted(s.restarts, "time") .. "; give a prompt to go on"
  end
  s.stopped, s.spent = false, false
  local marked, mark_why = mark(s, s.restarts + 1, false)
  if not marked then return false, mark_why end
  return loop(s)
end

--- Ends what the tools of `s` started.
local function close(s: Agent.Session)
  local worker = s.worker
  if worker ~= nil then Worker.close(worker) end
  local mcp = s.mcp
  if mcp ~= nil then AgentMcp.close(mcp) end
end

--- The agent [`Agent.new`] makes: [`Agent.Session`]'s fields, and its
--- methods, each the function above of its name.
local class AgentSession is Agent.Session
  mut model: string
  mut effort: string
  mut sign: Auth.Sign
  mut base_url?: string
  mut tools: {Tools.Tool}
  mut system: string
  mut where: string
  cwd: string
  mut send?: Agent.Send
  mut sandbox?: {Sandbox.Policy}
  mut commands: boolean
  mut modules?: {string}
  mut worker?: Worker.Set
  mut mcp?: AgentMcp.Set
  mut build?: string
  mut on?: function(event: Agent.Event)
  mut before?: Agent.Before
  mut after?: Agent.After
  mut on_failed?: string
  mut steering?: function(): {string}
  mut stopping?: function(): boolean
  messages: mut {Json.Value}
  mut db?: Sqlite.Handle
  mut id?: integer
  mut restarts: integer
  mut ended: boolean
  mut stopped: boolean
  mut spent: boolean
  mut last_reply?: string
  mut sent_ns?: integer
  mut budget?: Agent.Budget

  function prompt(self, text: string): boolean, string
    return prompt(self, text)
  end

  function resume(self): boolean, string
    return resume(self)
  end

  function unfinished(self): boolean
    return unfinished(self)
  end

  function settle(self): boolean, string
    return settle(self)
  end

  function warm(self): boolean, string
    return warm(self)
  end

  function close(self)
    close(self)
  end
end

--- The servers of `set` in its order; none where there is no set.
local function servers_of(set?: AgentMcp.Set): {AgentMcp.Server}
  local out: mut {AgentMcp.Server} = {}
  if set == nil then return out end
  for _, name in ipairs(set.names) do out[#out + 1] = assert(set.servers[name]) end
  return out
end

--- A new agent, from `options`: a session kept where `options.db` is, or
--- nowhere. A kept session's tool calls left without results are not settled
--- here: call `settle` before its next prompt.
---
---     local agent = Agent.new({ sign = sign, cwd = "/src", effort = "low", system = "Be brief." })
---     print(agent.model, agent.effort) -- claude-opus-5-5  low
function Agent.new(options: Agent.Options): Agent.Session
  local held: mut {Json.Value} = {}
  for _, m in ipairs(options.messages or {}) do held[#held + 1] = m end
  local tools: mut {Tools.Tool} = {}
  for _, t in ipairs(options.tools or Tools.all()) do tools[#tools + 1] = t end
  local model = options.model or Agent.MODELS.opus
  local agent: AgentSession = {
    model = model, effort = options.effort or Agent.effort(model), sign = options.sign, base_url = options.base_url,
    tools = tools,
    system = options.system or Prompt.build(options.cwd, Prompt.contexts(options.cwd),
      { tools = tools, commands = options.commands == true, loads = options.modules }),
    where = options.where or Prompt.where(options.cwd, servers_of(options.mcp)), cwd = options.cwd,
    send = options.send, sandbox = options.sandbox, commands = options.commands == true, modules = options.modules,
    worker = options.worker, mcp = options.mcp, build = options.build, messages = held, db = options.db, id = options.id,
    restarts = options.restarts or 0, ended = options.ended == true, stopped = false, spent = false,
    on = nil, before = nil, after = nil, on_failed = nil, steering = nil, stopping = nil, last_reply = nil,
    sent_ns = nil, budget = options.budget,
  }
  return agent
end

return Agent
