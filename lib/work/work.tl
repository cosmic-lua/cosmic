#!/usr/bin/env cosmic
-- lib/work/work.tl: work pipeline commands
--
-- subcommands (all write json to stdout):
--   labels      ensure required labels exist
--   pr-limit    exit 1 if too many open PRs
--   issues      fetch open todo issues
--   issue       pick highest priority issue from issues.json
--   doing       transition issue label from todo to doing
--   act         execute actions from check phase
--
-- env vars: WORK_REPO, WORK_MAX_PRS, WORK_INPUT, WORK_ISSUE, WORK_ACTIONS

local json = require("cosmic.json")

-- --- helpers ---

local function read_file(path: string): string
   local f = io.open(path, "r")
   if not f then return nil end
   local content = f:read("*a")
   f:close()
   return content
end

local function run(cmd: string): boolean, string
   local p = io.popen(cmd .. " 2>&1")
   if not p then return false, "popen failed" end
   local out = p:read("*a")
   local ok = p:close() as boolean
   return ok, out
end

local function require_env(name: string): string
   local v = os.getenv(name)
   if not v or v == "" then
      io.stderr:write("error: " .. name .. " not set\n")
      os.exit(1)
   end
   return v
end

local function emit_ok()
   io.write("{}")
end

-- --- subcommands ---

local commands: {string: function()}

commands = {
   labels = function()
      local repo = require_env("WORK_REPO")
      local labels = {"todo", "doing", "done", "failed", "friction"}
      for _, label in ipairs(labels) do
         os.execute("gh label create " .. label .. " --repo " .. repo .. " --force 2>/dev/null")
      end
      emit_ok()
   end,

   ["pr-limit"] = function()
      local repo = require_env("WORK_REPO")
      local max_prs = tonumber(os.getenv("WORK_MAX_PRS")) or 4

      local p = io.popen("gh pr list --repo " .. repo .. " --state open --json number 2>&1")
      if not p then
         io.stderr:write("failed to run gh pr list\n")
         os.exit(1)
      end

      local out = p:read("*a")
      p:close()

      local prs = json.decode(out) as {any}
      if not prs then
         io.stderr:write("warning: could not parse PR list\n")
         emit_ok()
         return
      end

      if #prs > max_prs then
         io.stderr:write("pr limit reached: " .. tostring(#prs) .. " open PRs (max " .. tostring(max_prs) .. ")\n")
         os.exit(1)
      end
      emit_ok()
   end,

   issues = function()
      local repo = require_env("WORK_REPO")

      local p = io.popen(table.concat({
         "gh", "issue", "list",
         "--repo", repo,
         "--label", "todo",
         "--state", "open",
         "--json", "number,title,body,url,labels,createdAt",
         "--limit", "100",
      }, " "))
      if not p then
         io.stderr:write("failed to run gh issue list\n")
         os.exit(1)
      end

      local out = p:read("*a")
      p:close()

      local issues = json.decode(out)
      if not issues then
         io.stderr:write("failed to parse issues json\n")
         os.exit(1)
      end

      io.write((json.encode(issues)))
   end,

   issue = function()
      local record Label
         name: string
      end

      local record RawIssue
         number: integer
         title: string
         body: string
         url: string
         labels: {Label}
         createdAt: string
      end

      local function get_priority(labels: {Label}): integer
         for _, label in ipairs(labels) do
            if label.name == "p0" then return 0 end
            if label.name == "p1" then return 1 end
            if label.name == "p2" then return 2 end
         end
         return 3
      end

      local input_file = require_env("WORK_INPUT")
      local input = read_file(input_file)
      if not input or input == "" then
         io.stderr:write("no input\n")
         os.exit(1)
      end

      local issues = json.decode(input) as {RawIssue}
      if not issues or #issues == 0 then
         io.stderr:write("no issues to work on\n")
         os.exit(1)
      end

      -- sort by priority then creation date
      table.sort(issues, function(a: RawIssue, b: RawIssue): boolean
         local ap = get_priority(a.labels)
         local bp = get_priority(b.labels)
         if ap ~= bp then return ap < bp end
         return a.createdAt < b.createdAt
      end)

      local selected = issues[1]

      -- generate a unique branch name
      local hash = require("cosmic.hash")
      local time = require("cosmic.time")
      local sec, nsec = time.now()
      local seed = tostring(selected.number) .. (selected.title or "") .. (selected.body or "") .. tostring(sec) .. tostring(nsec)
      local suffix = hash.sha256_hex(seed):sub(1, 8)

      local issue = {
         number = selected.number,
         title = selected.title,
         body = selected.body,
         url = selected.url,
         branch = "work/" .. tostring(selected.number) .. "-" .. suffix,
      }

      io.write((json.encode(issue)))
   end,

   doing = function()
      local issue_file = require_env("WORK_ISSUE")
      local issue_raw = read_file(issue_file)
      if not issue_raw then
         io.stderr:write("could not read " .. issue_file .. "\n")
         os.exit(1)
      end

      local issue = json.decode(issue_raw) as {string:any}
      local url = (issue.url or "") as string

      if url == "" then
         io.stderr:write("no url in issue.json\n")
         os.exit(1)
      end

      io.stderr:write("transitioning issue to doing: " .. url .. "\n")
      os.execute("gh issue edit '" .. url .. "' --remove-label todo --add-label doing")
      emit_ok()
   end,

   act = function()
      local function issue_number_from_url(url: string): string
         if not url then return nil end
         return url:match("/issues/(%d+)")
      end

      local issue_file = require_env("WORK_ISSUE")
      local actions_file = require_env("WORK_ACTIONS")

      local issue_raw = read_file(issue_file)
      if not issue_raw then
         io.stderr:write("could not read " .. issue_file .. "\n")
         os.exit(1)
      end
      local issue = json.decode(issue_raw) as {string:any}
      local issue_url = (issue.url or "") as string

      local actions_raw = read_file(actions_file)
      if not actions_raw then
         io.stderr:write("no actions.json found, updating labels as failed\n")
         run("gh issue edit '" .. issue_url .. "' --remove-label doing --add-label failed")
         os.exit(0)
      end

      local data = json.decode(actions_raw) as {string:any}
      if not data then
         io.stderr:write("could not parse " .. actions_file .. "\n")
         run("gh issue edit '" .. issue_url .. "' --remove-label doing --add-label failed")
         os.exit(1)
      end

      local verdict = (data.verdict or "unknown") as string
      local actions = (data.actions or {}) as {{string:any}}

      io.stderr:write("verdict: " .. verdict .. "\n")

      local all_ok = true
      for _, act in ipairs(actions) do
         local action_type = (act.action or "unknown") as string
         io.stderr:write("executing: " .. action_type .. "\n")

         if action_type == "comment_issue" then
            local body = (act.body or "") as string
            local ok, out = run("gh issue comment '" .. issue_url .. "' --body '" .. body:gsub("'", "'\\''") .. "'")
            if not ok then
               io.stderr:write("  failed: " .. (out or "") .. "\n")
               all_ok = false
            end

         elseif action_type == "create_pr" then
            local branch = (act.branch or "") as string
            local title = (act.title or "") as string
            local body = (act.body or "") as string

            local num = issue_number_from_url(issue_url)
            if num then
               local ref = "Closes #" .. num
               if not body:find(ref, 1, true) then
                  body = body .. "\n\n" .. ref
               end
            end

            local ok, out = run("gh pr create --head '" .. branch .. "' --title '" .. title:gsub("'", "'\\''") .. "' --body '" .. body:gsub("'", "'\\''") .. "'")
            if not ok then
               io.stderr:write("  failed: " .. (out or "") .. "\n")
               all_ok = false
            end
         else
            io.stderr:write("  skipped unknown action: " .. action_type .. "\n")
         end
      end

      local success = verdict == "pass" and all_ok
      run("gh issue edit '" .. issue_url .. "' --remove-label doing")
      if success then
         run("gh issue edit '" .. issue_url .. "' --add-label done")
      else
         run("gh issue edit '" .. issue_url .. "' --add-label failed")
      end
      emit_ok()
   end,
}

-- dispatch
local subcmd = arg[1]
if not subcmd or not commands[subcmd] then
   io.stderr:write("usage: work.tl <labels|pr-limit|issues|issue|doing|act>\n")
   os.exit(1)
end

commands[subcmd]()
