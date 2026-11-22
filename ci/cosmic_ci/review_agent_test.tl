local AnthropicApi = require("cosmic_ci.anthropic_api")
local GithubApi = require("cosmic_ci.github_api")
local Json = require("cosmic.json")
local ReviewAgent = require("cosmic_ci.review_agent")

--- One request a fake client was sent.
local record Sent
  method: string
  path: string
  body?: string
end

--- A Claude API client that answers each request with the next id of
--- `ids`, or with a 500 once they run out; `sent` collects the requests.
local function claude(ids: {string}): AnthropicApi.Client, {Sent}
  local sent: mut {Sent} = {}
  local function send(request: AnthropicApi.Request): AnthropicApi.Reply?, string
    sent[#sent + 1] = { method = request.method, path = request.path, body = request.body }
    local id = ids[#sent]
    if id == nil then return { status = 500, body = '{"error":{"message":"down"}}' }, "" end
    return { status = 200, body = '{"id":' .. Json.quote(id) .. '}' }, ""
  end
  return { send = send }, sent
end

--- The string the JSON `body` holds at `steps`, nil where it holds none.
local function at(body: string?, steps: {string | integer}): string?
  local object = assert(Json.decode_object(assert(body)))
  local value, _ = Json.get(object, steps)
  if value is string then return value end
  return nil
end

--- The boolean the JSON `body` holds at `steps`, nil where it holds none.
local function flag(body: string?, steps: {string | integer}): boolean?
  local object = assert(Json.decode_object(assert(body)))
  local value, _ = Json.get(object, steps)
  if value is boolean then return value end
  return nil
end

local made <const> = { "agent_1", "env_1", "vlt_1", "cred_1", "depl_1" }
local tokens <const>: ReviewAgent.Tokens = { github = "ghp_api", push = "ghp_push" }

local function test_an_apply_with_no_lock_creates_each_resource_in_order_and_fills_the_lock()
  local client, sent = claude(made)
  local lock: ReviewAgent.Lock = {}
  local applied, why = ReviewAgent.apply(client, lock, tokens)
  assert(applied, why)
  local paths: mut {string} = {}
  for _, request in ipairs(sent) do paths[#paths + 1] = request.method .. " " .. request.path end
  assert(table.concat(paths, ", ") == "POST v1/agents, POST v1/environments, POST v1/vaults, " ..
      "POST v1/vaults/vlt_1/credentials, POST v1/deployments", table.concat(paths, ", "))
  assert(lock.agent == "agent_1" and lock.environment == "env_1" and lock.vault == "vlt_1" and
      lock.credential == "cred_1" and lock.deployment == "depl_1")
end

local function test_the_agent_is_opus_with_no_web_and_no_one_asked()
  local client, sent = claude(made)
  assert(ReviewAgent.apply(client, {}, tokens))
  local agent = assert(sent[1]).body
  assert(at(agent, { "model", "id" }) == "claude-opus-5-5")
  assert(at(agent, { "tools", 1, "default_config", "permission_policy", "type" }) == "always_allow")
  assert(flag(agent, { "tools", 1, "configs", 1, "enabled" }) == false)
  assert(flag(agent, { "tools", 1, "configs", 2, "enabled" }) == false)
  assert(tostring(at(agent, { "system" })):find("ci/agents/weekly-review.md", 1, true) ~= nil)
  local environment = assert(sent[2]).body
  assert(at(environment, { "config", "networking", "type" }) == "limited")
  assert(flag(environment, { "config", "networking", "allow_package_managers" }) == false)
end

local function test_each_token_goes_only_where_it_is_used()
  local client, sent = claude(made)
  assert(ReviewAgent.apply(client, {}, tokens))
  local credential = assert(sent[4]).body
  assert(at(credential, { "auth", "secret_name" }) == "GH_TOKEN")
  assert(at(credential, { "auth", "secret_value" }) == "ghp_api")
  assert(at(credential, { "auth", "networking", "allowed_hosts", 1 }) == "api.github.com")
  assert(at(credential, { "auth", "networking", "allowed_hosts", 2 }) == nil)
  assert(flag(credential, { "auth", "injection_location", "body" }) == false)
  local deployment = assert(sent[5]).body
  assert(at(deployment, { "resources", 1, "authorization_token" }) == "ghp_push")
  assert(not assert(deployment):find("ghp_api", 1, true), "the API token is in the deployment")
  -- The agent, its environment and its vault hold neither token.
  for index = 1, 3 do
    local body = assert(assert(sent[index]).body)
    assert(not body:find("ghp_", 1, true), body)
  end
  assert(at(deployment, { "resources", 1, "checkout", "name" }) == "main")
end

local function test_the_deployment_runs_weekly_with_the_ids_and_a_hard_budget()
  local client, sent = claude(made)
  assert(ReviewAgent.apply(client, {}, tokens))
  local deployment = assert(sent[5]).body
  assert(at(deployment, { "agent" }) == "agent_1")
  assert(at(deployment, { "environment_id" }) == "env_1")
  assert(at(deployment, { "vault_ids", 1 }) == "vlt_1")
  assert(at(deployment, { "schedule", "expression" }) == "0 20 * * 6")
  assert(at(deployment, { "schedule", "timezone" }) == "America/Los_Angeles")
  assert(at(deployment, { "budget", "max_list_cost", "amount" }) == "5000")
  assert(at(deployment, { "budget", "max_list_cost", "currency" }) == "USD")
end

local function test_an_apply_with_a_lock_updates_each_resource_by_its_id()
  local client, sent = claude(made)
  local lock: ReviewAgent.Lock = { agent = "a", environment = "e", vault = "v", credential = "c", deployment = "d" }
  assert(ReviewAgent.apply(client, lock, { github = "ghp_new", push = "ghp_push2" }))
  local paths: mut {string} = {}
  for _, request in ipairs(sent) do paths[#paths + 1] = request.path end
  assert(table.concat(paths, ", ") == "v1/agents/a, v1/environments/e, v1/vaults/v, " ..
      "v1/vaults/v/credentials/c, v1/deployments/d", table.concat(paths, ", "))
  -- A credential's name and hosts cannot change: an update sends the secret alone.
  assert(at(assert(sent[4]).body, { "auth", "secret_value" }) == "ghp_new")
  assert(at(assert(sent[5]).body, { "resources", 1, "authorization_token" }) == "ghp_push2")
  assert(at(assert(sent[4]).body, { "auth", "secret_name" }) == nil)
  assert(at(assert(sent[5]).body, { "agent" }) == "a")
  assert(lock.agent == "a" and lock.deployment == "d")
end

local function test_a_credential_without_its_vault_is_made_again_in_the_new_one()
  local client, sent = claude(made)
  local lock: ReviewAgent.Lock = { agent = "a", environment = "e", credential = "c" }
  assert(ReviewAgent.apply(client, lock, tokens))
  assert(assert(sent[4]).path == "v1/vaults/vlt_1/credentials", assert(sent[4]).path)
  assert(lock.vault == "vlt_1" and lock.credential == "cred_1")
end

local function test_a_failed_apply_keeps_the_ids_it_made()
  local client = claude({ "agent_1", "env_1" })
  local lock: ReviewAgent.Lock = {}
  local applied, why = ReviewAgent.apply(client, lock, tokens)
  assert(not applied and why == "POST v1/vaults: HTTP 500: down", why)
  assert(lock.agent == "agent_1" and lock.environment == "env_1" and lock.vault == nil)
end

local function test_a_lock_reads_back_what_it_wrote()
  local lock: ReviewAgent.Lock = { agent = "a", vault = "v", deployment = "d" }
  local text = ReviewAgent.encode_lock(lock)
  assert(text == '{\n  "agent": "a",\n  "vault": "v",\n  "deployment": "d"\n}\n', text)
  local back = assert(ReviewAgent.decode_lock(text))
  assert(back.agent == "a" and back.vault == "v" and back.deployment == "d" and back.environment == nil)
  assert(ReviewAgent.encode_lock({}) == "{}\n")
  local bad, why = ReviewAgent.decode_lock('{"agent": 3}')
  assert(bad == nil and why == "agent: want a string", why)
end

--- A GitHub client that answers each request with `answer`; `sent`
--- collects the requests.
local function github(answer: string): GithubApi.Client, {GithubApi.Request}
  local sent: mut {GithubApi.Request} = {}
  local function send(request: GithubApi.Request): GithubApi.Reply?, string
    sent[#sent + 1] = request
    return { status = 201, headers = {}, body = answer }, ""
  end
  local function fetch(_url: string, _path: string): boolean, string return false, "no fetch" end
  return { send = send, fetch = fetch, base = "https://api.test" }, sent
end

local function test_a_draft_pull_request_goes_from_the_branch_into_main_as_a_draft()
  local client, sent = github('{"html_url":"https://github.test/o/r/pull/7"}')
  local url, why = ReviewAgent.draft_pr(client, "o/r", "weekly-review/2026-11-28-x", "t", "b")
  assert(url == "https://github.test/o/r/pull/7", why)
  assert(assert(sent[1]).method == "POST" and assert(sent[1]).url == "https://api.test/repos/o/r/pulls", assert(sent[1]).url)
  assert(at(assert(sent[1]).body, { "head" }) == "weekly-review/2026-11-28-x")
  assert(at(assert(sent[1]).body, { "base" }) == "main")
  assert(flag(assert(sent[1]).body, { "draft" }) == true)
end

local function test_a_branch_outside_weekly_review_is_refused_unsent()
  local client, sent = github("{}")
  for _, head in ipairs({ "main", "weekly-review/", "feature/weekly-review/x", "Weekly-review/x", " weekly-review/x" }) do
    local url, why = ReviewAgent.draft_pr(client, "o/r", head, "t", "b")
    assert(url == nil and why:find("must start with weekly-review/", 1, true) ~= nil, head .. ": " .. why)
  end
  assert(#sent == 0)
end

local function test_the_report_is_an_issue()
  local client, sent = github('{"html_url":"https://github.test/o/r/issues/8"}')
  local url, why = ReviewAgent.issue(client, "o/r", "weekly review 2026-11-28", "body")
  assert(url == "https://github.test/o/r/issues/8", why)
  assert(assert(sent[1]).url == "https://api.test/repos/o/r/issues", assert(sent[1]).url)
  assert(at(assert(sent[1]).body, { "title" }) == "weekly review 2026-11-28")
end
