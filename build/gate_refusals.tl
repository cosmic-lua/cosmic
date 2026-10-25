--- Writes the list of the fork's refusals ([`testdata/gate/fork_refusals.json`]): the templates [`build.fork_refusals`] reads
--- from the fork's source ([`checker/tl.tl`] and the modules it uses), each with the places it is spelled and, kept from
--- the file as it was, the reason it has no program ([`lang.check_verdicts`]'s `refusal_problems`). Run it from the tree's
--- root as `bin/cosmic build/gate_refusals.tl`. A template new to the list has no reason: it needs a program in
--- [`testdata/gate/refusal_programs.txt`], put in the table by `bin/cosmic build/gate_record.tl --fork`, or a reason.
---
-- TODO: delete this script once the fork is deleted at the switch: the list is then frozen data, which
-- lang/check_verdicts_test.tl holds to the verdict table.
local Fs = require("cosmic.fs")
local ForkRefusals = require("build.fork_refusals")
local plural = require("build.plural")
local Verdicts = require("lang.check_verdicts")

local PATH <const> = "testdata/gate/fork_refusals.json"

local function main()
  local made, why = ForkRefusals.read()
  assert(made ~= nil, why)
  assert(#made.trouble == 0, table.concat(made.trouble, "\n"))
  local kept: mut {string: Verdicts.Refusal} = {}
  local there, _ = Fs.exists(PATH)
  if there == true then
    local old, trouble = Verdicts.read_refusals((assert(Fs.read(PATH))))
    assert(old ~= nil, PATH .. ": " .. tostring(trouble))
    for _, each in ipairs(old) do
      kept[each.id] = each
    end
  end
  local list: mut {Verdicts.Refusal} = {}
  for _, each in ipairs(made.refusals) do
    local before = kept[each.id]
    local reason, because = "", ""
    if before ~= nil then
      reason, because = before.reason, before.why
    end
    list[#list + 1] = {
      id = each.id, kind = each.kind, template = each.template, sites = table.concat(each.sites, " "), reason = reason, why = because,
    }
  end
  assert(Fs.write(PATH, Verdicts.write_list(list)))
  print(plural.count(#list, "template") .. " written to " .. PATH)
end

main()
