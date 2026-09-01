--- The spec bar's grammar: the one heading a spec sidecar must
--- carry — what to build — and whether a given body carries it. Also
--- the read-access half of the bar: a repository the spec's own text
--- reaches (a `github.com` URL, wherever it sits) that is not the
--- item's own `repo` field must be named under a `## Access` heading,
--- so a claim or a review that cannot reach it bounces at the bar
--- instead of after a pull.
---
--- There is no Acceptance section, because acceptance is not
--- per-item: the CI gate passing is the one definition of done every
--- item shares, and proof specific to a change rides the DIFF as a
--- test or ratchet the gate runs — a gate outlives the sidecar that
--- asked for it. The bar checks only what a machine can check
--- honestly: whether the Change decides enough is the puller's
--- judgment (a wrong call comes back as a question the item gets
--- blocked on, or as a release),
--- and optional prose sections ride along untouched. Whether a
--- declared repository is actually reachable is the same kind of
--- judgment — this only checks that the requirement is STATED.
---
--- It also names a spec's REVISION, because the sidecar is half of
--- what a review judges: the diff is the other half, and a rework
--- that answers a bounce by rewriting the spec moves this half alone.
local hash = require("cosmic.hash")

--- The headings a spec must carry.
local READY_SECTIONS < const >: {string} = {
  "Change",
}

--- The heading a spec declares its out-of-self read access under.
local ACCESS < const > = "access"

--- The lines gathered under each heading in `body`, keyed by the
--- lower-cased heading text — the section-scanning `ready_gaps` and
--- `declared_repos` both stand on. A heading counts at any level
--- ("## Change", "# change"), matched case-insensitively; a thematic
--- break (---) ends any section, so a footer appended below a break
--- belongs to no heading.
--- @param body string The spec sidecar's markdown
--- @return {string: string} Heading text -> its non-blank lines, joined with "\n"
local function sections(body: string): {string: string}
  local out: {string: string} = {}
  local current: string = nil
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local text = line:match("^#+%s+(.-)%s*$")
    if text then
      current = text:lower()
    elseif line:match("^%s*%-%-%-+%s*$") then
      current = nil
    elseif current and line:match("%S") then
      out[current] = (out[current] or "") .. line .. "\n"
    end
  end
  return out
end

--- Spec-bar lint: the gaps that keep a body from being buildable,
--- each as one readable line. A heading counts as filled only when at
--- least one non-blank line follows it before the next heading, so a
--- pasted template with hollow sections still fails.
--- @param body string The spec sidecar's markdown
--- @return {string} Gap descriptions, possibly empty
local function ready_gaps(body: string): {string}
  local filled = sections(body)
  local gaps: {string} = {}
  for _, name in ipairs(READY_SECTIONS) do
    if not (filled[name:lower()] or ""):match("%S") then
      gaps[#gaps + 1] = ("%s is missing or empty"):format(name)
    end
  end
  return gaps
end

--- The `owner/repo` pairs a `github.com` URL in `text` names —
--- `https://github.com/owner/repo`, a bare `github.com/owner/repo`,
--- or the SSH `git@github.com:owner/repo` — normalized to lowercase
--- with a trailing `.git` or sentence-ending `.` stripped. The one
--- signal `reached_repos` and `declared_repos` both read: a URL is
--- unambiguous, where a bare `owner/repo` token is indistinguishable
--- from a module path (`cosmic/fs`) or a doc path (`docs/decisions`)
--- and would false-positive on nearly every spec in this repo.
--- @param text string Any spec text
--- @return {string} Repo slugs, in first-seen order, may repeat
local function github_urls(text: string): {string}
  local out: {string} = {}
  for owner, name in text:gmatch("github%.com[:/]([%w%-%.]+)/([%w%-%._]+)") do
    name = name:gsub("%.git$", ""):gsub("%.$", "")
    out[#out + 1] = (owner .. "/" .. name):lower()
  end
  return out
end

--- The repositories a spec's OWN text reaches, wherever a
--- `github.com` URL sits in it — a command in `## Change`, a citation
--- in `## Evidence`, a fixture in `## Acceptance`. This is "reaches",
--- not "needs": the item's own `repo` and any self-mention are not
--- filtered out here, because that judgment needs the item — see
--- `_work.gitgate.undeclared_repos`.
--- @param body string The spec sidecar's markdown
--- @return {string} Repo slugs, deduplicated, in first-seen order
local function reached_repos(body: string): {string}
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for _, slug in ipairs(github_urls(body)) do
    if not seen[slug] then
      seen[slug] = true
      out[#out + 1] = slug
    end
  end
  return out
end

--- The repositories a spec's `## Access` section names as read access
--- it needs, cheaply and loosely: a `github.com` URL there, or a bare
--- `owner/repo` mention — the section exists to be written once and
--- read, not parsed strictly, so a spurious extra entry costs nothing
--- (it can only make a real reference look MORE declared, never less).
--- @param body string The spec sidecar's markdown
--- @return {string: boolean} Declared repo slugs, lower-cased
local function declared_repos(body: string): {string: boolean}
  local text = sections(body)[ACCESS] or ""
  local out: {string: boolean} = {}
  for _, slug in ipairs(github_urls(text)) do
    out[slug] = true
  end
  for owner, name in text:gmatch("([%w%-%.]+)/([%w%-%._]+)") do
    out[(owner .. "/" .. (name:gsub("%.$", ""))):lower()] = true
  end
  return out
end

--- The revision of a spec sidecar: a content digest of its body, so
--- two readings of the same text are the same revision and any edit is
--- a different one. A body of "" — an item with no sidecar — hashes to
--- a stable constant, which is the right answer rather than a case to
--- special-case: an item that has never had a spec has not changed one.
--- @param body string The spec sidecar's markdown, "" when it has none
--- @return string The revision, 64 lowercase hex characters
local function revision(body: string): string
  return hash.sha256_hex(body)
end

local record spec
  READY_SECTIONS: {string}
  ready_gaps: function(body: string): {string}
  reached_repos: function(body: string): {string}
  declared_repos: function(body: string): {string: boolean}
  revision: function(body: string): string
end

local M: spec = {
  READY_SECTIONS = READY_SECTIONS,
  ready_gaps = ready_gaps,
  reached_repos = reached_repos,
  declared_repos = declared_repos,
  revision = revision,
}

return M
