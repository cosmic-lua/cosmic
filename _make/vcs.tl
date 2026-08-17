--- What `ci` judges versus what CI judges: a merge-base check.
---
--- `--make ci` gates the tree checked out RIGHT NOW. `.github/workflows/
--- pr.yml`'s `actions/checkout` uses take no `ref:`, so on a `pull_request`
--- event they check out `github.ref` -- `refs/pull/<N>/merge`, a synthetic
--- commit that exists on no branch and on no developer's machine. A branch
--- that passes `--make ci` locally can still fail once merged, and nothing
--- in the gate's own output says so. `diverged` answers "is HEAD the same
--- tree `origin/main`-relative CI would judge", and `notice` renders the
--- one line `ci` prints when the answer is no. The exit code never moves:
--- `main` advances constantly, so failing here would make `ci: PASS`
--- unreachable for nearly every branch.
local child = require("cosmic.child")

--- How long the probe waits for `git` to answer. `git` is a well-behaved,
--- locally-installed binary rather than an arbitrary candidate, but the
--- probe still bounds it: a hung `git` (a lock held by another process, a
--- credential prompt some environment triggers despite `-q`) must not hang
--- every `--make ci` run.
local PROBE_MS < const > = 10000

--- The one line `ci` prints when HEAD is not a descendant of `base_ref` --
--- exact text, no discretion. `base_sha` is truncated to 12 characters,
--- the short form `git` itself uses for a stable, readable prefix.
--- @param base_ref string The ref CI merges against, e.g. "origin/main"
--- @param base_sha string That ref's full commit sha
--- @return string The notice line
local function notice(base_ref: string, base_sha: string): string
  return "ci: HEAD is not a descendant of " .. base_ref .. " (" .. base_ref ..
  " " .. base_sha:sub(1, 12) .. "); this gate judged the branch, CI judges " ..
  "the merge"
end

--- Run one bounded `git` call and hand back its Result, or nil for any
--- failure to even get an answer -- `git` missing, the spawn itself
--- failing, or the wait timing out. Follows `_make/converge.tl`'s
--- `drives_a_build` verbatim: empty stdin so a reader gets EOF rather than
--- the terminal, a wait timeout so a hung child still loses, and `h:stop()`
--- on the failure path so a timed-out child does not leak.
--- @param argv {string} The git command and its arguments
--- @return child.Result | nil The finished child's Result, or nil
local function run_git(argv: {string}): child.Result | nil
  local h, serr = child.start(argv, {stdin = ""})
  if not (h is child.Handle) then
    local _ = serr
    return nil
  end
  local r = h:wait(PROBE_MS)
  if not (r is child.Result) then
    local _ok, _err = h:stop() -- start's partner, so the child does not leak
    return nil
  end
  return r
end

--- The ref CI merges against. Not a parameter: `diverged` answers one
--- fixed question (is HEAD what CI's `pull_request` checkout would judge),
--- and `pr.yml` merges every PR against this one ref.
local BASE_REF < const > = "origin/main"

--- Whether HEAD is NOT a descendant of `origin/main` -- the question that
--- decides whether `notice` has anything to say.
---
--- Two git calls: `rev-parse --verify -q origin/main` resolves the ref
--- (fails silently on a shallow, `origin/main`-less checkout -- the CI
--- case, since `actions/checkout` fetches `--depth=1` and only the merge
--- ref), then `merge-base --is-ancestor origin/main HEAD` asks whether
--- that commit is an ancestor of HEAD. The base sha comes back only when
--- the ref resolved AND the ancestor check failed (exit nonzero, meaning
--- "not an ancestor" -- diverged). Every other outcome -- no such ref, no
--- git repo, `git` absent, a probe timeout -- returns nil with no output;
--- a probe that cannot answer says nothing rather than guessing.
--- @return string | nil The base sha, only when HEAD has diverged from it
--- @return string Why the probe could not answer, when it returns nil
local function diverged(): string | nil, string
  local rp = run_git({"git", "rev-parse", "--verify", "-q", BASE_REF})
  if not rp then
    return nil, "git: not available"
  end
  if not rp.ok then
    return nil, BASE_REF .. ": does not resolve"
  end
  local base_sha = (rp.stdout or ""):gsub("%s+$", "")
  local mb = run_git({"git", "merge-base", "--is-ancestor", BASE_REF, "HEAD"})
  if not mb then
    return nil, "git merge-base: probe failed"
  end
  if mb.ok then
    return nil, "HEAD is a descendant of " .. BASE_REF
  end
  return base_sha
end

local record VcsModule
  BASE_REF: string
  notice: function(base_ref: string, base_sha: string): string
  diverged: function(): string | nil, string
end

local M: VcsModule = {
  BASE_REF = BASE_REF,
  notice = notice,
  diverged = diverged,
}

return M
