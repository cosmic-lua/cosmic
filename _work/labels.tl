--- The board's label vocabulary: every label the board reads or
--- writes, with the color and description it carries on GitHub, and
--- `init`, the verb that creates them. Five of them are the phases,
--- in board order; the other three are markers a phase label sits
--- beside. The phase NAMES are the model's (`model.PHASES`) — this
--- module owns only how they appear on GitHub, so a color or wording
--- change never touches the flow rules.

local gh = require("_work.github")
local model = require("_work.model")

--- One label: name, hex color, description.
local record Label
  name: string
  color: string
  description: string
end

--- Every label the board uses, phases first, in board order.
local LABELS: {Label} = {
  {name = "work:plan", color = "FBCA04",
    description = "traced to a goal, still ambiguous"},
  {name = "work:ready", color = "0E8A16",
    description = "meets the ready bar; pullable"},
  {name = "work:do", color = "1D76DB",
    description = "in implementation: claimed work and rework"},
  {name = "work:check", color = "5319E7",
    description = "PR open; awaiting a planner verdict"},
  {name = "work:land", color = "0052CC",
    description = "accepted; awaiting its merge"},
  {name = "work:epic", color = "C5DEF5",
    description = "decomposition parent; never pulled"},
  {name = "work:enable", color = "F9D0C4",
    description = "exists to make implementers succeed"},
  {name = "work:finding", color = "D93F0B",
    description = "implementer evidence; filed even at the limit"},
}

--- The labels an issue carries on GitHub: its phase, then every marker
--- it is marked with, in board order. The write half of the vocabulary
--- `model.phase_of` and `model.has_marker` read, so a filing and a
--- reading never disagree about how a marker is spelled.
--- @param issue model.Issue The issue as the board sees it
--- @return {string} Label names, phase first
local function labels_of(issue: model.Issue): {string}
  local names: {string} = {"work:" .. issue.phase}
  if issue.epic then
    names[#names + 1] = "work:epic"
  end
  if issue.finding then
    names[#names + 1] = "work:finding"
  end
  if issue.enable then
    names[#names + 1] = "work:enable"
  end
  return names
end

--- init: create the label vocabulary, idempotently. Prints its own
--- output including the trailing `work-init:` verdict line, like every
--- other board verb.
--- @param repo string "owner/name"
--- @return integer Exit code
local function cmd_init(repo: string): integer
  for _, l in ipairs(LABELS) do
    local ok, err = gh.ensure_label(repo, l.name, l.color, l.description)
    if not ok then
      io.stderr:write(l.name .. ": " .. err .. "\n")
      print("work-init: ERROR")
      return 1
    end
    print("  " .. l.name)
  end
  print("work-init: OK")
  return 0
end

local record labels
  type Label = Label
  LABELS: {Label}
  labels_of: function(issue: model.Issue): {string}
  cmd_init: function(repo: string): integer
end

local M: labels = {
  LABELS = LABELS,
  labels_of = labels_of,
  cmd_init = cmd_init,
}

return M
