--- The standing verdict on an issue's pull request: which PR closes
--- the issue, which review verdict was posted last, and whether a
--- commit followed it. Verdicts are posted on the PR while the board
--- reads the issue, so without this the rework a `work-verdict: request
--- changes` asks for is invisible from the card — `show` prints what
--- this resolves, and `move N check` refuses while an unanswered
--- request-changes stands.
---
--- The grammar half is pure and pinned by verdict_test.tl: a verdict is
--- a comment whose FIRST line is exactly `work-verdict: <kind>`, with
--- `plan-verdict:` the older spelling open PRs still carry. `standing`
--- is the network half, three reads over _work.github and nothing more
--- — this is the one PR question the board tool owns, not a general
--- PR-reading surface.

local gh = require("_work.github")

--- One conversation comment reduced to what the grammar reads.
local record Comment
  body: string
  created_at: string
end

--- A posted verdict: its kind and when it was posted.
local record Verdict
  --- "accept" | "request changes" | "reject"
  kind: string
  --- ISO 8601 UTC, as GitHub emits it
  at: string
  --- The verbatim `enable:` trailer line, or nil when the comment
  --- carries none.
  enable: string
end

--- The review state of one issue's PR. `pr` is 0 when no open pull
--- request closes the issue, and `kind` is nil when the PR carries no
--- verdict yet; the head fields describe the commit the PR points at,
--- and `answered` says whether that commit followed the verdict.
local record Standing
  pr: integer
  url: string
  kind: string
  at: string
  head_sha: string
  head_at: string
  answered: boolean
  --- The verbatim `enable:` trailer line from the standing verdict's
  --- comment, or nil when it carries none.
  enable: string
end

local KINDS: {string: boolean} = {
  ["accept"] = true,
  ["request changes"] = true,
  ["reject"] = true,
}

--- The verdict a comment carries, or nil when its first line is not
--- one. Anchored on the first line so quoting a verdict in prose is
--- not itself a verdict, and tolerant of a `\r\n` body.
--- @param comment_body string Comment body
--- @return string | nil "accept", "request changes", or "reject"
local function parse(comment_body: string): string
  local first = (comment_body or ""):match("^([^\n]*)")
  first = first:gsub("\r$", "")
  local kind = first:match("^work%-verdict: (.+)$")
  or first:match("^plan%-verdict: (.+)$")
  if kind and KINDS[kind] then
    return kind
  end
  return nil
end

--- Whether a PR body references "Closes #<issue>" (case-insensitive on
--- the verb), anchored on the full digit run so `#70` never matches a
--- search for `#7`. This is how a PR names the issue it closes, and so
--- how the board resolves an issue's PR.
--- @param pr_body string PR body
--- @param issue integer Issue number the PR must close
--- @return boolean True when the reference is present
local function closes(pr_body: string, issue: integer): boolean
  for num in (pr_body or ""):gmatch("[Cc]loses #(%d+)") do
    if tonumber(num) == issue then
      return true
    end
  end
  return false
end

--- The `enable:` trailer a verdict comment carries, or nil when none of
--- its lines match. A line must read exactly `enable: #<N>` or
--- `enable: none (<reason>)` — a reason-less `enable: none` does not
--- match, nor does the word appearing inside prose.
--- @param comment_body string Comment body
--- @return string | nil The trailer line, verbatim
local function parse_enable(comment_body: string): string
  for raw in (comment_body or ""):gmatch("([^\n]*)\n?") do
    local trailer = raw:gsub("\r$", "")
    if trailer:match("^enable: #%d+$") or trailer:match("^enable: none %(.+%)$") then
      return trailer
    end
  end
  return nil
end

--- The last verdict in a comment list, or nil when it carries none.
--- Comments arrive oldest first, so the last recognized one is the
--- standing verdict.
--- @param comments {Comment} Comments, oldest first
--- @return Verdict | nil The standing verdict
local function latest(comments: {Comment}): Verdict
  local out: Verdict = nil
  for _, c in ipairs(comments) do
    local kind = parse(c.body or "")
    if kind then
      out = {kind = kind, at = c.created_at or "", enable = parse_enable(c.body or "")}
    end
  end
  return out
end

--- Whether a commit followed a verdict. Both stamps are ISO 8601 UTC
--- in GitHub's `Z` form, which orders lexicographically; an absent
--- stamp reads as "did not follow", so an unknown head never clears a
--- standing request-changes.
--- @param verdict_at string When the verdict was posted
--- @param head_at string When the PR's head commit was committed
--- @return boolean True when the head commit is newer than the verdict
local function is_answered(verdict_at: string, head_at: string): boolean
  if verdict_at == nil or head_at == nil then
    return false
  end
  if verdict_at == "" or head_at == "" then
    return false
  end
  return head_at > verdict_at
end

--- The open pull request that closes an issue, from its timeline: a
--- `cross-referenced` entry whose source is an open PR whose body
--- closes this issue. The highest such number wins, so a reopened
--- second attempt supersedes an earlier one.
--- @param entries {gh.RawTimelineEntry} Timeline entries
--- @param issue integer The issue number
--- @return integer PR number, 0 when none qualifies
local function linked_pr(entries: {gh.RawTimelineEntry}, issue: integer): integer
  local best = 0
  for _, e in ipairs(entries) do
    local source = e.source
    local pr = source and source.issue
    if e.event == "cross-referenced" and pr and pr.pull_request ~= nil
    and (pr.state or "") == "open" and closes(pr.body or "", issue)
    and pr.number > best then
      best = pr.number
    end
  end
  return best
end

--- The refusal a move into `check` earns, or nil when nothing blocks
--- it: a `request changes` verdict stands and no commit followed it.
--- Any other state — an accept, a reject, rework already pushed, no
--- verdict, no PR — passes, because `check` is exactly where those
--- belong.
--- @param s Standing The PR's review state
--- @return string | nil The refusal message
local function blocks_check(s: Standing): string
  if s.pr == 0 or s.kind ~= "request changes" or s.answered then
    return nil
  end
  return ("PR #%d carries an unanswered 'work-verdict: request changes' "
    .. "from %s; head %s is from %s — push the rework first, or --force")
  :format(s.pr, s.at, (s.head_sha or "?"):sub(1, 7), s.head_at or "?")
end

--- The refusal a move OUT of `check` toward `do` or `plan` earns, or nil
--- when nothing blocks it: an accept (no trailer required), no PR
--- closing the issue, or the standing verdict already carries an
--- `enable:` trailer. Otherwise the countermeasure is missing and the
--- move is refused until it is added.
--- @param s Standing The PR's review state
--- @return string | nil The refusal message
local function blocks_send_back(s: Standing): string
  if s.kind == "accept" or s.pr == 0 or s.enable then
    return nil
  end
  return ("PR #%d carries a '%s' verdict with no 'enable:' trailer; add "
    .. "'enable: #<issue>' or 'enable: none (<reason>)' to the verdict "
    .. "comment, or --force"):format(s.pr, s.kind or "no verdict")
end

--- The standing verdict as `show` prints it: one headline, the head
--- commit it is judged against, and the PR's URL. The answered/
--- unanswered decoration is for `request changes` alone — it is the
--- only verdict rework can answer.
--- @param s Standing The PR's review state
--- @return string The block, without a trailing newline
local function line(s: Standing): string
  if s.pr == 0 then
    return "verdict: none (no open PR closes this issue)"
  end
  if s.kind == nil then
    return ("verdict: none yet on PR #%d\n  %s"):format(s.pr, s.url or "")
  end
  local mark = ""
  local note = "follows it"
  if s.kind == "request changes" then
    if s.answered then
      mark = " — answered"
    else
      mark = " — UNANSWERED"
      note = "predates it; the rework is not pushed"
    end
  end
  return ("verdict: %s on PR #%d at %s%s\n  head %s at %s %s\n  %s"):format(
    s.kind, s.pr, s.at, mark, (s.head_sha or "?"):sub(1, 7),
    s.head_at or "?", note, s.url or "")
end

--- The review state of an issue's PR: resolve the PR from the issue's
--- timeline, then read its head commit's date and its comments. Three
--- reads, and none of them when no PR closes the issue.
--- @param repo string "owner/name"
--- @param issue integer Issue number
--- @return Standing | nil The review state (pr = 0 when no PR is linked)
--- @return string Error message on failure
local function standing(repo: string, issue: integer): Standing, string
  local entries, terr = gh.list_issue_timeline(repo, issue)
  if entries == nil then
    return nil, terr
  end
  local number = linked_pr(entries, issue)
  if number == 0 then
    return {pr = 0, answered = false}
  end
  local pull, perr = gh.get_pull(repo, number)
  if pull == nil then
    return nil, perr
  end
  local head = pull.head
  local sha = head and head.sha
  if sha == nil then
    return nil, ("PR #%d carries no head SHA"):format(number)
  end
  local commit, cerr = gh.get_commit(repo, sha)
  if commit == nil then
    return nil, cerr
  end
  local meta = commit.commit
  local committer = meta and meta.committer
  local out: Standing = {
    pr = number,
    url = pull.html_url or "",
    head_sha = sha,
    head_at = (committer and committer.date) or "",
    answered = false,
  }
  local raw, rerr = gh.list_issue_comments(repo, number)
  if raw == nil then
    return nil, rerr
  end
  local comments: {Comment} = {}
  for _, c in ipairs(raw) do
    comments[#comments + 1] = {body = c.body or "", created_at = c.created_at or ""}
  end
  local v = latest(comments)
  if v then
    out.kind = v.kind
    out.at = v.at
    out.enable = v.enable
    out.answered = is_answered(v.at, out.head_at)
  end
  return out
end

local record verdict
  type Comment = Comment
  type Verdict = Verdict
  type Standing = Standing
  parse: function(comment_body: string): string
  closes: function(pr_body: string, issue: integer): boolean
  latest: function(comments: {Comment}): Verdict
  is_answered: function(verdict_at: string, head_at: string): boolean
  linked_pr: function(entries: {gh.RawTimelineEntry}, issue: integer): integer
  blocks_check: function(s: Standing): string
  blocks_send_back: function(s: Standing): string
  line: function(s: Standing): string
  standing: function(repo: string, issue: integer): Standing, string
end

local M: verdict = {
  parse = parse,
  closes = closes,
  latest = latest,
  is_answered = is_answered,
  linked_pr = linked_pr,
  blocks_check = blocks_check,
  blocks_send_back = blocks_send_back,
  line = line,
  standing = standing,
}

return M
