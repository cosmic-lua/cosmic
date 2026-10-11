--- The dialect every template has, whether or not it says `{{use}}`: the
--- attributes of htmx that run their value as script, read it as JSON
--- that may run, or open a socket to a URL no slot rule can follow, are
--- refused a slot (with or without a `data-` prefix).
--- `{{use htmx}}` replaces the rule for the JSON attributes with a slot that
--- takes a `SafeJson`; the rest stay. Private to [`cosmic.template`].

local types = require("cosmic.template.types")

local SCRIPT <const>: types.Rule = { class = "refused", why = "would be script: htmx runs it as JavaScript" }

local JSON <const>: types.Rule = { class = "refused",
  why = "is JSON that htmx may also run as JavaScript (with a 'js:' prefix); {{use htmx}} takes a JSON slot there " ..
    "(an Html.json value), and without it the slot is refused" }

-- A trigger's `[filter]` is a JavaScript expression, so no value is safe.
-- TODO: once cosmic.web.htmx has a SafeTrigger (templates.md open question 3),
-- the htmx dialect takes one in 'hx-trigger'; until then a data-driven
-- trigger is written as literal variants in the template.
local TRIGGER <const>: types.Rule = { class = "refused",
  why = "would be a trigger, whose '[filter]' htmx runs as JavaScript; no slot is allowed in one" }

local def: types.Def = {
  name = "html",
  targets = "2.0.11",
  exact = {
    -- Removed from the htmx docs of 2.x but still read, and evaluated by
    -- default, by htmx 2.0.11 (getHXVarsForElement).
    ["hx-vars"] = SCRIPT,
    ["hx-vals"] = JSON,
    ["hx-headers"] = JSON,
    ["hx-request"] = JSON,
    ["hx-trigger"] = TRIGGER,
    -- The legacy form of htmx-ext-ws 2.0.2, `hx-ws="connect:URL"`, which
    -- still opens a socket to a URL after a prefix no slot rule can follow.
    -- A page that loads the extension reads it whether or not the template
    -- says `{{use htmx}}`, so it is refused in every template; use ws-connect.
    ["hx-ws"] = { class = "refused",
      why = "is the legacy WebSocket form, whose URL follows 'connect:'; use ws-connect" },
  },
  prefixes = {
    -- `hx-on:click`, `hx-on::after-request`, `hx-on--after-request` and the
    -- older `hx-on`: the wildcard `hx-on` family (processHxOnWildcard).
    { prefix = "hx-on", rule = SCRIPT },
  },
  families = { "hx-" },
  plain = {},
}

return def
